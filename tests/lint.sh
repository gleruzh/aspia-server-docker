#!/usr/bin/env bash
#
# tests/lint.sh: hadolint for every Dockerfile, shellcheck for every shell script, actionlint for
# the workflows (it also runs shellcheck on their run: blocks), that the podman/*.env.example files
# list the variables of .env.example that apply to their unit, scripts/versions.sh check, the
# input checks of scripts/versions.sh files and scripts/aspia-release.sh (with a stub gh), and that
# publish.yml publishes from main only.
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
check_publish_workflow() {
    local wf=.github/workflows/publish.yml ok=0 line
    echo "${wf} publishes from main only"
    # shellcheck disable=SC2016 # the literal text of the check in the workflow
    grep -qF '[[ "${GITHUB_REF}" != "refs/heads/main" ]]' "${wf}" \
        || { echo "${wf}: no refs/heads/main check in the Plan step"; ok=1; }
    [[ "$(sed -n '/^concurrency:/,/^[^ ]/p' "${wf}")" == $'concurrency:\n  group: publish\n  cancel-in-progress: false\n'* ]] \
        || { echo "${wf}: no workflow-level concurrency group 'publish'"; ok=1; }
    if grep -nE '^    concurrency:' "${wf}"; then echo "${wf}: job-level concurrency"; ok=1; fi
    if grep -nE '^ +[A-Z_]+: \$\{\{ *secrets\.(DOCKERHUB|QUAY)_[A-Z]+ *\}\}' "${wf}"; then
        echo "${wf}: a registry secret is passed to a step's env; pass a boolean instead"; ok=1
    fi
    grep -q 'certificate-identity' "${wf}" || { echo "${wf}: no cosign verify command"; ok=1; }
    while IFS= read -r line; do
        [[ "${line}" == *'publish\\.yml@refs/heads/main$'* || "${line}" == *'publish\.yml@refs/heads/main$'* ]] \
            || { echo "cosign identity not pinned to refs/heads/main: ${line}"; ok=1; }
    done < <(grep -rn --include='*.md' --include='*.yml' -e '--certificate-identity' .github docs README.md podman)
    return "${ok}"
}
check_publish_workflow || status=1

((status == 0)) && echo "lint: ok"
exit "${status}"
