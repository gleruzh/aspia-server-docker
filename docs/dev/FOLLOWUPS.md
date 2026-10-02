# Follow-ups

Ideas and gaps found while working on a PR, left out because they are outside its scope.
Each item names the PR that found it.

## From PR 1 (image 3.0.21)

- **Path overrides** (partly resolved in PR 3). `aspia_start` and `aspia_health` use the fixed paths
  `/etc/aspia/router.conf`, `/etc/aspia/relay.conf` and `/var/lib/aspia/router.db3`. The binaries also
  honour `ASPIA_ROUTER_CONFIG_FILE`, `ASPIA_RELAY_CONFIG_FILE` and `ASPIA_ROUTER_DB_FILE`. PR 3 makes
  `aspia_start` refuse to start with a clear error when one of these is set, rather than silently
  checking or editing the wrong file (the "refuse" option from this item). Actually honouring them
  (making every path in both scripts follow the variable) is still open.
- **Backups on later upgrades.** The database is copied only before the 2.x migration. A future 3.x
  release that changes the schema again would upgrade `router.db3` in place with no copy. Idea: store
  the image version that last ran next to the database and copy `router.db3` whenever it changes.
- **`EXTERNAL_IP` validation** -- resolved in PR 3: `ASPIA_RELAY_PUBLIC_ADDRESS` (`EXTERNAL_IP`'s new
  name) is validated as an IP literal or a host name of at most 64 characters, matching the Router's
  own `isValidHostName`/`isValidIpAddress` (notes section 13.1). The Router can still silently ignore a
  syntactically valid address it dislikes for other reasons (an IP that is not actually reachable, for
  example); that is unchanged and is not detectable without a real end-to-end connection.
- **Healthcheck blind spots.** An ESTABLISHED socket to the Router does not prove that the Router
  accepted the Relay: an invalid `public_address`, or a sixth Relay over the limit of five, is visible
  only in the Router log. A log-based check would need the Router log in a file or a pipe the check
  can read.
- **Role-aware healthcheck** -- resolved in PR 5: `aspia_start` and `aspia_health` both take the process
  list from `role_services` in `aspia_common.sh` (`ASPIA_ROLE`), so they cannot disagree.
- **Non-root** -- resolved in PR 3 for the single-container image: `PUID`/`PGID` chown
  `/etc/aspia`/`/var/lib/aspia` and run both processes as that uid/gid (notes section 13.4 confirmed
  both binaries work this way). Not tested: `PUID`/`PGID` on a volume that already holds a large,
  long-lived deployment (only fresh and small test volumes were used), and combining `PUID`/`PGID`
  with the 2.x migration on a volume that was previously owned by root end-to-end in production
  (the migration renames files in `/etc/aspia`, which needs it to be writable by the target user; the
  entrypoint chowns before the migration runs, but this has only been exercised by `tests/run.sh`,
  not against a real historical 2.x volume).
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

## From PR 3 (environment configuration)

Candidates from the PR 3 task that were deliberately left out, with the reason:

- **Initial administrator password variable.** Not added. Notes section 13.5: `createConfig()`
  hardcodes `admin`/`admin`; there is no CLI option, no config key, and no environment variable for
  it. The only way to change it is over the network, through an authenticated Client, using Aspia's
  own SRP variant (`base/crypto/srp_math.cc`) -- not something `sqlite3`/`jq` can drive. The image can
  only print the default and tell the user to change it (already done in `aspia_start`).
- **`*/listen_interface` variables.** Not added. Not in the PR's candidate list, and notes section
  13.7 shows why it does not fit the "validate at startup, then fail clearly" principle: a bad value
  (a hostname, a bogus literal, a valid IP not present on the container) does not stop the process --
  it silently disables just that one listener while the container keeps running and stays "healthy"
  by every other check. Format validation alone (IP literal only, no hostnames) would not catch the
  "valid IP not on this container" case, so it would give a false sense of safety. Left as a
  file-only setting.
- **`router.conf` `[relay] port` (8063) as a variable.** Not added. It is the port between the
  co-located Router and Relay inside this single container; `docker-compose.yml` does not publish it
  today and there is no host-side reason to change it. Exposing it would also require always keeping
  `relay.conf`'s `[router] port` in sync (unlike every other variable in this PR, which only ever
  writes to the file its own name suggests), for no real benefit in this PR's single-container model.
  PR 5 (relay-standalone) needs the Relay's Router address *and* port to be configurable together
  when the Relay runs on a different host, and should add both then. -- PR 5 added the Relay side
  (`ASPIA_RELAY_ROUTER_ADDRESS`, `ASPIA_RELAY_ROUTER_PORT`, only with `ASPIA_ROLE=relay`). The Router's own
  `[relay] port` is still file-only, and `compose.router.yml` publishes `8063:8063` literally: a changed port
  needs both edits.
