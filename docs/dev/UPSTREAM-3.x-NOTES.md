# Aspia 3.x server: verified facts

Single source of truth for all work on the 3.x upgrade. Every statement below was checked on
2026-09-30 against the real Aspia 3.0.21 release (build `3.0.21.8214`) or against upstream source
at tag `v3.0.21`. Each fact names the command or source that verified it. If you need a fact that is
not here, verify it the same way and add it, with its command.

Legend: **[run]** observed by running the binary; **[src]** read in `dchapyshev/aspia` at tag
`v3.0.21` (path given); **[api]** GitHub API; **[doc]** aspia.org (quoted, not independently
tested).

Verification environment: Apple Silicon Mac, Docker Desktop 29.8.1, amd64 containers under
emulation (`--platform linux/amd64`). No behaviour below depends on the CPU, but CI on real
amd64 runners is the definitive check.

## 0. How to reproduce

```bash
# Packages
gh release download v3.0.21 -R dchapyshev/aspia -p 'aspia-router-3.0.21-x86_64.deb' -p 'aspia-relay-3.0.21-x86_64.deb'

# Probe image: packages installed at build time, no data mounted (as in the real image)
cat > Dockerfile.probe <<'EOF'
FROM debian:trixie-slim
COPY *.deb /tmp/
RUN apt-get update && apt-get install -y --no-install-recommends /tmp/aspia-router-3.0.21-x86_64.deb /tmp/aspia-relay-3.0.21-x86_64.deb iproute2 procps sqlite3 && rm -rf /var/lib/apt/lists/* /tmp/*.deb
CMD ["sleep","infinity"]
EOF
docker build --platform linux/amd64 -f Dockerfile.probe -t aspia-probe:3.0.21 .
docker run -d --name probe --platform linux/amd64 aspia-probe:3.0.21
docker exec probe bash -c '...'   # the commands quoted below
```

Source files: `gh api "repos/dchapyshev/aspia/contents/source/<path>?ref=v3.0.21" --jq .content | base64 -d`.

## 1. Releases and packages

| Fact | Verified by |
|---|---|
| v3.0.21 published 2026-09-30, not a pre-release. v3.0.16 to v3.0.21 were published on six of the seven days from 2026-09-25 to 2026-09-30: expect frequent releases. | [api] `gh api repos/dchapyshev/aspia/releases --jq '.[0:6][] \| "\(.tag_name) \(.published_at) pre=\(.prerelease)"'` |
| Linux server assets: `aspia-router-3.0.21-x86_64.deb`, `aspia-relay-3.0.21-x86_64.deb` (plus `.rpm` and Windows `.msi`). No arm64 server packages. There is no `aspia-console` package in 3.x. | [api] `gh api repos/dchapyshev/aspia/releases/tags/v3.0.21 --jq '.assets[].name'` |
| Upstream publishes **no checksum file** for Linux packages (2.7.0 had only `windows-*-sha256.txt`). GitHub exposes a per-asset `digest` field, computed by GitHub and not signed by upstream. | [api] same command with `.digest` |
| sha256 `aspia-router-3.0.21-x86_64.deb` = `9fe886dd4e1c8958de2e8747bbfe56e52239f3c8e22ac078d6f5ec682fff69e4` | `shasum -a 256` on the download, equals the API digest |
| sha256 `aspia-relay-3.0.21-x86_64.deb` = `a566d6d17d44e9f8069af2774933fdeb6cda10c9bc6aa8aa9971ad901c7d879f` | same |
| sha256 3.0.18 (for CI tests of the bump workflow): router `4e62172af6b5f89266c0f16eafa3dda4d43920df18a9656c1a782661be5e574f`, relay `3e675a0a806e6922fb076ecf730c92b80e3e9b7fcac0dbc2f45a415b48b81cfd` | [api] digest field |
| Package `Depends: libdbus-1-3, libstdc++6, libgcc-s1 \| libgcc1, libc6 (>= 2.28)`. With `--no-install-recommends` apt adds only `libdbus-1-3` to `debian:trixie-slim`. Without that flag apt also pulls in `dbus`. Qt is linked statically. | [run] `dpkg-deb -e` then `cat control`; `dpkg -l \| grep -iE 'dbus\|qt'` in the probe image |
| Package contents: exactly one file each, `/usr/bin/aspia_router` (68 MB) and `/usr/bin/aspia_relay` (65 MB). **No systemd unit is shipped**; 2.7.0 shipped `/usr/lib/systemd/system/aspia-router.service`. | [run] `dpkg-deb -x` then `find` |
| `postinst configure` runs `aspia_<x> --install \|\| true` and, only on upgrade with systemd present, `systemctl start`. `preinst upgrade` stops the service and pkills the process. `prerm remove` runs `--remove`. | [run] `dpkg-deb -e`, read the scripts |
| `--install` is a no-op without configuration ("Configuration does not exist; the service was not installed"). **If `/etc/aspia` holds data while the package is installed, `--install` writes a `router.conf` containing a new `seed_key` and opens `router.db3`.** Therefore never install the packages with user data mounted. A normal `docker build` does not mount data, so this is safe there. | [src] `source/router/main.cc` `installService()`; [run] installing with the 2.7.0 volumes mounted created a 148-byte `router.conf` |
| Installing the packages creates the empty directories `/var/log/aspia/router` and `/var/log/aspia/relay`. It does not create `/etc/aspia` or `/var/lib/aspia`. | [run] `ls -la /etc/aspia /var/lib/aspia /var/log/aspia` in the probe image |
| Debian base used for probing: `debian:trixie-slim` (Debian 13.7). Index digest `sha256:a99cfc517144bc59b1978475ec53b46ecabec7e43635402ee5b77cc54cd1b20a`, linux/amd64 manifest `sha256:7792b1f7702a86946cd518db72b6a407302c3e9bc1635634368b878189e8221c`. These digests were current on 2026-09-30; re-resolve them when you pin. | `docker buildx imagetools inspect debian:trixie-slim` |
| `awk` in `debian:trixie-slim` is `mawk`, present without extra packages. `ss` needs `iproute2`, which is not in the slim image. | [run] `readlink -f /usr/bin/awk` |

