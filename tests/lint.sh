#!/usr/bin/env bash
#
# tests/lint.sh: hadolint for every Dockerfile, shellcheck for every shell script.
# Both run as pinned containers, so the result does not depend on what the host has installed.

set -euo pipefail

cd "$(dirname "$0")/.."

readonly HADOLINT=hadolint/hadolint:v2.14.0@sha256:27086352fd5e1907ea2b934eb1023f217c5ae087992eb59fde121dce9c9ff21e
readonly SHELLCHECK=koalaman/shellcheck:v0.11.0@sha256:61862eba1fcf09a484ebcc6feea46f1782532571a34ed51fedf90dd25f925a8d

readonly DOCKERFILES=(Dockerfile tests/helper/Dockerfile)
readonly SCRIPTS=(aspia_start aspia_health tests/run.sh tests/lint.sh tests/helper/x25519_pub)

status=0
for file in "${DOCKERFILES[@]}"; do
    echo "hadolint ${file}"
    docker run --rm -i "${HADOLINT}" hadolint - < "${file}" || status=1
done

echo "shellcheck ${SCRIPTS[*]}"
docker run --rm -v "${PWD}:/mnt:ro" -w /mnt "${SHELLCHECK}" "${SCRIPTS[@]}" || status=1

((status == 0)) && echo "lint: ok"
exit "${status}"
