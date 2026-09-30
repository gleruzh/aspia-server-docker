#!/usr/bin/env bash
#
# tests/run.sh: builds the image and runs the behaviour scenarios on plain Docker.
# Needs only Docker (and network access to pull the base images and the 2.7.0 image).
#
#   tests/run.sh                  build the image from this checkout, then test it
#   ASPIA_TEST_IMAGE=img tests/run.sh   test an existing image instead of building one
#
# Every container, volume and network the tests create carries the label aspia-test=<run id>
# and is removed on exit, also when a scenario fails.
#
# Scenarios:
#   0. build: a tampered checksum makes the build fail; 0b. a docker run command replaces the server
#   0c. docker-compose.yml: local build by default, ASPIA_IMAGE override, EXTERNAL_IP required
#   1. clean start
#   2. restart keeps keys and configuration; 2b. a changed EXTERNAL_IP is applied, with a copy
#   3. upgrade from paprikkafox/aspia-server:2.7.0
#   4. docker stop is fast and clean
#   5. a crashed process stops the container with a non-zero exit code
#   6. EXTERNAL_IP unset, empty or blank
#   7. database without configuration: refuse, change nothing; 7b. same for a lone relay.conf and
#      for an invalid 2.x relay.json (checked before anything is written)
#   8. healthcheck: a Relay that is running but not connected is not healthy
#   9. ASPIA_ROUTER_*/ASPIA_RELAY_* variables land in the configuration; healthy on custom ports
#  10. a variable removed: the hand edit in the file survives; setting it again overwrites it
#  11. an invalid value: one clear error naming the variable, non-zero exit, nothing written
#  12. ASPIA_RELAY_PUBLIC_ADDRESS=auto with no network: clear error, non-zero exit
#  13. a 2.x migration start also applies a new Relay variable (one the upstream migration itself copies)
#  14. PUID/PGID: both processes run as that uid/gid, and the files they write are owned by it
# Lint (hadolint, shellcheck) is in tests/lint.sh.

set -euo pipefail

cd "$(dirname "$0")/.."

readonly PLATFORM=linux/amd64
readonly OLD_IMAGE=paprikkafox/aspia-server:2.7.0@sha256:8db62b95681b09ab8dc2346d803a2981d7a44826b3a06310ab27b3d054215b82
readonly HELPER_IMAGE=aspia-server-test-helper:local
readonly RUN_ID="aspia-test-$$"
readonly IP_OLD=203.0.113.10   # EXTERNAL_IP given to 2.7.0
readonly IP_NEW=203.0.113.11   # EXTERNAL_IP given to the new image
readonly HEALTH_TIMEOUT=180    # seconds; generous because CI or emulation may be slow
IMAGE="${ASPIA_TEST_IMAGE:-aspia-server:test}"

# ---------------------------------------------------------------------------------------------
# Output, cleanup

log() { printf '\n=== %s\n' "$*"; }
ok() { printf '  ok   %s\n' "$*"; }
CURRENT_CONTAINER=""
fail() {
    printf '  FAIL %s\n' "$*" >&2
    if [[ -n "${CURRENT_CONTAINER}" ]]; then
        printf -- '--- last 60 log lines of %s:\n' "${CURRENT_CONTAINER}" >&2
        docker logs --tail 60 "${CURRENT_CONTAINER}" >&2 2>&1 || true
    fi
    exit 1
}

cleanup() {
    local id
    docker ps -aq --filter "label=aspia-test=${RUN_ID}" | while read -r id; do
        docker rm -f "${id}" >/dev/null 2>&1 || true
    done
    docker volume ls -q --filter "label=aspia-test=${RUN_ID}" | while read -r id; do
        docker volume rm "${id}" >/dev/null 2>&1 || true
    done
    docker network ls -q --filter "label=aspia-test=${RUN_ID}" | while read -r id; do
        docker network rm "${id}" >/dev/null 2>&1 || true
    done
    [[ -z "${TAMPER_DIR:-}" ]] || rm -rf "${TAMPER_DIR}"
}
trap cleanup EXIT
trap 'exit 130' INT TERM

# ---------------------------------------------------------------------------------------------
# Docker helpers

new_volume() { docker volume create --label "aspia-test=${RUN_ID}" "${RUN_ID}-$1" >/dev/null; echo "${RUN_ID}-$1"; }

# run_new <name> <config volume> <database volume> [docker run options...]: starts the image under
# test as container ${RUN_ID}-<name> and makes it CURRENT_CONTAINER (whose log a failure prints).
run_new() {
    local name="${RUN_ID}-$1" cfg="$2" db="$3"
    shift 3
    docker run -d --platform "${PLATFORM}" --label "aspia-test=${RUN_ID}" --name "${name}" \
        -v "${cfg}:/etc/aspia" -v "${db}:/var/lib/aspia" "$@" "${IMAGE}" >/dev/null
    CURRENT_CONTAINER="${name}"
}

# helper <config volume> <database volume> <command...>: runs a command in the helper image with the
# volumes mounted read-only. Independent of the image under test.
helper() {
    local cfg="$1" db="$2"
    shift 2
    docker run --rm --platform "${PLATFORM}" --label "aspia-test=${RUN_ID}" \
        -v "${cfg}:/etc/aspia:ro" -v "${db}:/var/lib/aspia:ro" "${HELPER_IMAGE}" "$@"
}
helper_rw() {
    local cfg="$1" db="$2"
    shift 2
    docker run --rm --platform "${PLATFORM}" --label "aspia-test=${RUN_ID}" \
        -v "${cfg}:/etc/aspia" -v "${db}:/var/lib/aspia" "${HELPER_IMAGE}" "$@"
}

state() { docker inspect -f "{{$1}}" "$2"; }

# log_has <container> <extended regex>: the log is read completely first; "docker logs | grep -q"
# would fail under pipefail when grep exits early.
log_has() { grep -qE -- "$2" <<<"$(docker logs "$1" 2>&1)"; }

# sigterm_lines <container>: how many times an Aspia process logged a received SIGTERM.
sigterm_lines() { grep -cE 'Signal received: +"SIGTERM"' <<<"$(docker logs "$1" 2>&1)" || true; }

# wait_healthy <container>: fails if the container stops or is not healthy within HEALTH_TIMEOUT.
wait_healthy() {
    local i status
    for ((i = 0; i < HEALTH_TIMEOUT; i++)); do
        [[ "$(state .State.Running "$1")" == true ]] || fail "$1 exited (code $(state .State.ExitCode "$1")) instead of becoming healthy"
        status="$(state .State.Health.Status "$1")"
        if [[ "${status}" == healthy ]]; then
            ok "$1 is healthy after ~${i} s"
            return 0
        fi
        sleep 1
    done
    fail "$1 is not healthy after ${HEALTH_TIMEOUT} s (status ${status}); last check: $(docker inspect -f '{{range .State.Health.Log}}{{.Output}}{{end}}' "$1" | tail -3)"
}

