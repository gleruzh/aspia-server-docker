#!/usr/bin/env bash
#
# tests/podman.sh: tests the Quadlet unit in podman/ on a Linux machine with Podman and systemd,
# for both install variants from podman/README.md.
#
#   tests/podman.sh [system|rootless|guard|relay|all]      (default: all)
#
# For each variant it installs the files as the README says (the unit's Image= line is replaced by
# ASPIA_TEST_IMAGE, the one edit the README asks for; the test asserts that nothing else differs),
# runs the Quadlet generator in dry-run mode, starts the service, and checks: the unit is generated
# without errors; the service starts and the container becomes healthy ("podman healthcheck run"
# succeeds); the unit is wanted by default.target (so it starts at boot); "systemctl stop" finishes
# quickly and cleanly; the keys are the same after "systemctl restart"; and systemd restarts the
# container after it was killed. It also applies the Network=host edit that the unit file describes
# in a comment and checks it. Both units: the container has exactly the capabilities of AddCapability=,
# no-new-privileges, a read-only root filesystem and the --pids-limit of PodmanArgs=.
# Everything it installed is removed at the end, and nothing it did not install is touched.
#
# "guard" checks that safety: it creates a volume and a unit that look like a user's own install,
# runs the test (which must refuse to start) and asserts that both are still there.
#
# "relay" tests the Relay-only unit aspia-relay.container, system-wide and rootless: it starts a
# Router with ASPIA_ROLE=router (plain "podman run" as root, port 8063 published on this machine),
# installs the relay unit as podman/README.md says, pointed at the Router's address and key, and
# checks: the generator, the service becomes healthy (connected), the Router logs the Relay's key
# pool, the unit is wanted by default.target, and "systemctl stop" is quick and clean. The
# system-wide Relay uses this machine's own address (through the published port); the rootless one
# uses the Router container's bridge address, because rootless Podman 5 (pasta) gives a container
# the host's own address, so the host's address would lead the Relay back to itself.
#
# THIS INSTALLS A SERVICE AND USES PORTS 8060-8070 AND THE VOLUMES systemd-aspia-config/systemd-aspia-data
# (relay: systemd-aspia-relay-config, and a container named aspia-podman-test-router).
# Run it only on a throwaway machine (a CI runner, a VM). It refuses to start when the unit, the
# container, the volumes or any of the ports already exist.
#
# Environment:
#   ASPIA_TEST_IMAGE    (required) the image to test. Used as it is when Podman already has it;
#                       else taken from Docker's image store ("docker save | podman load"; not for
#                       a digest reference, which Docker cannot save); else pulled.
#   ASPIA_TEST_USER     rootless user when this script runs as root (default aspia-podman-test;
#                       created, and removed again, if it does not exist). An existing user is never
#                       modified: it must already have ranges in /etc/subuid and /etc/subgid. When
#                       run as a normal user, that user is the rootless user (same requirement).
# The system-wide variant needs root, or sudo without a password. ss (iproute2) is required.

set -euo pipefail

cd "$(dirname "$0")/.."

readonly REPO="${PWD}"
readonly UNIT=aspia-server.service
readonly CONTAINER=aspia-server
readonly RELAY_UNIT=aspia-relay.service
readonly RELAY_CONTAINER=aspia-relay
readonly TEST_ROUTER=aspia-podman-test-router
readonly SERVER_FILES=(aspia-server.container aspia-config.volume aspia-data.volume aspia-server.env)
readonly SERVER_VOLUMES=(systemd-aspia-config systemd-aspia-data)
readonly RELAY_FILES=(aspia-relay.container aspia-relay-config.volume aspia-relay.env)
readonly RELAY_VOLUMES=(systemd-aspia-relay-config)
readonly PORTS=(8060 8061 8062 8063 8065 8070)
readonly RELAY_PORTS=(8063 8070)
readonly STOP_LIMIT=20          # seconds: "systemctl stop" must finish well inside systemd's 70 s default
readonly HEALTHY_TIMEOUT=240    # seconds; generous, because CI runners and emulation are slow

MODE=""                         # system or rootless: set per variant
RL_USER=""
RL_HOME=""
RL_RUNTIME=""
UNIT_DIR=""
VARIANT_LABEL=""
GENERATOR_ARGS=()
CREATED_USER=0
ENABLED_LINGER=0
OWNED_DIR=""                    # the unit directory this run installs into; set only after check_free passed
RELAY_OWNED_DIR=""              # the same for the relay variant (check_free_relay)
CREATED_TAGS=()                 # image names this run added to the Podman store (and so removes again)
ROOT_TAGS=()                    # the same for root's store, for the relay variant's Router
STOPLOG=""                      # temporary file of check_clean_stop: removed there, and on exit if a check failed first