## 2. Command line (both 3.0.21)

`aspia_router --help` [run]:
```
--install --remove --start --stop    Service management (systemd / Windows SCM)
--keygen                             Generate and print a key pair
--create-config                      Create the initial configuration
--reset-otp <user>                   Reset two-factor authentication for a user
--check-update / --install-update    Built-in updater (manual only, see section 9)
--update-channel <stable|beta|alpha>
-h --help, --help-all, -v --version
```
`aspia_relay --help` [run]: the same, without `--keygen` and `--reset-otp`.

- `--version` prints `aspia_router 3.0.21.8214` / `aspia_relay 3.0.21.8214` [run].
- Running with no arguments runs the service **in the foreground** (no daemonising). Stdout and
  stderr stay attached [run].
- There is **no CLI option to set a user password**. `--create-config` always creates
  `admin`/`admin` [src] `source/router/main.cc` `createConfig()`: `kUserName[] = "admin"`,
  `kPassword[] = "admin"`.

## 3. `--create-config` (clean system)

[run] `aspia_router --create-config; aspia_relay --create-config` in a clean container. Exit code 0 for both.

Router stdout (printed to stdout, not to the log):
```
Configuration successfully created. Don't forget to change your password!
User name: admin
Password: admin
Host public key file: /etc/aspia/host.pub
Relay public key file: /etc/aspia/relay.pub
```
Do not copy these lines to the container log as they are, because they contain the default password.

Files created:

| Path | Mode | Content |
|---|---|---|
| `/etc/aspia/router.conf` | 0600 root | INI, see section 4 |
| `/etc/aspia/host.pub` | 0644 | 64 hex chars, lowercase, no newline: the public key that **hosts** are configured with |
| `/etc/aspia/relay.pub` | 0644 | 64 hex chars: the public key that **relays** use to authenticate the Router |
| `/etc/aspia/relay.conf` | 0600 root | INI, see section 4 |
| `/var/lib/aspia/router.db3` | 0644 | SQLite database. It runs in WAL mode once the Router starts, which adds `router.db3-wal` and `router.db3-shm`. |

Refusals [src] `createConfig()`: it exits 1 with "Continuation is impossible" if `router.conf` is
non-empty, or if `host.pub`, `relay.pub` or `router.db3` already exists. So `--create-config`
**never overwrites** an existing configuration, key or database. That makes it safe to call only when
all of those are absent.