# wait_exited <container> <timeout seconds>: waits until the container has stopped.
wait_exited() {
    local i
    for ((i = 0; i < $2; i++)); do
        [[ "$(state .State.Running "$1")" == false ]] && return 0
        sleep 1
    done
    fail "$1 is still running after $2 s"
}

# ini_value <file content> <section> <key>: reads a key from INI text (own parser, not the image's).
ini_value() {
    printf '%s\n' "$1" | awk -v section="[$2]" -v key="$3" '
        { sub(/\r$/, "") }
        /^\[/ { in_section = ($0 == section); next }
        in_section && index($0, key "=") == 1 { print substr($0, length(key) + 2); exit }
    '
}

lower() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }

# listening_ports <container> <tcp|udp>: prints the local ports of listening TCP / bound UDP sockets,
# read from /proc inside the container (IPv4 and IPv6).
listening_ports() {
    local state
    [[ "$2" == tcp ]] && state=0A || state=07
    docker exec "$1" cat "/proc/net/$2" "/proc/net/${2}6" 2>/dev/null \
        | awk -v state="${state}" '$4 == state { n = split($2, a, ":"); print a[n] }' \
        | while read -r hex; do printf '%d\n' "0x${hex}"; done | sort -u
}

# pid_of <container> <process name>: prints the pid(s) of the process inside the container.
pid_of() {
    docker exec "$1" bash -c '
        for p in /proc/[0-9]*; do
            [[ "$(cat "$p/comm" 2>/dev/null)" == "$1" ]] && echo "${p#/proc/}"
        done; true' _ "$2"
}

# send_signal <container> <signal> <pid>: the exec may itself be killed when the container stops
# as a result, so its exit status is not meaningful.
send_signal() {
    docker exec "$1" bash -c 'kill -s "$1" "$2"' _ "$2" "$3" || true
}

# compose_config <docker compose config options...>: reads docker-compose.yml only from the
# environment given, never from a .env file in the checkout.
compose_config() { docker compose --env-file /dev/null -f docker-compose.yml config "$@"; }

config_sums() {
    helper "$1" "$2" sha256sum /etc/aspia/router.conf /etc/aspia/relay.conf /etc/aspia/host.pub /etc/aspia/relay.pub
}

# ---------------------------------------------------------------------------------------------
# Scenarios

scenario_build() {
    log "0. Build: the image, and a build with a tampered checksum must fail"
    TAMPER_DIR="$(mktemp -d)"
    cp Dockerfile aspia_start aspia_health aspia_common.sh checksums.sha256 .dockerignore "${TAMPER_DIR}/"
    # Flip the first hex digit of the router checksum.
    awk 'NR == 1 { c = substr($0, 1, 1); $0 = (c == "0" ? "1" : "0") substr($0, 2) } { print }' \
        checksums.sha256 > "${TAMPER_DIR}/checksums.sha256"
    if docker build --progress=plain --platform "${PLATFORM}" "${TAMPER_DIR}" > "${TAMPER_DIR}/build.log" 2>&1; then
        fail "the build succeeded with a wrong checksum"
    fi
    grep -q 'FAILED' "${TAMPER_DIR}/build.log" || { cat "${TAMPER_DIR}/build.log" >&2; fail "the build failed, but not on the checksum"; }
    ok "a wrong checksum fails the build: $(grep -m1 -o 'aspia-router[^ ]*: FAILED' "${TAMPER_DIR}/build.log")"

    if [[ -n "${ASPIA_TEST_IMAGE:-}" ]]; then
        ok "testing the given image ${IMAGE}"
    else
        docker build -q --platform "${PLATFORM}" -t "${IMAGE}" . >/dev/null
        ok "built ${IMAGE}"
    fi
    # The helper uses the product's base image, taken from the Dockerfile so that one edit updates both.
    docker build -q --platform "${PLATFORM}" -t "${HELPER_IMAGE}" \
        --build-arg "BASE_IMAGE=$(awk '/^FROM / { print $2; exit }' Dockerfile)" tests/helper >/dev/null
    ok "built ${HELPER_IMAGE}"
}

scenario_compose() {
    local images out
    log "0c. docker-compose.yml: builds locally by default, ASPIA_IMAGE overrides, ports from the same variable"
    images="$(EXTERNAL_IP="${IP_NEW}" ASPIA_IMAGE='' compose_config --images)"
    [[ "${images}" == "aspia-server:3.0.21" ]] || fail "default image is '${images}', expected aspia-server:3.0.21"
    EXTERNAL_IP="${IP_NEW}" ASPIA_IMAGE='' compose_config --format json \
        | grep -q '"build"' || fail "the compose service has no build section"
    images="$(EXTERNAL_IP="${IP_NEW}" ASPIA_IMAGE=registry.example/aspia-server:3.0.21 compose_config --images)"
    [[ "${images}" == registry.example/aspia-server:3.0.21 ]] || fail "ASPIA_IMAGE is not used: '${images}'"
    ok "default image aspia-server:3.0.21 with a build section; ASPIA_IMAGE overrides it"

    # EXTERNAL_IP/ASPIA_RELAY_PUBLIC_ADDRESS is required by the entrypoint (scenario 6), not by
    # compose: "docker compose config" must still succeed without it, so that a user who sets only
    # the new alias is not blocked by compose before the container ever runs.
    if out="$(unset EXTERNAL_IP; compose_config 2>&1)"; then
        ok "docker compose config succeeds without EXTERNAL_IP (the container enforces it instead)"
    else
        fail "docker compose config failed without EXTERNAL_IP: ${out}"
    fi

    # Every published port comes from the same variable on both sides (host and container).
    out="$(EXTERNAL_IP="${IP_NEW}" ASPIA_RELAY_PEER_PORT=19070 compose_config --format json)"
    if ! grep -q '"target": 19070' <<<"${out}" || ! grep -q '"published": "19070"' <<<"${out}"; then
        fail "ASPIA_RELAY_PEER_PORT did not change both sides of the port mapping: ${out}"
    fi
    ok "ASPIA_RELAY_PEER_PORT changes both the published and the container port"

    docker compose --env-file .env.example -f docker-compose.yml config >/dev/null \
        || fail "docker compose config failed with .env.example"
    ok "docker compose config succeeds with .env.example"
}

