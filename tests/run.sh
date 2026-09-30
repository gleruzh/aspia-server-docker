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
#   0. build: a tampered checksum makes the build fail
#   1. clean start
#   2. restart keeps keys and configuration; 2b. a changed EXTERNAL_IP is applied, with a copy
#   3. upgrade from paprikkafox/aspia-server:2.7.0
#   4. docker stop is fast and clean
#   5. a crashed process stops the container with a non-zero exit code
#   6. EXTERNAL_IP unset, empty or blank
#   7. database without configuration: refuse, change nothing
#   8. healthcheck: a Relay that is running but not connected is not healthy
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

config_sums() {
    helper "$1" "$2" sha256sum /etc/aspia/router.conf /etc/aspia/relay.conf /etc/aspia/host.pub /etc/aspia/relay.pub
}

# ---------------------------------------------------------------------------------------------
# Scenarios

scenario_build() {
    log "0. Build: the image, and a build with a tampered checksum must fail"
    TAMPER_DIR="$(mktemp -d)"
    cp Dockerfile aspia_start aspia_health checksums.sha256 .dockerignore "${TAMPER_DIR}/"
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
    docker build -q --platform "${PLATFORM}" -t "${HELPER_IMAGE}" tests/helper >/dev/null
    ok "built ${HELPER_IMAGE}"
}

S1_CFG="" S1_DB="" S1_NAME=""

scenario_clean_start() {
    local name logs host_pub relay_pub relay_conf router_conf ports port net
    log "1. Clean start on empty volumes"
    S1_CFG="$(new_volume s1-config)"
    S1_DB="$(new_volume s1-db)"
    net="${RUN_ID}-net"
    docker network create --label "aspia-test=${RUN_ID}" "${net}" >/dev/null
    run_new s1 "${S1_CFG}" "${S1_DB}" -e "EXTERNAL_IP=${IP_NEW}" --network "${net}" --network-alias aspia
    name="${CURRENT_CONTAINER}"
    S1_NAME="${name}"
    wait_healthy "${name}"

    helper "${S1_CFG}" "${S1_DB}" test -s /etc/aspia/router.conf -a -s /etc/aspia/relay.conf \
        -a -s /etc/aspia/host.pub -a -s /etc/aspia/relay.pub -a -s /var/lib/aspia/router.db3 \
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
    for port in 8060 8061 8062 8070; do
        docker run --rm --platform "${PLATFORM}" --label "aspia-test=${RUN_ID}" --network "${net}" "${HELPER_IMAGE}" \
            timeout 5 bash -c "exec 3<>/dev/tcp/aspia/${port}" || fail "cannot connect to ${port}/tcp from another container"
    done
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
    local start elapsed code n
    log "4. docker stop: under 10 s, exit code 0 or 143"
    CURRENT_CONTAINER="${S1_NAME}"
    start="$(date +%s)"
    docker stop "${S1_NAME}" >/dev/null
    elapsed=$(($(date +%s) - start))
    code="$(state .State.ExitCode "${S1_NAME}")"
    ((elapsed < 10)) || fail "docker stop took ${elapsed} s"
    [[ "${code}" == 0 || "${code}" == 143 ]] || fail "exit code ${code} after docker stop"
    ok "stopped in ${elapsed} s (whole seconds), exit code ${code}"
    # Log lines after the entrypoint forwarded the signal: both Aspia processes must report it.
    n="$(docker logs "${S1_NAME}" 2>&1 \
        | awk '/Received SIGTERM/ { tail = "" } { tail = tail $0 "\n" } END { printf "%s", tail }' \
        | grep -cE 'Signal received: +"SIGTERM"' || true)"
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
    for ((i = 0; i < 60; i++)); do
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
    for ((i = 0; i < 60; i++)); do
        [[ "$(state .State.Running "${name}")" == true ]] || fail "2.7.0 does not run on the restored backups"
        docker exec "${name}" cat /proc/net/tcp /proc/net/tcp6 \
            | awk '$4 == "01" && $3 ~ /:1F7C$/ { found = 1 } END { exit !found }' && break
        sleep 1
    done
    ((i < 60)) || fail "the 2.7.0 Relay is not connected to the 2.7.0 Router 60 s after the rollback"
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
        log_has "${name}" 'ERROR: EXTERNAL_IP is not set' || fail "no clear message about EXTERNAL_IP"
        files="$(helper "${cfg}" "${db}" find /etc/aspia /var/lib/aspia -mindepth 1)"
        [[ -z "${files}" ]] || fail "files were created: ${files}"
        ok "EXTERNAL_IP ${variant}: exit code ${code}, message: $(grep -m1 -o 'ERROR: EXTERNAL_IP is not set[^.]*' <<<"$(docker logs "${name}" 2>&1)")"
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

# ---------------------------------------------------------------------------------------------

scenario_build
scenario_clean_start
scenario_restart
scenario_new_external_ip
scenario_stop
scenario_crash
scenario_relay_not_connected
scenario_upgrade
scenario_no_external_ip
scenario_orphan_database

log "All scenarios passed (image ${IMAGE})"
