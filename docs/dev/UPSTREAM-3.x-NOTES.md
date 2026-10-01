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

Resolved since the first version of this file: DNS names in `peer/public_address`, brute-force protection,
a network path to the updater and a non-root Relay (section 13); the minimum 2.x Host version, 2.6.0
(section 15, upstream documentation). Still open:

- Whether a 2.x Client or Console can connect to a 3.x Router (the upstream guide does not say; a 3.x
  Client is needed to manage the Router, section 15).
- Running the 2.x migration as non-root on a chowned, formerly root-owned volume.

## 13. Open items resolved (verified 2026-09-30)

Same legend as above. Source at tag `v3.0.21` was read from the tarball
(`gh api repos/dchapyshev/aspia/tarball/v3.0.21`). Paths below are relative to `source/`, and line
numbers refer to that tag. Run tests used `aspia-probe:3.0.21` with `--platform linux/amd64`, a user-defined
Docker bridge network, and `ASPIA_LOG_TO_STDOUT=1 ASPIA_LOG_TO_FILE=0 LANG=C.UTF-8` so that `docker logs`
shows the full log. Where a fact needed TRACE lines, `ASPIA_LOG_LEVEL=0` was added.

### 13.1 `peer/public_address`: DNS names are accepted

| Fact | Verified by |
|---|---|
| **An empty `public_address` stops the Relay from ever connecting to the Router.** The Relay logs `ERROR ... onPrepare : 100 ] Empty peer address`, returns from `RouterWorker::onPrepare`, keeps running, and opens no connection to 8063. Like an empty `public_key`, **the entrypoint must refuse to start when this key is empty**. | [src] `relay/workers/router_worker.cc:98-102`; [run] relay with `public_address=` for 8 s: that log line, and 0 ESTABLISHED sockets |
| The Relay does not validate the value. It sends the string unchanged to the Router as `RelayKeyPool.peer_host`. | [src] `relay/workers/router_worker.cc:72,126,351`; `proto/router_relay.proto:29` (`string peer_host`) |
| The Router accepts the key pool when `NetUtils::isValidIpAddress(host) \|\| NetUtils::isValidHostName(host)` holds. Otherwise it logs `ERROR ... "[Relay#N]" Ignoring key pool with invalid peer endpoint (host: "<value>" port: 8070 )` and drops **all** keys from that relay. The relay connection itself stays up. | [src] `router/relay.cc:171-177` |
| `isValidHostName`: not empty, **at most 64 characters**, only letters, digits, `.`, `_` and `-`, at least one letter or digit. There is no check of label structure and no DNS lookup. `isValidIpAddress` accepts IPv4 and IPv6 literals (`QHostAddress`). | [src] `base/net/net_utils.cc:33` (`kMaxHostNameLength = 64`), `:144-149`, `:175-203` |
| [run] `public_address=relay1.example.test`: Relay log `Peer address: "relay1.example.test"`, Router log `Received key pool: 100` followed by `Added key with id 0..99 for relay 1`, with no error. | [run] two containers, Router `vf-router`, Relay with `router/address=vf-router` |
| [run] `public_address=bad_host!name`: the Relay logs `Connection to the router is established`, but the Router logs `Ignoring key pool with invalid peer endpoint (host: "bad_host!name" port: 8070 )`. **The Relay therefore looks healthy (an ESTABLISHED socket to 8063) while being unusable.** A `/proc/net/tcp` healthcheck cannot detect this. | [run] |
| [run] A 65-character hostname (`a`×60 + `.test`) is rejected with the same `Ignoring key pool` line. A 64-character hostname is accepted (`Added key with id 0 for relay 4`). | [run] |
| Clients and Hosts resolve the announced host with `asio::ip::tcp::resolver::async_resolve`, so a DNS name is resolved **on the peer**, not on the Router or the Relay. | [src] `base/peer/relay_peer.cc:91-98` |
| The Router log never prints the announced `peer_host` for an accepted pool. Only the Relay log shows it (`Peer address: "..."`). | [run] Router log above |

Not verified: an end-to-end session through the Relay with a DNS name (that needs a GUI Client and Host);
an IPv6 literal as `public_address` (source only).

### 13.2 Brute-force and flood protection in the Router (and Relay)

| Fact | Verified by |
|---|---|
| **There is no ban and no counter of failed password logins or failed handshakes.** In the Router, nothing connects to `TcpServer::sig_errorOccurred` (the signal emitted when a handshake fails). A wrong password costs the attacker one TCP connection. | [src] `grep -rn sig_errorOccurred router` finds only per-channel connects in `client_operator.cc:68`, `host.cc:47`, `relay.cc:49` (after authentication); `base/net/tcp_server.cc:331-341` |
| What exists instead is a **per-source-IP connection rate limit (FloodGuard, GCRA)** on every listener, applied at `accept()` **before** the white list and before any cryptography. It is keyed by `asio::ip::address` of the peer. A v4-mapped address counts as its own key. Each listener has its own guard, so the budgets are separate per port. | [src] `base/net/flood_guard.h:29-50`, `base/net/flood_guard.cc:76-127`; `base/net/tcp_server.cc:259-265` (flood guard) then `:269-281` (white list) |
| Router limits (burst = `max`, then `max`/60 s steady; pending = handshakes in flight across all sources): **client 8062: 60/min per IP, 30 pending**; **host 8061 and legacy 8060: 300/min per IP, 100 pending, each port separately**; **relay 8063: 30/min per IP, 10 pending**. | [src] `router/workers/client_worker.cc:137-147`, `host_worker.cc:169-190`, `relay_worker.cc:140-151`; `base/net/tcp_server.cc:84-105` |
| Relay peer port 8070: 60 connections per 60 s per IP, 60 pending sessions. | [src] `relay/workers/relay_worker.cc:44-46,244-246,452-455` |
| Rejection = the accepted socket is closed immediately. There is **no ban period**: a source regains one connection every `60 s / max`. The tracking map holds at most 10 000 addresses and fails **open** when full. | [src] `flood_guard.cc:48-50,79-101` |
| Log: `WARNING ... Per-address rate limit hit for "<addr>"; rejected N connection(s) since last warning` (at most one line per 30 s), and `WARNING ... Pending connection limit reached (...)`. Each individual rejection is logged only at TRACE: `Connection rejected by flood guard`. | [src] `flood_guard.cc:114-121,139-146`; [run] below |
| [run] 75 back-to-back TCP connects from one container to 8062: **60 accepted, 15 rejected** (15 × TRACE `Connection rejected by flood guard`, one `WARNING ... Per-address rate limit hit for "::ffff:172.21.0.3"`). A connect from a second container IP right afterwards was accepted and not rate-limited. | [run] `for i in $(seq 1 75); do (exec 3<>/dev/tcp/vf-router/8062; exec 3>&-); done` |
| Two-factor (TOTP) only: **per user** (not per IP), 10 failed codes lead to a **15-minute** block. The state is in memory and is lost when the Router restarts. | [src] `router/handlers/two_factor_handler.h:83-84,126`; `two_factor_handler.cc:181-196,323-338` |
| Other caps: at most **5 concurrent relays** (see 13.6), at most 32 concurrent Client sessions per user (`kMaxClientsPerUser`), a 10 s handshake timeout for pending connections, and a 1-minute authenticator timeout. | [src] `router/workers/relay_worker.cc:195`, `router/workers/client_worker.h:67`, `base/net/tcp_server.cc:36`, `base/peer/authenticator.cc:36` |
| Consequence for NAT or source rewriting (rootless Podman with slirp4netns/pasta port forwarding, some proxies): all peers share **one** budget per listener (for example 60 Client connections per minute in total), and `*/white_list` cannot tell them apart. Nothing gets banned. | follows from the rows above; Podman itself not tested |