say() { printf '\n=== %s\n' "$*"; }
ok() { printf 'ok - %s\n' "$*"; }
die() {
    printf 'FAIL - %s\n' "$*" >&2
    dump_diagnostics || true
    exit 1
}

# quiet: runs a command, hides its output and ignores its failure (cleanup).
quiet() { "$@" > /dev/null 2>&1 || true; }

as_root() {
    if ((EUID == 0)); then "$@"; else sudo -n "$@"; fi
}

as_rootless_user() {
    local -a envs=("HOME=${RL_HOME}" "XDG_RUNTIME_DIR=${RL_RUNTIME}" "DBUS_SESSION_BUS_ADDRESS=unix:path=${RL_RUNTIME}/bus")
    if [[ "$(id -un)" == "${RL_USER}" ]]; then
        env "${envs[@]}" "$@"
    else
        as_root runuser -u "${RL_USER}" -- env "${envs[@]}" "$@"
    fi
}

# run: executes a command as root (system variant) or as the rootless user (rootless variant).
run() {
    if [[ "${MODE}" == system ]]; then as_root "$@"; else as_rootless_user "$@"; fi
}

sctl() {
    if [[ "${MODE}" == system ]]; then run systemctl "$@"; else run systemctl --user "$@"; fi
}

# wait_until TIMEOUT COMMAND...: polls until the command succeeds; fails after TIMEOUT seconds.
wait_until() {
    local deadline=$((SECONDS + $1))
    shift
    until "$@"; do
        ((SECONDS < deadline)) || return 1
        sleep 2
    done
}

dump_diagnostics() {
    [[ -n "${MODE}" ]] || return 0
    echo "--- diagnostics (${MODE}) ---"
    sctl status "${UNIT}" --no-pager -l 2>&1 | tail -n 30 || true
    run podman ps -a 2>&1 || true
    run podman logs --tail 40 "${CONTAINER}" 2>&1 || true
    if [[ "${MODE}" == system ]]; then
        as_root journalctl -u "${UNIT}" --no-pager -n 40 2>&1 || true
    fi
    if [[ -n "${RELAY_OWNED_DIR}" ]]; then
        sctl status "${RELAY_UNIT}" --no-pager -l 2>&1 | tail -n 30 || true
        run podman logs --tail 40 "${RELAY_CONTAINER}" 2>&1 || true
        as_root podman logs --tail 40 "${TEST_ROUTER}" 2>&1 || true
    fi
}

find_generator() {
    local candidate
    for candidate in \
        /usr/lib/systemd/system-generators/podman-system-generator \
        /usr/libexec/podman/quadlet \
        /usr/lib/podman/quadlet \
        /usr/libexec/podman/quadlet-generator; do
        if [[ -x "${candidate}" ]]; then
            echo "${candidate}"
            return 0
        fi
    done
    return 1
}

# key_digest: a digest of every key line in router.conf and relay.conf. The test fails when
# there is none: an empty digest would make "same keys" trivially true.
key_digest() {
    local conf keys
    conf="$(run podman exec "${CONTAINER}" cat /etc/aspia/router.conf /etc/aspia/relay.conf)" || die "cannot read router.conf/relay.conf in the container"
    keys="$(grep -E '^(private_key|public_key|seed_key)=' <<< "${conf}" | sort || true)"
    [[ -n "${keys}" ]] || die "no key lines found in router.conf/relay.conf"
    printf '%s\n' "${keys}" | sha256sum | cut -d' ' -f1
}

# is_healthy [CONTAINER]: the container's healthcheck passes and its status is healthy.
is_healthy() {
    local container="${1:-${CONTAINER}}"
    run podman healthcheck run "${container}" > /dev/null 2>&1 \
        && [[ "$(run podman inspect --format '{{.State.Health.Status}}' "${container}" 2> /dev/null)" == healthy ]]
}

wait_healthy() { wait_until "${HEALTHY_TIMEOUT}" is_healthy; }

