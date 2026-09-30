Task: set up GitHub Actions for aspia-server-docker: checks on pull requests, automatic updates when Aspia publishes a new release, and publishing the image to registries. Branch ci/build-publish from main (PR 1 is already merged there).

Read first: docs/dev/UPSTREAM-3.x-NOTES.md, Dockerfile, tests/run.sh, and the existing files in .github/workflows (decide what to replace and explain it in the PR description).

Context: this repository is a fork that acts as the project's home, and the result may later be offered to the original repository. So the same YAML must work for any owner without edits: it publishes to ghcr.io/<repository owner>/aspia-server by default, and to other registries only when that owner has configured the secrets.

WHAT TO DO

1. Single source of version. A file in the repository root (for example versions.env) with ASPIA_VERSION and the sha256 of both .deb packages. Dockerfile, tests and workflows read the version only from there.

2. ci.yml - on pull_request and on push to main: hadolint, shellcheck, actionlint, image build, tests/run.sh, and a vulnerability scan of the image (report to the log and to the Security tab; it does not fail the build, since we do not control vulnerabilities in Debian packages). Use the pull_request trigger, not pull_request_target: code from other people's PRs must not get access to secrets.

3. upstream-watch.yml - on a schedule (every 6 hours) and manually. It fetches the latest stable release of dchapyshev/aspia through the API (skipping pre-releases and drafts) and compares it with versions.env. If the release is newer and contains both x86_64 .deb packages: download them, compute sha256, update versions.env and every pinned image tag in the repository (compose files, Quadlet units, README examples), build the image, run tests/run.sh, and open a PR "chore: bump Aspia to X.Y.Z" with the test results in the description. If a PR for that version is already open, do nothing.
   Account for two GitHub limitations and explain in the PR how you handled them: a PR created with GITHUB_TOKEN does not trigger other workflows (so the tests run inside this same job); scheduled workflows are disabled after 60 days without repository activity, and they do not run in a fork until Actions is enabled there.
   No auto-merge: a version change has already broken the config format once, so a human decides. If the tests fail on the new version, still open the PR, as a draft, with the failure log.

4. publish.yml - on push to main when versions.env or the image files change; weekly on a schedule (rebuild to pick up base image security updates); manually with a version input.
   - Before publishing, run tests/run.sh against the very image that will be published.
   - Tags: X.Y.Z, X.Y, X, latest. The weekly rebuild overwrites these tags and also adds an immutable X.Y.Z-YYYYMMDD tag.
   - Registries: GHCR always, with GITHUB_TOKEN. Docker Hub if the secrets DOCKERHUB_USERNAME and DOCKERHUB_TOKEN are set. Quay.io if QUAY_USERNAME and QUAY_TOKEN are set. The image name in each registry comes from repository variables, defaulting to <repository owner>/aspia-server. Missing secrets are not an error: the step is skipped with a clear log line.
   - latest and the floating X and X.Y tags are published for convenience only; nothing in this repository references them. Write the pushed image digest to the job summary so a release can be pinned by digest.
   - Dependabot keeps the pinned base image digest and the pinned action SHAs current through pull requests; nothing is bumped silently.
   - Platform: linux/amd64 only.
   - SBOM and build provenance attestations; cosign keyless signing.
   - Syncing the Docker Hub description from the README as a separate step, also only when the secrets exist.

5. Hygiene: third-party actions pinned by commit SHA with a version comment; minimal permissions at job level; concurrency so two publishes of the same version never run at once; dependabot.yml for github-actions and docker.

6. Documentation: docs/ci.md - which secrets and variables to set, how to trigger a publish manually, how to enable Docker Hub and Quay. Build status badges in the README, built from the repository path rather than a hard-coded owner where the badge syntax allows it; otherwise list them in docs/dev/FOLLOWUPS.md as fork-specific.

VERIFICATION
You may have no Docker Hub secrets; do not pretend publishing there was verified. What can and must be verified: actionlint is clean; ci.yml passes in the fork; publish.yml, run manually from the branch, publishes to the fork's GHCR and the image pulled from there passes tests/run.sh; upstream-watch.yml, run manually on a test branch where versions.env is temporarily set back to 3.0.18, opens a correct PR for 3.0.21. Attach links to those runs. Close the test PR and delete the test branch afterwards.

OUT OF SCOPE
Changes to Dockerfile and entrypoint beyond reading the version from versions.env; self-update of users' running containers; arm64.

DELIVERABLE
The branch, the PR description, a table "secret or variable - purpose - required or optional", links to the runs in the fork, and a list of what only the repository owner can verify.