### 13.3 No network path to the updater

| Fact | Verified by |
|---|---|
| `ConsoleUpdater` (the only user of `base/update/` in the server binaries) is called only from `main()`, when `--check-update` or `--install-update` is set, before any worker starts. | [src] `router/main.cc:505-508`, `relay/main.cc:244-247`; `grep -rlE 'UpdateInstaller\|UpdateChecker\|ConsoleUpdater'` finds, outside `base/update/`, only `router/main.cc`, `relay/main.cc`, `host/`, `client/`, `common/` |
| No router or relay protocol message asks the Router or Relay to update. `grep -niE 'update\|install\|upgrade'` over `proto/router_relay.proto`, `relay_peer.proto`, `router_admin.proto`, `router_client.proto` and `router.proto` finds nothing. | [src] |
| The only "update" command in the router protocol is `HostRequest` `"update"` (admin-only). The Router **forwards it to a remote Host**, which then checks for its own update. It does not touch the Router. | [src] `proto/router_manager.proto:42-43`; `router/client_admin.cc:229-240` → `router/workers/host_worker.cc:536-542` → `router/host_ng.cc:125-128` |
| `ASPIA_NO_VERIFY_TLS_PEER` (disables TLS verification) is read only by the update checker and the downloader, so it affects only `--check-update` and `--install-update`. | [src] `base/update/update_checker.cc:279`, `base/net/http_file_downloader.cc:105` |

The updater cannot be reached over the network. It is reachable only through the two CLI flags.

### 13.4 Non-root and runtime write paths

| Fact | Verified by |
|---|---|
| **Runtime writes, observed with inotify** during a normal Router + Relay run (config present, no migration, 25 s including start, relay registration and SIGTERM stop): `CREATE`/`MODIFY` only on `/var/lib/aspia/router.db3-wal`, `router.db3-shm`, and the two log files in `/var/log/aspia/{router,relay}/`. **Nothing under `/etc/aspia` was written** (only opened). The WAL and SHM files remain after shutdown. | [run] `inotifywait -m -r -e modify,create,delete,moved_to,moved_from,attrib,open /etc /var/lib/aspia /var/log/aspia` (inotify-tools installed inside a throwaway container) |
| **Router, `/etc/aspia` read-only** (`:ro` volume, `--read-only` root filesystem, `ASPIA_LOG_TO_FILE=0`): starts normally, and all four TCP listeners come up. | [run] |
| **Router, `/var/lib/aspia` read-only:** it starts and listens, but 1 s later logs `ERROR ... Unable to execute : "attempt to write a readonly database"` / `Unable to prune expired host removals`. **The database directory must be writable** (the directory, not only the file, because SQLite creates `-wal` and `-shm` there). | [run]; [src] `router/database.cc` WAL; inotify rows above |
| **Relay as `nobody` (65534) with `relay.conf` owned by 65534, mode 0600, on a read-only volume, with a `--read-only` root filesystem:** runs and connects (`Connection to the router is established`). **The Relay needs read access only.** | [run] `docker run --user 65534:65534 --read-only -v <vol>:/etc/aspia:ro ... aspia_relay` |
| **Router and Relay both as `nobody`**, `/etc/aspia` read-only and owned by 65534, `/var/lib/aspia` read-write and owned by 65534: all Router listeners (8060-8063) plus 8070 come up, the Relay registers (`New relay session: "127.0.0.1"`), and there are no errors. | [run] |
| Relay as `nobody` with a root-owned 0600 `relay.conf`: `ERROR ... IniFile : 101 ] Unable to open file "/etc/aspia/relay.conf" : "Permission denied"`. It then runs on defaults (empty key and address), logs `Empty router address`, and **does not exit**. | [run] |
| Log directory not writable (uid < 1000 uses `/var/log/aspia/<component>`, which the package creates as root 0755): the Relay as `nobody` with default logging writes **no log file and prints no error about it**. It still runs and connects. Use `ASPIA_LOG_TO_FILE=0` together with `ASPIA_LOG_TO_STDOUT=1`, or chown the log directory. | [run] `vf-roD`: only the three harmless startup ERRORs in `docker logs`, ESTABLISHED to 8063; [src] `base/logging.cc:104-111` |
| Writes to `/etc/aspia` happen only in `--create-config`, in the 2.x migration (`router.conf`, `relay.conf`, renames `*.json` to `*.json.bak`), and in `--install` with data present (section 1). A read-only `/etc/aspia` is therefore safe only after those steps. | [src] `router/main.cc` `createConfig()`; `router/migration_utils.cc`, `relay/migration_utils.cc` (section 8) |
| **Correction to section 1:** the probe image is not free of logs. `postinst` runs `aspia_router --install` and `aspia_relay --install`, and each run leaves one log file (`/var/log/aspia/router/aspia_router-<ts>.log`, `/var/log/aspia/relay/aspia_relay-<ts>.log`, owned by root) in the image. | [run] `find /var/log/aspia -ls` in `aspia-probe:3.0.21`; the log contains `Command line: ( "/usr/bin/aspia_router" , "--install" )` |

Not tested: `chown -R` of an existing root-owned 2.x volume followed by the migration run as `nobody` (the
migration renames files in `/etc/aspia`, so that directory would need to be writable by the user).

### 13.5 No non-interactive way to set the initial admin password