scenario_command() {
    local out
    log "0b. A command given to docker run runs instead of the server, under tini"
    # No EXTERNAL_IP: if the server started instead, it would exit 1 with an error.
    out="$(docker run --rm --platform "${PLATFORM}" --label "aspia-test=${RUN_ID}" "${IMAGE}" \
        sh -c 'cat /proc/1/comm; aspia_router --version 2>/dev/null')" \
        || fail "the command exited non-zero: ${out}"
    [[ "$(head -n 1 <<<"${out}")" == tini ]] || fail "PID 1 is not tini: ${out}"
    grep -qE '^aspia_router [0-9]' <<<"${out}" || fail "the command did not run: ${out}"
    ok "ran 'aspia_router --version' under tini: $(grep -E '^aspia_router' <<<"${out}")"
}

S1_CFG="" S1_DB="" S1_NAME=""

scenario_clean_start() {
    local name logs host_pub relay_pub relay_conf router_conf ports port net unreachable
    log "1. Clean start on empty volumes"
    S1_CFG="$(new_volume s1-config)"
    S1_DB="$(new_volume s1-db)"
    net="${RUN_ID}-net"
    docker network create --label "aspia-test=${RUN_ID}" "${net}" >/dev/null
    run_new s1 "${S1_CFG}" "${S1_DB}" -e "EXTERNAL_IP=${IP_NEW}" --network "${net}" --network-alias aspia
    name="${CURRENT_CONTAINER}"
    S1_NAME="${name}"
    wait_healthy "${name}"

    # shellcheck disable=SC2016  # $f is expanded by sh inside the helper container
    helper "${S1_CFG}" "${S1_DB}" sh -c 'for f in /etc/aspia/router.conf /etc/aspia/relay.conf /etc/aspia/host.pub \
            /etc/aspia/relay.pub /var/lib/aspia/router.db3; do test -s "$f" || exit 1; done' \
        || fail "configs, keys or database missing"
    ok "router.conf, relay.conf, host.pub, relay.pub and router.db3 were created"

    host_pub="$(helper "${S1_CFG}" "${S1_DB}" cat /etc/aspia/host.pub)"
    relay_pub="$(helper "${S1_CFG}" "${S1_DB}" cat /etc/aspia/relay.pub)"
    router_conf="$(helper "${S1_CFG}" "${S1_DB}" cat /etc/aspia/router.conf)"
    relay_conf="$(helper "${S1_CFG}" "${S1_DB}" cat /etc/aspia/relay.conf)"

    [[ "$(helper "${S1_CFG}" "${S1_DB}" x25519_pub "$(ini_value "${router_conf}" host private_key)")" == "$(lower "${host_pub}")" ]] \
        || fail "host.pub does not match host/private_key in router.conf"
    ok "host.pub is the public key of host/private_key"
    [[ "$(ini_value "${relay_conf}" peer public_address)" == "${IP_NEW}" ]] || fail "relay.conf public_address is not ${IP_NEW}"
    ok "relay.conf [peer] public_address = ${IP_NEW}"
    [[ "$(lower "$(ini_value "${relay_conf}" router public_key)")" == "$(lower "${relay_pub}")" ]] \
        || fail "relay.conf [router] public_key is not relay.pub"
    ok "relay.conf [router] public_key = relay.pub"

    logs="$(docker logs "${name}" 2>&1)"
    grep -qF "${host_pub}" <<<"${logs}" || fail "the log does not contain the public key for hosts"
    ok "the log contains the public key for hosts (${host_pub})"
    grep -q 'Connection to the router is established' <<<"${logs}" || fail "the Relay did not log a connection to the Router"
    ok "the Relay logged 'Connection to the router is established'"
    if grep -qiE 'password: *[^ ]' <<<"${logs}"; then fail "the log contains a password line"; fi
    ok "the log contains no password"

    ports="$(listening_ports "${name}" tcp | tr '\n' ' ')"
    for port in 8060 8061 8062 8063 8070; do
        grep -qw "${port}" <<<"${ports}" || fail "nothing listens on ${port}/tcp (listening: ${ports})"
    done
    ok "listening TCP ports: ${ports}(an extra random port is Docker's embedded DNS on a user network)"
    grep -qw 8065 <<<"$(listening_ports "${name}" udp)" || fail "nothing listens on 8065/udp"
    ok "listening UDP port: 8065"
    # One helper container tries every port and prints the ones it could not reach.
    unreachable="$(docker run --rm --platform "${PLATFORM}" --label "aspia-test=${RUN_ID}" --network "${net}" "${HELPER_IMAGE}" \
        bash -c 'for p in 8060 8061 8062 8070; do timeout 5 bash -c "exec 3<>/dev/tcp/aspia/$p" 2>/dev/null || echo "$p"; done')"
    [[ -z "${unreachable}" ]] || fail "cannot connect from another container to: ${unreachable//$'\n'/ }"
    ok "8060, 8061, 8062 and 8070 accept TCP connections from another container"
}

scenario_restart() {
    local before after logs
    log "2. Restart: keys and configuration unchanged"
    CURRENT_CONTAINER="${S1_NAME}"
    before="$(config_sums "${S1_CFG}" "${S1_DB}")"
    docker restart "${S1_NAME}" >/dev/null
    wait_healthy "${S1_NAME}"
    after="$(config_sums "${S1_CFG}" "${S1_DB}")"
    [[ "${before}" == "${after}" ]] || fail "configs or keys changed on restart:"$'\n'"${before}"$'\n'"${after}"
    ok "sha256 of router.conf, relay.conf, host.pub, relay.pub unchanged"
    helper "${S1_CFG}" "${S1_DB}" sh -c '! ls /etc/aspia /var/lib/aspia | grep -q "\.pre-"' || fail "a restart created backup files"
    ok "no backup copies created on restart"
    logs="$(docker logs "${S1_NAME}" 2>&1)"
    [[ "$(grep -c 'Public key for hosts' <<<"${logs}")" == 2 ]] || fail "expected the key banner twice"
    [[ "$(grep 'Public key for hosts' <<<"${logs}" | awk '{print $NF}' | sort -u | wc -l | tr -d ' ')" == 1 ]] \
        || fail "the logged key changed across the restart"
    ok "the same public key was logged on both starts"
}

