#!/usr/bin/env bash
#
# tests/run.sh: builds the image and runs the behaviour scenarios on plain Docker.
# Needs only Docker (and network access to pull the base images).
#
#   tests/run.sh                  build the image from this checkout, then test it
#   ASPIA_TEST_IMAGE=img tests/run.sh   test an existing image instead of building one
#   tests/run.sh --list           print the scenario groups, their weights and scenarios, and exit
#   tests/run.sh --shard 2/3      run only the groups of shard 2 of 3 (how CI splits the run)
#   tests/run.sh clean-start refused-2x   run only these groups (names from --list)
#
# A group is the unit of selection: its scenarios share containers or volumes and run in order. Any
# selection first builds the image and the helper. --shard spreads the groups over the shards by
# weight (see GROUP_TABLE at the end), the same way on every machine.
#
# Every container, volume and network the tests create carries the label aspia-test=<run id>, has
# the run id in its name, and is removed on exit, also when a scenario fails; the images it builds
# are tagged with the run id and untagged on exit. Runs on one Docker host do not collide: each has
# its own names, tags and subnet.
#
# Scenarios:
#   0. build: a tampered checksum makes the build fail; 0b. a docker run command replaces the server,
#      and the image runs the Aspia version in versions.env
#   0c. docker-compose.yml: local build by default, ASPIA_IMAGE override, EXTERNAL_IP required;
#      the client port on every address unless ASPIA_ROUTER_CLIENT_BIND_IP is set
#   1. clean start; only the owner can read the volumes (directories 700, files 600, host.pub 644);
#      the first-start warning about the empty client allow-list (not repeated in 2); the random
#      admin password is in /etc/aspia/initial-admin-password (root:root 600) and not in the log
#   2. restart keeps keys and configuration, and restricts files an older image left readable (a
#      symbolic link is skipped); 2b. a changed EXTERNAL_IP is applied, with a copy
#   3. Aspia 2.x data (router.json, or a lone relay.json): refused with the pointer to 3.0.37 and
#      nothing written (no router.conf, no keys)
#   4. docker stop is fast and clean
#   5. a crashed process stops the container with a non-zero exit code
#   6. EXTERNAL_IP unset, empty or blank
#   7. database without configuration: refuse, change nothing; 7b. same for a lone relay.conf
#   8. healthcheck: a Relay that is running but not connected is not healthy
#   9. ASPIA_ROUTER_*/ASPIA_RELAY_* variables land in the configuration; healthy on custom ports;
#      the removed ASPIA_ROUTER_LEGACY_PORT only logs a warning
#  10. a variable removed: the hand edit in the file survives; setting it again overwrites it
#  11. an invalid value: one clear error naming the variable, non-zero exit, nothing written
#  12. ASPIA_RELAY_PUBLIC_ADDRESS=auto with no network: clear error, non-zero exit; 12b. tests/auto_address.sh
#      in the image (range filter, response parser, sources and openssl options with a stub openssl,
#      certificate checks with the real one); 12c. auto with a stub openssl: a private answer is skipped,
#      the next source's address lands in relay.conf; docker stop during the detection is fast and clean
#  14. PUID/PGID: both processes run as that uid/gid, and the files they write are owned by it
#  15. an allow-list variable set to an empty value does not clear an existing list
#  16. PUID/PGID with an invalid variable: refused, and no file's ownership was changed
# ASPIA_ROLE (PR 5). Scenarios 0-16 above run without it, i.e. as role all, unchanged.
#   0d. compose.router.yml / compose.relay.yml: role, pinned image, only the ports of the role
#  17. a Router (role router) and a Relay (role relay) in two containers: both healthy, and the
#      Router log shows the Relay registered; each container runs and stores only its part
#  18. a second Relay (key from a root-only mounted file, PUID/PGID set): both Relays registered
#      with the one Router; the Relay's files belong to PUID/PGID
#  19. a Relay with a wrong Router key: never healthy, and the log says ACCESS_DENIED, also on its own
#      retry (19b); recreated on its volume with the right key and another Router address: relay.conf
#      updated (with a backup) and healthy
#  20. a Relay whose Router is unreachable: keeps running and retrying, unhealthy, log says why;
#      after the Router is back, it reconnects and is healthy again (20b)
#      The Relays of 19, 20 and 21 start together. Aspia retries a Router connection after a fixed 15 s,
#      so the checks that need a retry (19b, 20b) run after 21 and 22 instead of waiting for it.
#  21. ASPIA_ROUTER_RELAY_ALLOWED_IPS in role router: the listed Relay registers, another is refused
#  22. role relay with a required setting missing or invalid (also a bad Router address, a key file
#      inside the volumes with PUID/PGID): one clear message, non-zero exit, nothing written; a
#      Router's volume is refused
#  23. one process: docker stop is clean, and the process dying stops the container non-zero
#  24. ASPIA_ROLE=all given explicitly behaves as the default; relay-only variables are ignored;
#      a remote Relay can register with the combined container too
# Hardening (PR 5b). Every server container above starts with HARDENING, the settings the compose files ship.
#   0e. the compose files, the Podman units and the README carry exactly those settings
# Scenario 1 also checks a running container (capabilities, no-new-privileges, read-only root, pids
# limit; the Aspia processes without any capability, also as root); 14 does the same with PUID/PGID,
# then starts its volumes as root with another EXTERNAL_IP (the backup keeps owner, mode, mtime; the
# Aspia processes keep only DAC_OVERRIDE, for the files of uid 1000) and with a changed port.
# Lint (hadolint, shellcheck) is in tests/lint.sh.

set -euo pipefail

cd "$(dirname "$0")/.."