Key algorithm: X25519 [src] `generateKeys()`. The host key pair and the relay key pair are
**different** on a clean install. `router.conf` stores both private keys; the public keys exist only
in the `.pub` files. Neither binary has a command that derives a public key from a private key.

## 4. Configuration format (INI, replaces 2.x JSON)

Paths: `/etc/aspia/router.conf` and `/etc/aspia/relay.conf`. Both can be overridden by the environment
variables **`ASPIA_ROUTER_CONFIG_FILE`** and **`ASPIA_RELAY_CONFIG_FILE`** [src]
`source/router/settings.cc` and `source/relay/settings.cc`, `configFilePath()`. **These names are
read by the binaries themselves.** Any `ASPIA_ROUTER_*` or `ASPIA_RELAY_*` variable scheme we add
must not reuse these two names for anything else.

The files are written with mode 0600 [src] the `Settings()` constructor. A missing key falls back to
the default in the table. Unknown keys are ignored (the migrated file below lacks most keys and works).

### router.conf, as generated [run]
```ini
[client]
listen_interface=
port=8062
white_list=

[host]
legacy_port=8060
listen_interface=
port=8061
private_key=<64 hex>
white_list=

[relay]
listen_interface=
port=8063
private_key=<64 hex>
white_list=

[router]
seed_key=<128 hex>

[stun]
enabled=1
listen_interface=
port=8065
```

| Section/key | Default | Meaning | Source |
|---|---|---|---|
| `client/port` | 8062 | TCP port for Clients (the address book / management in the Client app) | [src] settings.cc, `build_config.h` |
| `host/port` | 8061 | TCP port for 3.x Hosts | same |
| `host/legacy_port` | 8060 | TCP port for 2.x Hosts ("Port 8060 is kept for hosts of previous versions", [doc] changelog 3.0.15) | same |
| `relay/port` | 8063 | TCP port Relays connect to | same |
| `stun/port`, `stun/enabled` | 8065, 1 | built-in STUN server, **UDP** | same; [run] `ss -ulnp` |
| `*/listen_interface` | empty = all | address to bind; the log says `"ANY"` when empty | [run] log |
| `client/white_list`, `host/white_list`, `relay/white_list` | empty = allow all | **comma**-separated IPs or subnets. Invalid entries are dropped with an ERROR log line. The log says "Connections from all hosts/clients/relays will be allowed" when a list is empty. | [src] `setWhiteList()`, `isValidWhiteListEntry()`; [run] log |
| `host/private_key`, `relay/private_key` | generated | hex | [src] |
| `router/seed_key` | generated | hex, 64 bytes | [src] |

There is no admin allow-list in 3.x: 2.x `AdminWhiteList` has no 3.x equivalent and the migration
does not read it [src] `source/router/migration_utils.cc`.

### relay.conf, as generated [run]
```ini
[peer]
idle_timeout=5
listen_interface=
max_count=100
port=8070
public_address=

[router]
address=127.0.0.1
port=8063
public_key=
```

| Section/key | Default | Meaning | Source |
|---|---|---|---|
| `peer/port` | 8070 | TCP port that Clients and Hosts use to reach the Relay. **The Relay announces this port to peers.** | [src] relay settings.cc; [run] log "Peer port: 8070" |
| `peer/public_address` | empty | address the Relay announces to peers (the old `EXTERNAL_IP`). Not checked for hostname support; do that before accepting hostnames. | [src]; [run] log "Peer address" |
| `peer/idle_timeout` | 5 | minutes | [src] `Minutes` |
| `peer/max_count` | 100 | max peers | [src] |
| `peer/listen_interface` | empty = all | | [src] |
| `router/address` | 127.0.0.1 | Router address | [src] |
| `router/port` | 8063 | Router relay port | [src] |
| `router/public_key` | **empty** | Must be the content of the Router's **`relay.pub`** (not `host.pub`). Empty makes the Relay log `ERROR ... Empty router public key`, but the process **keeps running** and never connects. | [run] |

## 5. Runtime behaviour