scenario_new_external_ip() {
    local name before_relay before_other relay_conf relay_pub backups
    local ip=198.51.100.7
    log "2b. A changed EXTERNAL_IP is applied to the existing relay.conf, with a copy first"
    docker stop "${S1_NAME}" >/dev/null
    # Also empty [router] public_key, so that one start changes relay.conf twice.
    helper_rw "${S1_CFG}" "${S1_DB}" sed -i 's/^public_key=.*/public_key=/' /etc/aspia/relay.conf
    before_relay="$(helper "${S1_CFG}" "${S1_DB}" sha256sum /etc/aspia/relay.conf | awk '{print $1}')"
    before_other="$(helper "${S1_CFG}" "${S1_DB}" sha256sum /etc/aspia/router.conf /etc/aspia/host.pub /etc/aspia/relay.pub)"
    run_new s2b "${S1_CFG}" "${S1_DB}" -e "EXTERNAL_IP=${ip}"
    name="${CURRENT_CONTAINER}"
    wait_healthy "${name}"
    relay_conf="$(helper "${S1_CFG}" "${S1_DB}" cat /etc/aspia/relay.conf)"
    relay_pub="$(helper "${S1_CFG}" "${S1_DB}" cat /etc/aspia/relay.pub)"
    [[ "$(ini_value "${relay_conf}" peer public_address)" == "${ip}" ]] || fail "public_address is not ${ip}"
    [[ "$(lower "$(ini_value "${relay_conf}" router public_key)")" == "$(lower "${relay_pub}")" ]] || fail "public_key was not refilled"
    ok "relay.conf: public_address = ${ip}, empty public_key refilled from relay.pub"
    backups="$(helper "${S1_CFG}" "${S1_DB}" sh -c 'sha256sum /etc/aspia/relay.conf.pre-*' | awk '{print $1}')"
    [[ "${backups}" == "${before_relay}" ]] || fail "expected exactly one relay.conf backup equal to the old file, got: ${backups}"
    ok "one backup copy of relay.conf, equal to the file before the change"
    [[ "$(helper "${S1_CFG}" "${S1_DB}" sha256sum /etc/aspia/router.conf /etc/aspia/host.pub /etc/aspia/relay.pub)" == "${before_other}" ]] \
        || fail "router.conf or the keys changed"
    ok "router.conf, host.pub and relay.pub unchanged"
    docker rm -f "${name}" >/dev/null
    docker start "${S1_NAME}" >/dev/null   # back to IP_NEW for the next scenarios
    CURRENT_CONTAINER="${S1_NAME}"
    wait_healthy "${S1_NAME}"
}

scenario_stop() {
    local start elapsed code n before
    log "4. docker stop: under 10 s, exit code 0 or 143"
    CURRENT_CONTAINER="${S1_NAME}"
    before="$(sigterm_lines "${S1_NAME}")"
    start="$(date +%s)"
    docker stop "${S1_NAME}" >/dev/null
    elapsed=$(($(date +%s) - start))
    code="$(state .State.ExitCode "${S1_NAME}")"
    ((elapsed < 10)) || fail "docker stop took ${elapsed} s"
    [[ "${code}" == 0 || "${code}" == 143 ]] || fail "exit code ${code} after docker stop"
    ok "stopped in ${elapsed} s (whole seconds), exit code ${code}"
    # Both Aspia processes must report the forwarded signal. Counting the new lines checks exactly
    # that, independent of the order in which the lines reach docker logs.
    n=$(($(sigterm_lines "${S1_NAME}") - before))
    [[ "${n}" == 2 ]] || fail "expected both processes to log SIGTERM, found ${n}"
    ok "both Aspia processes logged the forwarded SIGTERM and exited"
}

# crash_one <process name> <signal>: the process dies on its own (nobody stopped the container).
crash_one() {
    local pid code
    docker start "${S1_NAME}" >/dev/null
    CURRENT_CONTAINER="${S1_NAME}"
    wait_healthy "${S1_NAME}"
    pid="$(pid_of "${S1_NAME}" "$1")"
    [[ "${pid}" =~ ^[0-9]+$ ]] || fail "expected one $1 process, found: '${pid}'"
    send_signal "${S1_NAME}" "$2" "${pid}"
    wait_exited "${S1_NAME}" 30
    code="$(state .State.ExitCode "${S1_NAME}")"
    [[ "${code}" != 0 ]] || fail "the container exited 0 after SIG$2 to $1"
    ok "SIG$2 to $1 (pid ${pid}): the container exited with code ${code}"
}

scenario_crash() {
    log "5. A process dies: the container exits non-zero"
    crash_one aspia_relay KILL
    crash_one aspia_router TERM   # a clean exit 0 of one process is still a failure of the container
}

scenario_relay_not_connected() {
    local out code i
    log "8. Healthcheck: a Relay that cannot authenticate the Router is not healthy"
    # A wrong but well-formed Router key, set by hand; the entrypoint must leave it alone.
    helper_rw "${S1_CFG}" "${S1_DB}" sed -i \
        's/^public_key=.*/public_key=0000000000000000000000000000000000000000000000000000000000000001/' /etc/aspia/relay.conf
    docker start "${S1_NAME}" >/dev/null
    CURRENT_CONTAINER="${S1_NAME}"
    for ((i = 0; i < HEALTH_TIMEOUT; i++)); do
        log_has "${S1_NAME}" 'ACCESS_DENIED' && break
        sleep 1
    done
    log_has "${S1_NAME}" 'ACCESS_DENIED' || fail "the Relay did not report ACCESS_DENIED"
    [[ "$(state .State.Running "${S1_NAME}")" == true ]] || fail "the container stopped"
    code=0
    out="$(docker exec "${S1_NAME}" /usr/bin/aspia_health)" || code=$?
    [[ "${code}" != 0 ]] || fail "aspia_health reports healthy although the Relay is not connected: ${out}"
    grep -q 'not connected to the Router' <<<"${out}" || fail "unexpected healthcheck output: ${out}"
    ok "aspia_health exits ${code}: ${out}"
    log_has "${S1_NAME}" 'WARNING: \[router\] public_key' || fail "no warning about the differing key"
    [[ "$(helper "${S1_CFG}" "${S1_DB}" grep '^public_key=' /etc/aspia/relay.conf)" == "public_key=0000000000000000000000000000000000000000000000000000000000000001" ]] \
        || fail "the entrypoint overwrote a key set by hand"
    ok "the hand-set key was kept and the entrypoint logged a warning"
    docker stop "${S1_NAME}" >/dev/null
}

