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
  silently ignores a Relay whose address it rejects (separate addendum, 13.1).
- **Healthcheck blind spots.** An ESTABLISHED socket to the Router does not prove that the Router
  accepted the Relay: an invalid `public_address`, or a sixth Relay over the limit of five, is visible
  only in the Router log. A log-based check would need the Router log in a file or a pipe the check
  can read.
- **Role-aware healthcheck** (PR 5). `aspia_health` always checks Router and Relay. `aspia_start`
  keeps its process list in `SERVICES`; the healthcheck will need the same decision.
- **Non-root.** Both processes run as root, as in 2.7.0. The addendum (13.4) shows that the Router and
  Relay run as `nobody` with the right ownership; changing ownership of an existing 2.x volume and
  running the migration as non-root is not tested.
- **Published image.** `docker-compose.yml` references `paprikkafox/aspia-server:3.0.21`, which does
  not exist until PR 2 publishes it. PR 2 decides the registries and should document pinning by digest.
- **Backup copies accumulate.** Every change of `EXTERNAL_IP` leaves a `relay.conf.pre-*` copy. Harmless
  and small, but nothing prunes them.
- **Build downloads.** `ADD <url>` re-checks the release assets on every build. A local package cache
  (or a `--build-context`) would make repeated CI builds faster.
- **README.** The Russian half only points to the English "Ports" and "Upgrading from 2.x" sections
  (PR 6 translates). The Docker Hub link in the README describes the old image.

## From the PR 1 review (codex, agy and four cleanup reviewers)

Correctness points not fixed in PR 1, each small and open for discussion:

- **Command override.** `docker run <image> bash` still runs `aspia_start`, because the ENTRYPOINT
  ignores its arguments. Idea: `exec "$@"` when arguments are given, or split into ENTRYPOINT (tini)
  and CMD (`aspia_start`).
- **Router dies during start.** `wait_listening` returns early and the Relay is still started for a
  moment; the supervisor then stops it and the container exits non-zero, so the outcome is right,
  but the log shows a start summary. Idea: skip the remaining starts once a child has exited.
- **Stop during start-up.** A SIGTERM that arrives before the processes start ends the container with
  exit code 0 rather than 143. The stop test accepts both.
- **Relay config without Router config.** A `relay.conf` left alone (no `router.conf`, no database)
  leads to a new Router with new keys and a Relay whose hand-set key no longer matches; the
  container warns and is unhealthy. Idea: refuse to start, as for an orphan database.
- **`HEALTHCHECK --start-interval`** needs Docker Engine 25 or later; older engines use the normal
  interval during the start period. Say so in the README requirements (PR 6).
- **Test speed.** The three image builds in `tests/run.sh` run one after another, and several helper
  containers read one file each. Parallel builds or batched reads would save time in CI.

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
