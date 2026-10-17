#!/usr/bin/env bash
#
# tests/auto_address.sh: unit tests of ASPIA_RELAY_PUBLIC_ADDRESS=auto in aspia_start, without network
# access. Runs inside the image under test, fed on stdin by tests/run.sh (scenario 12b):
#
#   docker run --rm -i --network none <image> bash -s < tests/auto_address.sh
#
#   1. the range filter (auto_address_rejected): loopback, private, link-local, CGNAT, multicast,
#      unspecified and documentation addresses are refused, public ones accepted
#   2. the response parser (parse_address_response)
#   3. detect_public_address with a stub openssl: the source order, the first valid answer wins, a
#      refused or invalid answer moves on to the next source, the openssl options and the request
#   4. a stop request (SIGTERM) during the detection skips the remaining sources
#   5. the real openssl against a local "openssl s_server": an answer is used only when the certificate
#      chains to the CA bundle and is valid for the host name
#
# Prints a line for every check and exits non-zero if one failed.

# shellcheck source=aspia_start
source /usr/bin/aspia_start
set +e

failed=0
ok() { printf '  ok   %s\n' "$*"; }
bad() { printf '  FAIL %s\n' "$*"; failed=1; }

work="$(mktemp -d)"
trap 'kill $(jobs -p) 2>/dev/null; rm -rf "${work}"' EXIT

# ---------------------------------------------------------------------------------------------
# 1. The range filter

for ip in 0.0.0.0 0.1.2.3 10.0.0.1 10.255.255.255 100.64.0.1 100.127.255.255 127.0.0.1 169.254.10.1 \
    172.16.0.1 172.31.255.255 192.0.2.1 192.168.1.1 198.51.100.7 203.0.113.10 224.0.0.1 239.255.255.255 \
    :: ::1 fc00::1 fd12:3456::1 fe80::1 febf:ffff::1 ff02::1 FF05::2 2001:db8::1 2001:DB8:1:2::5; do
    if why="$(auto_address_rejected "${ip}")"; then ok "${ip} refused: ${why}"; else bad "${ip} accepted"; fi
done
for ip in 1.1.1.1 8.8.8.8 9.255.255.255 11.0.0.1 100.63.255.255 100.128.0.1 172.15.255.255 172.32.0.1 \
    192.0.3.1 192.169.0.1 198.51.101.1 203.0.114.1 223.255.255.255 \
    2001:4860:4860::8888 2606:4700:4700::1111 2a00:1450:4001::1 2001:db9::1 fec0::1 fbff::1; do
    if why="$(auto_address_rejected "${ip}")"; then bad "${ip} refused: ${why}"; else ok "${ip} accepted"; fi
done

# ---------------------------------------------------------------------------------------------
# 2. The response parser

# parsed <response> <expected body>: parse_address_response accepts it and prints the body.
parsed() {
    local got
    if got="$(parse_address_response "$1")" && [[ "${got}" == "$2" ]]; then
        ok "parsed: $2"
    else
        bad "response $(printf '%q' "$1"): got '${got}', expected '$2'"
    fi
}
# refused <response>: parse_address_response refuses it.
refused() {
    local got
    if got="$(parse_address_response "$1")"; then bad "accepted $(printf '%q' "$1") as '${got}'"; else ok "refused: ${got}"; fi
}

parsed $'HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nContent-Length: 8\r\n\r\n9.9.9.9\n' 9.9.9.9
parsed $'HTTP/1.0 200 OK\nServer: x\n\n  2001:4860::1  \n' 2001:4860::1
parsed $'HTTP/1.1 200\r\nX-Address: 192.0.2.1\r\n\r\n8.8.4.4' 8.8.4.4
parsed $'HTTP/1.1 200 OK\r\n\r\n' ''
parsed $'HTTP/1.0 200 OK\r\nContent-Length: 13\r\ncontent-type: text/plain\r\n\r\n203.0.113.45\n' 203.0.113.45
parsed $'HTTP/1.1 200 OK\ncontent-length: 7\n\n8.8.8.8' 8.8.8.8
refused $'HTTP/1.0 200 OK\r\nContent-Length: 13\r\n\r\n203.0.113.4'
refused $'HTTP/1.0 200 OK\r\nContent-Length: 3\r\n\r\n203.0.113.4'
refused $'HTTP/1.1 403 Forbidden\r\n\r\n8.8.8.8'
refused $'HTTP/1.1 2000 OK\r\n\r\n8.8.8.8'
refused $'HTTP/2 200\r\n\r\n8.8.8.8'
refused $'8.8.8.8\n'
refused $'HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\n'
refused ''

# ---------------------------------------------------------------------------------------------
# 3. detect_public_address with a stub openssl