scenario_upgrade() {
    local cfg db name old_pub old_priv old_db_sum old_json_sum router_conf relay_conf key logs out code i file
    log "3. Upgrade from ${OLD_IMAGE%@*}"
    cfg="$(new_volume s3-config)"
    db="$(new_volume s3-db)"
    name="${RUN_ID}-s3-old"
    CURRENT_CONTAINER="${name}"
    docker run -d --platform "${PLATFORM}" --label "aspia-test=${RUN_ID}" --name "${name}" \
        -e "EXTERNAL_IP=${IP_OLD}" -v "${cfg}:/etc/aspia" -v "${db}:/var/lib/aspia" "${OLD_IMAGE}" >/dev/null
    wait_exited "${name}" 60   # 2.7.0 only creates its configs on the first start
    docker start "${name}" >/dev/null
    sleep 10
    [[ "$(state .State.Running "${name}")" == true ]] || fail "2.7.0 did not keep running on its second start"
    docker stop -t 3 "${name}" >/dev/null
    ok "2.7.0 created its data (first start) and ran (second start)"

    # A fixture host, so the upgrade has a host row to keep.
    helper_rw "${cfg}" "${db}" sqlite3 /var/lib/aspia/router.db3 \
        "insert into hosts(key) values (x'00112233445566778899aabbccddeeff')"
    [[ "$(helper_rw "${cfg}" "${db}" sqlite3 /var/lib/aspia/router.db3 "select name from users")" == admin ]] \
        || fail "2.7.0 database has no admin user"
    old_pub="$(helper "${cfg}" "${db}" cat /etc/aspia/router.pub)"
    old_priv="$(helper "${cfg}" "${db}" sh -c 'grep -o "\"PrivateKey\": *\"[0-9A-Fa-f]*\"" /etc/aspia/router.json | grep -o "[0-9A-Fa-f]\{64\}"')"
    old_db_sum="$(helper "${cfg}" "${db}" sha256sum /var/lib/aspia/router.db3 | awk '{print $1}')"
    old_json_sum="$(helper "${cfg}" "${db}" sha256sum /etc/aspia/router.json /etc/aspia/relay.json | awk '{print $1}')"
    [[ ${#old_pub} == 64 && ${#old_priv} == 64 ]] || fail "could not read the 2.7.0 keys"
    ok "2.7.0 data: user admin, 1 fixture host, router.pub ${old_pub}"

    run_new s3-new "${cfg}" "${db}" -e "EXTERNAL_IP=${IP_NEW}"
    name="${CURRENT_CONTAINER}"
    wait_healthy "${name}"
    logs="$(docker logs "${name}" 2>&1)"

    key="$(grep 'Public key for hosts' <<<"${logs}" | awk '{print $NF}')"
    [[ "$(lower "${key}")" == "$(lower "${old_pub}")" ]] || fail "the logged key for hosts (${key}) is not the 2.7.0 router.pub (${old_pub})"
    ok "the logged public key for hosts equals the 2.7.0 router.pub"

    router_conf="$(helper "${cfg}" "${db}" cat /etc/aspia/router.conf)"
    [[ "$(lower "$(ini_value "${router_conf}" host private_key)")" == "$(lower "${old_priv}")" ]] \
        || fail "host/private_key is not the 2.7.0 PrivateKey"
    [[ "$(helper "${cfg}" "${db}" x25519_pub "$(ini_value "${router_conf}" host private_key)")" == "$(lower "${old_pub}")" ]] \
        || fail "the public key of host/private_key is not the 2.7.0 router.pub"
    ok "host/private_key is the 2.7.0 key: hosts configured with the 2.7.0 key keep working"
    [[ "$(helper "${cfg}" "${db}" cat /etc/aspia/host.pub /etc/aspia/relay.pub | tr -d '[:space:]' | tr '[:upper:]' '[:lower:]')" \
        == "$(lower "${old_pub}${old_pub}")" ]] || fail "host.pub and relay.pub were not created from the 2.7.0 router.pub"
    ok "host.pub and relay.pub hold the 2.7.0 key, as on a new install"
    grep -q 'Connection to the router is established' <<<"${logs}" || fail "the migrated Relay did not connect to the Router"
    ok "the migrated Relay connected to the migrated Router"

    relay_conf="$(helper "${cfg}" "${db}" cat /etc/aspia/relay.conf)"
    [[ "$(ini_value "${relay_conf}" peer public_address)" == "${IP_NEW}" ]] || fail "relay.conf public_address is not ${IP_NEW}"
    ok "relay.conf [peer] public_address follows the new EXTERNAL_IP (${IP_NEW})"

    out="$(helper "${cfg}" "${db}" ls /etc/aspia /var/lib/aspia)"
    grep -q '^router.json.bak$' <<<"${out}" || fail "upstream migration did not rename router.json"
    for file in /etc/aspia/router.json /etc/aspia/relay.json /var/lib/aspia/router.db3; do
        helper "${cfg}" "${db}" sh -c "ls ${file}.pre-* >/dev/null 2>&1" || fail "no backup copy of ${file}"
    done
    [[ "$(helper "${cfg}" "${db}" sh -c 'sha256sum /var/lib/aspia/router.db3.pre-*' | awk '{print $1}')" == "${old_db_sum}" ]] \
        || fail "the router.db3 backup is not the pre-upgrade database"
    [[ "$(helper "${cfg}" "${db}" sh -c 'sha256sum /etc/aspia/router.json.pre-* /etc/aspia/relay.json.pre-*' | awk '{print $1}')" == "${old_json_sum}" ]] \
        || fail "the router.json/relay.json backups are not the originals"
    ok "backups of router.json, relay.json and router.db3 exist and equal the 2.7.0 files"

    # Restart on migrated data: nothing changes, no new backups.
    out="$(config_sums_migrated "${cfg}" "${db}")"
    docker restart "${name}" >/dev/null
    wait_healthy "${name}"
    [[ "$(config_sums_migrated "${cfg}" "${db}")" == "${out}" ]] || fail "a restart after migration changed the configuration"
    [[ "$(helper "${cfg}" "${db}" sh -c 'ls /etc/aspia /var/lib/aspia | grep -c "\.pre-"')" == 3 ]] \
        || fail "a restart after migration created more backups"
    ok "a second start on migrated data changes nothing"

    docker stop "${name}" >/dev/null
    code="$(state .State.ExitCode "${name}")"
    [[ "${code}" == 0 || "${code}" == 143 ]] || fail "exit code ${code} after docker stop"
    [[ "$(helper_rw "${cfg}" "${db}" sqlite3 /var/lib/aspia/router.db3 'pragma integrity_check')" == ok ]] \
        || fail "database integrity check failed"
    [[ "$(helper_rw "${cfg}" "${db}" sqlite3 /var/lib/aspia/router.db3 "select name from users where id = 1")" == admin ]] \
        || fail "user admin is missing after the upgrade"
    [[ "$(helper_rw "${cfg}" "${db}" sqlite3 /var/lib/aspia/router.db3 "select lower(hex(key)) from hosts")" == 00112233445566778899aabbccddeeff ]] \
        || fail "the fixture host is missing after the upgrade"
    ok "database after the upgrade: integrity ok, user admin and the fixture host present"

    # The rollback documented in README.md: restore the backups, remove the 3.x files, run 2.7.0.
    # shellcheck disable=SC2016 # expanded by sh inside the helper container
    helper_rw "${cfg}" "${db}" sh -ec '
        for f in /etc/aspia/router.json /etc/aspia/relay.json /var/lib/aspia/router.db3; do
            cp -p "$(ls "$f".pre-* | head -n 1)" "$f"
        done
        rm -f /etc/aspia/router.conf /etc/aspia/relay.conf /var/lib/aspia/router.db3-wal /var/lib/aspia/router.db3-shm'
    name="${RUN_ID}-s3-rollback"
    CURRENT_CONTAINER="${name}"
    docker run -d --platform "${PLATFORM}" --label "aspia-test=${RUN_ID}" --name "${name}" \
        -e "EXTERNAL_IP=${IP_OLD}" -v "${cfg}:/etc/aspia" -v "${db}:/var/lib/aspia" "${OLD_IMAGE}" >/dev/null
    # 2.7.0's Relay connects to the Router on 8060 (hex 1F7C): ESTABLISHED (01) with remote port 8060.
    # 2.7.0 starts its Relay before its Router, so the first connection may come after a retry.
    for ((i = 0; i < HEALTH_TIMEOUT; i++)); do
        [[ "$(state .State.Running "${name}")" == true ]] || fail "2.7.0 does not run on the restored backups"
        docker exec "${name}" cat /proc/net/tcp /proc/net/tcp6 \
            | awk '$4 == "01" && $3 ~ /:1F7C$/ { found = 1 } END { exit !found }' && break
        sleep 1
    done
    ((i < HEALTH_TIMEOUT)) || fail "the 2.7.0 Relay is not connected to the 2.7.0 Router ${HEALTH_TIMEOUT} s after the rollback"
    docker stop -t 3 "${name}" >/dev/null
    [[ "$(helper_rw "${cfg}" "${db}" sqlite3 /var/lib/aspia/router.db3 "select lower(hex(key)) from hosts")" == 00112233445566778899aabbccddeeff ]] \
        || fail "the fixture host is missing after the rollback"
    ok "rollback as documented: 2.7.0 runs on the restored backups, its Relay connects, the host is there"
}

config_sums_migrated() {
    helper "$1" "$2" sha256sum /etc/aspia/router.conf /etc/aspia/relay.conf /etc/aspia/router.pub
}

scenario_no_external_ip() {
    local cfg db name code files variant
    log "6. EXTERNAL_IP unset, empty or blank: clear error, non-zero exit, nothing written"
    for variant in unset empty blank; do
        cfg="$(new_volume "s6-${variant}-config")"
        db="$(new_volume "s6-${variant}-db")"
        case "${variant}" in
            unset) run_new "s6-${variant}" "${cfg}" "${db}" ;;
            empty) run_new "s6-${variant}" "${cfg}" "${db}" -e EXTERNAL_IP= ;;
            blank) run_new "s6-${variant}" "${cfg}" "${db}" -e "EXTERNAL_IP=   " ;;
        esac
        name="${CURRENT_CONTAINER}"
        wait_exited "${name}" 60
        code="$(state .State.ExitCode "${name}")"
        [[ "${code}" != 0 ]] || fail "exit code 0 with EXTERNAL_IP ${variant}"
        log_has "${name}" 'ASPIA_RELAY_PUBLIC_ADDRESS is not set.*EXTERNAL_IP is not set' \
            || fail "no clear message about ASPIA_RELAY_PUBLIC_ADDRESS/EXTERNAL_IP"
        files="$(helper "${cfg}" "${db}" find /etc/aspia /var/lib/aspia -mindepth 1)"
        [[ -z "${files}" ]] || fail "files were created: ${files}"
        ok "EXTERNAL_IP ${variant}: exit code ${code}, message: $(grep -m1 -o 'ASPIA_RELAY_PUBLIC_ADDRESS is not set[^.]*' <<<"$(docker logs "${name}" 2>&1)")"
    done
    ok "no configuration or database was created"
}

