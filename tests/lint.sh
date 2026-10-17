#!/usr/bin/env bash
#
# tests/lint.sh: hadolint for every Dockerfile, shellcheck for every shell script, actionlint for
# the workflows (it also runs shellcheck on their run: blocks), that the podman/*.env.example files
# list the variables of .env.example that apply to their unit, that the Quadlet unit does not publish
# the Aspia 2.x port 8060 by default, that the Dockerfile installs no curl, scripts/versions.sh check,
# the input checks of scripts/versions.sh files and scripts/aspia-release.sh (with a stub gh), that
# publish.yml publishes from main only, and that rebuild.yml starts it on main only (and skips only a
# version that is not published yet).
# The linters run as pinned containers, so the result does not depend on what the host has installed.

set -euo pipefail

cd "$(dirname "$0")/.."

readonly HADOLINT=hadolint/hadolint:v2.14.0@sha256:27086352fd5e1907ea2b934eb1023f217c5ae087992eb59fde121dce9c9ff21e
readonly SHELLCHECK=koalaman/shellcheck:v0.11.0@sha256:61862eba1fcf09a484ebcc6feea46f1782532571a34ed51fedf90dd25f925a8d
readonly ACTIONLINT=rhysd/actionlint:1.7.12@sha256:b1934ee5f1c509618f2508e6eb47ee0d3520686341fec936f3b79331f9315667

readonly DOCKERFILES=(Dockerfile tests/helper/Dockerfile)
readonly SCRIPTS=(aspia_start aspia_health aspia_common.sh tests/run.sh tests/podman.sh tests/lint.sh tests/auto_address.sh tests/helper/x25519_pub scripts/versions.sh scripts/aspia-release.sh scripts/image-names.sh)

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
# either: ASPIA_IMAGE and ASPIA_ROUTER_CLIENT_BIND_IP (in Quadlet units the image is Image= and the
# bind address is in PublishPort=). aspia-server.env.example (all roles, but a Relay on its own has
# its own unit): everything else except ASPIA_RELAY_ROUTER_*. aspia-relay.env.example
# (ASPIA_ROLE=relay is set in the unit): everything else except ASPIA_ROLE and the Router's
# ASPIA_ROUTER_*. Names are the lines "NAME=" or "#NAME=".
env_names() { sed -nE 's/^#?([A-Z][A-Z0-9_]*)=.*/\1/p' "$1" | sort -u; }

# check_env_example FILE EXCLUDED_REGEX: FILE lists the variables of .env.example except those matching the regex.
check_env_example() {
    echo "$1 variables match .env.example"
    diff --label ".env.example" --label "$1" \
        <(env_names .env.example | grep -vE "$2") \
        <(env_names "$1") || status=1
}

check_env_example podman/aspia-server.env.example '^(ASPIA_IMAGE|ASPIA_ROUTER_CLIENT_BIND_IP|ASPIA_RELAY_ROUTER_.*)$'
check_env_example podman/aspia-relay.env.example '^(ASPIA_IMAGE|ASPIA_ROLE|ASPIA_ROUTER_.*)$'

# Only migrated 2.x Hosts need 8060: the unit has its PublishPort= line commented out, like the
# compose files (tests/run.sh, scenarios 0c and 0d, checks those).
echo "podman/aspia-server.container does not publish 8060"
if grep -q '^PublishPort=.*8060' podman/aspia-server.container; then
    echo "podman/aspia-server.container publishes the Aspia 2.x port 8060 by default" >&2
    status=1
fi

# curl and its libraries brought more than a third of the image's known vulnerabilities; aspia_start
# uses openssl s_client for ASPIA_RELAY_PUBLIC_ADDRESS=auto. No line of the Dockerfile outside its
# comments may name curl (a package list or a download alike).
echo "Dockerfile installs no curl"
if grep -nEw '^[^#]*curl' Dockerfile; then
    echo "Dockerfile: curl is back in the image; aspia_start does not need it (openssl s_client)" >&2
    status=1
fi

echo "scripts/versions.sh check"
scripts/versions.sh check || status=1

# The bump commit adds every file of scripts/versions.sh files, so an untracked file must never be listed.
tmp="$(mktemp -d)"
untracked="lint-untracked-$$.md"
trap 'rm -rf "${tmp}" "${untracked}"' EXIT
echo "scripts/versions.sh files lists tracked files only"
: > "${untracked}"
if scripts/versions.sh files | grep -qxF "${untracked}"; then echo "scripts/versions.sh files lists the untracked ${untracked}"; status=1; fi
rm -f "${untracked}"

