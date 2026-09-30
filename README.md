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

`EXTERNAL_IP` is required: the public address the Relay announces. Without it the container exits with an error. With docker compose, put `EXTERNAL_IP=<address>` into a `.env` file next to `docker-compose.yml`.

The Aspia log goes to `docker logs`; no log files are written.

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
- `EXTERNAL_IP` is written into the Relay configuration on every start.

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