scenario_orphan_database() {
    local cfg db name code sum_before
    log "7. A database but no configuration (e.g. config volume not mounted): refuse, change nothing"
    cfg="$(new_volume s7-config)"
    db="$(new_volume s7-db)"
    helper_rw "${cfg}" "${db}" sqlite3 /var/lib/aspia/router.db3 "create table users(id integer primary key, name text); insert into users(name) values ('admin')"
    sum_before="$(helper "${cfg}" "${db}" sha256sum /var/lib/aspia/router.db3)"
    run_new s7 "${cfg}" "${db}" -e "EXTERNAL_IP=${IP_NEW}"
    name="${CURRENT_CONTAINER}"
    wait_exited "${name}" 60
    code="$(state .State.ExitCode "${name}")"
    [[ "${code}" != 0 ]] || fail "exit code 0 with a database and no configuration"
    log_has "${name}" 'Nothing was changed' || fail "no clear message"
    [[ "$(helper "${cfg}" "${db}" sha256sum /var/lib/aspia/router.db3)" == "${sum_before}" ]] || fail "the database changed"
    [[ "$(helper "${cfg}" "${db}" find /etc/aspia /var/lib/aspia -mindepth 1)" == /var/lib/aspia/router.db3 ]] \
        || fail "files were created or renamed"
    ok "exit code ${code}; database untouched; no new keys or configs"
}

# refused_unchanged <name> <config volume> <database volume> <what>: starts the image on volumes that
# must be refused, and checks that it exits non-zero with a clear message and changes no file.
refused_unchanged() {
    local cfg="$2" db="$3" before name code
    before="$(helper "${cfg}" "${db}" sh -c 'cd / && find etc/aspia var/lib/aspia -mindepth 1 -exec sha256sum {} + 2>/dev/null | sort')"
    run_new "$1" "${cfg}" "${db}" -e "EXTERNAL_IP=${IP_NEW}"
    name="${CURRENT_CONTAINER}"
    wait_exited "${name}" 60
    code="$(state .State.ExitCode "${name}")"
    [[ "${code}" != 0 ]] || fail "exit code 0 with $4"
    log_has "${name}" 'Nothing was changed' || fail "no clear message for $4"
    [[ "$(helper "${cfg}" "${db}" sh -c 'cd / && find etc/aspia var/lib/aspia -mindepth 1 -exec sha256sum {} + 2>/dev/null | sort')" \
        == "${before}" ]] || fail "files were created or changed with $4"
    ok "$4: exit code ${code}, no file created or changed"
}

scenario_refused_relay_data() {
    local cfg db
    log "7b. Relay data that must not be used or changed: a lone relay.conf, a broken 2.x relay.json"
    cfg="$(new_volume s7b-config)"
    db="$(new_volume s7b-db)"
    helper_rw "${cfg}" "${db}" sh -c 'printf "[router]\npublic_key=%064d\n" 1 > /etc/aspia/relay.conf'
    refused_unchanged s7b "${cfg}" "${db}" "a relay.conf but no Router data"

    cfg="$(new_volume s7c-config)"
    db="$(new_volume s7c-db)"
    helper_rw "${cfg}" "${db}" sh -c 'echo "{}" > /etc/aspia/router.json && : > /var/lib/aspia/router.db3 && echo "{ not json" > /etc/aspia/relay.json'
    refused_unchanged s7c "${cfg}" "${db}" "an invalid 2.x relay.json"
}