# The stub answers for the host of "-connect <host>:443" from files in ${work}/stub: response.<host>
# (printed), rc.<host> (its exit code, default 0), sleep.<host> (seconds before answering). It
# records its arguments in args.<host>, one per line, and the request it read in request.<host>.
mkdir -p "${work}/bin" "${work}/stub"
cat > "${work}/bin/openssl" <<'EOF'
#!/bin/bash
dir="${STUB_DIR:?}" host=""
args=("$@")
while (($#)); do [[ "$1" == -connect ]] && host="${2%:443}"; shift; done
printf '%s\n' "${args[@]}" > "${dir}/args.${host}"
cat > "${dir}/request.${host}"
[[ -f "${dir}/sleep.${host}" ]] && sleep "$(cat "${dir}/sleep.${host}")"
[[ -f "${dir}/response.${host}" ]] && cat "${dir}/response.${host}"
exit "$(cat "${dir}/rc.${host}" 2>/dev/null || echo 0)"
EOF
chmod +x "${work}/bin/openssl"
export STUB_DIR="${work}/stub"
stub_path="${work}/bin:${PATH}"

# answer <host> <body>: the stub answers "HTTP/1.1 200 OK" with <body> and a line end, and their length.
answer() {
    printf 'HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nContent-Length: %d\r\n\r\n%s\n' "$((${#2} + 1))" "$2" \
        > "${STUB_DIR}/response.$1"
}
reset_stub() { rm -f "${STUB_DIR}"/*; }
contacted() { [[ -f "${STUB_DIR}/args.$1" ]]; }

# detect <expected address or "none">: runs detect_public_address with the stub; its log is in ${work}/log.
detect() {
    local rc=0 want="$1"
    PATH="${stub_path}" detect_public_address 2> "${work}/log" || rc=$?
    if [[ "${want}" == none ]]; then
        ((rc != 0)) && [[ -z "${DETECTED_ADDRESS}" ]] && return 0
    else
        ((rc == 0)) && [[ "${DETECTED_ADDRESS}" == "${want}" ]] && return 0
    fi
    bad "detect_public_address: rc ${rc}, DETECTED_ADDRESS '${DETECTED_ADDRESS}', expected ${want}; log:"
    cat "${work}/log"
    return 1
}
log_says() { grep -qF -- "$1" "${work}/log" || { bad "the log does not say: $1"; cat "${work}/log"; }; }

reset_stub
answer api.ipify.org 9.9.9.9
answer ifconfig.me 8.8.8.8
if detect 9.9.9.9; then
    log_says "detected the public address 9.9.9.9 (source: https://api.ipify.org)"
    contacted ifconfig.me && bad "a later source was asked after the first valid answer"
    ok "the first source answers: its address is used, no other source is asked"
fi

# The request: HTTP/1.0 GET with the Host header. The options: certificate and host name verified
# against the CA bundle, SNI set.
if grep -qx $'GET / HTTP/1.0\r' "${STUB_DIR}/request.api.ipify.org" \
    && grep -qx $'Host: api.ipify.org\r' "${STUB_DIR}/request.api.ipify.org"; then
    ok "request: GET / HTTP/1.0, Host: api.ipify.org"
else
    bad "unexpected request:"
    cat -A "${STUB_DIR}/request.api.ipify.org"
fi
expected_args=$'s_client\n-quiet\n-ignore_unexpected_eof\n-connect\napi.ipify.org:443\n-servername\napi.ipify.org\n-verify_hostname\napi.ipify.org\n-verify_return_error\n-CAfile\n/etc/ssl/certs/ca-certificates.crt'
if [[ "$(cat "${STUB_DIR}/args.api.ipify.org")" == "${expected_args}" ]]; then
    ok "openssl s_client options: ${expected_args//$'\n'/ }"
else
    bad "openssl options:"
    cat "${STUB_DIR}/args.api.ipify.org"
fi
if [[ -s /etc/ssl/certs/ca-certificates.crt ]]; then ok "the CA bundle exists"; else bad "/etc/ssl/certs/ca-certificates.crt is missing"; fi
if command -v curl >/dev/null; then bad "curl is installed: $(command -v curl)"; else ok "no curl in the image"; fi

reset_stub
echo 1 > "${STUB_DIR}/rc.api.ipify.org"
answer ifconfig.me 10.20.30.40
answer icanhazip.com 2a00:1450:4001::1
if detect 2a00:1450:4001::1; then
    log_says "https://api.ipify.org: no TLS connection, or its certificate could not be verified (openssl exit code 1)"
    log_says "https://ifconfig.me/ip answered 10.20.30.40, a private address (RFC 1918), not a public address"
    log_says "detected the public address 2a00:1450:4001::1 (source: https://icanhazip.com)"
    grep -qx $'GET /ip HTTP/1.0\r' "${STUB_DIR}/request.ifconfig.me" || bad "ifconfig.me was not asked for /ip"
    ok "a failed source and a private answer are skipped, the third source is used"
fi

reset_stub
printf 'HTTP/1.1 503 Service Unavailable\r\n\r\n' > "${STUB_DIR}/response.api.ipify.org"
answer ifconfig.me '<html>8.8.8.8</html>'
answer icanhazip.com 100.64.1.2
if detect none; then
    log_says "https://api.ipify.org answered with an HTTP status other than 200 ('HTTP/1.1 503 Service Unavailable')"
    log_says "https://ifconfig.me/ip answered '<html>8.8.8.8</html>', which is not an IP address"
    log_says "https://icanhazip.com answered 100.64.1.2, a carrier-grade NAT address (RFC 6598)"
    ok "no valid answer from any source: fails"
fi

reset_stub
echo 30 > "${STUB_DIR}/sleep.api.ipify.org"
answer ifconfig.me 8.8.8.8
start=${SECONDS}
if detect 8.8.8.8; then
    log_says "https://api.ipify.org did not answer within ${AUTO_ADDRESS_TIMEOUT} s"
    if ((SECONDS - start <= AUTO_ADDRESS_TIMEOUT + 2)); then
        ok "a source that hangs is given up after ${AUTO_ADDRESS_TIMEOUT} s"
    else
        bad "the hanging source took $((SECONDS - start)) s"
    fi
fi

# ---------------------------------------------------------------------------------------------
# 4. A stop request during the detection ends it at once: no waiting for the request, no further source.

reset_stub
echo 4 > "${STUB_DIR}/sleep.api.ipify.org"
echo 1 > "${STUB_DIR}/rc.api.ipify.org"
answer ifconfig.me 8.8.8.8
(
    trap 'on_signal TERM' TERM
    rc=0
    PATH="${stub_path}" detect_public_address 2>/dev/null || rc=$?
    echo "${rc} ${STOPPING} ${DETECTED_ADDRESS}" > "${work}/stop"
) &
sleep 1
start=${SECONDS}
kill -TERM $!
wait $!
read -r rc stopping address < "${work}/stop"
if [[ "${rc}" != 0 && "${stopping}" == 1 && -z "${address}" ]] && ((SECONDS - start <= 1)) && ! contacted ifconfig.me; then
    ok "SIGTERM during the first request: detection failed at once (STOPPING=1), no other source asked"
else
    bad "after SIGTERM: rc ${rc}, STOPPING ${stopping}, address '${address}', $((SECONDS - start)) s, ifconfig.me asked: $(contacted ifconfig.me && echo yes || echo no)"
fi

# ---------------------------------------------------------------------------------------------
# 5. The real openssl against a local TLS server (as root, port 443; this container is thrown away).
# Its certificate is for "localhost", issued by a test CA that is not in the bundle at first.

cd "${work}" || exit 1
openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes -days 1 -subj /CN=test-ca \
    -keyout ca.key -out ca.crt 2>/dev/null
openssl req -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes -subj /CN=localhost \
    -keyout server.key -out server.csr 2>/dev/null
openssl x509 -req -in server.csr -CA ca.crt -CAkey ca.key -days 1 -out server.crt \
    -extfile <(printf 'subjectAltName=DNS:localhost\n') 2>/dev/null
mkdir www
# -HTTP serves the file as the whole response, status line and headers included.
printf 'HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\n\r\n1.0.0.1\n' > www/ip
(cd www && exec openssl s_server -quiet -HTTP -accept 443 -cert ../server.crt -key ../server.key) >/dev/null 2>&1 &
for _ in $(seq 50); do (exec 3<>/dev/tcp/127.0.0.1/443) 2>/dev/null && break; sleep 0.1; done
echo "127.0.0.1 not-localhost.test" >> /etc/hosts

if response="$(fetch_https https://localhost/ip)"; then bad "an untrusted certificate was accepted: ${response}"; else ok "untrusted certificate: refused"; fi
cat ca.crt >> /etc/ssl/certs/ca-certificates.crt
if response="$(fetch_https https://localhost/ip)" && [[ "$(parse_address_response "${response}")" == 1.0.0.1 ]]; then
    ok "trusted certificate for the host name: answer 1.0.0.1"
else
    bad "trusted certificate refused, or a wrong answer: $(printf '%q' "${response}")"
fi
if response="$(fetch_https https://not-localhost.test/ip)"; then bad "a certificate for another name was accepted"; else ok "certificate for another host name: refused"; fi

((failed == 0)) && echo "auto_address: ok"
exit "${failed}"