# scripts/aspia-release.sh against a stub gh (no network): the version must be X.Y.Z, asset names
# match exactly, and fetch refuses a package that the GitHub API reports no digest for.
cat > "${tmp}/gh" <<'EOF'
#!/usr/bin/env bash
# gh api: prints STUB_ASSETS ("<name> <digest>" lines). gh release download: writes "stub" to <-D>/<-p>.
if [[ "$1" == api ]]; then printf '%s\n' "${STUB_ASSETS}"; exit 0; fi
while (($#)); do case "$1" in -p) name="$2"; shift ;; -D) dir="$2"; shift ;; esac; shift; done
printf stub > "${dir}/${name}"
EOF
chmod +x "${tmp}/gh"
readonly STUB_SHA=725c546b990dd1b41f3d5791b37c3c0edcb1f08cf150bdae32a73dfd166e02d7   # sha256 of "stub"

# check_release WANT ASSETS ARGS...: scripts/aspia-release.sh ARGS succeeds (WANT=ok) or fails (WANT=fail).
check_release() {
    local want="$1" assets="$2" got=ok
    shift 2
    echo "scripts/aspia-release.sh $* (expected: ${want})"
    PATH="${tmp}:${PATH}" STUB_ASSETS="${assets}" scripts/aspia-release.sh "$@" > "${tmp}/out" 2>&1 || got=fail
    [[ "${got}" == "${want}" ]] || { echo "got: ${got}"; cat "${tmp}/out"; status=1; }
}

# expect_out TEXT: the output of the last check_release contains TEXT.
expect_out() { grep -qF -- "$1" "${tmp}/out" || { cat "${tmp}/out"; status=1; }; }

debs=$'aspia-router-3.0.0-x86_64.deb sha256:'"${STUB_SHA}"$'\naspia-relay-3.0.0-x86_64.deb sha256:'"${STUB_SHA}"
check_release fail "${debs}" has-debs '3.0.0 x'
expect_out "is not X.Y.Z"
check_release fail "${debs}" fetch '3.0.0/../x' "${tmp}/debs"
expect_out "is not X.Y.Z"
check_release ok "${debs}" has-debs 3.0.0
check_release fail "${debs//./a}" has-debs 3.0.0
check_release fail $'aspia-router-3.0.0-x86_64.deb \naspia-relay-3.0.0-x86_64.deb ' fetch 3.0.0 "${tmp}/debs"
check_release ok "${debs}" fetch 3.0.0 "${tmp}/debs"
grep -qxF "${STUB_SHA} ${STUB_SHA}" "${tmp}/out" || { echo "fetch printed: $(cat "${tmp}/out")"; status=1; }

# publish.yml may publish only from main: the Plan step refuses any other ref, one workflow-level
# concurrency group serialises every publish, raw registry secrets never go into a step's env, and
# every documented cosign identity is pinned to publish.yml@refs/heads/main.
wf=.github/workflows/publish.yml
echo "${wf} publishes from main only"
# shellcheck disable=SC2016 # the literal text of the check in the workflow
grep -qF '[[ "${GITHUB_REF}" != "refs/heads/main" ]]' "${wf}" \
    || { echo "${wf}: no refs/heads/main check in the Plan step"; status=1; }
# Two-space indent: only the workflow-level concurrency block matches, not a job-level one.
grep -qxF '  group: publish' "${wf}" || { echo "${wf}: no workflow-level concurrency group 'publish'"; status=1; }
if grep -n 'cancel-in-progress: true' "${wf}"; then echo "${wf}: a publish must never be cancelled halfway"; status=1; fi
if grep -nE '^ +[A-Z_]+: \$\{\{ *secrets\.(DOCKERHUB|QUAY)_[A-Z]+ *\}\}' "${wf}"; then
    echo "${wf}: a registry secret is passed to a step's env; pass a boolean instead"; status=1
fi
grep -q 'certificate-identity' "${wf}" || { echo "${wf}: no cosign verify command"; status=1; }
# The workflow echoes the regexp with a doubled backslash, the docs have a single one.
# Captured, not piped into if: under pipefail a grep writing to /dev/null quits early and hides a hit.
unpinned="$(grep -rn --include='*.md' --include='*.yml' -e '--certificate-identity' .github docs README.md podman \
    | grep -vE 'publish\\{1,2}\.yml@refs/heads/main\$' || true)"
[[ -z "${unpinned}" ]] || { printf '%s\n' "${unpinned}" "cosign identity not pinned to refs/heads/main"; status=1; }

# rebuild.yml starts publish.yml on main only, and scans with the Trivy that ci.yml pins.
wf=.github/workflows/rebuild.yml
echo "${wf} starts publish.yml on main only, skips only an unpublished version, uses the Trivy of ci.yml"
dispatches="$(grep -n 'gh workflow run' "${wf}" || true)"
if [[ -z "${dispatches}" ]] || grep -v 'gh workflow run publish\.yml --ref main ' <<<"${dispatches}"; then
    echo "${wf}: every 'gh workflow run' must be 'gh workflow run publish.yml --ref main ...'"; status=1
fi
# A tag X.Y.Z that is not in GHCR yet (right after a version bump) ends the run with success, but only
# when the error is "not found" and the image has a tag latest; every other error fails it.
# shellcheck disable=SC2016 # the literal text of the checks in the workflow
if ! grep -qF "grep -qF ': not found' \"\${RUNNER_TEMP}/inspect.err\"" "${wf}" \
    || ! grep -qF 'docker buildx imagetools inspect "${GHCR_IMAGE}:latest"' "${wf}"; then
    echo "${wf}: a missing tag X.Y.Z must end the run only for 'not found' with a tag latest present"; status=1
fi
trivy_pins="$(grep -h '^  TRIVY_IMAGE: ' .github/workflows/ci.yml "${wf}" | sort -u)"
(($(wc -l <<<"${trivy_pins}") == 1)) || { printf '%s\n' "${trivy_pins}" "ci.yml and ${wf} pin different Trivy images"; status=1; }

((status == 0)) && echo "lint: ok"
exit "${status}"