scenario_env_apply() {
    local cfg db name router_conf relay_conf
    log "9. ASPIA_ROUTER_*/ASPIA_RELAY_* variables land in the configuration; healthy on custom ports"
    cfg="$(new_volume s9-config)"
    db="$(new_volume s9-db)"
    run_new s9 "${cfg}" "${db}" \
        -e "ASPIA_RELAY_PUBLIC_ADDRESS=${IP_NEW}" \
        -e ASPIA_ROUTER_CLIENT_PORT=19062 -e ASPIA_ROUTER_HOST_PORT=19061 -e ASPIA_ROUTER_LEGACY_PORT=19060 \
        -e ASPIA_ROUTER_STUN_ENABLED=1 -e ASPIA_ROUTER_STUN_PORT=19065 \
        -e ASPIA_ROUTER_CLIENT_ALLOWED_IPS=203.0.113.0/24 -e ASPIA_ROUTER_HOST_ALLOWED_IPS=203.0.113.0/24 \
        -e ASPIA_ROUTER_RELAY_ALLOWED_IPS=127.0.0.1,172.18.0.0/16 \
        -e ASPIA_RELAY_PEER_PORT=19070 -e ASPIA_RELAY_IDLE_TIMEOUT=10 -e ASPIA_RELAY_MAX_PEERS=50
    name="${CURRENT_CONTAINER}"
    # aspia_health reads every port from the config files, not from constants, so becoming healthy
    # on these non-default ports is itself proof that the healthcheck follows the new variables.
    wait_healthy "${name}"
    router_conf="$(helper "${cfg}" "${db}" cat /etc/aspia/router.conf)"
    relay_conf="$(helper "${cfg}" "${db}" cat /etc/aspia/relay.conf)"
    [[ "$(ini_value "${router_conf}" client port)" == 19062 ]] || fail "client/port not applied"
    [[ "$(ini_value "${router_conf}" host port)" == 19061 ]] || fail "host/port not applied"
    [[ "$(ini_value "${router_conf}" host legacy_port)" == 19060 ]] || fail "host/legacy_port not applied"
    [[ "$(ini_value "${router_conf}" stun port)" == 19065 ]] || fail "stun/port not applied"
    [[ "$(ini_value "${router_conf}" stun enabled)" == 1 ]] || fail "stun/enabled not applied"
    [[ "$(ini_value "${router_conf}" client white_list)" == "203.0.113.0/24" ]] || fail "client/white_list not applied"
    [[ "$(ini_value "${router_conf}" host white_list)" == "203.0.113.0/24" ]] || fail "host/white_list not applied"
    [[ "$(ini_value "${router_conf}" relay white_list)" == "127.0.0.1,172.18.0.0/16" ]] || fail "relay/white_list not applied"
    [[ "$(ini_value "${relay_conf}" peer port)" == 19070 ]] || fail "peer/port not applied"
    [[ "$(ini_value "${relay_conf}" peer idle_timeout)" == 10 ]] || fail "peer/idle_timeout not applied"
    [[ "$(ini_value "${relay_conf}" peer max_count)" == 50 ]] || fail "peer/max_count not applied"
    ok "every set variable landed in router.conf/relay.conf, and the container is healthy on non-default ports"
}

scenario_env_persistence() {
    local cfg db name port
    log "10. A hand-edited value survives while its variable is unset; setting the variable overwrites it"
    cfg="$(new_volume s10-config)"
    db="$(new_volume s10-db)"
    run_new s10 "${cfg}" "${db}" -e "ASPIA_RELAY_PUBLIC_ADDRESS=${IP_NEW}"
    name="${CURRENT_CONTAINER}"
    wait_healthy "${name}"
    docker stop "${name}" >/dev/null

    # Hand-edit client/port directly in the file, as a user editing router.conf on the volume would.
    helper_rw "${cfg}" "${db}" sed -i 's/^port=8062$/port=19999/' /etc/aspia/router.conf
    [[ "$(helper "${cfg}" "${db}" grep -c '^port=19999$' /etc/aspia/router.conf)" == 1 ]] \
        || fail "test setup: the hand edit did not take"

    # Restart with ASPIA_ROUTER_CLIENT_PORT still unset: the hand edit must survive.
    docker start "${name}" >/dev/null
    CURRENT_CONTAINER="${name}"
    wait_healthy "${name}"
    port="$(ini_value "$(helper "${cfg}" "${db}" cat /etc/aspia/router.conf)" client port)"
    [[ "${port}" == 19999 ]] \
        || fail "the hand-edited client/port was overwritten (now '${port}') although ASPIA_ROUTER_CLIENT_PORT is unset"
    ok "ASPIA_ROUTER_CLIENT_PORT unset: the hand-edited client/port=19999 survived a restart"

    docker stop "${name}" >/dev/null
    run_new s10b "${cfg}" "${db}" -e "ASPIA_RELAY_PUBLIC_ADDRESS=${IP_NEW}" -e ASPIA_ROUTER_CLIENT_PORT=8062
    name="${CURRENT_CONTAINER}"
    wait_healthy "${name}"
    port="$(ini_value "$(helper "${cfg}" "${db}" cat /etc/aspia/router.conf)" client port)"
    [[ "${port}" == 8062 ]] \
        || fail "ASPIA_ROUTER_CLIENT_PORT=8062 did not overwrite the earlier hand edit (still '${port}')"
    ok "setting ASPIA_ROUTER_CLIENT_PORT overwrites the earlier hand edit, as documented"
}

# run_invalid_env <slug> <text expected in the error> <docker run argument...>: starts the image
# with one bad ASPIA_ROUTER_*/ASPIA_RELAY_*/PUID/PGID value on fresh volumes and checks that it
# exits non-zero, names the variable, and creates nothing.
run_invalid_env() {
    local slug="$1" expect="$2" cfg db name code
    shift 2
    cfg="$(new_volume "s11-${slug}-config")"
    db="$(new_volume "s11-${slug}-db")"
    run_new "s11-${slug}" "${cfg}" "${db}" "$@"
    name="${CURRENT_CONTAINER}"
    wait_exited "${name}" 60
    code="$(state .State.ExitCode "${name}")"
    [[ "${code}" != 0 ]] || fail "exit code 0 with ${expect}"
    log_has "${name}" "${expect}" || fail "the error does not mention ${expect} (${slug})"
    [[ -z "$(helper "${cfg}" "${db}" find /etc/aspia /var/lib/aspia -mindepth 1)" ]] \
        || fail "files were created with ${expect}"
    ok "${expect}: exit code ${code}, nothing written"
}