| Fact | Verified by |
|---|---|
| Listening sockets of a running Router: TCP 8060, 8061, 8062, 8063 bound to `*` (a dual-stack tcp6 socket), UDP 8065 bound to `0.0.0.0`. Relay: TCP 8070 on `*`. | [run] `ss -Htlnup` |
| The Relay connects to Router:8063 within ~40 ms of start when the Router is up. It shows as ESTABLISHED in `/proc/net/tcp` (relay side, remote port `1F7F`) and in `/proc/net/tcp6` (router side, v4-mapped). Router log: `Added key with id N for relay 1`. Relay log: `Connection to the router is established`. | [run] `ss -Htn state established`; `awk '$4=="01"' /proc/net/tcp /proc/net/tcp6` |
| **Router not reachable:** the Relay logs `Connection to the router has been lost: ... CONNECTION_REFUSED`, then `Reconnect after 15 seconds`, and keeps retrying forever. It does not exit. | [run] Relay alone, 25 s |
| **Wrong Router key:** the Relay logs `EVP_DecryptFinal_ex failed`, then `Connection to the router has been lost: ... ACCESS_DENIED`, then `Reconnect after 15 seconds`, and keeps retrying. It does not exit, and no ESTABLISHED connection persists. | [run] random `public_key` |
| Starting the Relay before the Router therefore costs up to 15 s before the first successful connection. | follows from the two rows above |
| SIGTERM and SIGINT: both binaries catch them (`SigCgt` includes bits 2 and 15), log `Signal received: "SIGTERM"`, and **exit 0 within ~40 ms**. | [run] `kill -TERM $pid; wait $pid` → `exit=0 after 40 ms` for all four combinations |
| Harmless startup log lines in a container: `ERROR ... sd_login_monitor_new failed` (no systemd-logind), and `ERROR ... Unable to install signal handler for SIGKILL` / `SIGSTOP` (these cannot be caught). With `LANG` unset, Qt logs a `WARNING` about the "C" locale; `LANG=C.UTF-8` avoids it. | [run] |
| Restarting both processes on an existing 3.x config does not change `router.conf` or `relay.conf` (sha256 identical). | [run] `sha256sum -c` before/after a stop-start cycle |
| Non-root: the Router runs as `nobody` when `/etc/aspia` and `/var/lib/aspia` are owned by that user (all ports are above 1024). Not tested: the Relay as non-root, and changing ownership of existing volumes. | [run] `su -s /bin/bash nobody -c aspia_router` |

## 6. Logging

[src] `source/base/logging.cc`, [run] confirmed:

- Default: log to **file only**, level INFO (the log says "Logging level: 1"). Messages of level ERROR
  and above are **also** written to stderr. So `docker logs` shows only the harmless errors from section 5 unless configured otherwise.
- File location for uid < 1000: `/var/log/aspia/router/` and `/var/log/aspia/relay/`, one file per
  process start, named `aspia_<x>-YYYYMMDD-HHMMSS.mmm.log`. For uid >= 1000 it is `$XDG_STATE_HOME/aspia/logs` or
  `~/.local/state/aspia/logs`. Files older than 14 days are removed.
- Environment variables read by the binaries:
  - `ASPIA_LOG_TO_STDOUT=1`: write every log line to **stderr** (despite the name).
  - `ASPIA_LOG_TO_FILE=0`: no log file. [run] with both set, `docker logs` shows the full log and no new file is created.
  - `ASPIA_LOG_LEVEL=<int>`: minimum level, clamped to the range TRACE..FATAL.
  - `ASPIA_MAX_LOG_FILE_AGE=<days>`: at most 366.

## 7. 2.7.0 data (produced by `paprikkafox/aspia-server:2.7.0`)

Image `paprikkafox/aspia-server@sha256:8db62b95681b09ab8dc2346d803a2981d7a44826b3a06310ab27b3d054215b82` (amd64).

[run] `docker run --platform linux/amd64 -e EXTERNAL_IP=203.0.113.10 -v a27cfg:/etc/aspia -v a27db:/var/lib/aspia paprikkafox/aspia-server:2.7.0`, run twice:

- The **first start only generates configs and exits 0**. The second start runs both processes.
- `/etc/aspia/router.json`:
  `{"AdminWhiteList":"","ClientWhiteList":"","HostWhiteList":"","Port":"8060","PrivateKey":"<64 HEX>","RelayWhiteList":"","SeedKey":"<128 HEX>"}`. Hex is **uppercase**.
