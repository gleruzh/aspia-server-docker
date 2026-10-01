#!/usr/bin/env bash
#
# tests/podman.sh: tests the Quadlet unit in podman/ on a Linux machine with Podman and systemd,
# for both install variants from podman/README.md.
#
#   tests/podman.sh [system|rootless|all]      (default: all)
#
# For each variant it installs the files exactly as the README says, runs the Quadlet generator in
# dry-run mode, starts the service, and checks: the unit is generated without errors; the service
# starts and the container becomes healthy ("podman healthcheck run" succeeds); the unit is wanted
# by default.target (so it starts at boot); "systemctl stop" finishes quickly and cleanly; the
# keys are the same after "systemctl restart"; and systemd restarts the container after it was
# killed. It also applies the host-network edit from podman/README.md ("Networking") and checks it.
# Everything it installed is removed at the end.
#
# THIS INSTALLS A SERVICE AND USES PORTS 8060-8070 AND THE VOLUMES systemd-aspia-config/systemd-aspia-data.
# Run it only on a throwaway machine (a CI runner, a VM). It refuses to start when the unit, the
# container, the volumes or any of the ports already exist.
#
# Environment:
#   ASPIA_TEST_IMAGE    (required) the image to test. It is taken from Docker's image store when
#                       Docker has it ("docker save | podman load"), else Podman pulls or finds it.
#   ASPIA_TEST_ARCHIVE  optional: an image archive (docker save) to load instead of using Docker.
#   ASPIA_TEST_USER     rootless user when this script runs as root (default aspia-podman-test;
#                       created, and removed again, if it does not exist). When run as a normal
#                       user, that user is the rootless user.
# The system-wide variant needs root, or sudo without a password.

set -euo pipefail

cd "$(dirname "$0")/.."

readonly REPO="${PWD}"
readonly UNIT=aspia-server.service
readonly CONTAINER=aspia-server
readonly TEST_TAG=localhost/aspia-server-test:run
readonly PORTS=(8060 8061 8062 8063 8065 8070)
readonly STOP_LIMIT=20          # seconds: "systemctl stop" must finish well inside systemd's 70 s default
readonly HEALTHY_TIMEOUT=240    # seconds; generous, because CI runners and emulation are slow

MODE=""                         # system or rootless: set per variant
RL_USER=""
RL_HOME=""
RL_RUNTIME=""
CREATED_USER=0
ENABLED_LINGER=0
UNIT_DIR=""
FAILED=0

say() { printf '\n=== %s\n' "$*"; }
ok() { printf 'ok - %s\n' "$*"; }
die() {
    printf 'FAIL - %s\n' "$*" >&2
    FAILED=1
    dump_diagnostics || true
    exit 1
}

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

dump_diagnostics() {
    [[ -n "${MODE}" ]] || return 0
    echo "--- diagnostics (${MODE}) ---"
    sctl status "${UNIT}" --no-pager -l 2>&1 | tail -n 30 || true
    run podman ps -a 2>&1 || true
    run podman logs --tail 40 "${CONTAINER}" 2>&1 || true
    if [[ "${MODE}" == system ]]; then
        as_root journalctl -u "${UNIT}" --no-pager -n 40 2>&1 || true
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
    local keys
    keys="$(run podman exec "${CONTAINER}" cat /etc/aspia/router.conf /etc/aspia/relay.conf | grep -E '^(private_key|public_key|seed_key)=' | sort)"
    [[ -n "${keys}" ]] || die "no key lines found in router.conf/relay.conf"
    printf '%s\n' "${keys}" | sha256sum | cut -d' ' -f1
}

wait_healthy() {
    local deadline=$((SECONDS + HEALTHY_TIMEOUT)) status=""
    while ((SECONDS < deadline)); do
        if run podman healthcheck run "${CONTAINER}" > /dev/null 2>&1; then
            status="$(run podman inspect --format '{{.State.Health.Status}}' "${CONTAINER}" 2> /dev/null || true)"
            [[ "${status}" == healthy ]] && return 0
        fi
        sleep 2
    done
    return 1
}

check_free() {
    local port
    if command -v ss > /dev/null; then
        for port in "${PORTS[@]}"; do
            if ss -Hltun | awk -v p=":${port}" '$5 ~ p"$" {found=1} END {exit !found}'; then
                die "port ${port} is already in use on this machine; run this test on a throwaway machine"
            fi
        done
    fi
    run podman container exists "${CONTAINER}" 2> /dev/null && die "a container named ${CONTAINER} already exists"
    local volume
    for volume in systemd-aspia-config systemd-aspia-data; do
        run podman volume exists "${volume}" 2> /dev/null && die "volume ${volume} already exists"
    done
    [[ ! -e "${UNIT_DIR}/aspia-server.container" ]] || die "${UNIT_DIR}/aspia-server.container already exists"
    return 0
}