# check_hardening UNIT_FILE CONTAINER: the running container has what the shipped unit asks for.
check_hardening() {
    local unit=$1 container=$2 cap mask=0 caps pids status host
    local -A bit=([CHOWN]=0 [DAC_OVERRIDE]=1 [KILL]=5 [SETGID]=6 [SETUID]=7)
    caps="$(sed -n 's/^AddCapability=//p' "podman/${unit}")"
    pids="$(sed -n 's/^PodmanArgs=--pids-limit=//p' "podman/${unit}")"
    [[ -n "${caps}" && -n "${pids}" ]] || die "podman/${unit} has no AddCapability= or PodmanArgs=--pids-limit= line"
    for cap in ${caps}; do
        [[ -n "${bit[${cap}]:-}" ]] || die "check_hardening does not know ${cap}"
        mask=$((mask | (1 << ${bit[${cap}]})))
    done
    status="$(run podman exec "${container}" grep -E '^(CapEff|NoNewPrivs):' /proc/1/status | tr -s ' \t\n' ' ')"
    [[ "${status}" == "CapEff: $(printf '%016x' "${mask}") NoNewPrivs: 1 " ]] || die "${container}: PID 1 has '${status}', expected CapEff $(printf '%016x' "${mask}") (${caps}) and NoNewPrivs 1"
    host="$(run podman inspect --format '{{.HostConfig.ReadonlyRootfs}} {{.HostConfig.PidsLimit}}' "${container}")"
    [[ "${host}" == "true ${pids}" ]] || die "${container}: ReadonlyRootfs and PidsLimit are '${host}', expected 'true ${pids}'"
    if run podman exec "${container}" touch /usr/bin/aspia_start 2> /dev/null; then die "${container}: the root filesystem is writable"; fi
    ok "${container}: capabilities ${caps} only, no-new-privileges, read-only root, pids limit ${pids} (pids.max $(run podman exec "${container}" cat /sys/fs/cgroup/pids.max 2>&1))"
}

# restart_seen N: systemd has restarted the unit more than N times.
restart_seen() { (($(sctl show "${UNIT}" -p NRestarts --value) > $1)); }

pid_gone() { ! kill -0 "$1" 2> /dev/null; }

user_gone() { ! loginctl show-user "${RL_USER}" > /dev/null 2>&1; }

# check_free CONTAINER "VOLUMES" "FILES" PORTS...: refuses to go on when any of them already exists
# (volumes and files are space-separated lists; the files are in UNIT_DIR).
check_free() {
    local container=$1 port volume file
    local -a volumes files
    read -ra volumes <<< "$2"
    read -ra files <<< "$3"
    shift 3
    for port in "$@"; do
        if ss -Hltun | awk -v p=":${port}" '$5 ~ p"$" {found=1} END {exit !found}'; then
            die "port ${port} is already in use on this machine; run this test on a throwaway machine"
        fi
    done
    run podman container exists "${container}" 2> /dev/null && die "a container named ${container} already exists"
    for volume in "${volumes[@]}"; do
        run podman volume exists "${volume}" 2> /dev/null && die "volume ${volume} already exists"
    done
    for file in "${files[@]}"; do
        [[ ! -e "${UNIT_DIR}/${file}" ]] || die "${UNIT_DIR}/${file} already exists"
    done
}

# load_image RUNNER TAGS: makes ASPIA_TEST_IMAGE exist in the Podman store RUNNER (run: the current
# variant's, or as_root: root's) works on, and appends the name to the array TAGS when this run
# added it. Only names this run added are removed later, never a user's image.
load_image() {
    local runner=$1
    local -n tags=$2
    if "${runner}" podman image exists "${ASPIA_TEST_IMAGE}"; then
        return 0
    elif [[ "${ASPIA_TEST_IMAGE}" != *@* ]] && command -v docker > /dev/null \
        && docker image inspect "${ASPIA_TEST_IMAGE}" > /dev/null 2>&1; then
        docker save "${ASPIA_TEST_IMAGE}" | "${runner}" podman load -q > /dev/null || die "docker save | podman load failed"
    else
        "${runner}" podman pull -q "${ASPIA_TEST_IMAGE}" > /dev/null || die "could not pull ${ASPIA_TEST_IMAGE}"
    fi
    tags+=("${ASPIA_TEST_IMAGE}")
    "${runner}" podman image exists "${ASPIA_TEST_IMAGE}" || die "${ASPIA_TEST_IMAGE} is not in Podman's store after loading"
}