- `/etc/aspia/relay.json`: `MaxPeerCount, PeerAddress (=EXTERNAL_IP), PeerIdleTimeout, PeerPort 8070, RouterAddress 127.0.0.1, RouterPort 8060, RouterPublicKey (= router.pub), StatisticsEnabled, StatisticsInterval` (all string values).
- `/etc/aspia/router.pub`: 64 uppercase hex chars, the key configured on 2.x hosts.
- `/var/lib/aspia/router.db3`: tables `users(id,name,group,salt,verifier,sessions,flags)`, `hosts(id,key)`.
- Everything is owned by root with mode 0644. 2.7.0 writes no log files under `/var/log/aspia`.
- Listening: TCP 8060 (Router) and 8070 (Relay) only.
- `docker stop` on 2.7.0: the old script traps only SIGINT and runs its CMD in shell form with `nohup`,
  so the container is SIGKILLed: **exit code 137**, after 4 s in our run.

## 8. 3.0.21 on 2.7.0 data (upstream's own migration)

[run] Copied the 2.7.0 volumes, inserted one fixture host
(`insert into hosts(key) values (x'00112233445566778899aabbccddeeff')`), started `aspia_router` then
`aspia_relay` from the probe image on those volumes.

**Result: 3.0.21 reads 2.7.0 data.** Details:

| Fact | Verified by |
|---|---|
| The Router migrates on start when `/etc/aspia/router.json` exists. It does **not** check whether `router.conf` already exists, so values present in `router.json` overwrite `router.conf`. Afterwards it renames `router.json` to **`router.json.bak`**. | [run] log `Start migration for "/etc/aspia/router.json"` … `renamed to "/etc/aspia/router.json.bak"`; [src] `source/router/migration_utils.cc` |
| The Relay migrates only when `relay.json` exists **and `relay.conf` is empty or missing**. It replaces any existing `relay.json.bak`, then renames `relay.json` to `relay.json.bak`. | [run] log; [src] `source/relay/migration_utils.cc` |
| The 2.x `PrivateKey` is written to **both** `host/private_key` and `relay/private_key`, so the public key stays the same: **hosts configured with the 2.x `router.pub` keep working**, and the relay key equals the old `router.pub` as well. | [src] "Duplicate it into both so existing hosts and relays keep working"; [run] both `private_key` values in the migrated `router.conf` equal the old `PrivateKey` (lowercased) |
| The 2.x `Port` (8060) becomes `host/legacy_port`. Missing keys fall back to defaults, so the new listeners 8061, 8062, 8063 and 8065/udp open as well. The Relay's `router/port` is **forced to 8063**, whatever `relay.json` said. | [run] `ss -Htlnu`; relay.conf after migration |
| **Migration does not create `host.pub` or `relay.pub`.** Only the 2.x `router.pub` remains. The public key for hosts and relays after migration is the content of `router.pub`. | [run] `ls -la /etc/aspia` after migration |
| Relay migration copies `RouterPublicKey` (the old `router.pub`), `PeerAddress`, `PeerPort`, `PeerIdleTimeout` and `MaxPeerCount`. The migrated Relay **connected to the migrated Router**. | [run] ESTABLISHED 127.0.0.1 → 8063 |
| Not migrated: `AdminWhiteList` (dropped); `StatisticsEnabled` and `StatisticsInterval` (dropped). 2.x whitelists used `;` and 3.x uses `,`; the migration converts them. | [src] |
| **The database is upgraded in place, with no backup**: `CREATE TABLE IF NOT EXISTS` for new tables (`workspaces`, `workspace_access`, `host_groups`, `hosts_remove`, `client_device_tokens`) and `ALTER TABLE ... ADD COLUMN` on `users` and `hosts`. After this, 2.7.0 cannot be assumed to read the file. **The entrypoint must copy `router.db3` before the first 3.x start.** | [src] `source/router/database.cc`; [run] `.schema hosts` after migration |
| Data preserved: user `admin` (id 1) and the fixture host (id 1, same key) are present after migration. The admin's `sessions` changed from 3 to 19 (upstream schema upgrade). | [run] `sqlite3 router.db3 "select id,name,sessions,flags from users; select id,hex(key) from hosts"` |
| Migrated `router.conf` contains only the migrated keys (`white_list`, `legacy_port`, both `private_key`, `seed_key`). All other keys use their defaults at runtime. | [run] `cat router.conf` |
| A second start after migration changes nothing (sha256 identical). | [run] |