scenario_env_invalid() {
    log "11. An invalid value: one clear error naming the variable, non-zero exit, nothing written"
    run_invalid_env port "ASPIA_ROUTER_CLIENT_PORT='99999'" \
        -e "ASPIA_RELAY_PUBLIC_ADDRESS=${IP_NEW}" -e ASPIA_ROUTER_CLIENT_PORT=99999
    run_invalid_env bool "ASPIA_ROUTER_STUN_ENABLED='maybe'" \
        -e "ASPIA_RELAY_PUBLIC_ADDRESS=${IP_NEW}" -e ASPIA_ROUTER_STUN_ENABLED=maybe
    run_invalid_env list "ASPIA_ROUTER_CLIENT_ALLOWED_IPS='not-an-ip'" \
        -e "ASPIA_RELAY_PUBLIC_ADDRESS=${IP_NEW}" -e ASPIA_ROUTER_CLIENT_ALLOWED_IPS=not-an-ip
    run_invalid_env timeout "ASPIA_RELAY_IDLE_TIMEOUT='0'" \
        -e "ASPIA_RELAY_PUBLIC_ADDRESS=${IP_NEW}" -e ASPIA_RELAY_IDLE_TIMEOUT=0
    run_invalid_env maxpeers "ASPIA_RELAY_MAX_PEERS='abc'" \
        -e "ASPIA_RELAY_PUBLIC_ADDRESS=${IP_NEW}" -e ASPIA_RELAY_MAX_PEERS=abc
    run_invalid_env address "ASPIA_RELAY_PUBLIC_ADDRESS='bad_host!name'" \
        -e "ASPIA_RELAY_PUBLIC_ADDRESS=bad_host!name"
    run_invalid_env puid "PUID and PGID must both be set" \
        -e "ASPIA_RELAY_PUBLIC_ADDRESS=${IP_NEW}" -e PUID=1000
    run_invalid_env relaywhitelist "does not cover 127.0.0.1" \
        -e "ASPIA_RELAY_PUBLIC_ADDRESS=${IP_NEW}" -e ASPIA_ROUTER_RELAY_ALLOWED_IPS=172.18.0.0/16
}

scenario_env_auto_no_network() {
    local cfg db name code
    log "12. ASPIA_RELAY_PUBLIC_ADDRESS=auto with no network: clear error, non-zero exit, nothing written"
    cfg="$(new_volume s12-config)"
    db="$(new_volume s12-db)"
    run_new s12 "${cfg}" "${db}" -e ASPIA_RELAY_PUBLIC_ADDRESS=auto --network none
    name="${CURRENT_CONTAINER}"
    wait_exited "${name}" 60
    code="$(state .State.ExitCode "${name}")"
    [[ "${code}" != 0 ]] || fail "exit code 0 with ASPIA_RELAY_PUBLIC_ADDRESS=auto and no network"
    log_has "${name}" 'ASPIA_RELAY_PUBLIC_ADDRESS=auto: could not detect' \
        || fail "no clear message about the failed detection"
    [[ -z "$(helper "${cfg}" "${db}" find /etc/aspia /var/lib/aspia -mindepth 1)" ]] || fail "files were created"
    ok "auto with no network: exit code ${code}, nothing written"
}

scenario_env_migration() {
    local cfg db name relay_conf value
    log "13. A 2.x migration start also applies ASPIA_RELAY_MAX_PEERS (a field the upstream migration itself copies)"
    cfg="$(new_volume s13-config)"
    db="$(new_volume s13-db)"
    CURRENT_CONTAINER="${RUN_ID}-s13-old"
    docker run -d --platform "${PLATFORM}" --label "aspia-test=${RUN_ID}" --name "${CURRENT_CONTAINER}" \
        -e "EXTERNAL_IP=${IP_OLD}" -v "${cfg}:/etc/aspia" -v "${db}:/var/lib/aspia" "${OLD_IMAGE}" >/dev/null
    wait_exited "${CURRENT_CONTAINER}" 60   # 2.7.0 only creates its configs on the first start

    run_new s13-new "${cfg}" "${db}" -e "ASPIA_RELAY_PUBLIC_ADDRESS=${IP_NEW}" -e ASPIA_RELAY_MAX_PEERS=42
    name="${CURRENT_CONTAINER}"
    wait_healthy "${name}"
    relay_conf="$(helper "${cfg}" "${db}" cat /etc/aspia/relay.conf)"
    value="$(ini_value "${relay_conf}" peer max_count)"
    [[ "${value}" == 42 ]] \
        || fail "ASPIA_RELAY_MAX_PEERS was not carried through the 2.x migration (peer/max_count = '${value}')"
    ok "ASPIA_RELAY_MAX_PEERS=42 took effect on the migration start itself (written to relay.json first)"
}

scenario_puid_pgid() {
    local cfg db name uid_lines
    log "14. PUID/PGID: the Router and the Relay run as that uid/gid, and the files they write are owned by it"
    cfg="$(new_volume s14-config)"
    db="$(new_volume s14-db)"
    run_new s14 "${cfg}" "${db}" -e "ASPIA_RELAY_PUBLIC_ADDRESS=${IP_NEW}" -e PUID=1000 -e PGID=1000
    name="${CURRENT_CONTAINER}"
    wait_healthy "${name}"

    [[ "$(helper "${cfg}" "${db}" stat -c '%u:%g' /etc/aspia/router.conf)" == "1000:1000" ]] \
        || fail "router.conf is not owned by 1000:1000"
    [[ "$(helper "${cfg}" "${db}" stat -c '%u:%g' /var/lib/aspia/router.db3)" == "1000:1000" ]] \
        || fail "router.db3 is not owned by 1000:1000"
    ok "router.conf and router.db3 are owned by uid=1000 gid=1000"

    # shellcheck disable=SC2016  # expanded by sh inside the container, not by this shell
    uid_lines="$(docker exec "${name}" sh -c '
        for p in /proc/[0-9]*; do
            n=$(cat "$p/comm" 2>/dev/null)
            case "$n" in
                aspia_router|aspia_relay) echo "$n $(awk "/^Uid:/{print \$2}" "$p/status")" ;;
            esac
        done')"
    [[ "$(grep -c ' 1000$' <<<"${uid_lines}")" == 2 ]] \
        || fail "aspia_router and aspia_relay are not both running as uid 1000: ${uid_lines}"
    ok "aspia_router and aspia_relay both run as uid 1000 (${uid_lines//$'\n'/; })"
}

# ---------------------------------------------------------------------------------------------

scenario_build
scenario_command
scenario_compose
scenario_clean_start
scenario_restart
scenario_new_external_ip
scenario_stop
scenario_crash
scenario_relay_not_connected
scenario_upgrade
scenario_no_external_ip
scenario_orphan_database
scenario_refused_relay_data
scenario_env_apply
scenario_env_persistence
scenario_env_invalid
scenario_env_auto_no_network
scenario_env_migration
scenario_puid_pgid

log "All scenarios passed (image ${IMAGE})"