# set_variant_paths MODE: sets MODE, UNIT_DIR, GENERATOR_ARGS and VARIANT_LABEL (and prepares the
# rootless user).
set_variant_paths() {
    MODE="$1"
    GENERATOR_ARGS=(--dryrun)
    if [[ "${MODE}" == system ]]; then
        VARIANT_LABEL="system-wide (root)"
        UNIT_DIR=/etc/containers/systemd
    else
        VARIANT_LABEL="rootless"
        setup_rootless_user
        UNIT_DIR="${RL_HOME}/.config/containers/systemd"
        GENERATOR_ARGS+=(--user)
    fi
}

# install_unit CONTAINER_FILE VOLUME_FILES...: installs podman/<files> and podman/<name>.env.example
# (as <name>.env) into UNIT_DIR as podman/README.md says, replaces Image= with ASPIA_TEST_IMAGE, and
# asserts that Image= is the only difference from the shipped unit.
install_unit() {
    local container=$1 base=${1%.container} file
    shift
    local -a sources=("podman/${container}")
    for file in "$@"; do sources+=("podman/${file}"); done
    run mkdir -p "${UNIT_DIR}"
    run install -m 0644 "${sources[@]}" "${UNIT_DIR}/"
    run install -m 0644 "podman/${base}.env.example" "${UNIT_DIR}/${base}.env"
    run sed -i "s|^Image=.*|Image=${ASPIA_TEST_IMAGE}|" "${UNIT_DIR}/${container}"
    run grep -qxF "Image=${ASPIA_TEST_IMAGE}" "${UNIT_DIR}/${container}" || die "the Image= edit did not take"
    diff <(sed '/^Image=/d' "podman/${container}") <(run sed '/^Image=/d' "${UNIT_DIR}/${container}") \
        || die "the installed ${container} differs from the shipped one in more than its Image= line"
}

# check_clean_stop UNIT CONTAINER: "systemctl stop" is quick, ends both processes with exit code 0
# (read from the container's log) and leaves the unit's Result at success. Sets STOP_ELAPSED and
# STOP_RESULT for the caller's ok line.
check_clean_stop() {
    local unit=$1 container=$2 logger t0
    STOPLOG="$(mktemp)"
    run podman logs -f --tail 0 "${container}" > "${STOPLOG}" 2>&1 &
    logger=$!
    sleep 1                         # lets the logger attach before the stop produces output
    t0=${SECONDS}
    sctl stop "${unit}" || die "systemctl stop ${unit} failed"
    STOP_ELAPSED=$((SECONDS - t0))
    # "podman logs -f" ends when the container is gone; do not wait for it forever.
    wait_until 10 pid_gone "${logger}" || true
    kill "${logger}" 2> /dev/null || true
    wait "${logger}" 2> /dev/null || true
    grep -q 'All processes have exited; exit code 0' "${STOPLOG}" || { cat "${STOPLOG}"; die "${container} did not exit cleanly on SIGTERM (no 'All processes have exited; exit code 0' in its log)"; }
    rm -f "${STOPLOG}"
    STOPLOG=""
    STOP_RESULT="$(sctl show "${unit}" -p Result --value)"
    ((STOP_ELAPSED < STOP_LIMIT)) || die "systemctl stop took ${STOP_ELAPSED} s (limit ${STOP_LIMIT} s)"
    [[ "${STOP_RESULT}" == success ]] || die "the unit's Result after stop is '${STOP_RESULT}', not success"
}

setup_rootless_user() {
    local uid
    if ((EUID == 0)); then
        RL_USER="${ASPIA_TEST_USER:-aspia-podman-test}"
        if ! id "${RL_USER}" > /dev/null 2>&1; then
            useradd --create-home --shell /bin/bash "${RL_USER}"
            CREATED_USER=1
        fi
    else
        RL_USER="$(id -un)"
    fi
    RL_HOME="$(getent passwd "${RL_USER}" | cut -d: -f6)"
    # Rootless Podman needs subordinate uid/gid ranges. A user this run created gets them (userdel
    # removes them again); an existing user is never modified.
    if ((CREATED_USER == 1)) && ! grep -q "^${RL_USER}:" /etc/subuid 2> /dev/null; then
        as_root usermod --add-subuids 100000-165535 --add-subgids 100000-165535 "${RL_USER}"
    fi
    if ! grep -q "^${RL_USER}:" /etc/subuid 2> /dev/null || ! grep -q "^${RL_USER}:" /etc/subgid 2> /dev/null; then
        echo "${RL_USER} has no subordinate ID ranges, and this script does not modify an existing user. Add them (e.g. 'usermod --add-subuids 100000-165535 --add-subgids 100000-165535 ${RL_USER}')." >&2
        if ((EUID == 0)); then
            echo "Or set ASPIA_TEST_USER to another name; the script creates that user if it does not exist." >&2
        else
            echo "Or run the script as root (e.g. 'sudo --preserve-env=ASPIA_TEST_IMAGE tests/podman.sh'): it then creates a throwaway user." >&2
        fi
        exit 2
    fi
    uid="$(id -u "${RL_USER}")"
    RL_RUNTIME="/run/user/${uid}"
    # Querying needs no privileges; only enabling does.
    if ! loginctl show-user "${RL_USER}" -p Linger 2> /dev/null | grep -q yes; then
        as_root loginctl enable-linger "${RL_USER}"
        ENABLED_LINGER=1
    fi
    wait_until 30 test -S "${RL_RUNTIME}/bus" || die "no user systemd instance for ${RL_USER} (${RL_RUNTIME}/bus is missing)"
    # install(1) below copies from the source tree as the rootless user.
    as_rootless_user test -r "${REPO}/podman/aspia-server.container" || die "${RL_USER} cannot read ${REPO}/podman"
}

