#!/usr/bin/env bash
#
# scripts/versions.sh: reads, checks and bumps the Aspia version kept in versions.env.
#
#   scripts/versions.sh get [KEY]      print one value from versions.env (default: ASPIA_VERSION)
#   scripts/versions.sh env            print every KEY=value line (for $GITHUB_OUTPUT)
#   scripts/versions.sh files          list the files that pin the version
#   scripts/versions.sh check          versions.env is well formed and every pinned reference matches it
#   scripts/versions.sh bump VERSION ROUTER_SHA256 RELAY_SHA256
#                                      write versions.env, then replace the old version in every
#                                      pinned reference, then run check
#
# Pinned references: the ASPIA_VERSION default in the Dockerfile (Dockerfile syntax cannot read a
# file, so that default is a mirror, and the build fails when it differs from versions.env), and
# every image tag in the compose files, .env.example, Quadlet units and user documentation (*.md outside docs/dev/,
# which is history). An image tag of this image is valid only as <version> or <version>-YYYYMMDD;
# latest and the floating X and X.Y tags are published for convenience, never referenced here.
# Needs git, awk, sed and perl (all present on GitHub's Ubuntu runners and on macOS).

set -euo pipefail

cd "$(dirname "$0")/.."

readonly VERSIONS_FILE=versions.env
readonly LEGACY_TAG=2.7.0   # paprikkafox/aspia-server:2.7.0, the 2.x image that users upgrade from

die() {
    printf 'versions.sh: %s\n' "$*" >&2
    exit 1
}

usage() {
    sed -n '3,12s/^# \{0,1\}//p' "$0" >&2
    exit 2
}

get() { sed -n "s/^$1=//p" "${VERSIONS_FILE}"; }

valid_version() { [[ "$1" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; }
valid_sha256() { [[ "$1" =~ ^[0-9a-f]{64}$ ]]; }

pinned_files() {
    git ls-files --cached --others --exclude-standard -- Dockerfile .env.example '*.yml' '*.yaml' '*.container' '*.md' | grep -vE '^(\.github|docs/dev|tests)/' || true
}

check() {
    local version router relay dockerfile_version file line ref tag status=0
    version="$(get ASPIA_VERSION)"
    router="$(get ASPIA_ROUTER_SHA256)"
    relay="$(get ASPIA_RELAY_SHA256)"
    valid_version "${version}" || die "${VERSIONS_FILE}: ASPIA_VERSION '${version}' is not X.Y.Z"
    valid_sha256 "${router}" || die "${VERSIONS_FILE}: ASPIA_ROUTER_SHA256 is not 64 lowercase hex digits"
    valid_sha256 "${relay}" || die "${VERSIONS_FILE}: ASPIA_RELAY_SHA256 is not 64 lowercase hex digits"

    dockerfile_version="$(sed -n 's/^ARG ASPIA_VERSION=//p' Dockerfile)"
    if [[ "${dockerfile_version}" != "${version}" ]]; then
        printf 'Dockerfile: ARG ASPIA_VERSION=%s, versions.env has %s\n' "${dockerfile_version}" "${version}" >&2
        status=1
    fi
    if ! grep -qF "\${ASPIA_IMAGE:-aspia-server:${version}}" docker-compose.yml; then
        printf 'docker-compose.yml: the default image is not aspia-server:%s\n' "${version}" >&2
        status=1
    fi

    while IFS= read -r file; do
        while IFS=: read -r line ref; do
            tag="${ref#aspia-server:}"
            tag="${tag%.}"   # a sentence may end right after the tag
            if [[ "${tag}" != "${version}" && ! "${tag}" =~ ^${version//./\\.}-[0-9]{8}$ && "${tag}" != "${LEGACY_TAG}" ]]; then
                printf '%s:%s: aspia-server:%s (expected the exact version %s)\n' "${file}" "${line}" "${tag}" "${version}" >&2
                status=1
            fi
        done < <(grep -noE 'aspia-server:[A-Za-z0-9._-]+' "${file}" || true)
    done < <(pinned_files)

    ((status == 0)) || die "pinned references do not match ${VERSIONS_FILE}; run scripts/versions.sh bump"
    echo "versions: ok (Aspia ${version}; $(pinned_files | wc -l | tr -d ' ') pinned files checked)"
}

bump() {
    (($# == 3)) || usage
    local new="$1" router="$2" relay="$3" old tmp file
    valid_version "${new}" || die "version '${new}' is not X.Y.Z"
    valid_sha256 "${router}" || die "router sha256 is not 64 lowercase hex digits"
    valid_sha256 "${relay}" || die "relay sha256 is not 64 lowercase hex digits"
    old="$(get ASPIA_VERSION)"
    valid_version "${old}" || die "${VERSIONS_FILE}: current ASPIA_VERSION '${old}' is not X.Y.Z"

    tmp="$(mktemp)"
    awk -v version="${new}" -v router="${router}" -v relay="${relay}" '
        /^ASPIA_VERSION=/ { print "ASPIA_VERSION=" version; next }
        /^ASPIA_ROUTER_SHA256=/ { print "ASPIA_ROUTER_SHA256=" router; next }
        /^ASPIA_RELAY_SHA256=/ { print "ASPIA_RELAY_SHA256=" relay; next }
        { print }
    ' "${VERSIONS_FILE}" > "${tmp}"
    cat "${tmp}" > "${VERSIONS_FILE}"   # keeps the file mode
    rm -f "${tmp}"

    if [[ "${old}" != "${new}" ]]; then
        # The old version as a whole token: not inside 13.0.21, 3.0.210 or a build number 3.0.21.8214.
        while IFS= read -r file; do
            OLD="${old}" NEW="${new}" perl -pi -e 's/(?<![0-9.])\Q$ENV{OLD}\E(?![0-9]|\.[0-9])/$ENV{NEW}/g' "${file}"
        done < <(pinned_files)
    fi
    echo "bumped Aspia ${old} -> ${new}"
    check
}

case "${1:-}" in
    get) get "${2:-ASPIA_VERSION}" ;;
    env) grep -E '^ASPIA_[A-Z0-9_]+=' "${VERSIONS_FILE}" ;;
    files) pinned_files ;;
    check) check ;;
    bump) shift; bump "$@" ;;
    *) usage ;;
esac
