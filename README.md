**English** | [Русский](docs/README.ru.md)

# Aspia Server in Docker (Router + Relay)

[![CI](../../actions/workflows/ci.yml/badge.svg)](../../actions/workflows/ci.yml) [![Publish](../../actions/workflows/publish.yml/badge.svg)](../../actions/workflows/publish.yml)

This repository builds a Docker image of the server part of [Aspia](https://aspia.org/), an open-source remote desktop system. The image runs the Aspia Router and the Aspia Relay, version 3.0.23.

## What this is, and what it is not

- This is unofficial packaging. The Aspia developers do not publish or support this image.
- Aspia is written by Dmitry Chapyshev. The image installs the official Router and Relay packages and checks their checksums. This project continues the Docker image for Aspia 2.x and builds on other people's work. See [Licence and credits](#licence-and-credits) at the end.
- This is not Aspia documentation. For the Router, the Relay, the Host and the Client, read the documentation on [aspia.org](https://aspia.org/documentation.html).
- The image does not update itself. You choose the version and you update by hand.

## Requirements

- A Linux server with an x86_64 (amd64) processor. There is no ARM image, because Aspia publishes no ARM packages for the server.
- Docker Engine 25.0 or later, with the Docker Compose plugin (the `docker compose` command). Use the [official Docker instructions](https://docs.docker.com/engine/install/).
- A public IP address or a DNS name for the server. The Hosts and the Clients must be able to reach it.
- The ports in the section [Ports](#ports) must be open in your firewall.
- The Aspia Client and the Aspia Host, version 3.x. Download them from the [Aspia releases](https://github.com/dchapyshev/aspia/releases).

The commands below need a user who can use Docker: `sudo`, or the [post-installation steps](https://docs.docker.com/engine/install/linux-postinstall/).

## Quick start

The image is published to the GitHub Container Registry as `ghcr.io/<owner>/aspia-server`. Here `<owner>` is the GitHub account that publishes this repository. It is the account name in the address of the repository: `https://github.com/<owner>/aspia-server-docker`. Replace `<owner>` in all commands below.

1. Create a directory for the server and download two files into it:

    ```shell
    mkdir aspia-server
    cd aspia-server
    curl -fsSLO https://raw.githubusercontent.com/<owner>/aspia-server-docker/main/docker-compose.yml
    curl -fsSL -o .env https://raw.githubusercontent.com/<owner>/aspia-server-docker/main/.env.example
    ```

2. Open the file `.env` in a text editor. The file already contains the line `EXTERNAL_IP=203.0.113.10`. This is only an example address. Replace it with the public address of the server. If you keep it, relayed sessions fail and nothing reports an error. Then set the image. The image must have an exact version tag:

    ```shell
    # .env
    EXTERNAL_IP=203.0.113.10
    ASPIA_IMAGE=ghcr.io/<owner>/aspia-server:3.0.23
    ```

    `EXTERNAL_IP` is the address that the Relay gives to the Clients and the Hosts. It can be an IP address or a DNS name. The value `auto` detects the public IP address at every start.

3. Open the ports from the section [Ports](#ports) in the firewall of the server.

4. Download the image and start the container:

    ```shell
    docker compose pull
    docker compose up -d
    ```

5. Check that the container is healthy. After a few seconds the status shows `(healthy)`:

    ```shell
    docker compose ps
    ```

To see the log:

```shell
docker compose logs aspia-server
```

The service in `docker-compose.yml` is named `aspia-server`. In `compose.router.yml` it is named `aspia-router`, and in `compose.relay.yml` it is named `aspia-relay`. If you use one of those files, use its name in every command of this document that has a service name.

The terms in this document:

| Term | Meaning |
|---|---|
| Router | The Aspia program that the Hosts and the Clients connect to. It keeps the users and the list of Hosts. |
| Relay | The Aspia program that carries a session when the Client and the Host cannot connect directly. |
| Host | The Aspia program on a computer that you want to control. |
| Client | The Aspia program that you use to connect to a Host and to manage the Router. |
| server | The machine where you run this image. |

The server keeps its data in the directory `data` next to `docker-compose.yml`:

| Directory on the server | Path in the container | Content |
|---|---|---|
| `./data/config` | `/etc/aspia` | Configuration files and keys |
| `./data/database` | `/var/lib/aspia` | The Router database |

Keep this directory. It holds the keys of the Router. If you lose the keys, you must configure every Host again.

## First login

### The public key for Hosts

A Host needs the address of the Router and the public key for Hosts. The container prints the key in its log at every start:

```shell
docker compose logs aspia-server | grep 'Public key for hosts'
```

The key is also in the file `host.pub`:

```shell
docker compose exec aspia-server cat /etc/aspia/host.pub
```

Do not use the key in `relay.pub` for Hosts. That key is only for Relays.

### Connect with the Client and change the password

On the first start the Router creates the user `admin` with the password `admin`. Change this password after the first login.

1. Install the Aspia Client. At its first start the Client asks for a master password. The password is mandatory and cannot be recovered.
2. Add the Router: enter the address of your server (the Router accepts Clients on port 8062), set "Access Level" to "Administrator", and log in as `admin` with the password `admin`.
3. Two-factor authentication is mandatory in Aspia 3.x. At the first login the Client asks you to set it up with an authenticator app.
4. Open the users of the Router and change the password of `admin`.

The Client documentation describes these steps: [Aspia Client](https://aspia.org/docs/client). Aspia 3.x has no command and no configuration setting for this password. You can change it only in the Client.

### Connect a Host

1. Install the Aspia Host on a computer.
2. In the settings of the Host, open the tab "Router". Enter the address of your server and the public key for Hosts.
3. The Router accepts Hosts of Aspia 3.x on port 8061.

A Host that connects for the first time appears in the Client in the section "Unapproved hosts". You can connect to it there. Approve the Host to store its settings. See [Aspia Host](https://aspia.org/docs/host) and [Aspia Client](https://aspia.org/docs/client).

## Ports

Publish every port with the same number on the server and in the container. The Relay gives its own port number to the Clients and the Hosts, so a different port on the server breaks relayed sessions. `docker-compose.yml` already does this.

| Port | Variable | Service | Purpose | Open to the internet |
|---|---|---|---|---|
| 8060/tcp | `ASPIA_ROUTER_LEGACY_PORT` | Router | Hosts of Aspia 2.x | Only if you still have Hosts of Aspia 2.x |
| 8061/tcp | `ASPIA_ROUTER_HOST_PORT` | Router | Hosts of Aspia 3.x | Yes |
| 8062/tcp | `ASPIA_ROUTER_CLIENT_PORT` | Router | Clients: the address book and the management of the Router | Yes, or only to the networks of your users |
| 8065/udp | `ASPIA_ROUTER_STUN_PORT` | Router | Built-in STUN server | Yes |
| 8070/tcp | `ASPIA_RELAY_PEER_PORT` | Relay | Clients and Hosts in a relayed session | Yes. On a Relay-only server this is the only port to open. |
| 8063/tcp | none | Router | Relays | No. `docker-compose.yml` does not publish it. Open it only to a Relay on another server (see [Running a Relay on a separate host](#running-a-relay-on-a-separate-host)). |

The port numbers are the defaults. A variable changes the port in the configuration file and the published port.

Docker adds its own firewall rules for published ports. Read [Docker and ufw](https://docs.docker.com/engine/network/packet-filtering-firewalls/#docker-and-ufw) if you use `ufw` on the server.

## Environment variables

Set the variables in the file `.env` next to `docker-compose.yml`. The file `.env.example` lists all of them with comments. The port variables are in the table in [Ports](#ports). The compose files take the published port from the same variable, so the port on the server and the port in the container stay equal. If you edit `ports:` yourself, keep them equal.

After a change, apply it:

```shell
docker compose up -d
```

The rules:

- A variable that is set is written to the configuration file at every start.
- A variable that is not set does not change the configuration file. Your own changes in `router.conf` and `relay.conf` stay.
- An empty value counts as not set. For example, `ASPIA_ROUTER_CLIENT_ALLOWED_IPS=` does not clear an existing list. To clear a list, edit `router.conf`.
- An invalid value stops the start. The container then restarts again and again (status `Restarting`). The log names the variable. Nothing is changed.

| Variable | Default | What it sets |
|---|---|---|
| `EXTERNAL_IP` | none, required | The public address that the Relay gives to the Clients and the Hosts. An IP address, a DNS name of at most 64 characters, or `auto`. |
| `ASPIA_RELAY_PUBLIC_ADDRESS` | none | The new name of `EXTERNAL_IP`, with the same effect. If both are set to different values, this one is used. |
| `ASPIA_RELAY_IDLE_TIMEOUT` | `5` | Minutes that the Relay keeps an idle connection. |
| `ASPIA_RELAY_MAX_PEERS` | `100` | The maximum number of Clients and Hosts that the Relay serves at the same time. |
| `ASPIA_ROUTER_STUN_ENABLED` | `1` | `1` turns the built-in STUN server on, `0` turns it off. |
| `ASPIA_ROUTER_CLIENT_ALLOWED_IPS`, `ASPIA_ROUTER_HOST_ALLOWED_IPS` | empty: all addresses | Addresses and subnets that may connect as Clients or as Hosts, separated by commas, for example `203.0.113.0/24`. |
| `ASPIA_ROUTER_RELAY_ALLOWED_IPS` | empty: all addresses | Addresses and subnets that may connect as Relays. With `ASPIA_ROLE=all` the list must contain `127.0.0.1`, because the Relay in the same container connects from that address. |
| `ASPIA_ROLE` | `all` | What the container runs: `all` (Router and Relay), `router` or `relay`. The compose files set it. Set it yourself only for `docker run --env-file` or Podman. See [Running a Relay on a separate host](#running-a-relay-on-a-separate-host). |
| `ASPIA_RELAY_ROUTER_ADDRESS` | none | Only for `ASPIA_ROLE=relay`, and required there: the address of the Router. |
| `ASPIA_RELAY_ROUTER_PORT` | `8063` | Only for `ASPIA_ROLE=relay`: the Router port for Relays. |
| `ASPIA_RELAY_ROUTER_PUBLIC_KEY` | none | Only for `ASPIA_ROLE=relay`, and required there: the content of the file `relay.pub` of the Router. |
| `ASPIA_RELAY_ROUTER_PUBLIC_KEY_FILE` | none | Only for `ASPIA_ROLE=relay`: the path of a file with that key, instead of the key itself. |
| `PUID`, `PGID` | `0` (root) | Run the Router and the Relay as this user ID and group ID. Set both or neither. The container changes the owner of `./data/config` and `./data/database` at every start. |
| `TZ` | `UTC` | The time zone of the timestamps in the log, for example `Europe/Berlin`. |
| `ASPIA_LOG_LEVEL` | `1` | The minimum log level: `0` TRACE, `1` INFO, `2` WARNING, `3` ERROR, `4` FATAL. |
| `ASPIA_IMAGE` | `aspia-server:3.0.23` | The image that `docker compose` runs. The default is the name of a local build. |

Some settings have no variable: the Router port for Relays (`[relay] port` in `router.conf`) and the listen addresses (`listen_interface`). Edit `router.conf` or `relay.conf` for them. The container never overwrites such a change. There is also no variable for the password of `admin` (see [First login](#first-login)).

`ASPIA_ROUTER_CONFIG_FILE`, `ASPIA_ROUTER_DB_FILE` and `ASPIA_RELAY_CONFIG_FILE` are variables of the Aspia programs. The compose files do not pass them to the container, so they have no effect in `.env`. This image does not support them yet. If you set one of them in the container yourself (`docker run` or Podman), the container does not start.

## Security settings

The compose files and the Podman units start the container with few privileges:

- All Linux capabilities are dropped, except five. The list is below.
- No process can gain new privileges. Programs with the setuid bit do not work. The Podman units do not set this (see below).
- The files of the image are read-only. The container writes only to its two volumes.
- The container can have at most 128 processes and threads. It uses fewer than 30.

The five capabilities that stay:

- `CHOWN`: give the volumes to `PUID`/`PGID`, and keep the owner of a backup copy.
- `DAC_OVERRIDE`: read and write files of another user, for example in a directory of a user on the server, or from an earlier start with `PUID`/`PGID`. With `PUID`/`PGID` the health check needs it to read the configuration.
- `SETUID`: switch to the user `PUID`.
- `SETGID`: switch to the group `PGID`.
- `KILL`: pass the stop signal to the processes that run as `PUID`/`PGID`.

The same settings with `docker run`:

```shell
docker run -d --name aspia-server --restart unless-stopped \
  --cap-drop ALL --cap-add CHOWN --cap-add DAC_OVERRIDE --cap-add SETUID --cap-add SETGID --cap-add KILL \
  --security-opt no-new-privileges:true --read-only --pids-limit 128 \
  -e EXTERNAL_IP=203.0.113.10 \
  -p 8060:8060 -p 8061:8061 -p 8062:8062 -p 8065:8065/udp -p 8070:8070 \
  -v "$PWD/data/config:/etc/aspia" -v "$PWD/data/database:/var/lib/aspia" \
  ghcr.io/<owner>/aspia-server:3.0.23
```

The simplest setup needs none of the five capabilities: no `PUID` and `PGID`, and the volumes belong to root. For this setup you can remove the `--cap-add` flags, or `cap_add:` in the compose file.

All default ports are above 1024. A port below 1024 needs the capability `NET_BIND_SERVICE`. Docker needs it only with host networking: add `--cap-add NET_BIND_SERVICE`. Podman always needs it: add `AddCapability=NET_BIND_SERVICE` to the unit.

The Podman units do not set `NoNewPrivileges`. On Ubuntu 24.04 AppArmor then blocks the stop signal, and the container does not stop cleanly. Docker is not affected. The measurements are in [docs/dev/UPSTREAM-3.x-NOTES.md](docs/dev/UPSTREAM-3.x-NOTES.md), section 21.

## Updating

The image never updates itself. You update by hand when you decide to.

1. Read the [Aspia changelog](https://aspia.org/changelog).
2. Make a backup (see [Backup and restore](#backup-and-restore)). A new version can convert the database, and an older version may not read it after that.
3. In `.env`, replace the version in the tag of `ASPIA_IMAGE` with the new version.
4. Download the image and create the container again, then check the status and the log, as in the [Quick start](#quick-start):

    ```shell
    docker compose pull
    docker compose up -d
    docker compose ps
    ```

To return to the old version, put the old tag into `.env` and run `docker compose up -d`. If the new version has converted the data, restore the backup too.

Do not run `aspia_router --check-update` or `aspia_router --install-update` in the container. An update that is installed in the container is lost when the container is created again.

### Tags and digests

The tag `3.0.23` moves with every publish: a push to `main` that changes the image, a manual run, and the weekly rebuild with the Debian security updates. The tag `3.0.23-YYYYMMDD`, for example `3.0.23-20261005`, never moves. Only the weekly rebuild, or a manual run with a dated tag, creates it. Short tags such as `3.0` move too. Do not use them on a server. [docs/ci.md](docs/ci.md) has the details and shows how to verify the signature of the image.

For an image that never changes, use its digest. Show the digests of the image that you have downloaded:

```shell
docker image inspect --format '{{range .RepoDigests}}{{println .}}{{end}}' ghcr.io/<owner>/aspia-server:3.0.23
```

If you pulled the image from both registries, the list also has a line that starts with `docker.io`. Use the line that starts with `ghcr.io`. It looks like `ghcr.io/<owner>/aspia-server@sha256:...`. Put it into `.env`:

```shell
# .env
ASPIA_IMAGE=ghcr.io/<owner>/aspia-server@sha256:2ff06f77e1e364bf03245bc5453646a62313a4b4dba0ae086c89446d4558d4a0
```

The digest in this example is only an example. The summary of each publish run on GitHub shows it too.

## Upgrading from 2.x

This section is for a server that runs the old image `paprikkafox/aspia-server` (version 2.7.0, usually with the tag `latest`) with a `docker-compose.yml` and a `data` directory. The image 3.0.23 keeps your users, Hosts and keys. The official [migration guide](https://aspia.org/docs/migration) covers the order of the updates, the Console, the address books and two-factor authentication.

1. Go to the directory of the old installation. Write down `EXTERNAL_IP` from the old `docker-compose.yml`: the old file sets it in the `environment:` list. Then stop the container:

    ```shell
    docker compose down
    ```

2. Make a backup of the old data and the old compose file:

    ```shell
    (umask 077; sudo tar -czf - data docker-compose.yml > aspia-2.7.0-backup.tar.gz)
    ```

3. Download the new files. The new `docker-compose.yml` replaces the old one, which is now in the backup:

    ```shell
    curl -fsSLO https://raw.githubusercontent.com/<owner>/aspia-server-docker/main/docker-compose.yml
    curl -fsSL -o .env https://raw.githubusercontent.com/<owner>/aspia-server-docker/main/.env.example
    ```

4. Set the image and the address in `.env`, open the ports, then download the image and start the container, as in the [Quick start](#quick-start). Use the `EXTERNAL_IP` from step 1. Keep 8060/tcp open for the Hosts of Aspia 2.x.

What happens on the first start:

- The container copies `router.json`, `relay.json` and `router.db3` to files with the suffix `.pre-3.0.23-<time>`, next to the originals.
- Aspia converts `router.json` to `router.conf` and `relay.json` to `relay.conf`. It renames the old files to `router.json.bak` and `relay.json.bak`.
- Aspia upgrades the database `router.db3`. Aspia 2.7.0 may not read it after that.
- The Router keeps its key, so Hosts that use the key from `router.pub` keep working. The container copies `router.pub` to `host.pub` and `relay.pub`, the file names of Aspia 3.x.
- Two settings are not carried over: the administrator allow-list (`AdminWhiteList`; Aspia 3.x has no such setting) and the Relay statistics settings.
- These variables take effect only from the second start: `ASPIA_ROUTER_CLIENT_PORT`, `ASPIA_ROUTER_HOST_PORT`, `ASPIA_ROUTER_STUN_PORT` and `ASPIA_ROUTER_STUN_ENABLED`. If you set any of them, run `docker compose restart` after the first start.

To return to 2.7.0, stop the container, restore the backup from step 2 as in [Backup and restore](#backup-and-restore), and start the old version. The backup contains the old `docker-compose.yml`.

## Backup and restore

The directory `data` holds everything: the configuration, the keys and the database. Stop the container before the backup, so that the database files are complete.

The files in `data` belong to root (or to `PUID`, if you set it), so `tar` runs with `sudo`. Your own shell creates the archive file, so you own it and can copy it. The archive contains private keys. The command `umask 077` makes it readable only by you:

```shell
docker compose stop
(umask 077; sudo tar -czf - data .env docker-compose.yml > aspia-backup-$(date +%Y%m%d-%H%M%S).tar.gz)
docker compose start
```

If you use `compose.router.yml`, add it to the list of files. On a Relay server the list is `data .env compose.relay.yml`. To restore, use the name of your backup file:

```shell
docker compose down
sudo mv data data.old-$(date +%Y%m%d-%H%M%S)
sudo tar -xzf aspia-backup-20261002-114739.tar.gz
docker compose up -d
```

Store the backup on another machine.

## Running a Relay on a separate host

The same image can run the Router alone (`ASPIA_ROLE=router`) or a Relay alone (`ASPIA_ROLE=relay`). A Relay on another server carries the relayed traffic instead of the Router server. One Router accepts at most five Relays at the same time. Without `ASPIA_ROLE` the default `all` runs the Router and the Relay in one container. The [Ports](#ports) table shows which port each server needs.

### On the Router server

These steps run the Router alone from `compose.router.yml`. To keep the Router and a local Relay in one container, see [Alternative: keep the combined container](#alternative-keep-the-combined-container).

1. Download `compose.router.yml` into the directory of the server. It uses the same `data` directory and the same `.env` as `docker-compose.yml`. The keys stay the same, so the Hosts and the Clients need no change.

    ```shell
    curl -fsSLO https://raw.githubusercontent.com/<owner>/aspia-server-docker/main/compose.router.yml
    ```

2. Stop the combined container. Then make `compose.router.yml` the file that `docker compose` uses in this directory, and start the Router alone:

    ```shell
    docker compose down
    echo 'COMPOSE_FILE=compose.router.yml' >> .env
    docker compose up -d
    ```

    Plain `docker compose` commands now act on `compose.router.yml`. Add this file to your backup.

3. Get the public key for Relays. The Router prints it in the log as `Public key for relays`. It is also in the file `./data/config/relay.pub`.

    ```shell
    docker compose logs aspia-router | grep 'Public key for relays'
    ```

    On a new installation this key differs from the key for Hosts. After an upgrade from 2.x both keys are the old `router.pub`.

4. Allow only your Relays. In `.env`, set the addresses of the Relays as the Router sees them. A Relay behind NAT has the public address of its NAT. Then apply the change:

    ```shell
    # .env
    ASPIA_ROUTER_RELAY_ALLOWED_IPS=203.0.113.20
    ```

    ```shell
    docker compose up -d
    ```

    Without this variable the Router accepts a Relay from any address that can reach port 8063 and has the key from step 3. The log of the Router shows a `WARNING` about this until you set the variable.

5. In the firewall, allow 8063/tcp only from the Relay servers.

### Alternative: keep the combined container

Use this if the Router server should keep its own Relay and also accept Relays from other servers. Keep `docker-compose.yml` and do not download `compose.router.yml`. The service is `aspia-server`. The differences from the steps above:

- Add `"8063:8063"` to the `ports:` list of `docker-compose.yml`.
- Get the public key for Relays as in step 3.
- In step 4 the list must also contain `127.0.0.1`, because the Relay in the same container connects from that address. For example `ASPIA_ROUTER_RELAY_ALLOWED_IPS=127.0.0.1,203.0.113.20`.
- Run `docker compose up -d` to apply the changes.
- Do step 5 as it is.

### On each Relay server

1. Create a directory and download `compose.relay.yml`:

    ```shell
    mkdir aspia-relay
    cd aspia-relay
    curl -fsSLO https://raw.githubusercontent.com/<owner>/aspia-server-docker/main/compose.relay.yml
    ```

2. Create a file `.env` in this directory with these lines. Use the address of your Router, the public address of this Relay server and the public key for Relays that you got on the Router server. `COMPOSE_FILE` makes plain `docker compose` commands act on `compose.relay.yml`:

    ```shell
    # .env
    COMPOSE_FILE=compose.relay.yml
    ASPIA_IMAGE=ghcr.io/<owner>/aspia-server:3.0.23
    EXTERNAL_IP=203.0.113.20
    ASPIA_RELAY_ROUTER_ADDRESS=203.0.113.10
    ASPIA_RELAY_ROUTER_PUBLIC_KEY=047d0004a25c7f61e501c3eadc701732ca94c6a2fb035b4935caf7da7b27c555
    ```

    The key in this example is only an example. Instead of the key itself, you can give the path of a copy of `relay.pub` in `ASPIA_RELAY_ROUTER_PUBLIC_KEY_FILE`. The comments in `compose.relay.yml` show how to mount the file.

3. Start the Relay:

    ```shell
    docker compose pull
    docker compose up -d
    ```

    If a required setting is missing, the start fails with a message that names it. The container then restarts again and again.

4. In the firewall, allow 8070/tcp from the Clients and the Hosts.

### Check that the Relay is registered

On the Relay server:

```shell
docker compose ps
docker compose logs aspia-relay | grep 'Connection to the router'
```

The status is `(healthy)` when the Relay listens on 8070 and is connected to the Router. The log shows `Connection to the router is established`.

On the Router server:

```shell
docker compose logs aspia-router | grep -E 'New relay session|Received key pool'
```

The log shows the address of the Relay, for example `New relay session: "203.0.113.20"`.

If the Relay does not connect, it tries again every 15 seconds. Its log shows the reason:

| Message in the Relay log | Cause |
|---|---|
| `ACCESS_DENIED` | Wrong key. Use `relay.pub` of the Router, not `host.pub`. |
| `SPECIFIED_HOST_NOT_FOUND` | The DNS name of the Router does not resolve. |
| `CONNECTION_REFUSED` | Nothing listens on that address and port. Check that port 8063 is published on the Router server. |
| `SOCKET_TIMEOUT` | A firewall drops the packets. The message comes after 30 seconds. |
| `REMOTE_HOST_CLOSED` | The Router refused the Relay. The message comes immediately after the connection. The address of the Relay is not in `ASPIA_ROUTER_RELAY_ALLOWED_IPS`, or five Relays are already connected. |

A connected Relay can still stay unused. If the Router does not accept the public address of the Relay, only the Router log shows it: `Ignoring key pool with invalid peer endpoint`.

## Podman

To run the server under Podman as a systemd service (Quadlet), read [podman/README.md](podman/README.md).

## Building locally

You can build the image yourself instead of using the published one. The build downloads the Aspia packages from the official releases and checks them against the checksums in `versions.env`.

```shell
git clone https://github.com/<owner>/aspia-server-docker.git
cd aspia-server-docker
cp .env.example .env
```

Set `EXTERNAL_IP` in `.env`, and leave `ASPIA_IMAGE` unset. Then build and start. The image gets the name `aspia-server:3.0.23`:

```shell
docker compose up -d --build
```

To update a local build, run `git pull` and then the same command again. Do not use `--build` when `ASPIA_IMAGE` is set, and check the output of `docker compose pull` for errors: if the pull fails, `docker compose up -d` builds the image locally under the name of the published image.

The tests and the CI are described in [docs/ci.md](docs/ci.md).

## Troubleshooting

| Symptom | What to do |
|---|---|
| The container restarts again and again (status `Restarting`). The log says `ERROR: ASPIA_RELAY_PUBLIC_ADDRESS is not set`. | Set `EXTERNAL_IP` in `.env`. Then run `docker compose up -d`. |
| The container restarts again and again. The log names another variable. | Correct the value of that variable in `.env`. Then run `docker compose up -d`. |
| `docker compose pull` says `no matching manifest for linux/arm64`. | The server has an ARM processor. The image exists only for x86_64. |
| `EXTERNAL_IP=auto` stops the start with an error about the detection. | The server cannot reach the internet services that report its address. Set the address by hand. |
| The log shows `sd_login_monitor_new failed` or `Unable to install signal handler for SIGKILL`. | No action needed. These lines are normal in a container. |
| The status is `(unhealthy)`. | Read the log: `docker compose logs aspia-server`. Healthy means that the Router listens on its ports and the Relay is connected to the Router. |
| A Host does not connect. | Check that port 8061/tcp (8060/tcp for Aspia 2.x) is open. Check that the Host uses the key from `host.pub`, not from `relay.pub`. |
| The Client does not connect to the Router. | Check that port 8062/tcp is open. If `ASPIA_ROUTER_CLIENT_ALLOWED_IPS` is set, check that it contains the address of the Client. |
| Sessions work only in the local network, or relayed sessions fail. | Check that port 8070/tcp is open and that `EXTERNAL_IP` is the public address of the server, not the example address. The port on the server must be the same as in the container. |
| A user lost the authenticator app. | Reset the two-factor authentication of that user (see below). |
| You forgot the password of `admin`. | Another administrator can change it in the Client. Aspia 3.x has no command to set a password. |
| The Aspia 2.x Console does not work with the new Router. | The Console is removed in Aspia 3.x. Use the Client of Aspia 3.x. |
| The time in the log is wrong. | Set `TZ` in `.env`, for example `TZ=Europe/Berlin`. Then run `docker compose up -d`. |
| `Permission denied` when you read files in `data`. | The files belong to root (or to `PUID`). Use `sudo`. |
| A Relay on another server does not register. | See [Check that the Relay is registered](#check-that-the-relay-is-registered). |

To reset the two-factor authentication of a user, run these commands. Replace `admin` with the user name:

```shell
docker compose exec aspia-server aspia_router --reset-otp admin
docker compose restart
```

## Licence and credits

This repository is licensed under the GNU General Public License v3.0: see [LICENSE](LICENSE). Aspia is licensed under the GNU General Public License v3.0 too.

Thanks to:

- Dmitry Chapyshev ([dchapyshev](https://github.com/dchapyshev)) for Aspia: [dchapyshev/aspia](https://github.com/dchapyshev/aspia).
- Dmitry Fox ([paprikkafox](https://github.com/paprikkafox)) for the original aspia-server Docker image: [paprikkafox/aspia-server-docker](https://github.com/paprikkafox/aspia-server-docker).
- [SinitsaDA](https://github.com/SinitsaDA) for [SinitsaDA/aspia-server-docker](https://github.com/SinitsaDA/aspia-server-docker) (GPL-3.0). The 3.x image of this project was ported from its 3.x server image, its handling of the 2.x migration and its health check that opens no connections.

The work on this repository was done with the help of Claude, the AI assistant by Anthropic, used through Claude Code.