run_variant() {
    local label generator out status=0 before after restarts_before
    set_variant_paths "$1"
    label="${VARIANT_LABEL}"
    say "Variant: ${label}"
    check_free "${CONTAINER}" "${SERVER_VOLUMES[*]}" "${SERVER_FILES[*]}" "${PORTS[@]}"
    OWNED_DIR="${UNIT_DIR}"
    load_image run CREATED_TAGS
    ok "image ${ASPIA_TEST_IMAGE} is in Podman's store"

    say "Install the files the way podman/README.md says (the Image= line is the one edit)"
    install_unit aspia-server.container aspia-config.volume aspia-data.volume
    ok "installed into ${UNIT_DIR}; the unit differs from the shipped one only in Image=${ASPIA_TEST_IMAGE}"

    say "Quadlet generator, dry run"
    generator="$(find_generator)" || die "no Quadlet generator found (is this Podman older than 4.4?)"
    out="$(run "${generator}" "${GENERATOR_ARGS[@]}" 2>&1)" || status=$?
    printf '%s\n' "${out}"
    ((status == 0)) || die "the generator exited with status ${status}"
    grep -q '^ExecStart=/usr/bin/podman run' <<< "${out}" || die "the generator produced no ExecStart for the container"
    grep -q 'systemd-aspia-config' <<< "${out}" || die "the generator did not use the aspia-config volume"
    ok "generator: no errors"

    say "Start"
    sctl daemon-reload
    sctl start "${UNIT}" || die "systemctl start failed"
    wait_healthy || die "the container did not become healthy within ${HEALTHY_TIMEOUT} s"
    ok "service started; podman healthcheck run reports healthy"
    check_hardening aspia-server.container "${CONTAINER}"

    say "Starts at boot"
    sctl list-dependencies default.target --plain 2> /dev/null | grep -q "${UNIT}" || die "${UNIT} is not wanted by default.target"
    ok "${UNIT} is wanted by default.target"

    say "Keys survive a restart"
    before="$(key_digest)"
    sctl restart "${UNIT}" || die "systemctl restart failed"
    wait_healthy || die "not healthy after restart"
    after="$(key_digest)"
    [[ "${before}" == "${after}" ]] || die "keys changed across a restart (${before} -> ${after})"
    ok "keys identical after systemctl restart (${before})"

    say "Restart policy: systemd brings the container back after it is killed"
    restarts_before="$(sctl show "${UNIT}" -p NRestarts --value)"
    run podman kill --signal KILL "${CONTAINER}" > /dev/null || die "podman kill failed"
    wait_until "${HEALTHY_TIMEOUT}" restart_seen "${restarts_before}" || die "systemd did not restart the unit (NRestarts stayed ${restarts_before})"
    wait_healthy || die "not healthy after the automatic restart"
    [[ "$(key_digest)" == "${before}" ]] || die "keys changed after the automatic restart"
    ok "restarted by systemd (NRestarts was ${restarts_before}), healthy, same keys"

    say "Stop"
    check_clean_stop "${UNIT}" "${CONTAINER}"
    [[ "$(sctl is-active "${UNIT}" || true)" == inactive ]] || die "the unit is not inactive after stop"
    run podman container exists "${CONTAINER}" 2> /dev/null && die "the container still exists after stop"
    ok "stopped in ${STOP_ELAPSED} s, Result=${STOP_RESULT}, SIGTERM ended both processes with exit code 0, container removed"

    say "Start again: the data is still there"
    sctl start "${UNIT}" || die "second start failed"
    wait_healthy || die "not healthy after stop and start"
    [[ "$(key_digest)" == "${before}" ]] || die "keys changed across stop and start"
    ok "same keys after stop and start"

    say "Network=host: the edit described in the unit file (delete PublishPort= lines, uncomment the marked lines)"
    run sed -i -e '/^PublishPort=/d' \
        -e 's/^#\(Network=host\)$/\1/' \
        -e 's/^#\(Environment=ASPIA_ROUTER_RELAY_ALLOWED_IPS=127\.0\.0\.1\)$/\1/' "${UNIT_DIR}/aspia-server.container"
    run grep -qx 'Network=host' "${UNIT_DIR}/aspia-server.container" || die "the edit did not enable Network=host"
    run grep -qx 'Environment=ASPIA_ROUTER_RELAY_ALLOWED_IPS=127.0.0.1' "${UNIT_DIR}/aspia-server.container" || die "the edit did not enable the Environment= line"
    sctl daemon-reload
    sctl restart "${UNIT}" || die "restart with Network=host failed"
    wait_healthy || die "not healthy with Network=host"
    [[ "$(run podman inspect --format '{{.HostConfig.NetworkMode}}' "${CONTAINER}")" == host ]] || die "the container is not in the host network namespace"
    ss -Hltn | awk '$4 ~ /:8062$/ {found=1} END {exit !found}' || die "nothing listens on 8062 on the host with Network=host"
    run podman exec "${CONTAINER}" cat /etc/aspia/router.conf | grep -q '^white_list=127.0.0.1$' || die "ASPIA_ROUTER_RELAY_ALLOWED_IPS=127.0.0.1 did not reach router.conf"
    [[ "$(key_digest)" == "${before}" ]] || die "keys changed with Network=host"
    ok "Network=host: healthy, ports on the host, relay white list 127.0.0.1, same keys"

    cleanup_variant
    ok "variant ${label} passed"
}

