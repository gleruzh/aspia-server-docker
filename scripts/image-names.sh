#!/usr/bin/env bash
#
# scripts/image-names.sh: prints the registry-qualified image names as KEY=value lines, for
# "scripts/image-names.sh >> $GITHUB_ENV" in .github/workflows/publish.yml.
#
#   OWNER=<repository owner> [VAR_GHCR_IMAGE=...] [VAR_DOCKERHUB_IMAGE=...] [VAR_QUAY_IMAGE=...] \
#       scripts/image-names.sh
#
# Each job computes the names itself instead of passing them as job outputs: GitHub drops a job
# output whose value contains the value of any secret, and the default name <owner>/aspia-server
# contains the owner, which is often also the Docker Hub user name (DOCKERHUB_USERNAME).

set -euo pipefail

: "${OWNER:?OWNER (the repository owner) is not set}"

# Registries require lowercase repository names.
default_image="$(tr '[:upper:]' '[:lower:]' <<<"${OWNER}")/aspia-server"

echo "GHCR_IMAGE=ghcr.io/${VAR_GHCR_IMAGE:-${default_image}}"
echo "DOCKERHUB_IMAGE=docker.io/${VAR_DOCKERHUB_IMAGE:-${default_image}}"
echo "QUAY_IMAGE=quay.io/${VAR_QUAY_IMAGE:-${default_image}}"