Compatibility with other components, per [doc] https://aspia.org/changelog (3.0.15), not tested by us because it needs GUI clients:
- "The Router now listens on separate ports: 8061 for hosts, 8062 for clients and 8063 for relays."
- "Port 8060 is kept for hosts of previous versions."
- "Added a built-in STUN server (port 8065 by default)."
- "The Console has been removed. The address book and Router management are now part of the Client."
- The changelog says nothing about which 2.x host versions can connect, or whether 2.x Consoles can
  connect to 3.x. **Do not claim a minimum 2.x host version** (the SinitsaDA README says "2.6.2 and later";
  that is not verified here).

## 9. Built-in updater (relevant to the "no auto-update" rule)

- `--check-update` and `--install-update` exist and run **only when passed on the command line** [src]
  `source/router/main.cc` `main()`. Neither `source/router/service.cc` nor `source/relay/service.cc` contains any reference to updates
  (`grep -ci update` = 0). A service started with no arguments does not update itself. Not verified: whether a
  Client ("updates from the console", per the SinitsaDA README) can tell a Router to update. Where that would
  happen inside a container, its result is lost when the container is recreated.
- Consequence for the image: never call `--check-update` or `--install-update`. The README should say not to
  use them inside the container.

## 10. Healthcheck without opening connections to the Router

All of the following can be read from `/proc/net/tcp` and `/proc/net/tcp6` inside the container, with `awk`
(mawk) only. No sockets are opened, so the Router log stays clean and its brute-force counters are not triggered.

- LISTEN is state `0A`; ESTABLISHED is `01`. The port is the hex after the last `:` of column 2 (local) or column 3 (remote).
- The Router listens on 8060/8061/8062/8063 as tcp6 `*`. This was verified with IPv6 enabled in the container
  (`/proc/sys/net/ipv6/conf/all/disable_ipv6` = 0, the Docker default). Read both files, because the socket
  may be v4 or v6 depending on the kernel settings.
- Relay connected = an ESTABLISHED entry whose **remote** port is the relay's `router/port` (default 8063).
  With the wrong key there is no lasting ESTABLISHED entry (the retry happens every 15 s and fails
  immediately), so this check distinguishes "connected" from "running but not connected". [run]
- The UDP STUN socket appears in `/proc/net/udp` (state `07`) when enabled.

## 11. SinitsaDA/aspia-server-docker (assessment)

Cloned at `../SinitsaDA-aspia-server-docker`, commit `de15b99888204ee382738a088020ea3090bcbb74`
(2026-09-30, "Aspia 3.0.21: update .env.example"). License GPL-3.0 [api]. It is not a GitHub fork of paprikkafox.

### What each file does
| File | Purpose |
|---|---|
| `server/Dockerfile` | `debian:${DEBIAN_TAG:-stable-slim}`, `ARG ASPIA_VERSION` with **no default**. Downloads router and relay `.deb` with curl and installs them with `apt-get install ./*.deb`. Keeps `ca-certificates curl jq tzdata`. `LANG=C.UTF-8`. `VOLUME /etc/aspia /var/lib/aspia /var/log/aspia`. `EXPOSE 8060 8061 8062 8063 8065/udp 8070`. HEALTHCHECK every 30 s with a 60 s start period. `CMD ["/usr/bin/aspia_start"]` in exec form, no init. |
| `server/aspia_start` | Bash. Creates the config with `--create-config` if neither `router.conf` nor `router.json` exists; if `router.json` exists it leaves it to the binary's migration. Copies `router.pub` to `host.pub` and `relay.pub` when they are missing. Resolves `EXTERNAL_IP=auto` via ipify, ifconfig.me and icanhazip. Writes `peer/public_address` and `router/public_key` (from `relay.pub`) with an awk `ini_set` (or with `jq` into `relay.json` before migration). Starts the Router, sleeps 2 s, starts the Relay, then `wait -n`; if one process exits it kills the other and exits with that code. A trap forwards SIGINT and SIGTERM. |
| `server/aspia_health` | Reads `/proc/net/tcp*` with awk: the relay's router port is LISTEN, the peer port is LISTEN, and some ESTABLISHED socket has that router port as its remote port. The ports come from `relay.conf`. |
| `compose.yaml` | `network_mode: host`, image from `${ASPIA_IMAGE}:${ASPIA_VERSION}`, `EXTERNAL_IP` required, a `/var/log/aspia` bind mount, and an **updater service that mounts the Docker socket**. |
| `updater/*` | A container that updates, backs up and rolls back the server and imports 2.x data. **Not ported** (project rule: no auto-update, no Docker socket). |
| `.github/workflows/publish.yml` | A 6-hourly cron builds the latest upstream release, smoke-tests it with `--network host` until healthy, then pushes to GHCR as `X.Y.Z, X.Y, X, latest`. A weekly rebuild. It **commits to main** (`.env.example`) from CI. Actions are pinned by major tag, not SHA. |