check_free_relay() {
    check_free "${RELAY_CONTAINER}" "${RELAY_VOLUMES[*]}" "${RELAY_FILES[*]}" "${RELAY_PORTS[@]}"
    if as_root podman container exists "${TEST_ROUTER}" 2> /dev/null; then die "a container named ${TEST_ROUTER} already exists"; fi
}

# host_address: this machine's own IPv4 address on its default route, the address a Relay on
# another machine would use for the Router.
host_address() {
    ip -4 route get 1.1.1.1 2> /dev/null | awk '{ for (i = 1; i < NF; i++) if ($i == "src") { print $(i + 1); exit } }'
}

test_router_ready() { as_root podman exec "${TEST_ROUTER}" /usr/bin/aspia_health > /dev/null 2>&1; }
# The log is read completely first: "podman logs | grep -q" fails under pipefail when grep exits early.
relay_registered() { grep -q 'Received key pool' <<< "$(as_root podman logs "${TEST_ROUTER}" 2>&1)"; }
relay_healthy() { is_healthy "${RELAY_CONTAINER}"; }

run_relay_variant() {
    local label generator out status=0 addr key
    set_variant_paths "$1"
    label="relay unit, ${VARIANT_LABEL}"
    say "Variant: ${label}"
    check_free_relay
    RELAY_OWNED_DIR="${UNIT_DIR}"
    load_image run CREATED_TAGS
    load_image as_root ROOT_TAGS

    say "A Router to register with: ASPIA_ROLE=router, as root, 8063 published"
    as_root podman run -d --name "${TEST_ROUTER}" -e ASPIA_ROLE=router -p 8063:8063 "${ASPIA_TEST_IMAGE}" > /dev/null \
        || die "could not start the Router"
    wait_until "${HEALTHY_TIMEOUT}" test_router_ready || die "the Router did not become ready"
    key="$(as_root podman exec "${TEST_ROUTER}" cat /etc/aspia/relay.pub)" || die "cannot read the Router's relay.pub"
    if [[ "${MODE}" == system ]]; then
        addr="$(host_address)"
    else
        addr="$(as_root podman inspect --format '{{.NetworkSettings.IPAddress}}' "${TEST_ROUTER}")"
    fi
    [[ -n "${addr}" ]] || die "cannot find an address for the Router"
    ok "Router up at ${addr}; its relay key is ${key}"

    say "Install the relay unit the way podman/README.md says (the Image= line and the env file are the edits)"
    install_unit aspia-relay.container aspia-relay-config.volume
    run sed -i -e "s|^#\?ASPIA_RELAY_ROUTER_ADDRESS=.*|ASPIA_RELAY_ROUTER_ADDRESS=${addr}|" \
        -e "s|^#\?ASPIA_RELAY_ROUTER_PUBLIC_KEY=.*|ASPIA_RELAY_ROUTER_PUBLIC_KEY=${key}|" \
        -e "s|^EXTERNAL_IP=.*|EXTERNAL_IP=relay.example.test|" "${UNIT_DIR}/aspia-relay.env"
    run grep -qxF "ASPIA_RELAY_ROUTER_PUBLIC_KEY=${key}" "${UNIT_DIR}/aspia-relay.env" || die "the env file edit did not take"
    ok "installed into ${UNIT_DIR}"

    say "Quadlet generator, dry run"
    generator="$(find_generator)" || die "no Quadlet generator found (is this Podman older than 4.4?)"
    out="$(run "${generator}" "${GENERATOR_ARGS[@]}" 2>&1)" || status=$?
    ((status == 0)) || { printf '%s\n' "${out}"; die "the generator exited with status ${status}"; }
    grep -q 'systemd-aspia-relay-config' <<< "${out}" || die "the generator did not use the aspia-relay-config volume"
    grep -q 'ASPIA_ROLE=relay' <<< "${out}" || die "the generated service does not set ASPIA_ROLE=relay"
    ok "generator: no errors; the service runs with ASPIA_ROLE=relay and its own volume"

    say "Start: healthy means connected to the Router"
    sctl daemon-reload
    sctl start "${RELAY_UNIT}" || die "systemctl start ${RELAY_UNIT} failed"
    wait_until "${HEALTHY_TIMEOUT}" relay_healthy || die "the Relay did not become healthy within ${HEALTHY_TIMEOUT} s"
    wait_until 60 relay_registered || die "the Router did not log the Relay's key pool"
    ok "healthy; Router log: $(grep -m1 -o 'Received key pool.*' <<< "$(as_root podman logs "${TEST_ROUTER}" 2>&1)")"
    check_hardening aspia-relay.container "${RELAY_CONTAINER}"
    sctl list-dependencies default.target --plain 2> /dev/null | grep -q "${RELAY_UNIT}" || die "${RELAY_UNIT} is not wanted by default.target"
    ok "${RELAY_UNIT} is wanted by default.target"

    say "Stop"
    check_clean_stop "${RELAY_UNIT}" "${RELAY_CONTAINER}"
    ok "stopped in ${STOP_ELAPSED} s, Result=${STOP_RESULT}, exit code 0"

    cleanup_variant
    ok "variant ${label} passed"
}

