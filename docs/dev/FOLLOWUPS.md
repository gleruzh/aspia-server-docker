# Follow-ups

Ideas and gaps found while working on a PR, left out because they are outside its scope.
Each item names the PR that found it.

## From PR 1 (image 3.0.21)

- **Path overrides.** `aspia_start` and `aspia_health` use the fixed paths `/etc/aspia/router.conf`,
  `/etc/aspia/relay.conf` and `/var/lib/aspia/router.db3`. The binaries also honour
  `ASPIA_ROUTER_CONFIG_FILE`, `ASPIA_RELAY_CONFIG_FILE` and `ASPIA_ROUTER_DB_FILE`. If a user sets
  one of them, the entrypoint checks and edits the wrong file. Either honour them in both scripts, or
  refuse to start when they are set.
- **Backups on later upgrades.** The database is copied only before the 2.x migration. A future 3.x
  release that changes the schema again would upgrade `router.db3` in place with no copy. Idea: store
  the image version that last ran next to the database and copy `router.db3` whenever it changes.
- **`EXTERNAL_IP` validation** (PR 3). PR 1 rejects only empty or blank values and characters outside
  `[A-Za-z0-9._:-]`. The Router accepts an IP literal or a host name of at most 64 characters and
  silently ignores a Relay whose address it rejects (notes section 13.1).
- **Healthcheck blind spots.** An ESTABLISHED socket to the Router does not prove that the Router
  accepted the Relay: an invalid `public_address`, or a sixth Relay over the limit of five, is visible
  only in the Router log. A log-based check would need the Router log in a file or a pipe the check
  can read.
- **Role-aware healthcheck** (PR 5). `aspia_health` always checks Router and Relay. `aspia_start`
  keeps its process list in `SERVICES`; the healthcheck will need the same decision.
- **Non-root.** Both processes run as root, as in 2.7.0. Notes section 13.4 shows that the Router and
  Relay run as `nobody` with the right ownership; changing ownership of an existing 2.x volume and
  running the migration as non-root is not tested.
- **Published image.** `docker-compose.yml` builds locally by default (`image: ${ASPIA_IMAGE:-aspia-server:3.0.21}`
  plus `build: .`), because no owner name may be hard-coded. Done in PR 2: the image is published
  (`ghcr.io/<owner>/aspia-server`, optionally Docker Hub and Quay.io), README and docs/ci.md show the
  `ASPIA_IMAGE` value and pinning by digest, and `scripts/versions.sh` keeps the default tag in sync with
  `versions.env` (checked in CI). Still open: if `ASPIA_IMAGE` names a registry image that cannot be pulled
  (a typo, no access), `docker compose up` falls back to building locally under that name (compose v5.5.1),
  and `--build` with `ASPIA_IMAGE` set builds locally under the published name. Both come from `image:` and
  `build:` in one service. PR 2 left the file as it is: a pull-by-default compose file needs a default
  image name, which would be an owner name, and PR 3 is changing the same file. Decide in PR 6, together
  with the README rewrite: either a separate `compose.build.yaml` for building, or keep one file and
  document the fallback.
- **Backup copies accumulate.** Every change of `EXTERNAL_IP` leaves a `relay.conf.pre-*` copy. Harmless
  and small, but nothing prunes them.
- **Build downloads.** `ADD <url>` re-checks the release assets on every build. A local package cache
  (or a `--build-context`) would make repeated CI builds faster. PR 2: not changed. `publish.yml` builds
  with `no-cache` on purpose (the weekly rebuild must fetch current Debian packages), and `ci.yml` builds
  once per run, so a cache would save little; `tests/run.sh` still builds twice more (the tampered-checksum
  build and the helper image).
- **README.** The Russian half only points to the English "Ports" and "Upgrading from 2.x" sections
  (PR 6 translates). The Docker Hub link in the README describes the old image.

## From the PR 1 review (codex, agy and four cleanup reviewers)

Correctness points not fixed in PR 1, each small and open for discussion:

- **Router dies during start.** `wait_listening` returns early and the Relay is still started for a
  moment; the supervisor then stops it and the container exits non-zero, so the outcome is right,
  but the log shows a start summary. Idea: skip the remaining starts once a child has exited.
