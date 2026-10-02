# Сервер Aspia (Relay + Router)
### Текущая версия (Current version) - 3.0.21

[![CI](../../actions/workflows/ci.yml/badge.svg)](../../actions/workflows/ci.yml) [![Publish](../../actions/workflows/publish.yml/badge.svg)](../../actions/workflows/publish.yml)

https://hub.docker.com/r/paprikkafox/aspia-server

Данный контейнер предназначен для быстрого развертывания сервера удаленного доступа с открытым исходным кодом (aspia.org)

[![#AspiaLogo](https://www.aspia.org/lib/tpl/bootstrap3/images/logo.png "#AspiaLogo")](https://www.aspia.org/ "#AspiaLogo")

### Установка Docker:

Для Debian и Ubuntu:

```shell
sudo apt update # Обновляем репозитории
sudo apt upgrade # Обновляем пакеты системы
sudo apt install docker.io docker-compose # Установка Docker и docker-compose
sudo systemctl enable --now docker.service # Включаем и запускаем главный сервис Docker
sudo usermod -aG docker $USER # Добавляем текущего пользователя в группу docker, для работы без root прав (sudo)`
```

### Сборка образа Docker:

```shell
docker build -t username/aspia-server:3.0.21 .
```

**username** - имя профиля Docker Hub

**aspia-server** - имя образа 

**3.0.21** - тег версии

Разворачивание из образа описано здесь - https://hub.docker.com/r/paprikkafox/aspia-server

Порты Aspia 3.x и обновление с 2.x описаны ниже, в разделах "Ports" и "Upgrading from 2.x" (на английском).

Код проекта доступен под лицензией GNU General Public License 3 - [Aspia Remote Control](https://github.com/dchapyshev/aspia "dchapyshev")

Главный разработчик и автор проекта - Dmitry Chapyshev - [dchapyshev](https://github.com/dchapyshev/ "dchapyshev")

Сопровождающий Docker-образа Aspia Server - Dmitry Fox -  [paprikkafox](https://github.com/paprikkafox/ "paprikkafox")



# Aspia Server (Relay + Router)

https://hub.docker.com/r/paprikkafox/aspia-server

This container is designed for rapid deployment of an open source remote access server (aspia.org)

[![#AspiaLogo](https://www.aspia.org/lib/tpl/bootstrap3/images/logo.png "#AspiaLogo")](https://www.aspia.org/ "#AspiaLogo")

### Docker installation:

For Debian and Ubuntu:

```shell
sudo apt update # Update repositories
sudo apt upgrade # Update system packages
sudo apt install docker.io docker-compose # Install Docker and docker-compose
sudo systemctl enable --now docker.service # Enable and start the main Docker service
sudo usermod -aG docker $USER # Add the current user to the docker group, to work without root rights (sudo)`
```

### Building the Docker image:

```shell
docker build -t username/aspia-server:3.0.21 .
```

**username** - Docker Hub profile name

**aspia-server** - image name

**3.0.21** - version tag

Deployment from an image is described here - https://hub.docker.com/r/paprikkafox/aspia-server

### Published image

GitHub Actions builds the image (linux/amd64), runs the tests against it, and publishes it to `ghcr.io/<owner>/aspia-server`, where `<owner>` is the GitHub account of the repository you use. Docker Hub and Quay.io get the same image when the maintainer has enabled them ([docs/ci.md](docs/ci.md)).

Pin an exact version, or a digest for an image that never changes (the digest of each release is in the summary of its publish run):

```shell
docker pull ghcr.io/<owner>/aspia-server:3.0.21
docker pull ghcr.io/<owner>/aspia-server@sha256:<digest>
```

With docker compose, put the same reference into `.env`: `ASPIA_IMAGE=ghcr.io/<owner>/aspia-server:3.0.21` or `ASPIA_IMAGE=ghcr.io/<owner>/aspia-server@sha256:<digest>`.

The version tag is rebuilt every week to pick up Debian security updates, so its digest changes; every weekly rebuild also gets its own tag `3.0.21-YYYYMMDD`, which never moves. The tags `latest`, `<major>` and `<major>.<minor>` exist only for convenience: they change under you on the next pull, so do not use them on a server. The image is signed with cosign; [docs/ci.md](docs/ci.md) shows how to verify it.

### Podman (systemd service)

On a machine with Podman and no Docker (RHEL, AlmaLinux, Rocky, Fedora, Debian, Ubuntu), [podman/](podman/README.md) has a ready-made Quadlet unit: copy a few files, run `systemctl daemon-reload` and `systemctl start`, and the server runs as a systemd service that restarts on failure and starts at boot. System-wide and rootless installs are both described, with the network and firewall details, the manual update steps, and a fallback for Podman older than 4.5. Requires Podman 4.5 or later; use the published image (a local `podman build` needs Podman 5.1 or later).

### Ports

Publish every port one-to-one (host port = container port): the Relay announces its own port to clients and hosts.

| Port | Used by |
|---|---|
| 8060/tcp | Router: hosts of Aspia 2.x |
| 8061/tcp | Router: hosts of Aspia 3.x |
| 8062/tcp | Router: clients (address book and Router management) |
| 8065/udp | Router: built-in STUN server |
| 8070/tcp | Relay: clients and hosts |
| 8063/tcp | Router: Relays. Used inside the container; publish it only for a Relay on another machine (see "Running a Relay on a separate host"). |

`EXTERNAL_IP` (or its new name, `ASPIA_RELAY_PUBLIC_ADDRESS`) is required: the public address the Relay announces. Without one of them the container exits with a clear error, with docker compose and with `docker run` alike. With docker compose, put it into a `.env` file next to `docker-compose.yml`; see `.env.example` for every variable and the "Configuration" section below.

The Aspia log goes to `docker logs`; no log files are written.

### Configuration

Everything besides the address above is optional and has an upstream default. Copy `.env.example` to `.env` and uncomment what you need, or pass `-e VAR=value` to `docker run`.

**Precedence: if a variable is set, its value is written to the configuration file on every start; if it is unset, the value already in the file is left alone.** This is why a value you set by hand in `router.conf` or `relay.conf` on the volume survives a restart, as long as you never set the matching variable. An empty value (`VAR=`) counts as unset too, for every variable, including the allow-lists: it does not clear an existing list. To clear an allow-list, edit `router.conf` directly, or set the variable to the list you actually want. An invalid value (a bad port, address or list) makes the container print one message naming the variable and exit non-zero before starting anything.

| Variable | Configuration key | Default | Example |
|---|---|---|---|
| `EXTERNAL_IP` / `ASPIA_RELAY_PUBLIC_ADDRESS` | `relay.conf` `[peer] public_address` | none (required); `auto` detects it | `203.0.113.10`, `auto` |
| `ASPIA_RELAY_PEER_PORT` | `relay.conf` `[peer] port` | `8070` | `8070` |
| `ASPIA_RELAY_IDLE_TIMEOUT` | `relay.conf` `[peer] idle_timeout` (minutes) | `5` | `10` |
| `ASPIA_RELAY_MAX_PEERS` | `relay.conf` `[peer] max_count` | `100` | `200` |
| `ASPIA_ROUTER_CLIENT_PORT` | `router.conf` `[client] port` | `8062` | `8062` |
| `ASPIA_ROUTER_HOST_PORT` | `router.conf` `[host] port` | `8061` | `8061` |
| `ASPIA_ROUTER_LEGACY_PORT` | `router.conf` `[host] legacy_port` | `8060` | `8060` |
| `ASPIA_ROUTER_STUN_ENABLED` | `router.conf` `[stun] enabled` | `1` | `0` |
| `ASPIA_ROUTER_STUN_PORT` | `router.conf` `[stun] port` | `8065` | `8065` |
| `ASPIA_ROUTER_CLIENT_ALLOWED_IPS` | `router.conf` `[client] white_list` | empty = allow all | `203.0.113.0/24` |
| `ASPIA_ROUTER_HOST_ALLOWED_IPS` | `router.conf` `[host] white_list` | empty = allow all | `203.0.113.0/24` |
| `ASPIA_ROUTER_RELAY_ALLOWED_IPS` | `router.conf` `[relay] white_list` | empty = allow all | `127.0.0.1,172.18.0.0/16` |
| `PUID`, `PGID` | run the Router and the Relay as this uid/gid instead of root (both or neither) | `0` (root) | `1000` |
| `TZ` | timezone for the Router's/Relay's own log timestamps (the binaries' own variable) | `UTC` | `Europe/Berlin` |
| `ASPIA_LOG_LEVEL` | minimum log level the binaries write: 0 TRACE .. 4 FATAL (the binaries' own variable) | `1` (INFO) | `0` |
| `ASPIA_ROLE` | what the container runs: `all` (Router and Relay), `router`, `relay` | `all` | `relay` |
| `ASPIA_RELAY_ROUTER_ADDRESS` | `relay.conf` `[router] address` (`ASPIA_ROLE=relay` only) | none (required for `relay`) | `router.example.com` |
| `ASPIA_RELAY_ROUTER_PORT` | `relay.conf` `[router] port` (`ASPIA_ROLE=relay` only) | `8063` | `8063` |
| `ASPIA_RELAY_ROUTER_PUBLIC_KEY` / `..._FILE` | `relay.conf` `[router] public_key`: the Router's `relay.pub`, as a value or a file path (`ASPIA_ROLE=relay` only) | none (required for `relay`) | 64 hex digits |

Ports: `ASPIA_RELAY_PEER_PORT` matters most, because the Relay announces that port number to every client and host it serves; `docker-compose.yml` always publishes it as host port = container port, from the variable, so changing it changes both sides together. The same is true for the Router's ports.

`ASPIA_ROUTER_RELAY_ALLOWED_IPS`: with `ASPIA_ROLE=all` this image's own Relay reaches the Router over `127.0.0.1` (they run in the same container). If you set this variable, it must include `127.0.0.1`, or the container refuses to start with an explanation, rather than starting a Relay that can never connect to its own Router. With `ASPIA_ROLE=router` there is no such Relay and the rule does not apply.

Not configurable through a variable in this image: `router.conf`'s `[relay] port` (8063; `compose.router.yml` publishes it as 8063) and any `listen_interface` (a wrong value silently disables that listener, which does not fit "validate at startup, then fail clearly"). Edit `router.conf`/`relay.conf` directly for those; your edit is never overwritten by this image. There is also no variable for the initial administrator password: Aspia 3.x has no supported way to set it outside the Client (see docs/dev/FOLLOWUPS.md).

`docker run -e ASPIA_ROUTER_CONFIG_FILE=...`, `ASPIA_ROUTER_DB_FILE` and `ASPIA_RELAY_CONFIG_FILE` are the Aspia binaries' own variables for moving their files; this image's scripts do not yet follow them (they still read the default paths) and refuse to start rather than silently check the wrong file. See docs/dev/FOLLOWUPS.md.

### Security settings

The compose files and the Podman units start the container with few privileges. The same with `docker run`:

```shell
docker run -d --name aspia-server --restart unless-stopped \
  --cap-drop ALL --cap-add CHOWN --cap-add DAC_OVERRIDE --cap-add SETUID --cap-add SETGID --cap-add KILL \
  --security-opt no-new-privileges:true --read-only --pids-limit 128 \
  -e EXTERNAL_IP=203.0.113.10 \
  -p 8060:8060 -p 8061:8061 -p 8062:8062 -p 8065:8065/udp -p 8070:8070 \
  -v "$PWD/data/config:/etc/aspia" -v "$PWD/data/database:/var/lib/aspia" \
  ghcr.io/<owner>/aspia-server:3.0.21
```

All other capabilities are dropped, no process can gain privileges (setuid programs do not work), the image's own files are read-only (only the two volumes are written), and the container may have at most 128 processes and threads (it uses fewer than 30). The capabilities that stay:

- `CHOWN`: give the volumes to `PUID`/`PGID`, and keep the owner of a backup copy.
- `DAC_OVERRIDE`: read and write files of another user (a host directory, an earlier `PUID`/`PGID` install), and let the health check read the configuration under `PUID`/`PGID`.
- `SETUID`, `SETGID`: switch to `PUID`/`PGID`.
- `KILL`: pass `docker stop` on to the processes running as `PUID`/`PGID`.
- `NET_BIND_SERVICE` (Podman units only): Podman treats ports below 1024 as privileged; with Docker and `--network host`, such a port needs `--cap-add NET_BIND_SERVICE`.

For the simplest setup (no `PUID`/`PGID`, volumes owned by root) none of the five is needed: remove the `--cap-add` lines (`cap_add:` in a compose file). Details and measurements: [docs/dev/UPSTREAM-3.x-NOTES.md](docs/dev/UPSTREAM-3.x-NOTES.md), section 20.

### Running a Relay on a separate host

The same image runs the Router alone (`ASPIA_ROLE=router`) or a Relay alone (`ASPIA_ROLE=relay`), so a Relay can sit on another machine, closer to a group of users, or take the relayed traffic off the Router's machine. One Router accepts at most five Relays at a time (an Aspia limit). Without `ASPIA_ROLE` nothing changes: the default `all` is the combined container described above.

Which port must be open from where:

| Port | On | Reachable from |
|---|---|---|
| 8060/tcp, 8061/tcp | Router host | Aspia hosts (2.x on 8060, 3.x on 8061), as before |
| 8062/tcp, 8065/udp | Router host | Aspia clients (and hosts, for STUN), as before |
| 8063/tcp | Router host | **only the Relay hosts** |
| 8070/tcp | each Relay host | the clients and hosts that use this Relay |

```
clients, hosts --8060-8062/tcp, 8065/udp--> Router host
clients, hosts --8070/tcp-----------------> Relay host --8063/tcp (outgoing)--> Router host
```

**On the Router host**

1. Switch to `compose.router.yml`. It uses the same `./data` and `.env` as `docker-compose.yml`, so the keys stay the same and hosts and clients need no change: `docker compose -f docker-compose.yml down`, then `docker compose -f compose.router.yml up -d` (add `--build` when you build locally). To keep a Relay on the Router host too, keep `docker-compose.yml` instead and add `"8063:8063"` to its `ports:`; then `ASPIA_ROUTER_RELAY_ALLOWED_IPS` (step 3) must also contain `127.0.0.1`.
2. Copy the key for Relays: the Router prints it at startup as `Public key for relays` (`docker logs aspia-router`), and it is the file `./data/config/relay.pub`. It is not the key for hosts (`host.pub`); after an upgrade from 2.x both are the old `router.pub`.
3. Allow only your Relays: set `ASPIA_ROUTER_RELAY_ALLOWED_IPS` in `.env` to their addresses as the Router sees them (a Relay behind NAT shows up with its NAT's public address), comma-separated, and recreate the container (`up -d` again). **By default the Router accepts a Relay from any address that reaches 8063 and has the key from step 2**; the Router's startup log says so in a `WARNING` until the variable is set. A refused Relay is not logged by the Router at the default log level.
4. Firewall: allow 8063/tcp from the Relay hosts only. The other Router ports stay as they were.

**On each Relay host**

1. Put `compose.relay.yml` (or a checkout of this repository) in a directory, with a `.env` that sets `ASPIA_RELAY_ROUTER_ADDRESS` (the Router's address as seen from this host), `ASPIA_RELAY_ROUTER_PUBLIC_KEY` (the key from step 2), `EXTERNAL_IP` (this Relay's public address, announced to clients and hosts) and `ASPIA_IMAGE` (the published image, pinned: `ASPIA_IMAGE=ghcr.io/<owner>/aspia-server:3.0.21`). Instead of the key itself you can mount the Router's `relay.pub` and set `ASPIA_RELAY_ROUTER_PUBLIC_KEY_FILE`; the compose file shows how. With `PUID`/`PGID`, mount that file outside `/etc/aspia` and `/var/lib/aspia` (as the compose file does): the container re-owns both volumes and refuses to start if the key file is inside them. `ASPIA_RELAY_ROUTER_PORT` is needed only if the Router's port for Relays is not 8063.
2. `docker compose -f compose.relay.yml pull && docker compose -f compose.relay.yml up -d`. A missing required setting stops the container with one message that names it. Under Podman use `podman/aspia-relay.container` ([podman/README.md](podman/README.md), section 11).
3. Firewall: allow 8070/tcp in from the clients and hosts; this host must be able to connect out to the Router's 8063/tcp.

**Check that the Relay registered**

- Relay: `docker logs aspia-relay` shows `Connection to the router is established`, and the container becomes `healthy` (healthy = listening on 8070 and connected to the Router).
- Router: `docker logs aspia-router 2>&1 | grep -E 'New relay session|Received key pool'` shows the Relay's address, for example `New relay session: "198.51.100.20"` and `"[Relay#1]" Received key pool: 100 ( "198.51.100.20" )`. In the 3.x Client, Router management has a Relays list (from upstream's source; not checked with the Client here).
- If the Relay does not connect, it retries every 15 seconds, stays running and unhealthy, and its log says why: `ACCESS_DENIED` = wrong key (`host.pub` instead of `relay.pub`?); `SPECIFIED_HOST_NOT_FOUND` = the Router's name does not resolve; `CONNECTION_REFUSED` = nothing listens on that address and port (8063 not published?); `SOCKET_TIMEOUT` (after 30 s) = packets are dropped, usually by a firewall; `REMOTE_HOST_CLOSED` right after connecting = the Router refused it (`ASPIA_ROUTER_RELAY_ALLOWED_IPS`, or five Relays already connected). When the Router comes back, the Relay reconnects on its own.
- A Relay can be connected and still unused: if the Router rejects its public address, only the Router log says so (`Ignoring key pool with invalid peer endpoint`). This image checks the address format before starting, which rules out the cases known to cause it.

### Upgrading from 2.x

Stop the old container, put this repository's `docker-compose.yml` next to your `./data` directory, set `EXTERNAL_IP` in `.env`, and start it. Keep the volume paths: `./data/config` -> `/etc/aspia`, `./data/database` -> `/var/lib/aspia`.

The compose file builds the image from this repository by default:

```shell
docker compose up -d --build
```

To run a published image instead, set `ASPIA_IMAGE` in `.env`, pinned to a version or a digest (for example `ASPIA_IMAGE=ghcr.io/<owner>/aspia-server:3.0.21`), then run `docker compose pull` and `docker compose up -d`, without `--build`: with `--build`, compose would build locally and give the result the published name.

What happens to your data on the first start:

- Before anything is changed, the container copies `router.json`, `relay.json` and `router.db3` to `<file>.pre-3.0.21-<UTC time>` next to the originals. Nothing is deleted.
- Aspia 3.x converts its configuration itself: `router.json` becomes `router.conf`, `relay.json` becomes `relay.conf`, and the old files are renamed to `*.json.bak`. The database `router.db3` is upgraded in place; Aspia 2.7.0 may not be able to read it afterwards.
- Users and hosts are kept. The Router keeps its 2.x key, so hosts configured with the key from `router.pub` keep working. The key is printed in the log as "Public key for hosts". The container copies `router.pub` to `host.pub` and `relay.pub`, the 3.x names of the key files; `router.pub` is kept.
- Not carried over: `AdminWhiteList` (3.x has no equivalent) and the Relay statistics settings.
- `EXTERNAL_IP`/`ASPIA_RELAY_PUBLIC_ADDRESS` is written into the Relay configuration on every start. On the migration start itself, any of `ASPIA_ROUTER_LEGACY_PORT` and the three `ASPIA_ROUTER_*_ALLOWED_IPS`, `ASPIA_RELAY_PEER_PORT`, `ASPIA_RELAY_IDLE_TIMEOUT` or `ASPIA_RELAY_MAX_PEERS` that are set are written into `router.json`/`relay.json` before the binaries convert them, because those are the fields the upstream migration itself carries over. The other `ASPIA_ROUTER_*` port and STUN variables have no 2.x equivalent field, so they take effect starting from the *second* start (once `router.conf` exists).

Open these additional ports in your firewall: **8061/tcp**, **8062/tcp** and **8065/udp**. Port 8060 stays open for 2.x hosts.

Compatibility, per the upstream migration guide (https://aspia.org/docs/migration; not tested here, it needs GUI clients and hosts):

- Hosts of previous versions keep working; the minimum supported version is 2.6.0. They keep connecting on port 8060 and can be updated later.
- Recommended order: Router (this image), then Relay, then Clients and Hosts.
- The Console has been removed. Managing the Router, the address book and groups of computers need the 3.x Client. Old address books (`.aab`) are imported by hand in the Client ("Import Old Address Book…"). The guide does not say whether a 2.x Client or Console can connect to a 3.x Router.
- Two-factor authentication is mandatory in 3.x: at the first connection every user, including the administrator, is asked to enrol.

To go back to 2.7.0: stop the container, restore the `*.pre-3.0.21-*` copies over `router.json`, `relay.json` and `router.db3` (remove `router.conf`, `relay.conf`, `router.db3-wal` and `router.db3-shm`), and start the 2.7.0 image.

Do not run `aspia_router --check-update` / `--install-update` inside the container: an update installed there is lost when the container is recreated. Update by changing the image tag.

The project code is available under the GNU General Public License 3 - [Aspia Remote Control](https://github.com/dchapyshev/aspia "dchapyshev")

The main developer and author of the project is Dmitry Chapyshev - [dchapyshev](https://github.com/dchapyshev/ "dchapyshev")

Aspia Server Docker image maintainer - Dmitry Fox - [paprikkafox](https://github.com/paprikkafox/ "paprikkafox")