# guard_check: a check that fails before this run owns anything must leave an existing install alone.
guard_check() {
    local out status=0 volume_kept=0 unit_kept=0
    say "Guard: a refused run must not touch an existing install"
    MODE=system
    UNIT_DIR=/etc/containers/systemd
    check_free "${CONTAINER}" "${SERVER_VOLUMES[*]}" "${SERVER_FILES[*]}" "${PORTS[@]}"
    run mkdir -p "${UNIT_DIR}"
    run podman volume create systemd-aspia-config > /dev/null
    printf '# a unit that is not ours\n' | run tee "${UNIT_DIR}/aspia-server.container" > /dev/null
    out="$(GITHUB_STEP_SUMMARY='' "${REPO}/tests/podman.sh" system 2>&1)" || status=$?
    run podman volume exists systemd-aspia-config && volume_kept=1
    run grep -q 'not ours' "${UNIT_DIR}/aspia-server.container" && unit_kept=1
    quiet run podman volume rm -f systemd-aspia-config
    quiet run rm -f "${UNIT_DIR}/aspia-server.container"
    MODE=""
    UNIT_DIR=""
    ((status != 0)) || die "the test did not refuse to start next to an existing install"
    grep -q 'volume systemd-aspia-config already exists' <<< "${out}" || { printf '%s\n' "${out}"; die "the test refused for another reason than the existing volume"; }
    ((volume_kept == 1)) || die "the refused run deleted the existing volume"
    ((unit_kept == 1)) || die "the refused run deleted the existing unit"
    ok "refused to start; the existing volume and unit are untouched"
}