load_image() {
    local loaded=""
    : "${ASPIA_TEST_IMAGE:?set ASPIA_TEST_IMAGE to the image to test}"
    if [[ -n "${ASPIA_TEST_ARCHIVE:-}" ]]; then
        loaded="$(run podman load -q < "${ASPIA_TEST_ARCHIVE}" | sed -n 's/^Loaded image[^:]*: //p' | head -n 1)"
    elif command -v docker > /dev/null && docker image inspect "${ASPIA_TEST_IMAGE}" > /dev/null 2>&1; then
        loaded="$(docker save "${ASPIA_TEST_IMAGE}" | run podman load -q | sed -n 's/^Loaded image[^:]*: //p' | head -n 1)"
    else
        run podman pull -q "${ASPIA_TEST_IMAGE}" > /dev/null
        loaded="${ASPIA_TEST_IMAGE}"
    fi
    [[ -n "${loaded}" ]] || die "could not load the image into Podman"
    run podman tag "${loaded}" "${TEST_TAG}"
}

setup_rootless_user() {
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
    # Rootless Podman needs subordinate uid/gid ranges for the user.
    if ! grep -q "^${RL_USER}:" /etc/subuid 2> /dev/null; then
        as_root usermod --add-subuids 100000-165535 --add-subgids 100000-165535 "${RL_USER}"
    fi
    local uid
    uid="$(id -u "${RL_USER}")"
    RL_RUNTIME="/run/user/${uid}"
    if ! as_root loginctl show-user "${RL_USER}" -p Linger 2> /dev/null | grep -q yes; then
        as_root loginctl enable-linger "${RL_USER}"
        ENABLED_LINGER=1
    fi
    local waited=0
    while [[ ! -S "${RL_RUNTIME}/bus" ]] && ((waited < 30)); do
        sleep 1
        waited=$((waited + 1))
    done
    [[ -S "${RL_RUNTIME}/bus" ]] || die "no user systemd instance for ${RL_USER} (${RL_RUNTIME}/bus is missing)"
    # Make sure the rootless user's source tree is readable: install(1) below copies from it.
    if ! as_rootless_user test -r "${REPO}/podman/aspia-server.container"; then
        die "${RL_USER} cannot read ${REPO}/podman"
    fi
    # The user may not exist in a podman store yet: the first command creates it.
    return 0
}

