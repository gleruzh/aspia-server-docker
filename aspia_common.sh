# shellcheck shell=bash
#
# aspia_common.sh: helpers shared by aspia_start and aspia_health. Sourced, not executed; it only
# defines constants and functions.
#
# ini_get and the /proc/net socket check are based on server/aspia_health from
# SinitsaDA/aspia-server-docker (commit de15b99, GPL-3.0), https://github.com/SinitsaDA/aspia-server-docker.
# Changed: CRLF and spaces in the INI files are tolerated; TCP and UDP, local and remote ports.

# Socket states in /proc/net/*: TCP_ESTABLISHED=01, TCP_LISTEN=0A; a bound UDP socket is 07.
# shellcheck disable=SC2034  # used by the scripts that source this file
readonly TCP_ESTABLISHED=01 TCP_LISTEN=0A UDP_BOUND=07

# role_services <role>: prints the processes that ASPIA_ROLE=<role> runs, in start order, and fails
# for an unknown role. Empty means all. aspia_start starts these and aspia_health checks these, so
# the two always agree.
role_services() {
    case "$1" in
        "" | all) echo "router relay" ;;
        router) echo "router" ;;
        relay) echo "relay" ;;
        *) return 1 ;;
    esac
}

# ini_get <file> <section> <key> <default>: prints the value, or <default> if it is missing or empty.
ini_get() {
    local value=""
    if [[ -r "$1" ]]; then
        value="$(awk -v section="$2" -v key="$3" '
            function trim(s) { gsub(/^[ \t]+|[ \t]+$/, "", s); return s }
            { line = $0; sub(/\r$/, "", line) }
            line ~ /^[ \t]*\[/ { in_section = (trim(line) == "[" section "]"); next }
            in_section && (p = index(line, "=")) > 0 && trim(substr(line, 1, p - 1)) == key {
                print trim(substr(line, p + 1)); exit
            }
        ' "$1")"
    fi
    printf '%s\n' "${value:-${4-}}"
}

# stun_enabled <router.conf>: succeeds unless [stun] enabled is 0 or false (the Router's default is on).
stun_enabled() {
    local value
    value="$(ini_get "$1" stun enabled 1)"
    [[ "${value,,}" != "0" && "${value,,}" != "false" ]]
}

# socket_state <tcp|udp> <state> <local|remote> <port>: succeeds if such a socket exists (IPv4 or
# IPv6). Reads /proc only; no connection is opened.
socket_state() {
    local files=() file column
    for file in "/proc/net/$1" "/proc/net/${1}6"; do
        [[ -r "${file}" ]] && files+=("${file}")
    done
    ((${#files[@]})) || return 1
    [[ "$3" == "local" ]] && column=2 || column=3
    # 10#: a port written with a leading zero (08060) is decimal, as for the Aspia binaries.
    awk -v state="$2" -v column="${column}" -v port="$(printf '%04X' "$((10#$4))")" '
        FNR > 1 && $4 == state { n = split($column, a, ":"); if (toupper(a[n]) == port) { found = 1; exit } }
        END { exit !found }
    ' "${files[@]}"
}