| Fact | Verified by |
|---|---|
| The only place that creates a Router user without a Client is `createConfig()`, which hardcodes `admin`/`admin` with ADMIN, MANAGER and OPERATOR session rights and the `ENABLED` flag. | [src] `router/main.cc:307-323`; `grep -rn 'RouterUser::create\|User::create('` finds, outside `router/main.cc`, only `client/`, `host/` and `base/peer/` |
| No CLI option exists for it: router options are `install remove start stop keygen create-config reset-otp check-update install-update update-channel`. | [src] `router/main.cc:457-480` |
| No config key exists for it (`Settings` has only ports, listen interfaces, keys, white lists, seed key and STUN), and no environment variable (the full list is in 13.8). | [src] `router/settings.h`; env grep in 13.8 |
| A password can be changed only over the network, by an authenticated Client (`ChangePasswordRequest` carrying salt and verifier computed on the client side, or the admin's user management). | [src] `client/router_session.cc:720-730`, `router/client_operator.cc:201-203,512`, `router/handlers/user_request_handler.cc:397` |
| Writing `users.salt`/`verifier` with `sqlite3` would need Aspia's own SRP variant: `x = BLAKE2b512(s \| BLAKE2b512(lower(I) \| ":" \| p))`, with group `kDefaultGroup`. That is not a supported interface. | [src] `base/crypto/srp_math.cc:393-418`, `base/peer/user.cc:122-155`; not tried |

So a fresh install always starts with `admin`/`admin`, and the image can only tell the user to change it.

### 13.6 Relay and Router in separate containers (Docker bridge network)

Setup: `docker network create vf-net`. `vf-router` ran `aspia_router --create-config` and then `aspia_router`. Each
Relay container ran `aspia_relay --create-config`, then `sed` set `router/address=vf-router`,
`router/public_key=<router's relay.pub>` and `peer/public_address=<name>`.

| Fact | Verified by |
|---|---|
| The Relay resolves `router/address` as a container name and connects in about 40 ms: `Connecting to router...`, then `Connection to the router is established (session count: 0 )`. | [run] |
| **Router log lines for a registering relay** (exact): `INFO ... onNewRelayConnection : 208 ] New relay session: "172.21.0.3"`, then `INFO ... readKeyPool : 166 ] "[Relay#1]" Received key pool: 100 ( "172.21.0.3" )`, then `INFO ... add : 68 ] Relay not found in key pool. It will be added`, then **one line per key**: `INFO ... add : 76 ] Added key with id K for relay 1` (100 lines with the default `max_count=100`). On disconnect: `"[Relay#N]" Network error: TcpChannel::ErrorCode::REMOTE_HOST_CLOSED`, `All keys for relay N removed`. `N` is a per-connection counter, not a stable relay id. | [run] |
| **Several relays at once: yes, up to 5.** Two relay containers were connected at the same time (two ESTABLISHED sockets on 8063). With 6 relays, the 6th was refused: Router `ERROR ... onNewRelayConnection : 204 ] Too many relay sessions. Connection is rejected for "172.21.0.4"`; Relay `Connection to the router has been lost: ... REMOTE_HOST_CLOSED`, `Reconnect after 15 seconds`. | [src] `router/workers/relay_worker.cc:195-205` (`kMaxRelays = 5`); [run] five relays (1 + 4 extra processes on peer ports 8071-8074 via `ASPIA_RELAY_CONFIG_FILE`) |
| **`relay/white_list=172.21.0.3` (relay1's IP):** Router logs `Allowed relays: QStringList( "172.21.0.3" )`. Relay1 registers normally (`New relay session: "172.21.0.3"`). | [run] |
| Relay2 (172.21.0.4, not listed) is rejected: at INFO the Router logs **nothing**. At TRACE it logs `TRACE ... operator() : 278 ] Connection rejected by white list: "::ffff:172.21.0.4"`. Relay2 logs `Connection to the router has been lost: TcpChannel::ErrorCode::REMOTE_HOST_CLOSED` then `Reconnect after 15 seconds`, forever. | [run] `ASPIA_LOG_LEVEL=0` |
| White-list matching converts v4-mapped peers (`::ffff:a.b.c.d`) to IPv4, so plain IPv4 entries and IPv4 subnets match on the dual-stack listener. | [src] `base/net/net_utils.cc:254-286` |
| In a white-listed deployment the Relay container needs a **fixed IP** (or a subnet entry), because Docker assigns bridge IPs dynamically. | follows from above |

### 13.7 `listen_interface` values

| Value | Router (`client`/`host`/`relay`/`stun` `listen_interface`) | Relay (`peer/listen_interface`) | Verified by |
|---|---|---|---|
| empty | binds `::` (dual-stack TCP), log `Listen interface: "ANY" : <port>`. STUN binds UDP `0.0.0.0`. | binds `::`, log `"ANY"` | [src] `base/net/tcp_server.cc:136-139`, `relay/workers/relay_worker.cc:207-209`; [run] |
| IPv4 (`127.0.0.1`, `0.0.0.0`) | binds that address only (`127.0.0.1:8062`, `0.0.0.0:8061`, `0.0.0.0:8060`) | binds `127.0.0.1:8080`, and the Relay still connects to the Router | [run] `ss -Htln` |
| IPv6 (`::1`, `::`) | `host/listen_interface=::1` binds **both** `[::1]:8061` and `[::1]:8060` (the legacy port uses the host setting). `::` gives `*:8063`. | binds `[::1]:8080` and connects | [run] |
| bogus (`bogus.example`, `999.1.1.1`) | `ERROR ... isValidListenInterface : 166 ] Invalid interface address: "Invalid argument" ( 22 )` then `ERROR ... onPrepare ] Invalid listen interface address`. **That worker only** does not listen. The process keeps running and still logs `All workers started`. Hostnames are not resolved: an IP literal is required. | `ERROR ... Unable to get listen address: "Invalid argument" ( 22 )`. **No peer listener, and the Relay never connects to the Router** (the router connection is started from `RelayWorker::sig_ready`, which is not emitted). The process keeps running (killed by `timeout`, exit 124). | [src] `base/net/net_utils.cc:153-171`, `router/workers/*_worker.cc` `onPrepare`, `relay/workers/relay_worker.cc:194-204,268`; [run] |
| valid IP not on the container (`10.99.99.99`) | `ERROR ... acceptor::bind failed: "Cannot assign requested address" ( 99 )`, `ERROR ... Unable to start client listener`. There is no retry, and the process keeps running. | `ERROR ... bind failed: "Cannot assign requested address" ( 99 )`, and it does not connect to the Router | [run]; [src] `router/workers/client_worker.cc:155-164` |

Consequence: a mistyped `listen_interface` gives a **running container with a missing port**, so the
healthcheck must check every expected LISTEN socket.

### 13.8 Path overrides and every environment variable read

| Fact | Verified by |
|---|---|
| `ASPIA_ROUTER_CONFIG_FILE` moves **only `router.conf`**. `host.pub` and `relay.pub` are still written to `BasePaths::appConfigDir()` = `/etc/aspia`, and the database stays at `/var/lib/aspia/router.db3`. | [src] `router/main.cc:216-219,274-275` (`publicKeyDirectory()` = `appConfigDir()`); `base/files/base_paths.cc:60-61,108-111`; [run] `--create-config` with `ASPIA_ROUTER_CONFIG_FILE=/data/cfg/router.conf` created `/data/cfg/router.conf`, `/etc/aspia/host.pub`, `/etc/aspia/relay.pub`, `/var/lib/aspia/router.db3` |
| **`ASPIA_ROUTER_DB_FILE`** (not in the earlier notes) moves the database file. `--create-config` and the service both use it: [run] it created `/data/db/router.db3`, and the Router logged `Opening database: "/data/db/router.db3"`. | [src] `router/database.cc:379-392`; [run] |
| The 2.x migration always looks for `/etc/aspia/router.json` and `/etc/aspia/relay.json` (`appConfigDir()`), whatever the overrides say. | [src] `router/migration_utils.cc:37-39`, `relay/migration_utils.cc:36-38`; [run] log `Old configuration file does NOT exist: "/etc/aspia/router.json"` with the overrides set |
| `ASPIA_RELAY_CONFIG_FILE` moves `relay.conf` (the Relay has no other files). Several relay processes in one container, each with its own file, worked. | [src] `relay/settings.cc:33-40`; [run] 13.6 |

All environment variables that `aspia_router` and `aspia_relay` read in Aspia code. Source:
`grep -rnE 'qEnvironmentVariable|qgetenv|getenv|QProcessEnvironment' base router relay`, restricted to code
compiled into the two binaries. Checked against the binaries with
`grep -a -o 'ASPIA_[A-Z_]*' /usr/bin/aspia_{router,relay} | sort -u`:

| Variable | Binary | Effect | Source |
|---|---|---|---|
| `ASPIA_ROUTER_CONFIG_FILE` | router | path of `router.conf` | `router/settings.cc:56` |
| `ASPIA_ROUTER_DB_FILE` | router | path of `router.db3` | `router/database.cc:382` |
| `ASPIA_RELAY_CONFIG_FILE` | relay | path of `relay.conf` | `relay/settings.cc:36` |
| `ASPIA_LOG_LEVEL` | both | minimum log level, clamped to 0 (TRACE) .. FATAL; 1 = INFO is the default | `base/logging.cc:225-235`, `base/logging.h:114-115` |
| `ASPIA_LOG_TO_FILE` | both | `0` disables the log file | `base/logging.cc:241` |
| `ASPIA_LOG_TO_STDOUT` | both | `1` writes every line to stderr | `base/logging.cc:253` |
| `ASPIA_MAX_LOG_FILE_AGE` | both | days to keep log files | `base/logging.cc:270` |
| `ASPIA_NO_VERIFY_TLS_PEER` | both | if set, disables TLS peer verification, **for the updater only** | `base/update/update_checker.cc:279`, `base/net/http_file_downloader.cc:105` |
| `XDG_STATE_HOME`, `HOME` | both | log directory, **only when euid >= 1000** | `base/logging.cc:104-117` |
| `XDG_CONFIG_HOME`, `XDG_DATA_HOME`, `HOME` | both | only the per-user `appUser*Dir()` paths. The Router and Relay use `appConfigDir()`/`appDataDir()` (`/etc/aspia`, `/var/lib/aspia`), which ignore these variables. | `base/files/base_paths.cc:88,150,197` |

`ASPIA_SMALL_ICON_SIZE` (`base/gui_application.cc`) is GUI-only and does not appear in either server binary
(binary grep above). The other `XDG_*` strings in the binaries come from the statically linked Qt, as do the
usual `QT_*` variables. Their effect on the server binaries was not examined.

### 13.9 Changes to earlier sections implied by the above

- Section 4, `peer/public_address`: it accepts an IPv4 or IPv6 literal, or a hostname of at most 64 characters
  from `[A-Za-z0-9._-]`. **An empty value makes the Relay never connect**, and an invalid value makes the
  Router silently ignore the Relay's keys.
- Section 4, `*/listen_interface`: an IP literal only. A bad value disables that listener silently, and
  on the Relay it also prevents the Router connection.
- Section 5, non-root: the Relay also runs as `nobody` and needs only read access to `relay.conf`. The Router
  needs a writable `/var/lib/aspia` and a readable `/etc/aspia`.
- Section 9: the updater cannot be reached from the network (13.3). The "not verified" remark can go.
- Section 10: a Relay that shows ESTABLISHED to 8063 can still be useless (invalid `public_address`, or
  a 6th relay that is refused and reconnects every 15 s). Only the Router log shows this.
- Section 12: the brute-force, updater, non-root Relay and DNS-name items are resolved. Still open: the minimum
  2.x host version and 2.x/3.x Client compatibility, and running the migration as non-root on a chowned
  2.x volume.

## 14. Verified while implementing PR 1

Same legend. "Image" is the PR 1 image (`docker build --platform linux/amd64 -t aspia-server:test .`);
"probe" is `aspia-probe:3.0.21` from section 0; "tests" is `tests/run.sh`.

| Fact | Verified by |
|---|---|
| `aspia_relay --create-config` creates only `relay.conf` (0600, the content in section 4) and prints `Configuration successfully created.`, nothing secret. On a **non-empty** `relay.conf` it prints `Settings file already exists. Continuation is impossible.` and exits 1; on an **empty** `relay.conf` it succeeds. It does not fill `router/public_key`. | [run] probe: `aspia_relay --create-config` three times (clean, again, after `: > relay.conf`) |
| A public key can be derived from a `private_key` in `router.conf` with OpenSSL: DER prefix `302e020100300506032b656e04220420` + the 32 key bytes, then `openssl pkey -inform DER -pubout -outform DER`, last 32 bytes. The result equals `host.pub` / `relay.pub` of a fresh `--create-config`. The tests use this to prove key continuity without trusting `.pub` files. | [run] `tests/helper/x25519_pub <host/private_key>` = `host.pub`, `<relay/private_key>` = `relay.pub` |
| A Router port cannot be disabled with `0`: `host/port`, `host/legacy_port` and `stun/port` equal to 0 are rejected (`Invalid port specified in configuration file`, `Invalid legacy port ...`, `Invalid stun port ...`). STUN is switched off only by `stun/enabled`. So a healthy Router always listens on all four TCP ports. | [src] `router/workers/host_worker.cc:147-158`, `router/workers/stun_worker.cc:54-70` |
| With `ASPIA_LOG_TO_FILE=0` in the build environment, the package `postinst` (`--install`) writes no log file and `/var/log/aspia` does not exist in the image. (Without it, see the correction in the separate addendum: one log file per package is left in the layer.) | [run] image: `find / -xdev -path '/var/log/aspia*'` finds nothing |
| Both binaries log the signal as `Signal received:  "SIGTERM"  ( 15 )` (two spaces after the colon). Match it with `Signal received: +"SIGTERM"`. | [run] tests, scenario 4 |
| After 3.x has run, `router.db3` is in WAL mode and `-wal`/`-shm` stay after shutdown. `sqlite3` cannot open it from a **read-only** mount (`unable to open database file (14)`); read it through a writable mount while the Router is stopped. | [run] tests, scenario 3 |
| Setting `PeerAddress` in `relay.json` (with `jq`) **before** the first 3.x start is carried into `relay.conf` `peer/public_address` by the Relay's migration. The migrated Relay connects. | [run] tests, scenario 3 (2.7.0 with `EXTERNAL_IP=203.0.113.10`, 3.0.21 with `203.0.113.11`) |
| Rollback works: after the migration, copying the pre-migration `router.json`, `relay.json` and `router.db3` back, and deleting `router.conf`, `relay.conf`, `router.db3-wal` and `router.db3-shm`, lets `paprikkafox/aspia-server:2.7.0` start again; its Relay connects to 8060 and the fixture host is in the database. | [run] tests, scenario 3 (end) |
| The 2.7.0 → 3.0.21 upgrade also works with the compose bind mounts `./data/config` and `./data/database` (Docker Desktop, macOS): 2.7.0 via the old compose file, then the new compose file and `up -d`; healthy, same key, backups next to the originals. | [run] once by hand, with a temporary local tag `paprikkafox/aspia-server:3.0.21` for the test image, removed afterwards |
| On a user-defined Docker network, a container has an extra LISTEN socket on a random high port (Docker's embedded DNS). Tests that list listening ports must not require an exact set. | [run] tests, scenario 1 |
| Debian trixie ships `tini` 0.19.0-3+b8 (`/usr/bin/tini`, depends only on libc6). Started under `docker run --init` (so not PID 1) it warns `Tini is not running as PID 1 and isn't registered as a child subreaper`; with `tini -s` the warning is gone and stop/health behave the same. | [run] `apt-cache policy tini`; image with and without `-s`, `docker run --init` |
| `wait -n -p VAR` (bash 5.2 in trixie) **unsets** `VAR` when a trapped signal interrupts the wait. Under `set -u`, reading it needs `${VAR:-}`. | [run] first version of `aspia_start` failed on `docker stop` with `pid: unbound variable` |

## 15. Official migration guide (aspia.org/docs/migration)

[doc] https://aspia.org/docs/migration, fetched 2026-09-30. Upstream documentation, quoted; not tested
by us (needs GUI Clients and Hosts). Sections on the page: Before you start, Aspia Router, Aspia Relay, Aspia Host, Aspia Client.

| Statement (verbatim) | Section |
|---|---|
| "Version 3.0.0 keeps working with Hosts of previous versions, so the whole network does not have to be updated at once." | Before you start |
| "The minimum supported version is 2.6.0." (**supersedes** the unverified "2.6.2 and later" in the SinitsaDA README) | Before you start |
| "The recommended order is: Router, then Relay, then Clients and Hosts." | Before you start |
| "Until a Host is updated it keeps connecting to the Router as before." | Before you start |
| Ports: "8060 - Hosts of versions below 3.0.0", "8061 - Hosts of version 3.0.0", "8062 - Clients", "8063 - Relays", "8065 - STUN server" | Aspia Router |
| "The configuration is migrated automatically at the first start of the new version." "The white lists, the private key, the seed key and the listening interface are taken from the old configuration file." (consistent with section 8) | Aspia Router |
| Relay: "the address and the public key of the Router, the listening interface, the port for peers, the idle timeout and the maximum number of peers are taken from the old configuration file." "The migration always sets the new port for relays - 8063." | Aspia Relay |
| "A Host of version 2.7 does not have to be updated together with the Router. It keeps connecting to the Router on port 8060 and can be updated later." | Aspia Host |
| "The Console has been removed. Its functions are performed by the Client: the address book, groups of computers and the management of the Router are now tabs of its window." | Aspia Client |
| "Address books of previous versions are not converted automatically. Open the Client and use 'Import Old Address Book…' to import an existing `.aab` file." | Aspia Client |
| "Two-factor authentication is mandatory in version 3.0.0. At the first connection every user, including the administrator, is asked to enroll." "The connection to the Router requires a code of two-factor authentication." | Aspia Client |
| "The master password is now mandatory. At the first start the Client asks to set it…" (Client-side) | Aspia Client |

Not stated on the page: whether a 2.x Client or Console can connect to a 3.x Router. Consequence: docs must say
a 3.x Client is required to manage a 3.x Router (the 2.x Console no longer exists in 3.x), link the page, and not
claim 2.x Client compatibility.

## 16. Verified while implementing PR 2

Same legend, plus **[ci]** for facts about GitHub, the registries and the build tools rather than
about Aspia. Checked on 2026-09-30 with Docker Desktop 29.8.1 and buildx v0.37.1.

| Fact | Verified by |
|---|---|
| dchapyshev/aspia has 14 releases (v2.6.0 to v3.0.21). All tags have the form `vX.Y.Z`; none is a draft or a pre-release. The `releases/latest` endpoint returns `v3.0.21`. The watch workflow nevertheless filters drafts, pre-releases and other tag forms itself and picks the highest version with `sort -V`. | [api] `gh api 'repos/dchapyshev/aspia/releases?per_page=100' --paginate --jq '.[] \| "\(.tag_name) draft=\(.draft) pre=\(.prerelease)"'`; `gh api repos/dchapyshev/aspia/releases/latest --jq .tag_name` |
| The 3.0.21 packages downloaded with `gh release download` have the sha256 values in section 1, equal to the API `digest` field (`sha256:<hex>`). | [api] `scripts/aspia-release.sh fetch 3.0.21 <dir>` (checks each file against the API digest) |
| v2.7.0 also has `aspia-router-2.7.0-x86_64.deb` and `aspia-relay-2.7.0-x86_64.deb`, so "has both packages" alone does not tell 2.x from 3.x. The watch only proposes versions newer than `versions.env`. | [api] `gh api repos/dchapyshev/aspia/releases/tags/v2.7.0 --jq '.assets[].name'` |
| [ci] `docker buildx imagetools create --tag <repo>:<tag> ... <repo>@<digest>` with one source reuses the source index as it is: every new tag, in the same registry and in a second registry, has the **same digest**, and the attestation manifest (SBOM, provenance) is copied along. So a digest tested once can be tagged and copied without rebuilding. | [run] two local `registry:2` instances; image built with `--provenance mode=max --sbom true --output type=image,...,push-by-digest=true`; `docker buildx imagetools inspect --format '{{json .Manifest}}' <ref> \| jq -r .digest` for each tag |
| [ci] A push with `push-by-digest=true` creates no tag (the registry's tag list for the repository is empty), and `docker run --platform linux/amd64 <repo>@<digest>` pulls and runs it. `tests/run.sh` with `ASPIA_TEST_IMAGE=<repo>@<digest>` passes against such an image. | [run] `curl http://localhost:5001/v2/<name>/tags/list` returned `NAME_UNKNOWN` before tagging; full `tests/run.sh` run |
| [ci] Trivy 0.74.0 on the 3.0.21 image detects `debian 13.7` and reports 191 findings (HIGH 47, MEDIUM 75, LOW 65, UNKNOWN 4, CRITICAL 0), all in Debian packages. The Aspia binaries are not matched to any package database. | [run] `trivy image --input <docker save tar> --scanners vuln` (ci.yml's scan step, run locally) |
| [ci] The fork gleruzh/aspia-server-docker: Actions permissions `enabled: true, allowed_actions: all`; the old `docker-image.yml` is `active`, yet **no workflow run has ever happened**, not even for the push of PR 1 to main. So the fork gate (enable workflows in the Actions tab) is still closed; the API does not show it. Workflow permissions: `default_workflow_permissions: read`, `can_approve_pull_request_reviews: false`, i.e. `GITHUB_TOKEN` may not open pull requests until the owner allows it. | [api] `gh api repos/gleruzh/aspia-server-docker/actions/permissions`, `.../actions/workflows`, `.../actions/runs --jq .total_count` (0), `.../actions/permissions/workflow` |
| [ci] When the selected Buildx builder uses the `docker-container` driver (what `docker/setup-buildx-action` selects for the whole job by default), a plain `docker build -t <name> .` only warns `No output specified with docker-container driver` and **does not load the image** into the image store. `tests/run.sh` builds its helper image that way, so `publish.yml` sets `use: false` and passes the builder to `build-push-action` explicitly. | [run] `BUILDX_BUILDER=<container builder> docker build -t x .` then `docker image inspect x` fails; with the default builder it succeeds |
| [ci] `gh auth setup-git` works with only `GH_TOKEN` set (no stored login): it installs `gh auth git-credential` as the credential helper for github.com, and `git credential fill` returns `username=x-access-token` with the token. `upstream-watch.yml` pushes the bump branch this way, so the token is never written to `.git/config`. | [run] throwaway `HOME` and `GH_CONFIG_DIR`, `gh auth setup-git`, `git credential fill` |
| [ci] GitHub documentation (fetched 2026-09-30): `workflow_dispatch` and `schedule` "will only trigger a workflow run if the workflow file exists on the default branch"; scheduled workflows run only on the default branch and, in a public repository, "are automatically disabled when no repository activity has occurred in 60 days". So `publish.yml` and `upstream-watch.yml` cannot be dispatched in the fork before they are on `main`. | [doc] https://docs.github.com/en/actions/reference/workflows-and-actions/events-that-trigger-workflows |
| [ci] GitHub documentation (fetched 2026-09-30): events caused by `GITHUB_TOKEN` create no workflow runs, except `workflow_dispatch` and `repository_dispatch`; but a pull request created or updated with `GITHUB_TOKEN` now gets `pull_request` runs in an approval-required state, started by a user with write access via "Approve workflows to run". Not observed yet in this repository. | [doc] https://docs.github.com/en/actions/concepts/security/github_token |

## 17. Verified while implementing PR 3

Same legend. "Image" is the PR 3 image (`docker build --platform linux/amd64 -t aspia-server:test .`
in this branch's checkout).

| Fact | Verified by |
|---|---|
| `setpriv` (from `util-linux`) is present in `debian:trixie-slim` with no extra package, and can drop from root to an arbitrary numeric uid/gid that has no `/etc/passwd`/`/etc/group` entry: `setpriv --reuid=12345 --regid=12345 --clear-groups --no-new-privs id` prints `uid=12345 gid=12345 groups=12345`. `gosu` is not present; not needed. | [run] `docker run --rm --platform linux/amd64 debian:trixie-slim@sha256:a99cfc5... setpriv ...` |
| `/usr/share/zoneinfo` is present in `debian:trixie-slim` with no extra package (`tzdata` is **not** installed). Setting `TZ=America/New_York` changes both `date`'s output and the Aspia binaries' own log timestamps (`"INFO" "2026/09/30 16:37:29.069" ...` at local time instead of UTC) inside the built image, with no Dockerfile change. | [run] `docker run ... aspia-server:test bash -c 'TZ=America/New_York date'`; `docker run -e TZ=America/New_York aspia-server:test aspia_router --version` (stderr banner) |
| `curl` is not in `debian:trixie-slim`, and neither is `wget`. `curl`'s own `Depends` are only `libc6`, `libcurl4t64`, `zlib1g` -- **not** `ca-certificates` (that is a `Recommends`), so `apt-get install --no-install-recommends curl` alone cannot make an HTTPS request (`curl: (77) error setting certificate file`). Adding `ca-certificates` alongside `curl` fixes it; `api.ipify.org`, `ifconfig.me/ip` and `icanhazip.com` then all return the same IPv4 address for this host. | [run] probe: `apt-get install -y --no-install-recommends curl`; then again with `ca-certificates` added, `curl -sS https://api.ipify.org` |
| **Dockerfile bug (pre-existing, from PR 1), found through PUID/PGID**: `COPY --chmod=0644 aspia_common.sh /usr/lib/aspia-server/aspia_common.sh` creates the new directory `/usr/lib/aspia-server` with mode `0644` too (buildkit applies the same numeric mode to a directory it has to create for the destination), i.e. **no execute/search bit**, so a non-root user cannot `source` the file inside it even though the file itself is world-readable (`Permission denied`). Invisible as long as everything runs as root (root ignores the missing execute bit via `DAC_OVERRIDE`). Fixed by `RUN mkdir -p -m 0755 /usr/lib/aspia-server` before the `COPY --chmod`. | [run] `docker run --rm aspia-server:test ls -la /usr/lib/aspia-server/` showed `drw-r--r--` before the fix, `drwxr-xr-x` after; a container started with `PUID=1000 PGID=1000` failed with `aspia_start: line 33: .../aspia_common.sh: Permission denied` before the fix and started cleanly after |
| End-to-end with `PUID=1000 PGID=1000` on fresh volumes: the container chowns `/etc/aspia`/`/var/lib/aspia` to `1000:1000`, `aspia_router --create-config`/`aspia_relay --create-config` succeed as that user, both processes run as uid 1000 (`/proc/<pid>/status` `Uid:`), the Relay connects to the Router, and the healthcheck (run by `docker exec`, which defaults to root regardless of `PUID`/`PGID`) reports healthy. | [run] `docker run -e PUID=1000 -e PGID=1000 -e ASPIA_RELAY_PUBLIC_ADDRESS=... aspia-server:test`; `docker exec <c> sh -c 'awk "/^Uid:/{print \$2}" /proc/<pid>/status'` |
| `ASPIA_RELAY_MAX_PEERS` actually changes what the Relay sends: with `peer/max_count=50`, the Router log shows exactly `Added key with id 0` through `id 49` for the registering relay (50 lines), against 100 with the default. Confirms the key pool size the Relay reports is `max_count`, matching notes section 4. | [run] `aspia-server:test` with `ASPIA_RELAY_MAX_PEERS=50`, count of `Added key with id` lines in the Router log |
| `ASPIA_RELAY_PUBLIC_ADDRESS=auto` with `--network none`: `curl` fails immediately (no route), all three sources are tried and none answer, the container exits 1 with a message naming `ASPIA_RELAY_PUBLIC_ADDRESS=auto` and the three source names, and nothing is created under `/etc/aspia` or `/var/lib/aspia`. | [run] `docker run --network none -e ASPIA_RELAY_PUBLIC_ADDRESS=auto aspia-server:test`; `find /etc/aspia /var/lib/aspia -mindepth 1` on the volumes afterwards (empty) |
| Custom Router/Relay ports together with the healthcheck: starting with `ASPIA_ROUTER_CLIENT_PORT=19062`, `ASPIA_ROUTER_HOST_PORT=19061`, `ASPIA_ROUTER_LEGACY_PORT=19060`, `ASPIA_ROUTER_STUN_PORT=19065` and `ASPIA_RELAY_PEER_PORT=19070` at once, the container becomes `healthy` (`aspia_health` reads every port from the config files, not from constants, so it needed no PR 3 change) and `router.conf`/`relay.conf` contain exactly those values. | [run] `aspia-server:test` with the five port variables set; `docker inspect -f '{{.State.Health.Status}}'`; `docker exec ... cat /etc/aspia/router.conf /etc/aspia/relay.conf` |
| **`relay/white_list` footgun, found by testing our own new variable**: this image's own Relay always dials the Router at `router/address=127.0.0.1` (section 4). Setting `ASPIA_ROUTER_RELAY_ALLOWED_IPS` (`relay/white_list`) to a value that excludes `127.0.0.1` (e.g. a Docker-bridge subnet) makes the Router's own flood guard/white list (section 13.2) drop the co-located Relay's connection immediately (`TcpChannel::ErrorCode::REMOTE_HOST_CLOSED`, repeating every 15 s, matching section 5's "wrong key"/"not reachable" pattern but for a different cause). The Relay's TCP port still opens, so nothing in `aspia_start` catches it, and the container stays `unhealthy` for the full healthcheck window with no explanatory log line. PR 3's `aspia_start` now rejects a `ASPIA_ROUTER_RELAY_ALLOWED_IPS` that does not cover `127.0.0.1` at startup, before anything is written, with a message naming the cause. | [run] `aspia-server:test` with `ASPIA_ROUTER_RELAY_ALLOWED_IPS=172.18.0.0/16` (excludes 127.0.0.1): Relay log `Connection to the router has been lost: TcpChannel::ErrorCode::REMOTE_HOST_CLOSED` / `Reconnect after 15 seconds`, repeating, container `unhealthy`; the same value with PR 3's check in place makes the container exit 1 immediately instead |

## 18. Verified while implementing PR 4

Same legend. Podman facts are about the Quadlet unit in `podman/` and the real 3.0.21 image unless a row
says "stand-in". Environment: Docker Desktop 29.8.1 on Apple Silicon. Each Podman ran inside a privileged
`linux/arm64` container with systemd as PID 1 (`--privileged --cgroupns=host -v /sys/fs/cgroup:/sys/fs/cgroup:rw`,
`/var/lib/containers` and `/home` on Docker volumes); the amd64 Aspia image ran nested, through Docker
Desktop's Rosetta binfmt handler. "Stand-in" is a small arm64 busybox image with the same ports, an
`aspia_health` and the same SIGTERM behaviour, used where an old Podman cannot run an amd64 image on an arm64
host. It tests the unit and Podman, not Aspia. CI (ubuntu-24.04, real amd64) is the definitive run.

| Fact | Verified by |
|---|---|
| **The unit needs Podman 4.5 or later.** The Quadlet generator of Podman 4.4.1 rejects `HealthCmd`: `Error converting 'aspia-server.container', ignoring: unsupported key 'HealthCmd' in group 'Container'`. 4.5.1 accepts the unit. `VolumeName=` in a `.volume` file is unsupported through 4.6.2 (`unsupported key 'VolumeName' in group 'Volume'`), so the `.volume` files carry no keys and the volumes are named `systemd-aspia-config` and `systemd-aspia-data`. | [run] `podman-system-generator -dryrun` in `quay.io/podman/stable:v4.4.1` (and v4.5.1, v4.6.2, v4.7.2, v4.8.3, v4.9.4) with the files of `podman/` mounted in `/etc/containers/systemd` |
| The unit (final files) is generated without errors by 4.5.1, 4.6.2, 4.7.2, 4.8.3 and 4.9.4 (`rc=0`), and by 4.9.3 (Ubuntu 24.04), 5.4.2 (Debian 13) and 5.8.7 (Fedora 44) inside `tests/podman.sh`. | [run] dry runs as above; `tests/podman.sh` runs |
| `tests/podman.sh` (system-wide and rootless: generator, start, `podman healthcheck run`, wanted by `default.target`, same keys after restart, restart of a SIGKILLed container by systemd, `systemctl stop` time and clean exit, host-network edit) passes on **Podman 4.9.3 / Ubuntu 24.04**, **5.4.2 / Debian 13**, **5.8.7 / Fedora 44** with the real image, and on **4.5.1 / Fedora 38 userland** with the stand-in. | [run] four runs of `tests/podman.sh all` |
| `systemctl stop` of the unit finishes in 0.1 to 0.3 s on every Podman above, `Result=success`, and the container log ends with `aspia_relay stopped (exit code 0)`, `aspia_router stopped (exit code 0)`, `All processes have exited; exit code 0`: Quadlet's `ExecStop=podman rm -f` ends in the SIGTERM path of `aspia_start`, nothing is SIGKILLed (the Podman event list of a stop on 4.9.3 shows `died` then `remove`, no `kill`). The default `TimeoutStopSec` (70 s) is never reached. | [run] `tests/podman.sh` (timing and log check); `podman events` after a stop on 4.9.3 |
| `WantedBy=default.target` in `[Install]` works for both install variants with one unit file: the system manager lists the unit under `default.target`, and the user manager starts it. After restarting the whole outer container (systemd booting again) the system-wide service was running again, container healthy, with no `systemctl enable`. `multi-user.target` does not exist in a user manager, so it is not used. | [run] `systemctl list-dependencies default.target`; `docker restart` of the test host (4.9.3) |
| A relative `EnvironmentFile=aspia-server.env` is resolved by the generator against the unit's directory (`--env-file /etc/containers/systemd/aspia-server.env`, or the user's `~/.config/containers/systemd/...`) from 4.5.1 on. | [run] dry run output |
| **Quadlet drop-ins (`aspia-server.container.d/*.conf`) are ignored by Podman 4.9.3** (a `Network=host` drop-in changed nothing: the container kept its published ports and the Router still saw `10.0.2.100`) and honoured by 5.4.2. So the host-network alternative is a sed edit of the unit, not a drop-in file. | [run] rootless 4.9.3 with the drop-in, then `podman ps` and the STUN reply; 5.4.2 container ran with host ports |
| `podman healthcheck run` prints nothing and exits 0 when healthy. `podman ps` shows `(starting)` for the first 30 s, then `(healthy)`. With `HealthCmd` set in the unit and `Type=notify` (`--sdnotify=conmon`) the service counts as started as soon as the container is, not when it is healthy. | [run] |
| **Source address seen by the Router, per setup** (external client = another Docker container on the test host's network, 172.17.0.x): root with netavark, Podman 4.9.3: `::ffff:172.17.0.3`, the real one (Router TRACE `Connection rejected by white list`); the STUN reply on 5.8.7 (root and rootless) names `172.17.0.3`. **Rootless Podman 4.9.3 (slirp4netns, rootlessport): `::ffff:10.0.2.100` for every client**, and the STUN reply is `10.0.2.100`. Rootless 5.4.2 (pasta): real address `172.17.0.4` for an external client; a connection from the test host itself shows up as `172.17.0.2` (to 127.0.0.1) or `169.254.1.2` (to its own address). Rootless with `Network=host` on 4.9.3: real address (`172.17.0.3`) in the Router log and in the STUN reply. | [run] `ASPIA_LOG_LEVEL=0` and `ASPIA_ROUTER_CLIENT_ALLOWED_IPS=192.0.2.1` so that every connection is logged with its source; `nc` from a second container; the STUN probe below |
| **The per-address rate limit of 13.2 does get shared in rootless Podman 4.9.3.** Two containers (172.17.0.3 and .4) made 40 connections each to 8062 within a few seconds: 17 to 20 `Connection rejected by flood guard` and one `Per-address rate limit hit for "::ffff:10.0.2.100"`, i.e. one budget of 60 for both. The same two containers against a Router in host networking (4.9.3), and against rootless Podman 5.4.2 (pasta): 0 rejections. | [run] `loop.sh` (40 x `nc -w1 <ip> 8062`) from each container; `grep -c 'rejected by flood guard'` |
| **The STUN protocol is not RFC 5389**: a protobuf `PeerToStun{endpoint_request{magic_number = 0xA0B1C2D3, transaction_id}}` datagram is answered with `StunToPeer{endpoint{transaction_id, ip_address (string), port}}`, the address and port the datagram came from. Anything else is counted as an invalid datagram and dropped (logged once a minute). IPv4 only. The wire bytes of a probe are `0a 08 08 d3 85 c7 85 0a 10 01`. | [src] `proto/stun.proto`, `router/workers/stun_worker.cc` (`doReceiveRequest`, `doSendAddressReply`); [run] the probe answered `172.17.0.3` plus a port from a second container |
| With `Network=host` **port 8063 is open on every interface**, and an external connection to it is accepted (no white list). With `ASPIA_ROUTER_RELAY_ALLOWED_IPS=127.0.0.1` (valid under PR 3's check) an external connection to 8063 is rejected (`Connection rejected by white list: "::ffff:172.17.0.3"`) while the co-located Relay still registers (`New relay session: "127.0.0.1"`) and the container is healthy. | [run] rootless 4.9.3, host networking, `nc` to 8063 from a second container |
| Rootless Podman needs no sysctl for these ports (all above 1024), and a rootless unit with published ports forwards the STUN UDP port (the probe was answered on 4.9.3 and 5.8.7). | [run] |
| `PublishPort=` lines in a unit that also has `Network=host` are ignored without an error (5.4.2: the container ran in the host namespace with the lines present); the documented sed edit deletes them anyway. | [run] 5.4.2 drop-in test |
| On Debian 13 installed with `--no-install-recommends`, Podman 5.4.2 fails to publish ports: `netavark: nftables error: unable to execute nft: No such file or directory` (netavark only *Recommends* `nftables`). Installing `nftables` fixes it. | [run] first test run on a minimal Debian trixie image |
| Host directories with `:Z` work as the volumes (system-wide, Fedora 44, Podman 5.8.7): healthy, files owned by root on the host, `router.conf` identical after a restart. The test host had no SELinux, so the relabelling itself is untested. | [run] `Volume=/var/lib/aspia-server/config:/etc/aspia:Z` and `.../data:/var/lib/aspia:Z` |
| `podman volume inspect ... --format '{{.Mountpoint}}'` and `podman volume export <volume>` work for the named volumes (the export holds `host.pub`, `relay.conf`, `relay.pub`, `router.conf`); `podman info --format '{{.Host.RootlessNetworkCmd}}'` prints `pasta` on 5.8.7 (the field does not exist on 4.9.3). | [run] Fedora 44 / Podman 5.8.7 |
| Fallback without Quadlet: on Podman 3.4.4 (Ubuntu 22.04) `podman run -d ...` followed by `podman generate systemd --new --files --name --restart-policy=always` writes `container-aspia-server.service` (`Restart=always`, `WantedBy=default.target`, `Type=notify`); `systemctl enable --now` starts it, the container is `(healthy)` with the `--health-*` options from the command, `systemctl stop` takes 0.5 s. The generator's default policy is `on-failure`, hence the flag. Stand-in image. | [run] |
| Test-environment notes, not product facts: (1) rootless Podman on top of an overlay file system (the container's own writable layer) gives `exec container process ...: Invalid argument`; `/home` and `/var/lib/containers` on a Docker volume avoid it. (2) systemd 255 and later (Ubuntu 24.04, Debian 13, Fedora) as PID 1 in a `linux/amd64` Docker Desktop container fails every service start (exit 255) under Rosetta, and crun and runc fail there too (`Failed to re-execute libcrun via memory file descriptor`), so the test hosts are arm64 and the amd64 image runs nested. (3) The `quay.io/podman/stable` images ship a `containers.conf` (`cgroups = "disabled"`, `cgroupfs`) and a `storage.conf` (`fuse-overlayfs`, `fsync=0`) made for running without systemd; they hang or fail with systemd, so both were emptied or edited for the 4.5.1 run. (4) The Fedora test image needed `chmod u+s newuidmap newgidmap` (file capabilities are lost in image layers). | [run] |

Not verified in PR 4: a real reboot (a restart of the outer container stands in for it); SELinux enforcing
(`:Z`, and Podman's own labels under enforcing mode); firewalld and ufw rules and how Podman's forwarding rules
interact with them; Podman 4.5.0 itself (4.5.1 is the lowest run); EL8/EL9/EL10 themselves (their repositories
carry Podman 4.9.4, 5.8.2 and 5.8.2 per `dnf info podman` in `almalinux:8/9/10`, versions covered by the runs
above); a real Client or Host through the published Relay port; PUID/PGID in Podman; rootless host directories.