### Sound, and can be ported (after reading every line)
- Letting the binaries run their own 2.x migration instead of converting JSON in the shell (matches section 8).
- Copying `router.pub` to `host.pub` and `relay.pub` after migration, and only when they are missing (matches section 8).
- Filling `relay.conf` `router/public_key` from `relay.pub` (matches section 4).
- The awk `ini_set` / `ini_get` approach, since no INI tool ships in the slim image. Check edge cases: keys whose value contains `=`, a missing section, CRLF.
- The `/proc/net/tcp*` healthcheck idea (matches section 10).
- `wait -n` plus kill-the-other plus exit with the child's code, and signal forwarding to both children.
- `LANG=C.UTF-8`; `apt-get install --no-install-recommends ./file.deb`; the EXPOSE list; the notes about harmless log lines and about not using the built-in updater.

### Wrong or outdated for 3.0.21, or against this project's rules
- Base image not pinned (`stable-slim`, no digest); no checksum verification of the `.deb` files.
- `ARG ASPIA_VERSION` has no default, so a plain `docker build .` fails.
- `EXTERNAL_IP` unset only produces a warning and the container starts anyway. Our rule: a clear error and a non-zero exit.
- It **modifies `relay.json` in place before migration** (via jq) without a backup copy. Our rule: copy a file before changing it.
- **No backup of `router.db3`** before the first 3.x start, although the schema is altered in place (section 8).
- If `router.conf` and `router.json` are both missing but `router.db3` exists, it **renames the database and keys aside and generates new ones**. That silently gives the user new keys, so every host must be reconfigured. Our rule forbids this. Instead, stop with a clear message.
- Healthcheck: it checks only the relay port 8063 and the peer port 8070, and does not check the host and client ports (8060, 8061, 8062). The router port is read from `relay.conf` rather than `router.conf`. Our requirement: the Router listening on its ports, plus the Relay connected.
- The startup banner claims "8062/tcp consoles"; in 3.x they are Clients (the Console was removed, [doc]).
- `sleep 2` before starting the Relay is a guess. Waiting for the Router's 8063 LISTEN (read from `/proc`) is deterministic.
- `curl` kept in the image only for `EXTERNAL_IP=auto`. That feature belongs to PR 3 (env config), not PR 1.
- The `/var/log/aspia` volume is new. Logs to stdout (section 6) suit `docker logs` better; whether to also keep files is a PR decision.
- `publish.yml`: `latest` in the docs and examples, unpinned actions, a push to main from CI, and an update flow that feeds the updater container.

### Deliberately left behind
`updater/` (all of it), `import-2x.sh`, the Watchtower instructions, the `network_mode: host` default,
`compose.build.yaml`, the Synology and MikroTik docs (possible later docs, see FOLLOWUPS), and the
publish-to-main behaviour.

## 12. Open items (not verified; verify before relying on them)

- Whether `peer/public_address` accepts a DNS name rather than an IP.
- Minimum 2.x host version that can connect to 8060; 2.x Client/Console compatibility with 3.x.
- Relay as non-root; changing ownership of an existing root-owned 2.x volume.
- Whether the Router applies per-address brute-force protection, and its thresholds (relevant to rootless Podman source-address rewriting).
- Whether a Client can trigger `--install-update` remotely on a Router.