run_variant() {
    MODE="$1"
    local label generator
    if [[ "${MODE}" == system ]]; then
        label="system-wide (root)"
        UNIT_DIR=/etc/containers/systemd
    else
        label="rootless"
        setup_rootless_user
        UNIT_DIR="${RL_HOME}/.config/containers/systemd"
    fi
    say "Variant: ${label}"
    run podman --version
    check_free
    load_image
    ok "image loaded as ${TEST_TAG}"

    say "Install the files the way podman/README.md says"
    run mkdir -p "${UNIT_DIR}"
    run install -m 0644 podman/aspia-server.container podman/aspia-config.volume podman/aspia-data.volume "${UNIT_DIR}/"
    run install -m 0644 podman/aspia-server.env.example "${UNIT_DIR}/aspia-server.env"
    [[ "$(grep -c '^Image=' podman/aspia-server.container)" == 1 ]] || die "the unit must have exactly one Image= line"
    run sed -i "s|^Image=.*|Image=${TEST_TAG}|" "${UNIT_DIR}/aspia-server.container"
    ok "installed into ${UNIT_DIR} (the image is the single Image= line)"

    say "Quadlet generator, dry run"
    generator="$(find_generator)" || die "no Quadlet generator found (is this Podman older than 4.4?)"
    local out status=0
    if [[ "${MODE}" == system ]]; then
        out="$(run "${generator}" --dryrun 2>&1)" || status=$?
    else
        out="$(run "${generator}" --user --dryrun 2>&1)" || status=$?
    fi
    printf '%s\n' "${out}"
    ((status == 0)) || die "the generator exited with status ${status}"
    grep -q '^ExecStart=/usr/bin/podman run' <<< "${out}" || die "the generator produced no ExecStart for the container"
    # A missing /usr/share/containers/systemd (not every distribution ships it) is reported as an
    # "Error occurred resolving path" by some versions and is harmless. Anything else that looks
    # like a complaint from the generator is a failure.
    if grep -iE 'converting|unsupported|invalid|warning|error|failed|cannot' <<< "${out}" \
        | grep -vE '^#|Error occurred resolving path'; then
        die "the generator reported errors or warnings"
    fi
    grep -q 'systemd-aspia-config' <<< "${out}" || die "the generator did not use the aspia-config volume"
    ok "generator: no errors"

    say "Start"
    sctl daemon-reload
    sctl start "${UNIT}" || die "systemctl start failed"
    wait_healthy || die "the container did not become healthy within ${HEALTHY_TIMEOUT} s"
    ok "service started; podman healthcheck run reports healthy"

    say "Starts at boot"
    sctl list-dependencies default.target --plain 2> /dev/null | grep -q "${UNIT}" || die "${UNIT} is not wanted by default.target"
    ok "${UNIT} is wanted by default.target"

    say "Keys survive a restart"
    local before after
    before="$(key_digest)"
    sctl restart "${UNIT}" || die "systemctl restart failed"
    wait_healthy || die "not healthy after restart"
    after="$(key_digest)"
    [[ "${before}" == "${after}" ]] || die "keys changed across a restart (${before} -> ${after})"
    ok "keys identical after systemctl restart (${before})"

    say "Restart policy: systemd brings the container back after it is killed"
    local restarts_before restarts_after
    restarts_before="$(sctl show "${UNIT}" -p NRestarts --value)"
    run podman kill --signal KILL "${CONTAINER}" > /dev/null || die "podman kill failed"
    local deadline=$((SECONDS + HEALTHY_TIMEOUT))
    while ((SECONDS < deadline)); do
        restarts_after="$(sctl show "${UNIT}" -p NRestarts --value)"
        ((restarts_after > restarts_before)) && break
        sleep 2
    done
    ((${restarts_after:-0} > restarts_before)) || die "systemd did not restart the unit (NRestarts stayed ${restarts_before})"
    wait_healthy || die "not healthy after the automatic restart"
    [[ "$(key_digest)" == "${before}" ]] || die "keys changed after the automatic restart"
    ok "restarted by systemd (NRestarts ${restarts_before} -> ${restarts_after}), healthy, same keys"

    say "Stop"
    local t0 t1 elapsed result stoplog logger
    stoplog="$(mktemp)"
    run podman logs -f --tail 0 "${CONTAINER}" > "${stoplog}" 2>&1 &
    logger=$!
    sleep 1
    t0="$(date +%s.%N)"
    sctl stop "${UNIT}" || die "systemctl stop failed"
    t1="$(date +%s.%N)"
    # "podman logs -f" ends when the container is gone; do not wait for it forever.
    for _ in 1 2 3 4 5 6 7 8 9 10; do kill -0 "${logger}" 2> /dev/null || break; sleep 1; done
    kill "${logger}" 2> /dev/null || true
    wait "${logger}" 2> /dev/null || true
    grep -q 'All processes have exited; exit code 0' "${stoplog}" || { cat "${stoplog}"; die "the container did not exit cleanly on SIGTERM (no 'All processes have exited; exit code 0' in its log)"; }
    rm -f "${stoplog}"
    elapsed="$(awk -v a="${t0}" -v b="${t1}" 'BEGIN {printf "%.1f", b - a}')"
    result="$(sctl show "${UNIT}" -p Result --value)"
    echo "systemctl stop took ${elapsed} s, Result=${result}"
    awk -v e="${elapsed}" -v l="${STOP_LIMIT}" 'BEGIN {exit !(e < l)}' || die "systemctl stop took ${elapsed} s (limit ${STOP_LIMIT} s)"
    [[ "${result}" == success ]] || die "the unit's Result after stop is '${result}', not success"
    [[ "$(sctl is-active "${UNIT}" || true)" == inactive ]] || die "the unit is not inactive after stop"
    run podman container exists "${CONTAINER}" 2> /dev/null && die "the container still exists after stop"
    ok "stopped in ${elapsed} s, no timeout, SIGTERM ended both processes with exit code 0, container removed"

    say "Start again: the data is still there"
    sctl start "${UNIT}" || die "second start failed"
    wait_healthy || die "not healthy after stop and start"
    [[ "$(key_digest)" == "${before}" ]] || die "keys changed across stop and start"
    ok "same keys after stop and start"

    say "Optional: host networking instead of published ports (the sed command from podman/README.md)"
    run cp "${UNIT_DIR}/aspia-server.container" "${UNIT_DIR}/aspia-server.container.published"
    run sed -i -e '/^PublishPort=/d' \
        -e 's/^ContainerName=.*/&\nNetwork=host\nEnvironment=ASPIA_ROUTER_RELAY_ALLOWED_IPS=127.0.0.1/' "${UNIT_DIR}/aspia-server.container"
    sctl daemon-reload
    sctl restart "${UNIT}" || die "restart with Network=host failed"
    wait_healthy || die "not healthy with Network=host"
    [[ "$(run podman inspect --format '{{.HostConfig.NetworkMode}}' "${CONTAINER}")" == host ]] || die "the container is not in the host network namespace"
    if command -v ss > /dev/null; then
        ss -Hltn | awk '$4 ~ /:8062$/ {found=1} END {exit !found}' || die "nothing listens on 8062 on the host with Network=host"
    fi
    run podman exec "${CONTAINER}" cat /etc/aspia/router.conf | grep -q '^white_list=127.0.0.1$' || die "ASPIA_ROUTER_RELAY_ALLOWED_IPS=127.0.0.1 did not reach router.conf"
    [[ "$(key_digest)" == "${before}" ]] || die "keys changed with Network=host"
    ok "Network=host: healthy, ports on the host, relay white list 127.0.0.1, same keys"
    run mv "${UNIT_DIR}/aspia-server.container.published" "${UNIT_DIR}/aspia-server.container"
    sctl daemon-reload
    sctl restart "${UNIT}" || die "restart with published ports failed"
    wait_healthy || die "not healthy again with published ports"
    [[ "$(run podman inspect --format '{{.HostConfig.NetworkMode}}' "${CONTAINER}")" != host ]] || die "the container is still in the host network namespace"
    ok "published ports restored"

    cleanup_variant
    ok "variant ${label} passed"
}