readonly PLATFORM=linux/amd64
# Docker CLI with Compose v2.31, to check docker-compose.yml against the Compose v2 still common on servers.
COMPOSE_V2_IMAGE="$(scripts/tool-image.sh compose-v2)"
readonly COMPOSE_V2_IMAGE
readonly RUN_ID="aspia-test-$$-${RANDOM}"   # unique on the Docker host, also between machines sharing one
readonly HELPER_IMAGE="aspia-server-test-helper:${RUN_ID}"
readonly IP_OLD=203.0.113.10   # a first EXTERNAL_IP, which IP_NEW replaces
readonly IP_NEW=203.0.113.11   # the EXTERNAL_IP of most scenarios
# Log line of aspia_start: a new install without ASPIA_ROUTER_CLIENT_ALLOWED_IPS (a warning, logged once).
readonly FIRST_LOGIN_WARNING='WARNING: Router: first start without a client allow-list'
readonly HEALTH_TIMEOUT=180    # seconds; generous because CI or emulation may be slow
IMAGE="${ASPIA_TEST_IMAGE:-aspia-server:${RUN_ID}}"
BUILT_IMAGES=()                # the tags this run created, untagged on exit
# The hardening the compose files and Quadlet units ship (scenario 0e checks them against it).
readonly CAPS=(CHOWN DAC_OVERRIDE SETUID SETGID KILL SETPCAP)
readonly PIDS_LIMIT=128
HARDENING=(--cap-drop ALL --security-opt no-new-privileges:true --read-only --pids-limit "${PIDS_LIMIT}")
for cap in "${CAPS[@]}"; do HARDENING+=(--cap-add "${cap}"); done
readonly HARDENING
ASPIA_VERSION="$(sed -n 's/^ASPIA_VERSION=//p' versions.env)"   # the single source of the version
readonly ASPIA_VERSION

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
        docker rm -fv "${id}" >/dev/null 2>&1 || true   # -v: also the image's anonymous volumes
    done
    docker volume ls -q --filter "label=aspia-test=${RUN_ID}" | while read -r id; do
        docker volume rm "${id}" >/dev/null 2>&1 || true
    done
    docker network ls -q --filter "label=aspia-test=${RUN_ID}" | while read -r id; do
        docker network rm "${id}" >/dev/null 2>&1 || true
    done
    ((${#BUILT_IMAGES[@]} == 0)) || docker image rm "${BUILT_IMAGES[@]}" >/dev/null 2>&1 || true
    [[ -z "${TAMPER_DIR:-}" ]] || rm -rf "${TAMPER_DIR}"
    [[ -z "${STUB_DIR:-}" ]] || rm -rf "${STUB_DIR}"
}
trap 'exit 130' INT TERM

# ---------------------------------------------------------------------------------------------
# Docker helpers

new_volume() { docker volume create --label "aspia-test=${RUN_ID}" "${RUN_ID}-$1" >/dev/null; echo "${RUN_ID}-$1"; }

# run_new <name> <config volume> <database volume> [docker run options...]: starts the image under
# test as container ${RUN_ID}-<name> and makes it CURRENT_CONTAINER (whose log a failure prints).
run_new() {
    local name="${RUN_ID}-$1" cfg="$2" db="$3"
    shift 3
    docker run -d --platform "${PLATFORM}" --label "aspia-test=${RUN_ID}" --name "${name}" "${HARDENING[@]}" \
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

# snapshot_volumes <config volume> <database volume>: the checksum of every file in the volumes,
# sorted; two snapshots are equal if no file was created, removed or changed.
snapshot_volumes() {
    helper "$1" "$2" sh -c 'cd / && find etc/aspia var/lib/aspia -mindepth 1 -exec sha256sum {} + 2>/dev/null | sort'
}

state() { docker inspect -f "{{$1}}" "$2"; }

# log_has <container> <extended regex>: the log is read completely first; "docker logs | grep -q"
# would fail under pipefail when grep exits early.
log_has() { grep -qE -- "$2" <<<"$(docker logs "$1" 2>&1)"; }

# sigterm_lines <container>: how many times an Aspia process logged a received SIGTERM.
sigterm_lines() { grep -cE 'Signal received: +"SIGTERM"' <<<"$(docker logs "$1" 2>&1)" || true; }

# wait_healthy <container>: fails if the container stops or is not healthy within HEALTH_TIMEOUT. Polled
# every 0.5 s: the health probe runs every 2 s while the container starts (--start-interval).
wait_healthy() {
    local i status
    for ((i = 0; i < HEALTH_TIMEOUT * 2; i++)); do
        [[ "$(state .State.Running "$1")" == true ]] || fail "$1 exited (code $(state .State.ExitCode "$1")) instead of becoming healthy"
        status="$(state .State.Health.Status "$1")"
        if [[ "${status}" == healthy ]]; then
            ok "$1 is healthy after ~$((i / 2)) s"
            return 0
        fi
        sleep 0.5
    done
    fail "$1 is not healthy after ${HEALTH_TIMEOUT} s (status ${status}); last check: $(docker inspect -f '{{range .State.Health.Log}}{{.Output}}{{end}}' "$1" | tail -3)"
}

# wait_exited <container> <timeout seconds>: waits until the container has stopped. Polled every
# 0.2 s: a refused start exits within a fraction of a second.
wait_exited() {
    local i
    for ((i = 0; i < $2 * 5; i++)); do
        [[ "$(state .State.Running "$1")" == false ]] && return 0
        sleep 0.2
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

# count_tcp <container> <state hex: 01 established, 0A listening> <port>: how many TCP sockets are in
# that state with that local port, read from /proc inside the container (IPv4 and IPv6).
count_tcp() {
    docker exec "$1" cat /proc/net/tcp /proc/net/tcp6 \
        | awk -v state="$2" -v port="$(printf '%04X' "$3")" '$4 == state && $2 ~ (":" port "$") { n++ } END { print n + 0 }'
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
# compose_file_config <file> <docker compose config options...>: the same for another compose file.
compose_file_config() { docker compose --env-file /dev/null -f "$1" config "${@:2}"; }
# compose_v2_config <file> [NAME=value...]: the file read by Compose v2 (docker-compose-plugin v2, which most
# servers still have) with the given variables set; JSON on stdout, the error text if it fails.
compose_v2_config() {
    local file="$1" env=() var
    for var in "${@:2}"; do env+=(-e "${var}"); done
    docker run --rm --label "aspia-test=${RUN_ID}" -v "${PWD}/${file}:/w/${file}:ro" -w /w ${env[@]+"${env[@]}"} \
        "${COMPOSE_V2_IMAGE}" docker compose --env-file /dev/null -f "${file}" config --format json 2>&1
}
# published_ports <compose file>: its published ports on one line, sorted: "<host_ip or *> <port>/<protocol> ...".
published_ports() {
    compose_file_config "$1" --format json \
        | jq_img -r '.services[].ports[] | "\(.host_ip // "*") \(.published)/\(.protocol)"' | sort | tr '\n' ' '
}

# ip_of <container>: its address on the (one) network it is attached to.
ip_of() { docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "$1"; }

# wait_log <container> <extended regex> <count> <timeout s>: waits until the log has <count> such lines.
wait_log() {
    local i
    for ((i = 0; i < $4 * 2; i++)); do
        (($(grep -cE -- "$2" <<<"$(docker logs "$1" 2>&1)" || true) >= $3)) && return 0
        sleep 0.5
    done
    fail "$1: fewer than $3 log line(s) matching '$2' after $4 s"
}

# health_says <container> <text>: aspia_health fails and its output contains <text>.
health_says() {
    local out code=0
    out="$(docker exec "$1" /usr/bin/aspia_health)" || code=$?
    [[ "${code}" != 0 ]] || fail "$1: aspia_health reports healthy: ${out}"
    grep -qF -- "$2" <<<"${out}" || fail "$1: unexpected aspia_health output: ${out}"
}

# not_yet_healthy <container>: running, not healthy, and every health probe Docker kept (the last 5)
# failed, at least one ran. A container that passed one probe stays healthy for ~90 s (interval 30 s,
# 3 retries), so this covers its whole life so far without waiting; up to 60 s for the first probe
# (Docker before 25 has no start interval).
not_yet_healthy() {
    local i codes
    for ((i = 0; i < 60; i++)); do
        [[ "$(state .State.Running "$1")" == true ]] || fail "$1 exited (code $(state .State.ExitCode "$1"))"
        [[ "$(state .State.Health.Status "$1")" != healthy ]] || fail "$1 became healthy"
        codes="$(docker inspect -f '{{range .State.Health.Log}}{{.ExitCode}} {{end}}' "$1")"
        if [[ -n "${codes}" ]]; then
            [[ " ${codes}" != *" 0 "* ]] || fail "$1 passed a health probe (exit codes: ${codes})"
            return 0
        fi
        sleep 1
    done
    fail "$1: no health probe ran in 60 s"
}

config_sums() {
    helper "$1" "$2" sha256sum /etc/aspia/router.conf /etc/aspia/relay.conf /etc/aspia/host.pub /etc/aspia/relay.pub
}

# check_modes <config volume> <database volume>: only the owner can read what is in the volumes: the
# two directories 700, every file 600, except host.pub (the public key for Hosts) 644. Links are not judged.
check_modes() {
    local bad
    bad="$(helper "$1" "$2" find /etc/aspia /var/lib/aspia -maxdepth 1 ! -type l -exec stat -c '%a %n' {} + \
        | awk '{ want = 600 } $2 ~ /\/host\.pub$/ { want = 644 } $2 == "/etc/aspia" || $2 == "/var/lib/aspia" { want = 700 }
               $1 != want')"
    [[ -z "${bad}" ]] || fail "other modes than 700 (the directories), 600 (files) and 644 (host.pub):"$'\n'"${bad}"
}

# ---------------------------------------------------------------------------------------------
# Scenarios

# build_image <tag> <docker build arguments...>: builds the image and untags it on exit.
build_image() {
    BUILT_IMAGES+=("$1")
    docker build -q --platform "${PLATFORM}" -t "$@" >/dev/null
    ok "built $1"
}

# setup: the image under test (unless ASPIA_TEST_IMAGE names one) and the helper; every selection needs both.
setup() {
    log "Setup: the image under test and the helper image"
    if [[ -n "${ASPIA_TEST_IMAGE:-}" ]]; then
        ok "testing the given image ${IMAGE}"
    else
        build_image "${IMAGE}" .
    fi
    # The helper uses the product's base image, taken from the Dockerfile so that one edit updates both.
    build_image "${HELPER_IMAGE}" --build-arg "BASE_IMAGE=$(awk '/^FROM / { print $2; exit }' Dockerfile)" tests/helper
}

scenario_build() {
    log "0. Build: a build with a tampered checksum must fail"
    TAMPER_DIR="$(mktemp -d)"
    cp Dockerfile aspia_start aspia_health aspia_common.sh versions.env .dockerignore "${TAMPER_DIR}/"
    # Flip the first hex digit of the router checksum.
    awk 'BEGIN { FS = OFS = "=" } $1 == "ASPIA_ROUTER_SHA256" { c = substr($2, 1, 1); $2 = (c == "0" ? "1" : "0") substr($2, 2) } { print }' \
        versions.env > "${TAMPER_DIR}/versions.env"
    if docker build --progress=plain --platform "${PLATFORM}" "${TAMPER_DIR}" > "${TAMPER_DIR}/build.log" 2>&1; then
        fail "the build succeeded with a wrong checksum"
    fi
    grep -q 'FAILED' "${TAMPER_DIR}/build.log" || { cat "${TAMPER_DIR}/build.log" >&2; fail "the build failed, but not on the checksum"; }
    ok "a wrong checksum fails the build: $(grep -m1 -o 'aspia-router[^ ]*: FAILED' "${TAMPER_DIR}/build.log")"
}

scenario_compose() {
    local images out
    log "0c. docker-compose.yml: builds locally by default, ASPIA_IMAGE overrides, ports from the same variable"
    images="$(EXTERNAL_IP="${IP_NEW}" ASPIA_IMAGE='' compose_config --images)"
    [[ "${images}" == "aspia-server:${ASPIA_VERSION}" ]] || fail "default image is '${images}', expected aspia-server:${ASPIA_VERSION}"
    EXTERNAL_IP="${IP_NEW}" ASPIA_IMAGE='' compose_config --format json \
        | grep -q '"build"' || fail "the compose service has no build section"
    images="$(EXTERNAL_IP="${IP_NEW}" ASPIA_IMAGE="registry.example/aspia-server:${ASPIA_VERSION}" compose_config --images)"
    [[ "${images}" == "registry.example/aspia-server:${ASPIA_VERSION}" ]] || fail "ASPIA_IMAGE is not used: '${images}'"
    ok "default image aspia-server:${ASPIA_VERSION} with a build section; ASPIA_IMAGE overrides it"

    # Neither variable set: compose passes an empty EXTERNAL_IP, and the container refuses to start
    # (scenario 6). Compose cannot require "one of two" portably: Compose v2 evaluates a ":?" nested
    # in a default even when the outer variable is set.
    out="$(unset EXTERNAL_IP ASPIA_RELAY_PUBLIC_ADDRESS; compose_config --format json)" \
        || fail "docker compose config failed with neither address variable set: ${out}"
    grep -q '"EXTERNAL_IP": ""' <<<"${out}" || fail "EXTERNAL_IP is not empty with neither variable set: ${out}"
    ok "neither EXTERNAL_IP nor ASPIA_RELAY_PUBLIC_ADDRESS set: compose passes it empty, the container refuses (scenario 6)"

    # Only the new alias set: EXTERNAL_IP takes its value (a nested default, not a second ":?").
    out="$(unset EXTERNAL_IP; ASPIA_RELAY_PUBLIC_ADDRESS="${IP_NEW}" compose_config --format json)"
    grep -q "\"EXTERNAL_IP\": \"${IP_NEW}\"" <<<"${out}" \
        || fail "EXTERNAL_IP did not take the value of ASPIA_RELAY_PUBLIC_ADDRESS: ${out}"
    ok "docker compose config succeeds with only ASPIA_RELAY_PUBLIC_ADDRESS set; EXTERNAL_IP gets its value"

    # Every published port comes from the same variable on both sides (host and container).
    out="$(EXTERNAL_IP="${IP_NEW}" ASPIA_RELAY_PEER_PORT=19070 compose_config --format json)"
    if ! grep -q '"target": 19070' <<<"${out}" || ! grep -q '"published": "19070"' <<<"${out}"; then
        fail "ASPIA_RELAY_PEER_PORT did not change both sides of the port mapping: ${out}"
    fi
    ok "ASPIA_RELAY_PEER_PORT changes both the published and the container port"

    # The client port is on every address, as before
    # ASPIA_ROUTER_CLIENT_BIND_IP existed (no host_ip: IPv4 and IPv6), unless that variable is set.
    out="$(EXTERNAL_IP="${IP_NEW}" published_ports docker-compose.yml)"
    [[ "${out}" == "* 8061/tcp * 8062/tcp * 8065/udp * 8070/tcp " ]] || fail "docker-compose.yml publishes: ${out}"
    out="$(EXTERNAL_IP="${IP_NEW}" ASPIA_ROUTER_CLIENT_BIND_IP=127.0.0.1 published_ports docker-compose.yml)"
    [[ "${out}" == "* 8061/tcp * 8065/udp * 8070/tcp 127.0.0.1 8062/tcp " ]] \
        || fail "ASPIA_ROUTER_CLIENT_BIND_IP=127.0.0.1 did not limit only the client port: ${out}"
    ok "publishes 8061, 8062, 8065/udp and 8070 on every address; ASPIA_ROUTER_CLIENT_BIND_IP=127.0.0.1 limits 8062"

    docker compose --env-file .env.example -f docker-compose.yml config >/dev/null \
        || fail "docker compose config failed with .env.example"
    ok "docker compose config succeeds with .env.example"

    # The same file with Compose v2, which most servers still have (docker-compose-plugin v2).
    out="$(compose_v2_config docker-compose.yml "EXTERNAL_IP=${IP_NEW}")" \
        || fail "Compose v2 cannot read docker-compose.yml with EXTERNAL_IP set: ${out}"
    grep -q "\"EXTERNAL_IP\": \"${IP_NEW}\"" <<<"${out}" || fail "Compose v2 did not pass EXTERNAL_IP: ${out}"
    if grep -q '"host_ip"' <<<"${out}"; then fail "Compose v2 binds a port to one address by default: ${out}"; fi
    out="$(compose_v2_config docker-compose.yml "EXTERNAL_IP=${IP_NEW}" ASPIA_ROUTER_CLIENT_BIND_IP=127.0.0.1)" \
        || fail "Compose v2 cannot read docker-compose.yml with ASPIA_ROUTER_CLIENT_BIND_IP set: ${out}"
    grep -A1 '"host_ip": "127.0.0.1"' <<<"${out}" | grep -q '"target": 8062' \
        || fail "Compose v2 did not bind the client port to ASPIA_ROUTER_CLIENT_BIND_IP: ${out}"
    ok "Compose v2 ($(docker run --rm "${COMPOSE_V2_IMAGE}" docker compose version --short)) reads docker-compose.yml"
}

scenario_command() {
    local out
    log "0b. A command given to docker run runs instead of the server, under tini"
    # No EXTERNAL_IP: if the server started instead, it would exit 1 with an error.
    out="$(docker run --rm --platform "${PLATFORM}" --label "aspia-test=${RUN_ID}" "${HARDENING[@]}" "${IMAGE}" \
        sh -c 'cat /proc/1/comm; aspia_router --version 2>/dev/null')" \
        || fail "the command exited non-zero: ${out}"
    [[ "$(head -n 1 <<<"${out}")" == tini ]] || fail "PID 1 is not tini: ${out}"
    grep -qE '^aspia_router [0-9]' <<<"${out}" || fail "the command did not run: ${out}"
    grep -qF "aspia_router ${ASPIA_VERSION}." <<<"${out}" || fail "the image does not run Aspia ${ASPIA_VERSION} (versions.env): ${out}"
    ok "ran 'aspia_router --version' under tini: $(grep -E '^aspia_router' <<<"${out}")"
}

S1_CFG="" S1_DB="" S1_NAME=""

scenario_clean_start() {
    local name logs host_pub relay_pub relay_conf router_conf ports port net unreachable password password_file
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
    check_modes "${S1_CFG}" "${S1_DB}"
    ok "only the owner can read the volumes: directories 700, router.conf, relay.conf, relay.pub, router.db3* 600; host.pub 644"

    logs="$(docker logs "${name}" 2>&1)"
    grep -qF "${host_pub}" <<<"${logs}" || fail "the log does not contain the public key for hosts"
    ok "the log contains the public key for hosts (${host_pub})"
    grep -q 'Connection to the router is established' <<<"${logs}" || fail "the Relay did not log a connection to the Router"
    ok "the Relay logged 'Connection to the router is established'"
    if grep -qiE 'password: *[^ ]' <<<"${logs}"; then fail "the log contains a password line"; fi
    ok "the log contains no password"
    grep -qF "${FIRST_LOGIN_WARNING}" <<<"${logs}" \
        || fail "no warning that anyone may log in first while ASPIA_ROUTER_CLIENT_ALLOWED_IPS is empty"
    ok "the first start warns that anyone may log in first (ASPIA_ROUTER_CLIENT_ALLOWED_IPS not set)"
    # The random admin password is saved for the operator, never logged (root-only file, mode 600).
    password_file="$(docker exec "${name}" sh -c 'stat -c "%u:%g %a" /etc/aspia/initial-admin-password && cat /etc/aspia/initial-admin-password')" \
        || fail "cannot read initial-admin-password"
    [[ "${password_file%%$'\n'*}" == "0:0 600" ]] || fail "initial-admin-password is not root:root 600"
    password="${password_file#*$'\n'}"
    [[ "${password_file}" == *$'\n'* && -n "${password}" ]] || fail "initial-admin-password is empty"
    if grep -qF -- "${password}" <<<"${logs}"; then fail "the log contains the initial admin password"; fi
    ok "initial-admin-password is root:root 600, not empty, and its content is not in the log"

    ports="$(listening_ports "${name}" tcp | tr '\n' ' ')"
    for port in 8061 8062 8063 8070; do
        grep -qw "${port}" <<<"${ports}" || fail "nothing listens on ${port}/tcp (listening: ${ports})"
    done
    ok "listening TCP ports: ${ports}(an extra random port is Docker's embedded DNS on a user network)"
    grep -qw 8065 <<<"$(listening_ports "${name}" udp)" || fail "nothing listens on 8065/udp"
    ok "listening UDP port: 8065"
    # One helper container tries every port and prints the ones it could not reach.
    unreachable="$(docker run --rm --platform "${PLATFORM}" --label "aspia-test=${RUN_ID}" --network "${net}" "${HELPER_IMAGE}" \
        bash -c 'for p in 8061 8062 8070; do timeout 5 bash -c "exec 3<>/dev/tcp/aspia/$p" 2>/dev/null || echo "$p"; done')"
    [[ -z "${unreachable}" ]] || fail "cannot connect from another container to: ${unreachable//$'\n'/ }"
    ok "8061, 8062 and 8070 accept TCP connections from another container"
    check_hardening "${name}" "$(cap_mask "${CAPS[@]}")"   # aspia_start is root: the full set
}

scenario_restart() {
    local before after logs
    log "2. Restart: keys and configuration unchanged; files an older image left readable are restricted"
    CURRENT_CONTAINER="${S1_NAME}"
    before="$(config_sums "${S1_CFG}" "${S1_DB}")"
    # The modes an image before the permission fix left, and a link to a file of the read-only root:
    # following it would fail the chmod (a warning in the log).
    # shellcheck disable=SC2016  # expanded by sh inside the helper container
    helper_rw "${S1_CFG}" "${S1_DB}" sh -ec 'chmod 755 /etc/aspia /var/lib/aspia; chmod 644 /etc/aspia/* /var/lib/aspia/*
        ln -s /usr/bin/aspia_health /etc/aspia/link'
    docker restart "${S1_NAME}" >/dev/null
    wait_healthy "${S1_NAME}"
    check_modes "${S1_CFG}" "${S1_DB}"
    log_has "${S1_NAME}" 'Permissions: set the mode of /etc/aspia \(755 -> 700\), /var/lib/aspia \(755 -> 700\),.* /etc/aspia/relay.pub \(644 -> 600\)' \
        || fail "the log does not show the restricted modes"
    if log_has "${S1_NAME}" 'Cannot change the mode'; then fail "the symbolic link was followed"; fi
    helper_rw "${S1_CFG}" "${S1_DB}" rm /etc/aspia/link
    ok "0755 directories and 0644 files are 0700 and 0600 again (host.pub 0644) after a restart; the link was skipped"
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
    [[ "$(grep -cF "${FIRST_LOGIN_WARNING}" <<<"${logs}")" == 1 ]] \
        || fail "the warning about the first login is not logged exactly once (on the first start only)"
    ok "the warning about the first login was logged on the first start only"
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

# stop_check <container> <expected SIGTERM lines>: docker stop finishes in under 10 s with exit code
# 0 or 143, and that many Aspia processes logged the forwarded SIGTERM (counting the new log lines
# checks exactly that, independent of the order in which the lines reach docker logs).
stop_check() {
    local start elapsed code n before
    CURRENT_CONTAINER="$1"
    before="$(sigterm_lines "$1")"
    start="$(date +%s)"
    docker stop "$1" >/dev/null
    elapsed=$(($(date +%s) - start))
    code="$(state .State.ExitCode "$1")"
    ((elapsed < 10)) || fail "docker stop of $1 took ${elapsed} s"
    [[ "${code}" == 0 || "${code}" == 143 ]] || fail "exit code ${code} after docker stop of $1"
    n=$(($(sigterm_lines "$1") - before))
    [[ "${n}" == "$2" ]] || fail "expected $2 process(es) to log SIGTERM in $1, found ${n}"
    ok "$1: stopped in ${elapsed} s (whole seconds), exit code ${code}, $2 Aspia process(es) logged the forwarded SIGTERM"
}

scenario_stop() {
    log "4. docker stop: under 10 s, exit code 0 or 143, both Aspia processes got the signal"
    stop_check "${S1_NAME}" 2
}

# crash_one <process name> <signal> [container, default the one of scenario 1]: the process dies on
# its own (nobody stopped the container).
crash_one() {
    local name="${3:-${S1_NAME}}" pid code
    docker start "${name}" >/dev/null
    CURRENT_CONTAINER="${name}"
    wait_healthy "${name}"
    pid="$(pid_of "${name}" "$1")"
    [[ "${pid}" =~ ^[0-9]+$ ]] || fail "expected one $1 process in ${name}, found: '${pid}'"
    send_signal "${name}" "$2" "${pid}"
    wait_exited "${name}" 30
    code="$(state .State.ExitCode "${name}")"
    [[ "${code}" != 0 ]] || fail "${name} exited 0 after SIG$2 to $1"
    ok "${name}: SIG$2 to $1 (pid ${pid}), the container exited with code ${code}"
}

scenario_crash() {
    log "5. A process dies: the container exits non-zero"
    crash_one aspia_relay KILL
    crash_one aspia_router TERM   # a clean exit 0 of one process is still a failure of the container
}

scenario_relay_not_connected() {
    log "8. Healthcheck: a Relay that cannot authenticate the Router is not healthy"
    # A wrong but well-formed Router key, set by hand; the entrypoint must leave it alone.
    helper_rw "${S1_CFG}" "${S1_DB}" sed -i \
        's/^public_key=.*/public_key=0000000000000000000000000000000000000000000000000000000000000001/' /etc/aspia/relay.conf
    docker start "${S1_NAME}" >/dev/null
    CURRENT_CONTAINER="${S1_NAME}"
    wait_log "${S1_NAME}" 'ACCESS_DENIED' 1 "${HEALTH_TIMEOUT}"
    [[ "$(state .State.Running "${S1_NAME}")" == true ]] || fail "the container stopped"
    health_says "${S1_NAME}" 'not connected to the Router'
    ok "aspia_health fails: $(docker exec "${S1_NAME}" /usr/bin/aspia_health || true)"
    log_has "${S1_NAME}" 'WARNING: \[router\] public_key' || fail "no warning about the differing key"
    [[ "$(helper "${S1_CFG}" "${S1_DB}" grep '^public_key=' /etc/aspia/relay.conf)" == "public_key=0000000000000000000000000000000000000000000000000000000000000001" ]] \
        || fail "the entrypoint overwrote a key set by hand"
    ok "the hand-set key was kept and the entrypoint logged a warning"
    docker stop "${S1_NAME}" >/dev/null
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

# refused_unchanged <name> <config volume> <database volume> <what> [message regex [docker run options...]]:
# starts the image on volumes that must be refused, and checks that it exits non-zero with a clear
# message (the regex, by default 'Nothing was changed') and changes no file.
refused_unchanged() {
    local cfg="$2" db="$3" pattern="${5:-Nothing was changed}" before name code
    before="$(snapshot_volumes "${cfg}" "${db}")"
    run_new "$1" "${cfg}" "${db}" -e "EXTERNAL_IP=${IP_NEW}" "${@:6}"
    name="${CURRENT_CONTAINER}"
    wait_exited "${name}" 60
    code="$(state .State.ExitCode "${name}")"
    [[ "${code}" != 0 ]] || fail "exit code 0 with $4"
    log_has "${name}" "${pattern}" || fail "no clear message for $4"
    [[ "$(snapshot_volumes "${cfg}" "${db}")" == "${before}" ]] || fail "files were created or changed with $4"
    ok "$4: exit code ${code}, no file created or changed"
}

scenario_refused_relay_data() {
    local cfg db
    log "7b. Data that must not be used or changed, checked before anything is written: a lone relay.conf"
    cfg="$(new_volume s7b-config)"
    db="$(new_volume s7b-db)"
    helper_rw "${cfg}" "${db}" sh -c 'printf "[router]\npublic_key=%064d\n" 1 > /etc/aspia/relay.conf'
    refused_unchanged s7b "${cfg}" "${db}" "a relay.conf but no Router data"
}

# refused_2x <name> <what> <shell command that creates the 2.x data>: the image on volumes with Aspia 2.x
# data exits non-zero, names 3.0.37 as the version to start first, and writes nothing (no router.conf, no
# keys: the volumes' snapshot is the same).
refused_2x() {
    local cfg db
    cfg="$(new_volume "$1-config")"
    db="$(new_volume "$1-db")"
    helper_rw "${cfg}" "${db}" sh -c "$3"
    refused_unchanged "$1" "${cfg}" "${db}" "$2" 'Found Aspia 2\.x data.*3\.0\.37'
}

scenario_refused_2x_data() {
    log "3. Aspia 2.x data is refused with the way to 3.0.37, and nothing is written"
    refused_2x s3 "a 2.x router.json and router.db3" 'echo "{}" > /etc/aspia/router.json && : > /var/lib/aspia/router.db3'
    refused_2x s3b "a 2.x relay.json alone" 'echo "{}" > /etc/aspia/relay.json'
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
    [[ "$(ini_value "${router_conf}" stun port)" == 19065 ]] || fail "stun/port not applied"
    [[ "$(ini_value "${router_conf}" stun enabled)" == 1 ]] || fail "stun/enabled not applied"
    [[ "$(ini_value "${router_conf}" client white_list)" == "203.0.113.0/24" ]] || fail "client/white_list not applied"
    [[ "$(ini_value "${router_conf}" host white_list)" == "203.0.113.0/24" ]] || fail "host/white_list not applied"
    [[ "$(ini_value "${router_conf}" relay white_list)" == "127.0.0.1,172.18.0.0/16" ]] || fail "relay/white_list not applied"
    [[ "$(ini_value "${relay_conf}" peer port)" == 19070 ]] || fail "peer/port not applied"
    [[ "$(ini_value "${relay_conf}" peer idle_timeout)" == 10 ]] || fail "peer/idle_timeout not applied"
    [[ "$(ini_value "${relay_conf}" peer max_count)" == 50 ]] || fail "peer/max_count not applied"
    ok "every set variable landed in router.conf/relay.conf, and the container is healthy on non-default ports"
    # Aspia 3.1 has no port for 2.x Hosts: the variable only logs a warning and writes nothing.
    log_has "${name}" 'WARNING:.*ASPIA_ROUTER_LEGACY_PORT.*ignored' || fail "no warning that ASPIA_ROUTER_LEGACY_PORT is ignored"
    if grep -q 'legacy_port' <<<"${router_conf}"; then fail "ASPIA_ROUTER_LEGACY_PORT was written to router.conf"; fi
    ok "ASPIA_ROUTER_LEGACY_PORT=19060 is ignored with a warning, and still healthy"
    if log_has "${name}" "${FIRST_LOGIN_WARNING}"; then
        fail "a new install with ASPIA_ROUTER_CLIENT_ALLOWED_IPS set warns that anyone may log in first"
    fi
    ok "with ASPIA_ROUTER_CLIENT_ALLOWED_IPS set, no warning about the first login"
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
    log_has "${name}" 'Set EXTERNAL_IP \(or ASPIA_RELAY_PUBLIC_ADDRESS\) to the public address explicitly' \
        || fail "the error does not say to set EXTERNAL_IP"
    log_has "${name}" 'WARNING: Relay: https://api.ipify.org: no TLS connection' || fail "no reason given for the first source"
    [[ -z "$(helper "${cfg}" "${db}" find /etc/aspia /var/lib/aspia -mindepth 1)" ]] || fail "files were created"
    ok "auto with no network: exit code ${code}, nothing written"
}

scenario_env_auto_stub() {
    local out cfg db name relay_conf start elapsed code
    log "12b. tests/auto_address.sh in the image, without network: range filter, parser, sources, certificate checks"
    out="$(docker run --rm -i --platform "${PLATFORM}" --label "aspia-test=${RUN_ID}" --network none "${IMAGE}" \
        bash -s < tests/auto_address.sh 2>&1)" || { printf '%s\n' "${out}" >&2; fail "tests/auto_address.sh failed"; }
    ok "tests/auto_address.sh: $(grep -c '^  ok' <<<"${out}") checks passed"

    log "12c. ASPIA_RELAY_PUBLIC_ADDRESS=auto with a stub openssl: a private answer skipped, the next one used"
    # The stub answers a private address for the first source and 192.0.3.7 for the others, after
    # STUB_SLEEP seconds.
    STUB_DIR="$(mktemp -d)"
    cat > "${STUB_DIR}/openssl" <<'STUB'
#!/bin/bash
cat > /dev/null
sleep "${STUB_SLEEP:-0}"
[[ " $* " == *" api.ipify.org:443 "* ]] && body=10.1.2.3 || body=192.0.3.7
printf 'HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\n\r\n%s\n' "${body}"
STUB
    chmod 0755 "${STUB_DIR}" "${STUB_DIR}/openssl"
    cfg="$(new_volume s12c-config)"
    db="$(new_volume s12c-db)"
    run_new s12c "${cfg}" "${db}" -e EXTERNAL_IP=auto -v "${STUB_DIR}/openssl:/usr/local/bin/openssl:ro"
    name="${CURRENT_CONTAINER}"
    wait_log "${name}" 'External address \(Relay\): +192\.0\.3\.7$' 1 60
    log_has "${name}" 'https://api.ipify.org answered 10\.1\.2\.3, a private address \(RFC 1918\), not a public address' \
        || fail "the private answer of the first source was not reported"
    log_has "${name}" 'detected the public address 192\.0\.3\.7 \(source: https://ifconfig\.me/ip\)' \
        || fail "the detected address and its source are not logged"
    relay_conf="$(helper "${cfg}" "${db}" cat /etc/aspia/relay.conf)"
    [[ "$(ini_value "${relay_conf}" peer public_address)" == 192.0.3.7 ]] || fail "relay.conf public_address is not 192.0.3.7"
    ok "10.1.2.3 from the first source refused; 192.0.3.7 from the second in relay.conf"
    docker rm -fv "${name}" >/dev/null

    # docker stop while the first source has not answered yet (it answers after 30 s).
    cfg="$(new_volume s12c2-config)"
    db="$(new_volume s12c2-db)"
    run_new s12c2 "${cfg}" "${db}" -e EXTERNAL_IP=auto -e STUB_SLEEP=30 -v "${STUB_DIR}/openssl:/usr/local/bin/openssl:ro"
    name="${CURRENT_CONTAINER}"
    wait_log "${name}" 'auto: detecting the public address' 1 30
    sleep 1
    start=${SECONDS}
    docker stop "${name}" >/dev/null
    elapsed=$((SECONDS - start))
    code="$(state .State.ExitCode "${name}")"
    ((elapsed < 3)) || fail "docker stop during the detection took ${elapsed} s"
    [[ "${code}" == 0 ]] || fail "exit code ${code} after docker stop during the detection"
    if log_has "${name}" 'WARNING: Relay: https://|detected the public address'; then
        fail "the detection went on after the stop request"
    fi
    [[ -z "$(helper "${cfg}" "${db}" find /etc/aspia /var/lib/aspia -mindepth 1)" ]] || fail "files were created"
    ok "docker stop during the detection: ${elapsed} s, exit code 0, no answer waited for, nothing written"
}

scenario_puid_pgid() {
    local cfg db name uid_lines before
    log "14. PUID/PGID: the Router and the Relay run as that uid/gid, and the files they write are owned by it"
    cfg="$(new_volume s14-config)"
    db="$(new_volume s14-db)"
    # A link to a file of the read-only root: chown -R must re-own the link, never follow it.
    helper_rw "${cfg}" "${db}" ln -s /usr/bin/aspia_health /etc/aspia/link
    run_new s14 "${cfg}" "${db}" -e "ASPIA_RELAY_PUBLIC_ADDRESS=${IP_NEW}" -e PUID=1000 -e PGID=1000
    name="${CURRENT_CONTAINER}"
    wait_healthy "${name}"

    [[ "$(helper "${cfg}" "${db}" stat -c '%u:%g' /etc/aspia/router.conf)" == "1000:1000" ]] \
        || fail "router.conf is not owned by 1000:1000"
    [[ "$(helper "${cfg}" "${db}" stat -c '%u:%g' /var/lib/aspia/router.db3 /etc/aspia/link)" == $'1000:1000\n1000:1000' ]] \
        || fail "router.db3 or the link itself (not the file it points to) in /etc/aspia is not owned by 1000:1000"
    check_modes "${cfg}" "${db}"
    ok "router.conf, router.db3 and the link itself are owned by uid=1000 gid=1000; only that owner can read the files"

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
    check_hardening "${name}" 0000000000000000   # setpriv drops the capabilities of aspia_start too
    stop_check "${name}" 2   # tini signals uid 1000: needs KILL

    # As root, without PUID, on these volumes (files of uid 1000, mode 600): the new address needs
    # DAC_OVERRIDE to read them, and the backup keeps owner, mode and mtime (copy_file, no FOWNER).
    before="$(helper "${cfg}" "${db}" stat -c '%u:%g %a %Y' /etc/aspia/relay.conf)"
    run_new s14-root "${cfg}" "${db}" -e "EXTERNAL_IP=${IP_OLD}"
    wait_healthy "${CURRENT_CONTAINER}"
    [[ "$(helper "${cfg}" "${db}" sh -c 'stat -c "%u:%g %a %Y" /etc/aspia/relay.conf.pre-*')" == "${before}" ]] \
        || fail "the relay.conf backup is not 1000:1000, mode 600 and the mtime of ${before}"
    ok "as root on files of uid 1000: healthy, the relay.conf backup keeps owner, mode and mtime (${before})"
    # Root reads the files of uid 1000 with DAC_OVERRIDE: the only capability the Aspia processes keep then.
    check_hardening "${CURRENT_CONTAINER}" "$(cap_mask "${CAPS[@]}")" "$(cap_mask DAC_OVERRIDE)"
    docker rm -fv "${CURRENT_CONTAINER}" >/dev/null

    # PUID again with a non-default port: the health check (root) reads the 0600 router.conf of uid 1000.
    run_new s14-port "${cfg}" "${db}" -e "EXTERNAL_IP=${IP_OLD}" -e PUID=1000 -e PGID=1000 -e ASPIA_ROUTER_CLIENT_PORT=19062
    wait_healthy "${CURRENT_CONTAINER}"
    docker rm -fv "${CURRENT_CONTAINER}" >/dev/null
}

scenario_env_empty_allowlist() {
    local cfg db name list
    log "15. An allow-list variable set to an empty value does not clear an existing list"
    cfg="$(new_volume s15-config)"
    db="$(new_volume s15-db)"
    run_new s15 "${cfg}" "${db}" -e "ASPIA_RELAY_PUBLIC_ADDRESS=${IP_NEW}" -e ASPIA_ROUTER_CLIENT_ALLOWED_IPS=203.0.113.0/24
    name="${CURRENT_CONTAINER}"
    wait_healthy "${name}"
    list="$(ini_value "$(helper "${cfg}" "${db}" cat /etc/aspia/router.conf)" client white_list)"
    [[ "${list}" == "203.0.113.0/24" ]] || fail "test setup: the allow-list was not applied (got '${list}')"
    docker stop "${name}" >/dev/null

    # ASPIA_ROUTER_CLIENT_ALLOWED_IPS='' (as docker-compose.yml renders an unset variable with a
    # bare "${VAR}" default of "") must be treated the same as leaving the variable unset.
    run_new s15b "${cfg}" "${db}" -e "ASPIA_RELAY_PUBLIC_ADDRESS=${IP_NEW}" -e ASPIA_ROUTER_CLIENT_ALLOWED_IPS=
    name="${CURRENT_CONTAINER}"
    wait_healthy "${name}"
    list="$(ini_value "$(helper "${cfg}" "${db}" cat /etc/aspia/router.conf)" client white_list)"
    [[ "${list}" == "203.0.113.0/24" ]] \
        || fail "ASPIA_ROUTER_CLIENT_ALLOWED_IPS='' cleared the existing allow-list (now '${list}')"
    ok "ASPIA_ROUTER_CLIENT_ALLOWED_IPS='' (empty) left the existing client/white_list unchanged"
}

scenario_puid_pgid_refused() {
    local cfg db name code before after
    log "16. PUID/PGID with an invalid variable: refused, and no file's ownership was changed"
    cfg="$(new_volume s16-config)"
    db="$(new_volume s16-db)"
    # Existing root-owned data from a normal start (no PUID/PGID).
    run_new s16-seed "${cfg}" "${db}" -e "ASPIA_RELAY_PUBLIC_ADDRESS=${IP_NEW}"
    name="${CURRENT_CONTAINER}"
    wait_healthy "${name}"
    docker stop "${name}" >/dev/null

    before="$(helper "${cfg}" "${db}" sh -c 'cd / && find etc/aspia var/lib/aspia -mindepth 1 -exec stat -c "%u:%g %n" {} + | sort')"

    run_new s16 "${cfg}" "${db}" -e "ASPIA_RELAY_PUBLIC_ADDRESS=${IP_NEW}" -e PUID=1000 -e PGID=1000 \
        -e ASPIA_ROUTER_CLIENT_PORT=99999
    name="${CURRENT_CONTAINER}"
    wait_exited "${name}" 60
    code="$(state .State.ExitCode "${name}")"
    [[ "${code}" != 0 ]] || fail "exit code 0 with PUID/PGID and an invalid ASPIA_ROUTER_CLIENT_PORT"

    after="$(helper "${cfg}" "${db}" sh -c 'cd / && find etc/aspia var/lib/aspia -mindepth 1 -exec stat -c "%u:%g %n" {} + | sort')"
    [[ "${before}" == "${after}" ]] \
        || fail "ownership changed although the start was refused:"$'\n'"${before}"$'\n'"${after}"
    ok "PUID/PGID + an invalid variable: exit code ${code}, no file's ownership changed"
}

# ---------------------------------------------------------------------------------------------
# ASPIA_ROLE (PR 5). One machine, one Docker network: these scenarios show that the Relay registers
# with a Router in another container and is health-checked correctly. They cannot show traffic
# flowing through a Relay across real NAT; that needs two hosts and a real Client and Host.

readonly WRONG_KEY=0000000000000000000000000000000000000000000000000000000000000001
SPLIT_NET="" ROUTER_NAME="" ROUTER_KEY="" RELAY1_NAME=""
RELAY_A_IP="" RELAY_B_IP=""   # set by split_network: above the range Docker hands out first

# split_network: creates SPLIT_NET once per run, with a /24 of 10.213.0.0/16 given explicitly, so that
# scenario 21 can pin Relay addresses. Docker refuses a subnet that overlaps another network (also one
# of a concurrent run); then the next /24 is tried, from 10.213.48.0/24 on (earlier versions of this
# script take 10.213.47.0/24 unconditionally, and may run at the same time from another checkout).
split_network() {
    local n out
    [[ -z "${SPLIT_NET}" ]] || return 0
    for ((n = 48; n < 256; n++)); do
        if out="$(docker network create --label "aspia-test=${RUN_ID}" --subnet "10.213.${n}.0/24" "${RUN_ID}-split" 2>&1)"; then
            SPLIT_NET="${RUN_ID}-split" RELAY_A_IP="10.213.${n}.200" RELAY_B_IP="10.213.${n}.201"
            return 0
        fi
        grep -qi overlap <<<"${out}" || fail "docker network create failed: ${out}"
    done
    fail "no /24 of 10.213.48.0-10.213.255.0 is free for ${RUN_ID}-split"
}

scenario_compose_roles() {
    local file role out images
    log "0d. compose.router.yml and compose.relay.yml: role, pinned image, only the ports of the role"
    for file in compose.router.yml compose.relay.yml; do
        role="${file#compose.}"
        role="${role%.yml}"
        images="$(ASPIA_IMAGE='' compose_file_config "${file}" --images)"
        [[ "${images}" == "aspia-server:${ASPIA_VERSION}" ]] || fail "${file}: the default image is '${images}', expected aspia-server:${ASPIA_VERSION}"
        images="$(ASPIA_IMAGE="registry.example/aspia-server:${ASPIA_VERSION}" compose_file_config "${file}" --images)"
        [[ "${images}" == "registry.example/aspia-server:${ASPIA_VERSION}" ]] || fail "${file}: ASPIA_IMAGE is not used: '${images}'"
        out="$(compose_file_config "${file}" --format json)"
        grep -q "\"ASPIA_ROLE\": \"${role}\"" <<<"${out}" || fail "${file} does not set ASPIA_ROLE=${role}: ${out}"
        docker compose --env-file .env.example -f "${file}" config >/dev/null || fail "${file}: docker compose config failed with .env.example"
        out="$(compose_v2_config "${file}")" \
            || fail "Compose v2 cannot read ${file}: ${out}"
        grep -q "\"ASPIA_ROLE\": \"${role}\"" <<<"${out}" || fail "Compose v2: ${file} does not set ASPIA_ROLE=${role}: ${out}"
        ok "${file}: ASPIA_ROLE=${role}, image aspia-server:${ASPIA_VERSION} unless ASPIA_IMAGE is set; reads .env.example; Compose v2 reads it"
    done

    out="$(published_ports compose.router.yml)"
    [[ "${out}" == "* 8061/tcp * 8062/tcp * 8063/tcp * 8065/udp " ]] || fail "compose.router.yml publishes: ${out}"
    out="$(ASPIA_ROUTER_CLIENT_BIND_IP=127.0.0.1 published_ports compose.router.yml)"
    [[ "${out}" == "* 8061/tcp * 8063/tcp * 8065/udp 127.0.0.1 8062/tcp " ]] \
        || fail "compose.router.yml: ASPIA_ROUTER_CLIENT_BIND_IP=127.0.0.1 did not limit only the client port: ${out}"
    ok "compose.router.yml publishes 8061-8063 and 8065/udp, not the Relay port 8070; ASPIA_ROUTER_CLIENT_BIND_IP limits 8062"

    out="$(ASPIA_RELAY_PEER_PORT=19070 ASPIA_RELAY_ROUTER_ADDRESS=router.example.test compose_file_config compose.relay.yml --format json)"
    if [[ "$(grep -c '"published"' <<<"${out}")" != 1 ]] || ! grep -q '"published": "19070"' <<<"${out}" \
        || ! grep -q '"target": 19070' <<<"${out}"; then
        fail "compose.relay.yml must publish only the Relay port, both sides from ASPIA_RELAY_PEER_PORT: ${out}"
    fi
    grep -q '"ASPIA_RELAY_ROUTER_ADDRESS": "router.example.test"' <<<"${out}" || fail "compose.relay.yml does not pass ASPIA_RELAY_ROUTER_ADDRESS: ${out}"
    out="$(unset EXTERNAL_IP; ASPIA_RELAY_PUBLIC_ADDRESS="${IP_NEW}" compose_file_config compose.relay.yml --format json)"
    grep -q "\"EXTERNAL_IP\": \"${IP_NEW}\"" <<<"${out}" || fail "compose.relay.yml: EXTERNAL_IP did not take the value of ASPIA_RELAY_PUBLIC_ADDRESS: ${out}"
    ok "compose.relay.yml publishes only the Relay port (host = container, from ASPIA_RELAY_PEER_PORT) and passes the Relay variables"
}

# start_relay <slug> <router address> <router key> <external ip> [docker run options...]: an
# ASPIA_ROLE=relay container on SPLIT_NET, with its own volumes ${RUN_ID}-<slug>-config and -db
# (an existing slug reuses them). An empty key or external ip is not passed (the caller passes it
# another way). It becomes CURRENT_CONTAINER.
start_relay() {
    local slug="$1" addr="$2" key="$3" ip="$4"
    local -a args=(-e ASPIA_ROLE=relay --network "${SPLIT_NET}" -e "ASPIA_RELAY_ROUTER_ADDRESS=${addr}")
    shift 4
    [[ -z "${key}" ]] || args+=(-e "ASPIA_RELAY_ROUTER_PUBLIC_KEY=${key}")
    [[ -z "${ip}" ]] || args+=(-e "EXTERNAL_IP=${ip}")
    run_new "${slug}" "$(new_volume "${slug}-config")" "$(new_volume "${slug}-db")" "${args[@]}" "$@"
}

# relay_helper <slug> <command...>: helper on the volumes of start_relay <slug>.
relay_helper() {
    local slug="$1"
    shift
    helper "${RUN_ID}-${slug}-config" "${RUN_ID}-${slug}-db" "$@"
}

# expect_relay_refused <container> <log regex> [count, default 1]: the Relay logged the failure <count>
# times, is still running and has failed every health probe so far, and aspia_health says it is not connected.
expect_relay_refused() {
    CURRENT_CONTAINER="$1"
    wait_log "$1" "$2" "${3:-1}" 60
    not_yet_healthy "$1"
    health_says "$1" 'the Relay is not connected to the Router'
}

scenario_split() {
    local cfg db logs ports port relay_conf files ip out name
    log "17. ASPIA_ROLE=router and ASPIA_ROLE=relay in two containers on one Docker network"
    split_network
    cfg="$(new_volume s17-router-config)"
    db="$(new_volume s17-router-db)"
    run_new s17-router "${cfg}" "${db}" -e ASPIA_ROLE=router --network "${SPLIT_NET}" --network-alias aspia-router
    ROUTER_NAME="${CURRENT_CONTAINER}"
    wait_healthy "${ROUTER_NAME}"
    ROUTER_KEY="$(helper "${cfg}" "${db}" cat /etc/aspia/relay.pub)"
    logs="$(docker logs "${ROUTER_NAME}" 2>&1)"
    grep -qF "Public key for relays:     ${ROUTER_KEY}" <<<"${logs}" || fail "the Router does not print the key for Relays"
    grep -qF '8063/tcp  Router: relays (must be reachable from every Relay host)' <<<"${logs}" || fail "the Router does not print the port for Relays"
    grep -qF 'WARNING: Relays are accepted from ANY address' <<<"${logs}" || fail "no warning about the empty Relay allow-list"
    ok "the Router prints the key for Relays (${ROUTER_KEY}) and the port 8063/tcp, and warns that any address may register"
    ports="$(listening_ports "${ROUTER_NAME}" tcp | tr '\n' ' ')"
    for port in 8061 8062 8063; do
        grep -qw "${port}" <<<"${ports}" || fail "role router: nothing listens on ${port}/tcp (listening: ${ports})"
    done
    if grep -qw 8070 <<<"${ports}"; then fail "role router listens on the Relay port 8070"; fi
    [[ -z "$(pid_of "${ROUTER_NAME}" aspia_relay)" ]] || fail "role router runs aspia_relay"
    helper "${cfg}" "${db}" test ! -e /etc/aspia/relay.conf || fail "role router created relay.conf"
    ok "role router: only aspia_router runs, listening on ${ports}; no relay.conf"

    start_relay s17-relay1 aspia-router "${ROUTER_KEY}" "" -e ASPIA_RELAY_PUBLIC_ADDRESS=relay1.example.test
    RELAY1_NAME="${CURRENT_CONTAINER}"
    wait_healthy "${RELAY1_NAME}"
    ip="$(ip_of "${RELAY1_NAME}")"
    CURRENT_CONTAINER="${ROUTER_NAME}"
    wait_log "${ROUTER_NAME}" "New relay session: \"${ip}\"" 1 30
    wait_log "${ROUTER_NAME}" "Received key pool: [0-9]+ \\( \"${ip}\" \\)" 1 30
    ok "Router log: $(grep -m1 -oE "Received key pool: [0-9]+ \\( \"${ip}\" \\)" <<<"$(docker logs "${ROUTER_NAME}" 2>&1)") -- the Relay registered"
    CURRENT_CONTAINER="${RELAY1_NAME}"

    files="$(relay_helper s17-relay1 find /etc/aspia /var/lib/aspia -mindepth 1)"
    [[ "${files}" == /etc/aspia/relay.conf ]] || fail "role relay wrote more than relay.conf: ${files}"
    relay_conf="$(relay_helper s17-relay1 cat /etc/aspia/relay.conf)"
    [[ "$(ini_value "${relay_conf}" router address)" == aspia-router ]] || fail "relay.conf [router] address is not aspia-router"
    [[ "$(ini_value "${relay_conf}" router port)" == 8063 ]] || fail "relay.conf [router] port is not 8063"
    [[ "$(ini_value "${relay_conf}" router public_key)" == "${ROUTER_KEY}" ]] || fail "relay.conf [router] public_key is not the Router's relay.pub"
    [[ "$(ini_value "${relay_conf}" peer public_address)" == relay1.example.test ]] || fail "relay.conf [peer] public_address is not relay1.example.test"
    ok "role relay: only relay.conf was written (no Router configuration, keys or database), with the Router's address, port and key"
    ports="$(listening_ports "${RELAY1_NAME}" tcp | tr '\n' ' ')"
    grep -qw 8070 <<<"${ports}" || fail "role relay: nothing listens on 8070/tcp (listening: ${ports})"
    for port in 8061 8062 8063; do
        if grep -qw "${port}" <<<"${ports}"; then fail "role relay listens on the Router port ${port}"; fi
    done
    [[ -z "$(pid_of "${RELAY1_NAME}" aspia_router)" ]] || fail "role relay runs aspia_router"
    for name in "${ROUTER_NAME}" "${RELAY1_NAME}"; do
        out="$(docker exec "${name}" /usr/bin/aspia_health)" || fail "aspia_health failed in ${name}: ${out}"
    done
    ok "role relay: only aspia_relay runs, listening on ${ports}; aspia_health reports healthy in both containers"
}

scenario_two_relays() {
    local keyvol name ip cfg_owner
    log "18. A second Relay, its Router key from a root-only mounted file, PUID/PGID set: both Relays registered with the one Router"
    keyvol="$(new_volume s18-key)"
    # shellcheck disable=SC2016  # expanded by sh in the helper container
    docker run --rm --platform "${PLATFORM}" --label "aspia-test=${RUN_ID}" -v "${keyvol}:/k" "${HELPER_IMAGE}" \
        sh -c 'printf "%s\n" "$1" > /k/router-relay.pub && chmod 0400 /k/router-relay.pub' _ "${ROUTER_KEY}"
    start_relay s18-relay2 aspia-router "" relay2.example.test -v "${keyvol}:/run/aspia:ro" \
        -e ASPIA_RELAY_ROUTER_PUBLIC_KEY_FILE=/run/aspia/router-relay.pub -e PUID=1000 -e PGID=1000
    name="${CURRENT_CONTAINER}"
    wait_healthy "${name}"
    cfg_owner="$(relay_helper s18-relay2 stat -c '%u:%g' /etc/aspia/relay.conf)"
    [[ "${cfg_owner}" == 1000:1000 ]] || fail "relay.conf is owned by ${cfg_owner}, expected 1000:1000"
    ip="$(ip_of "${name}")"
    CURRENT_CONTAINER="${ROUTER_NAME}"
    wait_log "${ROUTER_NAME}" "Received key pool: [0-9]+ \\( \"${ip}\" \\)" 1 30
    [[ "$(count_tcp "${ROUTER_NAME}" 01 8063)" == 2 ]] \
        || fail "the Router has $(count_tcp "${ROUTER_NAME}" 01 8063) Relay connections on 8063, expected 2"
    docker exec "${RELAY1_NAME}" /usr/bin/aspia_health >/dev/null || fail "the first Relay is no longer healthy"
    ok "two Relays ($(ip_of "${RELAY1_NAME}"), ${ip}) registered: 2 ESTABLISHED connections on the Router's 8063, both healthy"
    ok "the root-only (0400) key file worked with PUID/PGID=1000, and relay.conf is owned by ${cfg_owner}"
}

FAIL_WRONGKEY="" FAIL_NOHOST="" FAIL_NOPORT="" S21_ROUTER="" S21_RELAY_A="" S21_RELAY_B=""

# start_failing_relays: starts the Relays of scenarios 19, 20 and 21 together, so that their 15 s
# retry cycles run side by side: a wrong key, an unknown Router name, a closed Router port, and the
# Router with an allow-list (where only one of two Relays is listed).
start_failing_relays() {
    local cfg db key
    log "19-21 (setup). Start the Relays that must fail, and the Router with an allow-list, together"
    start_relay s19-wrongkey aspia-router "${WRONG_KEY}" relay3.example.test
    FAIL_WRONGKEY="${CURRENT_CONTAINER}"
    start_relay s20-nohost no-such-router.invalid "${ROUTER_KEY}" relay4.example.test
    FAIL_NOHOST="${CURRENT_CONTAINER}"
    start_relay s20-noport aspia-router "${ROUTER_KEY}" relay5.example.test -e ASPIA_RELAY_ROUTER_PORT=8064
    FAIL_NOPORT="${CURRENT_CONTAINER}"
    cfg="$(new_volume s21-router-config)"
    db="$(new_volume s21-router-db)"
    # Without 127.0.0.1: allowed in role router (the check for it belongs to role all).
    run_new s21-router "${cfg}" "${db}" -e ASPIA_ROLE=router -e "ASPIA_ROUTER_RELAY_ALLOWED_IPS=${RELAY_A_IP}" \
        --network "${SPLIT_NET}" --network-alias aspia-router-b
    S21_ROUTER="${CURRENT_CONTAINER}"
    wait_healthy "${S21_ROUTER}"
    key="$(helper "${cfg}" "${db}" cat /etc/aspia/relay.pub)"
    start_relay s21-relay-a aspia-router-b "${key}" relay-a.example.test --ip "${RELAY_A_IP}"
    S21_RELAY_A="${CURRENT_CONTAINER}"
    start_relay s21-relay-b aspia-router-b "${key}" relay-b.example.test --ip "${RELAY_B_IP}"
    S21_RELAY_B="${CURRENT_CONTAINER}"
}

scenario_relay_wrong_key() {
    local name="${FAIL_WRONGKEY}"
    log "19a. A Relay with a wrong Router key: not healthy, and the log says why"
    expect_relay_refused "${name}" 'Connection to the router has been lost: .*ACCESS_DENIED'
    health_says "${name}" 'the Router is at aspia-router'
    wait_log "${name}" 'Reconnect after [0-9]+ seconds' 1 10
    ok "ACCESS_DENIED logged and another attempt scheduled; still running, not healthy; aspia_health names the Router"
}

# scenario_relay_wrong_key_retry: runs after 22, when the Relay of 19a has had its retry (15 s after
# its first attempt), so that the second ACCESS_DENIED needs (almost) no wait.
scenario_relay_wrong_key_retry() {
    local name="${FAIL_WRONGKEY}" router_ip conf
    log "19b. The Relay with the wrong key retried on its own: ACCESS_DENIED again; recreated with the right key"
    # Two attempts: this is the one place that shows the Relay retries on its own (the reconnect in 20b does too).
    expect_relay_refused "${name}" 'Connection to the router has been lost: .*ACCESS_DENIED' 2
    ok "ACCESS_DENIED logged on the retry too; still running, not healthy"

    # The same volume, a different Router address and the right key: relay.conf follows the variables.
    router_ip="$(ip_of "${ROUTER_NAME}")"
    docker rm -fv "${name}" >/dev/null
    start_relay s19-wrongkey "${router_ip}" "${ROUTER_KEY}" relay3.example.test
    name="${CURRENT_CONTAINER}"
    wait_healthy "${name}"
    conf="$(relay_helper s19-wrongkey cat /etc/aspia/relay.conf)"
    [[ "$(ini_value "${conf}" router address)" == "${router_ip}" ]] || fail "relay.conf [router] address was not updated to ${router_ip}"
    [[ "$(ini_value "${conf}" router public_key)" == "${ROUTER_KEY}" ]] || fail "relay.conf [router] public_key was not updated"
    # shellcheck disable=SC2016  # expanded by sh inside the helper container
    relay_helper s19-wrongkey sh -c 'grep -q "^public_key=$1" /etc/aspia/relay.conf.pre-*' _ "${WRONG_KEY}" \
        || fail "no relay.conf.pre-* backup with the old key"
    ok "recreated on its volume with ${router_ip} and the right key: relay.conf updated, backup relay.conf.pre-* has the old key, healthy"
    docker rm -fv "${name}" >/dev/null
}

scenario_relay_unreachable() {
    local name
    log "20a. A Relay whose Router is unreachable: keeps running and retrying, unhealthy, the log says why"
    expect_relay_refused "${FAIL_NOHOST}" 'Connection to the router has been lost: .*SPECIFIED_HOST_NOT_FOUND'
    health_says "${FAIL_NOHOST}" 'the Router is at no-such-router.invalid'
    expect_relay_refused "${FAIL_NOPORT}" 'Connection to the router has been lost: .*CONNECTION_REFUSED'
    ok "unknown Router name: SPECIFIED_HOST_NOT_FOUND; closed Router port: CONNECTION_REFUSED; both running, not healthy"
    docker rm -fv "${FAIL_NOHOST}" "${FAIL_NOPORT}" >/dev/null

    # The Router goes away and comes back: the Relay stays up and reconnects by itself.
    CURRENT_CONTAINER="${RELAY1_NAME}"
    docker stop "${ROUTER_NAME}" >/dev/null
    wait_log "${RELAY1_NAME}" 'Connection to the router has been lost' 1 30
    health_says "${RELAY1_NAME}" 'the Relay is not connected to the Router'
    [[ "$(state .State.Running "${RELAY1_NAME}")" == true ]] || fail "the Relay exited when its Router stopped"
    ok "Router stopped: the Relay logged the lost connection, keeps running, and aspia_health fails"
    docker start "${ROUTER_NAME}" >/dev/null
    wait_healthy "${ROUTER_NAME}"
}

# scenario_relay_reconnect: runs after 19b, when the Relay of 20a has had its retry since the Router came back.
scenario_relay_reconnect() {
    log "20b. The Router is back: the Relay reconnects on its own"
    CURRENT_CONTAINER="${RELAY1_NAME}"
    wait_log "${RELAY1_NAME}" 'Connection to the router is established \(session count' 2 60
    docker exec "${RELAY1_NAME}" /usr/bin/aspia_health >/dev/null || fail "the Relay reconnected but aspia_health fails"
    ok "Router back: the Relay reconnected on its own (it retries every 15 s) and is healthy again"
}

scenario_router_allow_list() {
    log "21. ASPIA_ROUTER_RELAY_ALLOWED_IPS with ASPIA_ROLE=router: the listed Relay registers, another is refused"
    CURRENT_CONTAINER="${S21_ROUTER}"
    log_has "${S21_ROUTER}" "Relays accepted from: +${RELAY_A_IP} " || fail "the Router does not log its Relay allow-list"
    if log_has "${S21_ROUTER}" 'accepted from ANY address'; then fail "the Router warns about an empty allow-list although one is set"; fi
    ok "role router starts with an allow-list that does not include 127.0.0.1, and logs it"
    CURRENT_CONTAINER="${S21_RELAY_A}"
    wait_healthy "${S21_RELAY_A}"
    wait_log "${S21_ROUTER}" "New relay session: \"${RELAY_A_IP}\"" 1 30
    expect_relay_refused "${S21_RELAY_B}" 'Connection to the router has been lost: .*REMOTE_HOST_CLOSED'
    if log_has "${S21_ROUTER}" "New relay session: \"${RELAY_B_IP}\""; then fail "the Router accepted the Relay that is not on its list"; fi
    ok "${RELAY_A_IP} registered; ${RELAY_B_IP} was closed (REMOTE_HOST_CLOSED in its log), not healthy"
    docker rm -fv "${S21_ROUTER}" "${S21_RELAY_A}" "${S21_RELAY_B}" >/dev/null
}

# run_invalid_relay <slug> <expected message> <omitted variables, space separated> [docker run options...]:
# run_invalid_env for a complete, valid ASPIA_ROLE=relay environment (Router address, key, own public
# address) without the omitted variables and with the options added.
run_invalid_relay() {
    local slug="$1" expect="$2" omit=" $3 " pair
    local -a args=()
    shift 3
    for pair in ASPIA_ROLE=relay ASPIA_RELAY_ROUTER_ADDRESS=router.example.test "ASPIA_RELAY_ROUTER_PUBLIC_KEY=${ROUTER_KEY}" \
        "ASPIA_RELAY_PUBLIC_ADDRESS=${IP_NEW}"; do
        [[ "${omit}" == *" ${pair%%=*} "* ]] || args+=(-e "${pair}")
    done
    run_invalid_env "${slug}" "${expect}" "${args[@]}" "$@"
}

# router_address_verdicts <value>...: "valid <value>" or "invalid <value>" per value, from
# is_valid_router_address of the image under test (sourcing aspia_start does not run main).
router_address_verdicts() {
    docker run --rm --platform "${PLATFORM}" --label "aspia-test=${RUN_ID}" --entrypoint bash "${IMAGE}" -c '
        source /usr/bin/aspia_start
        for v in "$@"; do
            if is_valid_router_address "$v"; then echo "valid $v"; else echo "invalid $v"; fi
        done' _ "$@"
}

scenario_relay_invalid() {
    local cfg db value verdicts label63 label64 name253 name254
    log "22. ASPIA_ROLE=relay with a required setting missing or invalid: one clear message, non-zero exit, nothing written"
    run_invalid_relay relay-none 'not set: ASPIA_RELAY_ROUTER_ADDRESS .*; ASPIA_RELAY_ROUTER_PUBLIC_KEY or ASPIA_RELAY_ROUTER_PUBLIC_KEY_FILE .*; ASPIA_RELAY_PUBLIC_ADDRESS or its alias EXTERNAL_IP' \
        'ASPIA_RELAY_ROUTER_ADDRESS ASPIA_RELAY_ROUTER_PUBLIC_KEY ASPIA_RELAY_PUBLIC_ADDRESS'
    ok "the message: $(grep -m1 -o 'ASPIA_ROLE=relay needs.*' <<<"$(docker logs "${CURRENT_CONTAINER}" 2>&1)")"
    run_invalid_relay relay-noaddr 'ASPIA_ROLE=relay needs these settings, which are not set: ASPIA_RELAY_ROUTER_ADDRESS [^;]*\. See' \
        ASPIA_RELAY_ROUTER_ADDRESS
    run_invalid_relay relay-nokey 'which are not set: ASPIA_RELAY_ROUTER_PUBLIC_KEY or ASPIA_RELAY_ROUTER_PUBLIC_KEY_FILE [^;]*\. See' \
        ASPIA_RELAY_ROUTER_PUBLIC_KEY
    run_invalid_relay relay-nopub 'which are not set: ASPIA_RELAY_PUBLIC_ADDRESS or its alias EXTERNAL_IP [^;]*\. See' \
        ASPIA_RELAY_PUBLIC_ADDRESS
    run_invalid_relay relay-badkey "ASPIA_RELAY_ROUTER_PUBLIC_KEY='abc' is not a key" \
        ASPIA_RELAY_ROUTER_PUBLIC_KEY -e ASPIA_RELAY_ROUTER_PUBLIC_KEY=abc
    run_invalid_relay relay-nokeyfile "ASPIA_RELAY_ROUTER_PUBLIC_KEY_FILE='/run/aspia/missing.pub': no readable file" \
        ASPIA_RELAY_ROUTER_PUBLIC_KEY -e ASPIA_RELAY_ROUTER_PUBLIC_KEY_FILE=/run/aspia/missing.pub
    run_invalid_relay relay-twokeys "Both ASPIA_RELAY_ROUTER_PUBLIC_KEY and ASPIA_RELAY_ROUTER_PUBLIC_KEY_FILE are set" \
        "" -e ASPIA_RELAY_ROUTER_PUBLIC_KEY_FILE=/etc/hostname
    run_invalid_relay relay-badaddr "ASPIA_RELAY_ROUTER_ADDRESS='router address!' is not an IP address or a host name" \
        ASPIA_RELAY_ROUTER_ADDRESS -e 'ASPIA_RELAY_ROUTER_ADDRESS=router address!'
    run_invalid_relay relay-octal "ASPIA_RELAY_ROUTER_ADDRESS='010.0.0.1' is not an IP address or a host name" \
        ASPIA_RELAY_ROUTER_ADDRESS -e ASPIA_RELAY_ROUTER_ADDRESS=010.0.0.1
    run_invalid_relay relay-badport "ASPIA_RELAY_ROUTER_PORT='0' is not a valid port" "" -e ASPIA_RELAY_ROUTER_PORT=0
    run_invalid_relay badrole "ASPIA_ROLE='both' is not one of: all" ASPIA_ROLE -e ASPIA_ROLE=both

    # The Router address check, value by value in one container: only IP literals and DNS names.
    label63="$(printf 'a%.0s' {1..63})"
    label64="${label63}a"
    name253="${label63}.${label63}.${label63}.$(printf 'b%.0s' {1..61})"   # 63+1+63+1+63+1+61
    name254="${name253}b"
    verdicts="$(router_address_verdicts 192.168.1.300 1.2.3.4.5 10.1 -router. ...a 010.0.0.1 0x7f.0.0.1 0x0a000001 0X7F.0.0.1 router..example.com \
        a-.example.com -a.example.com . "" "router address" "${label64}.example.com" "${name254}" \
        192.168.1.30 2001:db8::1 router.example.com router.example.com. localhost my_router-1 \
        "${label63}.example.com" "${name253}")"
    for value in 192.168.1.300 1.2.3.4.5 10.1 -router. ...a 010.0.0.1 0x7f.0.0.1 0x0a000001 0X7F.0.0.1 router..example.com a-.example.com -a.example.com . "" \
        "router address" "${label64}.example.com" "${name254}"; do
        grep -qxF "invalid ${value}" <<<"${verdicts}" || fail "the Router address '${value}' is accepted: ${verdicts}"
    done
    for value in 192.168.1.30 2001:db8::1 router.example.com router.example.com. localhost my_router-1 \
        "${label63}.example.com" "${name253}"; do
        grep -qxF "valid ${value}" <<<"${verdicts}" || fail "the Router address '${value}' is refused: ${verdicts}"
    done
    ok "ASPIA_RELAY_ROUTER_ADDRESS: 192.168.1.300, 1.2.3.4.5, 10.1, 010.0.0.1, 0x7f.0.0.1, 0x0a000001, 0X7F.0.0.1, -router., ...a, empty labels, 64-character labels and names over 253 are refused; IPv4, IPv6, FQDN (also with a trailing dot) and 253 characters are accepted"

    # A Router's configuration volume mounted on a Relay: refused before anything is written.
    cfg="$(new_volume s22-config)"
    db="$(new_volume s22-db)"
    helper_rw "${cfg}" "${db}" sh -c 'printf "[relay]\nport=8063\n" > /etc/aspia/router.conf'
    refused_unchanged s22 "${cfg}" "${db}" "role relay on a Router's configuration volume" \
        'Nothing was changed' \
        -e ASPIA_ROLE=relay -e ASPIA_RELAY_ROUTER_ADDRESS=router.example.test -e "ASPIA_RELAY_ROUTER_PUBLIC_KEY=${ROUTER_KEY}"
    log_has "${CURRENT_CONTAINER}" 'ASPIA_ROLE=relay, but the volumes hold a Router' || fail "no clear message for a Router's volume"
    ok "the message names the Router's files and says to use ASPIA_ROLE=router or all"

    # A key file inside the volumes, with PUID/PGID: the chown of the volumes would reach it.
    cfg="$(new_volume s22b-config)"
    db="$(new_volume s22b-db)"
    # shellcheck disable=SC2016  # expanded by sh inside the helper container
    helper_rw "${cfg}" "${db}" sh -c 'printf "%s\n" "$1" > /etc/aspia/relay.pub' _ "${ROUTER_KEY}"
    refused_unchanged s22b "${cfg}" "${db}" "role relay with PUID/PGID and the key file in /etc/aspia" \
        'Nothing was changed' \
        -e ASPIA_ROLE=relay -e ASPIA_RELAY_ROUTER_ADDRESS=router.example.test -e PUID=1000 -e PGID=1000 \
        -e ASPIA_RELAY_ROUTER_PUBLIC_KEY_FILE=/etc/aspia/relay.pub
    log_has "${CURRENT_CONTAINER}" 'Mount the key file somewhere else' || fail "no clear message for a key file inside the volumes"
    ok "the message says to mount the key file somewhere else"
}

# stop_one <container>: stop_check for a container with one Aspia process, which exits cleanly.
stop_one() {
    stop_check "$1" 1
    log_has "$1" 'All processes have exited; exit code 0' || fail "$1 did not log a clean exit"
}

scenario_single_process() {
    log "23. One process per container: docker stop is clean, and the process dying stops the container non-zero"
    stop_one "${RELAY1_NAME}"
    crash_one aspia_relay KILL "${RELAY1_NAME}"
    stop_one "${ROUTER_NAME}"
    crash_one aspia_router TERM "${ROUTER_NAME}"   # a clean exit 0 is still a failure of the container
}

scenario_role_all_explicit() {
    local cfg db name logs relay ip
    log "24. ASPIA_ROLE=all given explicitly: the default behaviour; the remote-Router variables are ignored"
    cfg="$(new_volume s24-config)"
    db="$(new_volume s24-db)"
    run_new s24 "${cfg}" "${db}" -e ASPIA_ROLE=all -e "EXTERNAL_IP=${IP_NEW}" -e ASPIA_RELAY_ROUTER_ADDRESS=elsewhere.example.test \
        --network "${SPLIT_NET}" --network-alias aspia-all
    name="${CURRENT_CONTAINER}"
    wait_healthy "${name}"
    logs="$(docker logs "${name}" 2>&1)"
    grep -qF 'WARNING: Ignored: ASPIA_RELAY_ROUTER_ADDRESS' <<<"${logs}" || fail "no warning that ASPIA_RELAY_ROUTER_ADDRESS is ignored"
    [[ "$(ini_value "$(helper "${cfg}" "${db}" cat /etc/aspia/relay.conf)" router address)" == 127.0.0.1 ]] \
        || fail "role all: the Relay does not use the Router in its own container"
    grep -q 'Connection to the router is established' <<<"${logs}" || fail "the Relay did not connect"
    grep -qF '8063/tcp  Router: relays (used inside the container)' <<<"${logs}" || fail "the role all summary changed"
    if grep -q 'Role: ' <<<"${logs}"; then fail "role all prints a role line"; fi
    ok "healthy, the Relay connects to 127.0.0.1, the summary is the role all one; the remote-Router variable is ignored with a warning"

    # The combined container can serve a Relay on another machine as well (README: keep the local Relay).
    start_relay s24-relay aspia-all "$(helper "${cfg}" "${db}" cat /etc/aspia/relay.pub)" relay6.example.test
    relay="${CURRENT_CONTAINER}"
    wait_healthy "${relay}"
    ip="$(ip_of "${relay}")"
    CURRENT_CONTAINER="${name}"
    wait_log "${name}" "Received key pool: [0-9]+ \\( \"${ip}\" \\)" 1 30
    [[ "$(count_tcp "${name}" 01 8063)" == 2 ]] || fail "expected the local and the remote Relay on 8063, found $(count_tcp "${name}" 01 8063)"
    docker exec "${name}" /usr/bin/aspia_health >/dev/null || fail "the combined container is no longer healthy"
    ok "a remote Relay (${ip}) registered with the combined container next to its own Relay; both connected, healthy"
}

# ---------------------------------------------------------------------------------------------
# Hardening (PR 5b)

# jq_img <args...>: jq from the image under test (the host may not have it).
jq_img() { docker run --rm -i --platform "${PLATFORM}" --label "aspia-test=${RUN_ID}" --entrypoint jq "${IMAGE}" "$@"; }

scenario_compose_hardening() {
    local file unit expected out caps readme line
    log "0e. The compose files, Podman units and README carry the hardening settings that the scenarios run with"
    caps="$(printf '"%s",' "${CAPS[@]}")"
    expected="{\"cap_drop\":[\"ALL\"],\"cap_add\":[${caps%,}],\"security_opt\":[\"no-new-privileges:true\"],\"read_only\":true,\"pids_limit\":${PIDS_LIMIT},\"tmpfs\":null}"
    # One jq run for the three files; each prints one line.
    out="$(for file in docker-compose.yml compose.router.yml compose.relay.yml; do
        EXTERNAL_IP="${IP_NEW}" compose_file_config "${file}" --format json
    done | jq_img -c '.services[] | {cap_drop, cap_add, security_opt, read_only, pids_limit, tmpfs}')"
    [[ "${out}" == "${expected}"$'\n'"${expected}"$'\n'"${expected}" ]] || fail "compose files: ${out}, expected ${expected} three times"
    ok "docker-compose.yml, compose.router.yml, compose.relay.yml: ${expected}"

    # The Quadlet units: the same set.
    for unit in podman/aspia-server.container podman/aspia-relay.container; do
        [[ "$(sed -n 's/^AddCapability=//p' "${unit}")" == "${CAPS[*]}" ]] || fail "${unit}: AddCapability= is not ${CAPS[*]}"
        for line in DropCapability=ALL ReadOnly=true; do
            grep -qxF -- "${line}" "${unit}" || fail "${unit} has no line ${line}"
        done
        # Absent on purpose: AppArmor on Ubuntu 24.04 then blocks tini's SIGTERM (notes, section 21).
        ! grep -q '^NoNewPrivileges=' "${unit}" || fail "${unit} sets NoNewPrivileges= (breaks the stop on Ubuntu 24.04, notes section 21)"
        [[ "$(grep '^PodmanArgs=' "${unit}")" == "PodmanArgs=--pids-limit=${PIDS_LIMIT} --read-only-tmpfs=false" ]] || fail "${unit}: PodmanArgs= is not --pids-limit=${PIDS_LIMIT} --read-only-tmpfs=false"
    done
    ok "both Podman units: AddCapability= ${CAPS[*]}, DropCapability=ALL, no NoNewPrivileges, ReadOnly, pids ${PIDS_LIMIT}"

    readme="$(sed -n '/^## Security settings$/,/^## Updating$/p' README.md)"
    for line in "--cap-drop ALL" "--security-opt no-new-privileges:true" "--read-only" "--pids-limit ${PIDS_LIMIT} "; do
        grep -qF -- "${line}" <<<"${readme}" || fail "the README docker run example has no '${line}'"
    done
    [[ "$(grep '^  --' <<<"${readme}" | grep -o -- '--cap-add [A-Z_]*' | sed 's/--cap-add //' | sort | tr '\n' ' ')" == "$(printf '%s\n' "${CAPS[@]}" | sort | tr '\n' ' ')" ]] \
        || fail "the README docker run example has other --cap-add flags than ${CAPS[*]}"
    ok "the README docker run example has the same flags"
}

# cap_mask <capability>...: the CapEff bit mask of these capabilities, as /proc/<pid>/status prints it.
cap_mask() {
    local cap mask=0 bit
    for cap in "$@"; do
        case "${cap}" in
            CHOWN) bit=0 ;;
            DAC_OVERRIDE) bit=1 ;;
            KILL) bit=5 ;;
            SETGID) bit=6 ;;
            SETUID) bit=7 ;;
            SETPCAP) bit=8 ;;
            *) fail "cap_mask does not know ${cap}" ;;
        esac
        mask=$((mask | (1 << bit)))
    done
    printf '%016x\n' "${mask}"
}

