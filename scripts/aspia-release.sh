#!/usr/bin/env bash
#
# scripts/aspia-release.sh: queries Aspia releases on GitHub (used by .github/workflows/upstream-watch.yml).
#
#   scripts/aspia-release.sh latest            print the newest stable version (X.Y.Z): no drafts,
#                                              no pre-releases, only tags of the form vX.Y.Z
#   scripts/aspia-release.sh has-debs VERSION  exit 0 if the release has both x86_64 server packages
#   scripts/aspia-release.sh fetch VERSION DIR download both packages into DIR, check them against the
#                                              digest the GitHub API reports (fail if it has none),
#                                              print "<router sha256> <relay sha256>"
#
# Needs gh (authenticated, or GH_TOKEN set), sha256sum or shasum, and jq-compatible --jq support in gh.

set -euo pipefail

readonly UPSTREAM="${ASPIA_UPSTREAM_REPO:-dchapyshev/aspia}"

die() {
    printf 'aspia-release.sh: %s\n' "$*" >&2
    exit 1
}

usage() {
    sed -n '3,11s/^# \{0,1\}//p' "$0" >&2
    exit 2
}

deb_names() { printf 'aspia-router-%s-x86_64.deb\naspia-relay-%s-x86_64.deb\n' "$1" "$1"; }

sha256() {
    if command -v sha256sum >/dev/null; then sha256sum "$1"; else shasum -a 256 "$1"; fi | awk '{print $1}'
}

latest() {
    local version
    # The API lists releases newest first; sort -V decides, so a late patch to an older line
    # cannot win over a newer version.
    version="$(gh api "repos/${UPSTREAM}/releases?per_page=100" \
        --jq '.[] | select(.draft == false and .prerelease == false) | .tag_name' \
        | sed -n 's/^v\([0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*\)$/\1/p' | sort -V | tail -n 1)"
    [[ -n "${version}" ]] || die "no stable release found in ${UPSTREAM}"
    echo "${version}"
}

require_version() { [[ "$1" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "version '$1' is not X.Y.Z"; }

assets() { gh api "repos/${UPSTREAM}/releases/tags/v$1" --jq '.assets[] | "\(.name) \(.digest // "")"'; }

has_debs() {
    require_version "$1"
    local list name
    list="$(assets "$1")"
    while IFS= read -r name; do
        awk -v n="${name}" '$1 == n { found = 1 } END { exit !found }' <<<"${list}" \
            || { echo "v$1 has no ${name}" >&2; return 1; }
    done < <(deb_names "$1")
}

fetch() {
    require_version "$1"
    local version="$1" dir="$2" list name api sum sums=()
    list="$(assets "${version}")"
    mkdir -p "${dir}"
    while IFS= read -r name; do
        gh release download "v${version}" -R "${UPSTREAM}" -p "${name}" -D "${dir}" --clobber >&2
        sum="$(sha256 "${dir}/${name}")"
        api="$(awk -v n="${name}" '$1 == n { print $2 }' <<<"${list}")"
        [[ -n "${api}" ]] || die "${name}: the GitHub API reports no digest"
        if [[ "${api}" != "sha256:${sum}" ]]; then
            die "${name}: downloaded sha256 ${sum} differs from the API digest ${api}"
        fi
        sums+=("${sum}")
    done < <(deb_names "${version}")
    echo "${sums[0]} ${sums[1]}"
}

case "${1:-}" in
    latest) latest ;;
    has-debs) (($# == 2)) || usage; has_debs "$2" ;;
    fetch) (($# == 3)) || usage; fetch "$2" "$3" ;;
    *) usage ;;
esac
