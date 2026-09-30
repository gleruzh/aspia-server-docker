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
- **Role-aware healthcheck** (PR 5). `aspia_health` always checks Router and Relay. `aspia_start`
  keeps its process list in `SERVICES`; the healthcheck will need the same decision.
- **Non-root** -- resolved in PR 3 for the single-container image: `PUID`/`PGID` chown
  `/etc/aspia`/`/var/lib/aspia` and run both processes as that uid/gid (notes section 13.4 confirmed
  both binaries work this way). Not tested: `PUID`/`PGID` on a volume that already holds a large,
  long-lived deployment (only fresh and small test volumes were used), and combining `PUID`/`PGID`
  with the 2.x migration on a volume that was previously owned by root end-to-end in production
  (the migration renames files in `/etc/aspia`, which needs it to be writable by the target user; the
  entrypoint chowns before the migration runs, but this has only been exercised by `tests/run.sh`,
  not against a real historical 2.x volume).
- **Published image.** `docker-compose.yml` builds locally by default (`image: ${ASPIA_IMAGE:-aspia-server:3.0.21}`
  plus `build: .`), because nothing is published yet and no owner name may be hard-coded. PR 2 publishes the
  image, documents the `ASPIA_IMAGE` value for each registry and pinning by digest, and keeps the default tag
  in sync with the version file. Note: if `ASPIA_IMAGE` names a registry image that cannot be pulled (a typo,
  no access), `docker compose up` falls back to building locally under that name (compose v5.5.1), and
  `--build` with `ASPIA_IMAGE` set builds locally under the published name. Both come from `image:` and
  `build:` in one service; when pulling becomes the everyday path, consider a separate compose file for
  building, so pulling and building cannot mix.
- **Backup copies accumulate.** Every change of `EXTERNAL_IP` leaves a `relay.conf.pre-*` copy. Harmless
  and small, but nothing prunes them.
- **Build downloads.** `ADD <url>` re-checks the release assets on every build. A local package cache
  (or a `--build-context`) would make repeated CI builds faster.
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
  when the Relay runs on a different host, and should add both then.
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