# check_hardening <container> <CapEff of aspia_start> [CapEff of the Aspia processes, default none]: tini, aspia_start and
# the Aspia processes (role all) have NoNewPrivs 1; tini (PID 1) has the full set (it forwards signals), aspia_start the
# given CapEff, the Aspia processes the given CapEff and the same bounding set; the root is read-only; the pids limit is set.
check_hardening() {
    local status host full name aspia="${3:-0000000000000000}"
    full="$(cap_mask "${CAPS[@]}")"
    # cat, not awk: a process that exits during the read must not fail it. Parsed here, on the host.
    # Only tini and the Aspia processes are judged: a health check (root, full set under PUID) may run at any time.
    # aspia_start shows up under that name only natively (under Rosetta its name is bash).
    status="$(docker exec "$1" sh -c 'cat /proc/[0-9]*/status 2>/dev/null; true' \
        | awk '/^Name:/ {n = $2} /^CapEff:/ {c = $2} /^CapBnd:/ {b = $2} /^NoNewPrivs:/ {print n, c, b, $2}')"
    for name in tini aspia_router aspia_relay; do
        grep -q "^${name} " <<<"${status}" || fail "$1: no ${name} in the process list: ${status}"
    done
    # "" forces a string comparison: awk reads 00000000000000e3 as the number 0e3 = 0.
    [[ -z "$(awk -v s="$2" -v a="${aspia}" -v f="${full}" '
            $1 == "tini" && ($4 != 1 || $2"" != f"") { print }
            $1 == "aspia_start" && ($4 != 1 || $2"" != s"") { print }
            $1 ~ /^aspia_(router|relay)$/ && ($4 != 1 || $2"" != a"" || $3"" != a"") { print }' <<<"${status}")" ]] \
        || fail "$1: expected NoNewPrivs 1, CapEff ${full} (tini), $2 (aspia_start), ${aspia} (Aspia, also CapBnd); got"$'\n'"${status}"
    host="$(docker inspect -f '{{.HostConfig.ReadonlyRootfs}} {{.HostConfig.PidsLimit}}' "$1")"
    [[ "${host}" == "true ${PIDS_LIMIT}" ]] || fail "$1: ReadonlyRootfs and PidsLimit are '${host}'"
    if docker exec "$1" touch /usr/bin/aspia_start 2>/dev/null; then fail "$1: the root filesystem is writable"; fi
    ok "$1: NoNewPrivs 1; CapEff: tini ${full}, aspia_start $2, aspia_router and aspia_relay ${aspia}; read-only root, pids limit ${PIDS_LIMIT}"
}

# ---------------------------------------------------------------------------------------------
# Scenario groups and selection

# One line per group: name, weight, and its functions in the order they run. The groups run in this
# order. The weight is the group's duration in seconds in CI (ubuntu-24.04, image given), rounded;
# --shard uses it only to spread the slow groups, so update it when a group gets much faster or slower.
readonly GROUP_TABLE=(
    "build               4  scenario_build"
    "command             1  scenario_command"
    "compose             6  scenario_compose"
    "compose-roles       2  scenario_compose_roles"
    "compose-hardening   1  scenario_compose_hardening"
    "clean-start        26  scenario_clean_start scenario_restart scenario_new_external_ip scenario_stop scenario_crash scenario_relay_not_connected"
    "refused-2x          6  scenario_refused_2x_data"
    "no-external-ip      1  scenario_no_external_ip"
    "orphan-database     1  scenario_orphan_database"
    "refused-data        4  scenario_refused_relay_data"
    "env-apply           3  scenario_env_apply"
    "env-persistence    11  scenario_env_persistence"
    "env-invalid         4  scenario_env_invalid"
    "auto-no-network     2  scenario_env_auto_no_network"
    "auto-stub          10  scenario_env_auto_stub"
    "puid               11  scenario_puid_pgid"
    "empty-allowlist     7  scenario_env_empty_allowlist"
    "puid-refused        4  scenario_puid_pgid_refused"
    "split              46  scenario_split scenario_two_relays start_failing_relays scenario_relay_wrong_key scenario_relay_unreachable scenario_router_allow_list scenario_relay_invalid scenario_relay_wrong_key_retry scenario_relay_reconnect scenario_single_process scenario_role_all_explicit"
)

# SCAN_WEIGHT: the Trivy scan that ci.yml runs after the tests of shard 1 (image save, scan, SARIF upload;
# 15 s in CI), in seconds like the weights above. Shard 1 starts with it as its load, so it gets fewer groups.
readonly SCAN_WEIGHT=15

# shard_groups <i> <n>: the names of the groups of shard i of n, one per line. The heaviest group first,
# each to the shard with the least weight so far (the lowest shard on a tie): the same on every machine.
shard_groups() {
    local -a load=()
    local k best weight name
    for ((k = 1; k <= $2; k++)); do load[k]=0; done
    load[1]=${SCAN_WEIGHT}
    while read -r weight _ name; do
        best=1
        for ((k = 2; k <= $2; k++)); do
            if ((load[k] < load[best])); then best=${k}; fi
        done
        load[best]=$((load[best] + weight))
        if ((best == $1)); then echo "${name}"; fi
    done < <(printf '%s\n' "${GROUP_TABLE[@]}" | awk '{ print $2, NR, $1 }' | sort -k1,1nr -k2,2n)
}

usage_error() {
    printf 'tests/run.sh: %s\nUsage: tests/run.sh [--list] [--shard I/N | GROUP...]\n' "$1" >&2
    exit 2
}

LIST=0 SHARD="" SELECTED=()
while (($#)); do
    case "$1" in
        --list) LIST=1 ;;
        --shard)
            if [[ ! "${2:-}" =~ ^([1-9][0-9]*)/([1-9][0-9]*)$ ]] || ((BASH_REMATCH[1] > BASH_REMATCH[2])); then
                usage_error "--shard needs I/N with 1 <= I <= N, not '${2:-}'"
            fi
            SHARD="$2"
            shift
            ;;
        -*) usage_error "unknown option $1" ;;
        *)
            printf '%s\n' "${GROUP_TABLE[@]}" | awk -v g="$1" '$1 == g { found = 1 } END { exit !found }' \
                || usage_error "no group '$1' (tests/run.sh --list prints them)"
            SELECTED+=("$1")
            ;;
    esac
    shift