cleanup_variant() {
    [[ -n "${MODE}" ]] || return 0
    sctl stop "${UNIT}" > /dev/null 2>&1 || true
    run podman rm -f "${CONTAINER}" > /dev/null 2>&1 || true
    if [[ -n "${UNIT_DIR}" ]]; then
        run rm -f "${UNIT_DIR}/aspia-server.container" "${UNIT_DIR}/aspia-config.volume" \
            "${UNIT_DIR}/aspia-data.volume" "${UNIT_DIR}/aspia-server.env" > /dev/null 2>&1 || true
        run rm -f "${UNIT_DIR}/aspia-server.container.published" > /dev/null 2>&1 || true
    fi
    sctl daemon-reload > /dev/null 2>&1 || true
    run podman volume rm -f systemd-aspia-config systemd-aspia-data > /dev/null 2>&1 || true
    run podman rmi -f "${TEST_TAG}" > /dev/null 2>&1 || true
    if [[ "${MODE}" == rootless ]]; then
        if ((ENABLED_LINGER == 1)); then as_root loginctl disable-linger "${RL_USER}" > /dev/null 2>&1 || true; fi
        if ((CREATED_USER == 1)); then
            as_root userdel --remove "${RL_USER}" > /dev/null 2>&1 || true
        fi
        ENABLED_LINGER=0
        CREATED_USER=0
    fi
    MODE=""
    UNIT_DIR=""
}

on_exit() {
    local status=$?
    trap - EXIT
    cleanup_variant || true
    if ((status == 0 && FAILED == 0)); then
        echo
        echo "podman: all checks passed"
    else
        echo
        echo "podman: FAILED"
    fi
    exit "${status}"
}

main() {
    local which="${1:-all}"
    case "${which}" in system | rootless | all) ;; *)
        echo "usage: tests/podman.sh [system|rootless|all]" >&2
        exit 2
        ;;
    esac
    command -v podman > /dev/null || { echo "podman is not installed" >&2; exit 2; }
    command -v systemctl > /dev/null || { echo "systemctl is not available" >&2; exit 2; }
    [[ -d /run/systemd/system ]] || { echo "systemd is not running as init on this machine" >&2; exit 2; }
    if ((EUID != 0)); then
        sudo -n true 2> /dev/null || { [[ "${which}" == rootless ]] || { echo "the system-wide variant needs root or passwordless sudo" >&2; exit 2; }; }
    fi
    echo "Podman: $(podman --version); systemd: $(systemctl --version | head -n 1)"
    if [[ -r /etc/os-release ]]; then
        # shellcheck disable=SC1091
        echo "OS: $(. /etc/os-release && echo "${PRETTY_NAME}")"
    fi
    trap on_exit EXIT
    [[ "${which}" == rootless ]] || run_variant system
    [[ "${which}" == system ]] || run_variant rootless
}

main "$@"
