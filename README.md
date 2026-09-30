# Сервер Aspia (Relay + Router)
### Текущая версия (Current version) - 3.0.21

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

### Ports

Publish every port one-to-one (host port = container port): the Relay announces its own port to clients and hosts.

| Port | Used by |
|---|---|
| 8060/tcp | Router: hosts of Aspia 2.x |
| 8061/tcp | Router: hosts of Aspia 3.x |
| 8062/tcp | Router: clients (address book and Router management) |
| 8065/udp | Router: built-in STUN server |
| 8070/tcp | Relay: clients and hosts |
| 8063/tcp | Router: Relays. Used inside the container; publish it only for a Relay on another machine. |

`EXTERNAL_IP` (or its new name, `ASPIA_RELAY_PUBLIC_ADDRESS`) is required: the public address the Relay announces. Without one of them, `docker compose config`/`up` fails with a clear error, and a plain `docker run` container exits the same way. With docker compose, put it into a `.env` file next to `docker-compose.yml`; see `.env.example` for every variable and the "Configuration" section below.

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

Ports: `ASPIA_RELAY_PEER_PORT` matters most, because the Relay announces that port number to every client and host it serves; `docker-compose.yml` always publishes it as host port = container port, from the variable, so changing it changes both sides together. The same is true for the Router's ports.

`ASPIA_ROUTER_RELAY_ALLOWED_IPS`: this image's own Relay always reaches the Router over `127.0.0.1` (they run in the same container). If you set this variable, it must include `127.0.0.1`, or the container refuses to start with an explanation, rather than starting a Relay that can never connect to its own Router.

Not configurable through a variable in this image: `router.conf`'s internal `[relay] port` (8063, used only between the Router and the Relay inside this container; there is nothing on the host to publish it for) and any `listen_interface` (a wrong value silently disables that listener, which does not fit "validate at startup, then fail clearly"). Edit `router.conf`/`relay.conf` directly for those; your edit is never overwritten by this image. There is also no variable for the initial administrator password: Aspia 3.x has no supported way to set it outside the Client (see docs/dev/FOLLOWUPS.md).

`docker run -e ASPIA_ROUTER_CONFIG_FILE=...`, `ASPIA_ROUTER_DB_FILE` and `ASPIA_RELAY_CONFIG_FILE` are the Aspia binaries' own variables for moving their files; this image's scripts do not yet follow them (they still read the default paths) and refuse to start rather than silently check the wrong file. See docs/dev/FOLLOWUPS.md.

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