- **Secret values from files (`*_FILE`).** Not added. None of the settings this PR exposes are secret
  (ports, addresses, allow-lists, timeouts, limits, log level); the only real secrets (the Router's
  and the Relay's private keys, the seed key) are generated by the binaries themselves and never
  accepted from the user, so there is nothing to point a `*_FILE` variable at.
- **Router administrator allow-list.** Not added: notes section 4 states there is no such key in
  3.x (2.x's `AdminWhiteList` has no successor and is dropped, not migrated).
- **Fully honouring `ASPIA_ROUTER_CONFIG_FILE`/`ASPIA_ROUTER_DB_FILE`/`ASPIA_RELAY_CONFIG_FILE`.**
  PR 3 only refuses to start when one of these binary-native variables is set (see the "Path
  overrides" item above); making every path in `aspia_start`/`aspia_health` actually follow them is
  a larger, self-contained change left for later.

## From PR 4 (Podman Quadlet)

- **Untested on purpose or by lack of a machine:** a real reboot (the tests restart the whole test host once
  instead); SELinux in enforcing mode (the `:Z` host-directory variant); the firewalld and ufw commands in
  `podman/README.md` and how Podman's forwarding rules interact with them; Podman 4.5.0 (4.5.1 is the lowest
  run); RHEL-family distributions themselves; rootless host directories; `PUID`/`PGID` under Podman; a real Client
  or Host through the Relay. Read the CI job's Podman version in the job summary and add it to the "Tested with" line of
  `podman/README.md` and to notes section 18.
- **Podman 4.4 (RHEL 9.2).** The unit needs 4.5 because of `HealthCmd`. Expressing the health check with
  `PodmanArgs=--health-cmd=...` would reach 4.4.1, at the cost of losing the Quadlet keys and of untested
  behaviour. Not done: 4.4 is old, and the fallback in `podman/README.md` covers it.
- **Rootless on Podman 4.x without `Network=host`.** Rootless slirp4netns rewrites the client address
  (notes section 18); `Network=host` is the documented way out. Not tried: switching 4.x to pasta where it is
  available (`Network=pasta` needs a newer Podman than 4.9.3 had in the test), or slirp4netns with
  `port_handler=slirp4netns`, which keeps the source address in some versions.
- **Ports in the unit are not derived from the environment file.** Compose takes both sides of a port
  mapping from one variable; Quadlet cannot, so changing a port variable needs a matching `PublishPort=` edit
  (or `Network=host`). A small generator script could write the `PublishPort=` lines from the env file.
- **`Notify=healthy`.** Not used: `systemctl start` returns when the container has started, not when it is
  healthy. A start that waits for `healthy` would make `systemctl start` fail loudly on a bad `EXTERNAL_IP`;
  needs a test on each Podman version first.
- **A `.build` unit** (Quadlet builds the image from a checkout) would remove the `podman build` step from
  the default `Image=localhost/...` path; not added to keep the unit one file plus two volumes.
- **CI duplicates the image build.** The `podman` job builds its own image (about as long as the `test`
  job's build); it could reuse the `test` job's image through an artifact, if build time matters.
- **For PR 5: `Network=host` needs a second setting.** In the combined image the Router accepts relay
  registrations on 8063 from any address unless `ASPIA_ROUTER_RELAY_ALLOWED_IPS` is set, so with host
  networking (needed for rootless Podman 4.x) the unit must also set `ASPIA_ROUTER_RELAY_ALLOWED_IPS=127.0.0.1`
  (a commented pair of lines in the unit). The Router/Relay split (PR 5), or an entrypoint default of
  `127.0.0.1` when the Relay is co-located and the variable is unset, would remove that.
  **Decided in PR 5: keep the default, document it.** An entrypoint default of `127.0.0.1` would break the rule
  "an unset variable leaves the file alone", and would silently lock out any Relay on another machine that
  already registers with a combined container publishing 8063 (the README has said since PR 1 that 8063 is
  published for exactly that). With `ASPIA_ROLE=router` the startup log now warns while the Relay allow-list is
  empty, and the README's new section says so; role `all` keeps its old log, and the `Network=host` pair of
  lines in the Podman unit stays.
- **The Dockerfile's `HEALTHCHECK --start-interval` breaks `podman build` on Podman < 5.1** (`flag provided
  but not defined: -start-interval`; notes section 18). Documented in `podman/README.md`: build with Docker
  and `podman load`, or use the published image. A change to the image would remove it.
- **PR 6 (README rewrite).** The main README has only a short pointer to `podman/README.md`; the Podman text
  should be folded into the new structure and translated.

## From PR 5 (Relay on a separate host)

- **Not verified on two hosts.** The tests run a Router and Relays on one Docker network (and one Podman host);
  they show registration, health and failure behaviour, not a session relayed across real NAT. The manual
  two-host check is in the PR 5 description; record its result in notes section 19.
- **Anonymous `/var/lib/aspia` volume for a Relay.** The Dockerfile declares `/var/lib/aspia` a `VOLUME`, so
  Docker and Podman create an empty anonymous volume for an `ASPIA_ROLE=relay` container too. Harmless; removing
  it needs a Dockerfile change (e.g. no `VOLUME` line, the compose files and units mount what they need).
- **No Router-only Podman unit.** Under Podman a Router alone is `aspia-server.container` with `ASPIA_ROLE=router`
  in its env file and an added `PublishPort=8063:8063/tcp` (podman/README.md, section 11). Not covered by
  `tests/podman.sh`. A separate `aspia-router.container` would make it a copy-and-start like the Relay.
- **Role `all` does not warn about an empty Relay allow-list.** Only role `router` does, so that role `all`
  logs exactly what it logged before. With `docker-compose.yml` 8063 is not published, so the warning would be
  noise there; with `Network=host` it would not.
- **Key distribution.** The Router's `relay.pub` is copied to each Relay by hand (value or mounted file). Out of
  scope for PR 5.
- **A connected Relay can still be useless** (an address the Router rejects, a sixth Relay): see "Healthcheck
  blind spots" above. The Relay's own log shows a sixth Relay only as `REMOTE_HOST_CLOSED`, like an allow-list
  refusal.
- **Test network.** Scenarios 17-24 of `tests/run.sh` create a Docker network with the fixed subnet
  `10.213.47.0/24` (scenario 21 pins two Relay addresses). A machine that already uses that subnet fails at
  `docker network create`; change `SPLIT_SUBNET` there.

## From PR 5b (hardening)

- **Non-root by default is possible.** The whole container as `--user 1000:1000` with no capability at all runs
  and stops cleanly on volumes owned by 1000 (notes section 20). It would drop all five capabilities, but needs
  the volumes owned by that uid first (a one-time `chown` for existing installs) and a change to `aspia_start`
  (it refuses PUID/PGID with `--user`, and `mkdir -p` of the volume paths). A breaking change: its own PR.
- **A tighter set for the simplest setup.** Without PUID/PGID and with root-owned volumes no capability is needed
  (notes section 20). Not shipped as a variant: a user who later sets PUID/PGID, or mounts a host directory owned
  by a user, would get a failing start. The README names the override.
- **`PidsLimit=` in the Quadlet units** once the minimum Podman is 4.7 or later; until then `PodmanArgs=--pids-limit=`.
- **The Podman fallback without Quadlet** (podman/README.md, section 9, `podman run` for Podman < 4.5) does not
  carry the hardening flags. Not tested on Podman 3.4/4.4 with the real image (section 18: stand-in only).
- **Native amd64 pid counts.** The pids limit (128) was sized from runs under Rosetta, which adds a thread per
  process; native counts are lower. CI (amd64) runs `tests/run.sh` with the limit.
- **`aspia_health` falls back to the default ports when it cannot read the config** (an unreadable 0600 file), so it
  checks the wrong ports. It should report "cannot read" instead.
- **Under PUID/PGID, DAC_OVERRIDE is needed only by the health check** (root reads the 0600 config of PUID). It could
  run through `setpriv` as PUID instead. Root on volumes of another uid still needs DAC_OVERRIDE.
- **Ports below 1024 under Docker with host networking** need `--cap-add NET_BIND_SERVICE` (the compose files
  use a bridge network, where Docker allows them; the Quadlet units carry it). The README says so; nothing checks it.

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

- **upstream-watch.yml not verified end to end.** The owner chose not to run the planned rehearsal
  (a test branch set back to 3.0.18). Verified so far: actionlint, the scripts it calls (version
  lookup, package download with digest check, `versions.sh bump`) locally, and the PR body with a
  stubbed `gh pr create`. Still unverified on GitHub: pushing the `aspia-bump/X.Y.Z` branch with
  `GITHUB_TOKEN`, opening the pull request, and whether its `ci.yml` run waits for "Approve workflows
  to run". Check on the first real Aspia release after 3.0.21: the scheduled run should open
  "chore: bump Aspia to X.Y.Z" within 6 hours; read its log and the pull request body, and correct
  docs/ci.md if GitHub behaves differently.
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
