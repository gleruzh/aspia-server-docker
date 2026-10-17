#!/usr/bin/env bash
#
# scripts/tool-image.sh NAME: prints the image that .github/tool-images/Dockerfile pins as
# "FROM <image> AS NAME", e.g. "scripts/tool-image.sh trivy". Fails when there is no such line.

set -euo pipefail

cd "$(dirname "$0")/.."

readonly FILE=.github/tool-images/Dockerfile

image="$(awk -v name="${1:?usage: $0 NAME}" '$1 == "FROM" && $3 == "AS" && $4 == name { print $2; exit }' "${FILE}")"
[[ -n "${image}" ]] || { echo "$0: no image named '$1' in ${FILE}" >&2; exit 1; }
echo "${image}"