# remove_install DIR UNIT CONTAINER "VOLUMES" "FILES": stops the unit and removes what an install
# put there (the files are in DIR). Only called for a directory this run owns.
remove_install() {
    local dir=$1 unit=$2 container=$3 file volume
    local -a volumes files
    read -ra volumes <<< "$4"
    read -ra files <<< "$5"
    quiet sctl stop "${unit}"
    quiet run podman rm -f -v "${container}"
    for file in "${files[@]}"; do quiet run rm -f "${dir}/${file}"; done
    quiet sctl daemon-reload
    for volume in "${volumes[@]}"; do quiet run podman volume rm -f "${volume}"; done
}

cleanup_variant() {
    [[ -n "${MODE}" ]] || return 0
    local tag
    # Only what this run installed: before check_free passed (OWNED_DIR unset), anything found belongs to the user.
    if [[ -n "${RELAY_OWNED_DIR}" ]]; then
        quiet as_root podman rm -f -v "${TEST_ROUTER}"
        remove_install "${RELAY_OWNED_DIR}" "${RELAY_UNIT}" "${RELAY_CONTAINER}" "${RELAY_VOLUMES[*]}" "${RELAY_FILES[*]}"
        RELAY_OWNED_DIR=""
    fi
    if [[ -n "${OWNED_DIR}" ]]; then
        remove_install "${OWNED_DIR}" "${UNIT}" "${CONTAINER}" "${SERVER_VOLUMES[*]}" "${SERVER_FILES[*]}"
        OWNED_DIR=""
    fi
    for tag in "${CREATED_TAGS[@]}"; do
        quiet run podman rmi -f "${tag}"
    done
    CREATED_TAGS=()
    for tag in "${ROOT_TAGS[@]}"; do
        quiet as_root podman rmi -f "${tag}"
    done
    ROOT_TAGS=()
    if [[ "${MODE}" == rootless ]]; then
        if ((ENABLED_LINGER == 1)); then quiet as_root loginctl disable-linger "${RL_USER}"; fi
        if ((CREATED_USER == 1)); then
            # userdel refuses while the user's manager still runs.
            quiet as_root loginctl terminate-user "${RL_USER}"
            quiet wait_until 30 user_gone
            quiet as_root userdel --remove "${RL_USER}"
        fi
    fi
    MODE=""
    UNIT_DIR=""
}

on_exit() {
    local status=$?
    trap - EXIT
    cleanup_variant || true
    [[ -z "${STOPLOG}" ]] || rm -f "${STOPLOG}"
    echo
    if ((status == 0)); then echo "podman: all checks passed"; else echo "podman: FAILED"; fi
    exit "${status}"
}

main() {
    local which="${1:-all}" unit
    case "${which}" in system | rootless | guard | relay | all) ;; *)
        echo "usage: tests/podman.sh [system|rootless|guard|relay|all]" >&2
        exit 2
        ;;
    esac
    : "${ASPIA_TEST_IMAGE:?set ASPIA_TEST_IMAGE to the image to test}"
    command -v podman > /dev/null || { echo "podman is not installed" >&2; exit 2; }
    command -v systemctl > /dev/null || { echo "systemctl is not available" >&2; exit 2; }
    command -v ss > /dev/null || { echo "ss (iproute2) is required" >&2; exit 2; }
    [[ -d /run/systemd/system ]] || { echo "systemd is not running as init on this machine" >&2; exit 2; }
    if ((EUID != 0)) && [[ "${which}" != rootless ]]; then
        sudo -n true 2> /dev/null || { echo "the system-wide variant needs root or passwordless sudo" >&2; exit 2; }
    fi
    for unit in podman/aspia-server.container podman/aspia-relay.container; do
        [[ "$(grep -c '^Image=' "${unit}")" == 1 ]] || { echo "${unit} must have exactly one Image= line" >&2; exit 2; }
    done
    printf '### Podman Quadlet test\n\n- %s; %s; %s\n' "$(podman --version)" "$(systemctl --version | head -n 1)" \
        "$(sed -n 's/^PRETTY_NAME="\(.*\)"$/\1/p' /etc/os-release 2> /dev/null)" | tee -a "${GITHUB_STEP_SUMMARY:-/dev/null}"
    trap on_exit EXIT
    if [[ "${which}" == guard || "${which}" == all ]]; then guard_check; fi
    if [[ "${which}" == system || "${which}" == all ]]; then run_variant system; fi
    if [[ "${which}" == rootless || "${which}" == all ]]; then run_variant rootless; fi
    if [[ "${which}" == relay || "${which}" == all ]]; then
        run_relay_variant system
        run_relay_variant rootless
    fi
}

main "$@"