- **Stop during start-up.** A SIGTERM that arrives before the processes start ends the container with
  exit code 0 rather than 143. The stop test accepts both.
- **`HEALTHCHECK --start-interval`** needs Docker Engine 25 or later; older engines use the normal
  interval during the start period. Say so in the README requirements (PR 6).
- **Test speed.** The three image builds in `tests/run.sh` run one after another, and several helper
  containers read one file each. Parallel builds or batched reads would save time in CI. PR 2: CI and
  publish build the product image first and pass it as `ASPIA_TEST_IMAGE`, so `tests/run.sh` builds only
  the tampered context and the helper. The rest is still open; measure on the first real CI runs.

## From PR 2 (CI and publishing)

- **Badges.** README uses relative badge links (`../../actions/workflows/ci.yml/badge.svg`), so no owner
  name is hard-coded. GitHub resolves them against the repository; this was not verified before the first
  push. If they do not render, the fallback is absolute URLs, which are fork-specific:
  `https://github.com/gleruzh/aspia-server-docker/actions/workflows/ci.yml/badge.svg` and
  `https://github.com/gleruzh/aspia-server-docker/actions/workflows/publish.yml/badge.svg` (and the
  paprikkafox equivalents if this is offered upstream). On Docker Hub the description sync turns relative
  links into absolute ones (`enable-url-completion`); check that the badges render there too.
- **Tool images are not tracked by Dependabot.** hadolint, shellcheck and actionlint (`tests/lint.sh`) and
  Trivy (`ci.yml`) are pinned by tag and digest, but Dependabot's docker ecosystem reads only Dockerfiles
  and compose files. Update them by hand, or move them into a small Dockerfile that Dependabot watches.
- **Base packages between Debian point releases.** The base image is pinned by digest, so the weekly
  rebuild picks up new versions only of the packages the Dockerfile installs (jq, tini, libdbus-1-3 and
  their dependencies); fixes to packages already in `debian:trixie-slim` arrive when Dependabot bumps the
  digest. An `apt-get upgrade` in the Dockerfile would pick them up weekly too, at the cost of a less
  reproducible build. Out of scope for PR 2 (no Dockerfile changes beyond the version).
- **Untested digests in GHCR.** When `tests/run.sh` fails in `publish.yml`, the digest that was pushed
  for testing stays in GHCR untagged. Harmless, but a cleanup job (for example
  `actions/delete-package-versions` for untagged versions) could remove them.
- **Manual publish from a branch** moves `latest`, `X` and `X.Y` too. Fine for the maintainer, but an
  input that limits a manual run to the version tag would make workflow tests from branches safer.

## Roadmap

- **linux/arm64 images.** Blocked upstream; today the image is linux/amd64 only and must not be
  emulated. Checked on 2026-09-30:
  - No release of dchapyshev/aspia has ever published Linux arm64 server packages. The only arm64
    assets are Android `.apk` files for the Client and Host
    (`gh api "repos/dchapyshev/aspia/releases?per_page=100" --jq '.[].assets[].name' | grep -i arm`).
  - Upstream CI can already build them. `.github/workflows/linux.yml` (tag v3.0.21) has an `arm64-linux`
    matrix entry on a self-hosted Raspberry Pi OS 12 runner (`rpios12`), and `installer/linux/build_packages.sh`
    produces `.deb` and `.rpm` packages. They are only 7-day CI artifacts, not release assets. The last
    successful `linux.yml` run was on 2026-08-03 (run 30796352641); its artifacts have expired.
  - No upstream issue asks for Linux arm64 server packages
    (`gh search issues --repo dchapyshev/aspia "arm64 OR aarch64 OR raspberry"`: no results).
  - Next step: open an issue upstream asking to attach the arm64 Router and Relay `.deb` files to
    releases. The owner opens it; agents do not act in other people's repositories. Once upstream
    publishes them, add linux/arm64 to the publish matrix on a native arm64 runner (no QEMU), give each
    architecture its own checksum entries, and run tests/run.sh on arm64 too.
  - Not pursued: building Router and Relay from source ourselves. That would ship binaries upstream never
    released, and the vcpkg and Qt build is heavy.
