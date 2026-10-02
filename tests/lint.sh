#!/usr/bin/env bash
#
# tests/lint.sh: hadolint for every Dockerfile, shellcheck for every shell script, actionlint for
# the workflows (it also runs shellcheck on their run: blocks), that the podman/*.env.example files
# list the variables of .env.example that apply to their unit, and scripts/versions.sh check.
# The linters run as pinned containers, so the result does not depend on what the host has installed.

set -euo pipefail

cd "$(dirname "$0")/.."

readonly HADOLINT=hadolint/hadolint:v2.14.0@sha256:27086352fd5e1907ea2b934eb1023f217c5ae087992eb59fde121dce9c9ff21e
readonly SHELLCHECK=koalaman/shellcheck:v0.11.0@sha256:61862eba1fcf09a484ebcc6feea46f1782532571a34ed51fedf90dd25f925a8d
readonly ACTIONLINT=rhysd/actionlint:1.7.12@sha256:b1934ee5f1c509618f2508e6eb47ee0d3520686341fec936f3b79331f9315667

readonly DOCKERFILES=(Dockerfile tests/helper/Dockerfile)
readonly SCRIPTS=(aspia_start aspia_health aspia_common.sh tests/run.sh tests/podman.sh tests/lint.sh tests/helper/x25519_pub scripts/versions.sh scripts/aspia-release.sh scripts/image-names.sh)

status=0
for file in "${DOCKERFILES[@]}"; do
    echo "hadolint ${file}"
    docker run --rm -i "${HADOLINT}" hadolint - < "${file}" || status=1
done

echo "shellcheck ${SCRIPTS[*]}"
docker run --rm -v "${PWD}:/mnt:ro" -w /mnt "${SHELLCHECK}" "${SCRIPTS[@]}" || status=1

echo "actionlint .github/workflows"
docker run --rm -v "${PWD}:/repo:ro" -w /repo "${ACTIONLINT}" -no-color || status=1

# The Podman env files list the variables of .env.example that apply to their unit. Never in
# either: ASPIA_IMAGE (the image is the Image= line of the unit). aspia-server.env.example (all
# roles, but a Relay on its own has its own unit): everything else except ASPIA_RELAY_ROUTER_*.
# aspia-relay.env.example (ASPIA_ROLE=relay is set in the unit): everything else except
# ASPIA_ROLE and the Router's ASPIA_ROUTER_*. Names are the lines "NAME=" or "#NAME=".
env_names() { sed -nE 's/^#?([A-Z][A-Z0-9_]*)=.*/\1/p' "$1" | sort -u; }

# check_env_example FILE EXCLUDED_REGEX: FILE lists the variables of .env.example except those matching the regex.
check_env_example() {
    echo "$1 variables match .env.example"
    diff --label ".env.example" --label "$1" \
        <(env_names .env.example | grep -vE "$2") \
        <(env_names "$1") || status=1
}

check_env_example podman/aspia-server.env.example '^(ASPIA_IMAGE|ASPIA_RELAY_ROUTER_.*)$'
check_env_example podman/aspia-relay.env.example '^(ASPIA_IMAGE|ASPIA_ROLE|ASPIA_ROUTER_.*)$'

echo "scripts/versions.sh check"
scripts/versions.sh check || status=1

((status == 0)) && echo "lint: ok"
exit "${status}"