done
[[ -z "${SHARD}" || ${#SELECTED[@]} == 0 ]] || usage_error "--shard and group names do not go together"
if [[ -n "${SHARD}" ]]; then
    while read -r name; do SELECTED+=("${name}"); done < <(shard_groups "${SHARD%/*}" "${SHARD#*/}")
fi
ALL=0
[[ -n "${SHARD}" || ${#SELECTED[@]} != 0 ]] || ALL=1

# selected <group name>: the group runs in this selection.
selected() { ((ALL)) || [[ " ${SELECTED[*]-} " == *" $1 "* ]]; }

RUN=() RUN_NAMES=()   # the selected GROUP_TABLE lines and group names, in the order they run
for entry in "${GROUP_TABLE[@]}"; do
    read -r name _ <<<"${entry}"
    if selected "${name}"; then RUN+=("${entry}") RUN_NAMES+=("${name}"); fi
done

if ((LIST)); then
    total=0
    for entry in ${RUN[@]+"${RUN[@]}"}; do
        read -r name weight functions <<<"${entry}"
        printf '%-18s %3d  %s\n' "${name}" "${weight}" "${functions}"
        total=$((total + weight))
    done
    printf '%-18s %3d\n' total "${total}"
    exit 0
fi

((ALL)) || log "Groups${SHARD:+ of shard ${SHARD}}: ${RUN_NAMES[*]-(none)}"

trap cleanup EXIT   # only a run that builds and starts things has anything to remove
setup
for entry in ${RUN[@]+"${RUN[@]}"}; do
    read -r -a functions <<<"${entry}"
    started=${SECONDS}
    for function in "${functions[@]:2}"; do "${function}"; done
    # The time to compare with the weight in GROUP_TABLE (from a CI log, when updating the weights).
    printf '  time %s: %d s (weight in GROUP_TABLE: %d)\n' "${functions[0]}" $((SECONDS - started)) "${functions[1]}"
done

if ((ALL)); then
    log "All scenarios passed (image ${IMAGE})"
else
    log "All scenarios passed in ${SHARD:+shard ${SHARD}: }${RUN_NAMES[*]-(no group)} (image ${IMAGE})"
fi
