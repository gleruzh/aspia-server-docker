**English** | [Русский](docs/README.ru.md)

# Aspia Server in Docker (Router + Relay)

[![CI](../../actions/workflows/ci.yml/badge.svg)](../../actions/workflows/ci.yml) [![Publish](../../actions/workflows/publish.yml/badge.svg)](../../actions/workflows/publish.yml)

This repository builds a Docker image of the server part of [Aspia](https://aspia.org/), an open-source remote desktop system. The image runs the Aspia Router and the Aspia Relay, version 3.0.21.

## What this is, and what it is not

- This is unofficial packaging. The Aspia developers do not publish or support this image.
- Aspia itself is written by Dmitry Chapyshev: [dchapyshev/aspia](https://github.com/dchapyshev/aspia). The image installs the Router and Relay packages from the official Aspia releases and checks their checksums.
- The original Docker image of the Aspia server (Aspia 2.x) is by Dmitry Fox: [paprikkafox/aspia-server-docker](https://github.com/paprikkafox/aspia-server-docker). This project continues it for Aspia 3.x.
- This is not Aspia documentation. For the Router, the Relay, the Host and the Client, read the documentation on [aspia.org](https://aspia.org/documentation.html).
- The image does not update itself. You choose the version and you update by hand.

The terms in this document:

| Term | Meaning |
|---|---|
| Router | The Aspia program that the Hosts and the Clients connect to. It keeps the users and the list of Hosts. |
| Relay | The Aspia program that carries a session when the Client and the Host cannot connect directly. |
| Host | The Aspia program on a computer that you want to control. |
| Client | The Aspia program that you use to connect to a Host and to manage the Router. |
| server | The machine where you run this image. |

## Requirements

- A Linux server with an x86_64 (amd64) processor. Aspia publishes no ARM packages for the Router and the Relay, so there is no ARM image.
- Docker Engine 25.0 or later, with the Docker Compose plugin (the `docker compose` command). Install them with the [official Docker instructions](https://docs.docker.com/engine/install/). The image health check uses an option that needs Docker Engine 25.0.
- A public IP address or a DNS name for the server. The Hosts and the Clients must be able to reach it.
- The ports in the section [Ports](#ports) must be open in your firewall.
- The Aspia Client and the Aspia Host, version 3.x. Download them from the [Aspia releases](https://github.com/dchapyshev/aspia/releases).

The commands below run as a user who can use Docker. On a default Docker installation this needs `sudo`, or the steps in [Linux post-installation steps for Docker Engine](https://docs.docker.com/engine/install/linux-postinstall/).

## Quick start

The image is published to the GitHub Container Registry as `ghcr.io/<owner>/aspia-server`. Here `<owner>` is the GitHub account that publishes this repository. It is the account name in the address of the repository: `https://github.com/<owner>/aspia-server-docker`. Replace `<owner>` in all commands below.

1. Create a directory for the server and download two files into it:

    ```shell
    mkdir aspia-server
    cd aspia-server
    curl -fsSLO https://raw.githubusercontent.com/<owner>/aspia-server-docker/main/docker-compose.yml
    curl -fsSL -o .env https://raw.githubusercontent.com/<owner>/aspia-server-docker/main/.env.example
    ```

2. Open the file `.env` in a text editor. Set the public address of the server and the image. The image must have an exact version tag:

    ```shell
    EXTERNAL_IP=203.0.113.10
    ASPIA_IMAGE=ghcr.io/<owner>/aspia-server:3.0.21
    ```

    `EXTERNAL_IP` is required. It is the address that the Relay gives to the Clients and the Hosts. It can be an IP address or a DNS name. The value `auto` detects the public IP address at every start.

3. Download the image and start the container:

    ```shell
    docker compose pull
    docker compose up -d
    ```

4. Check that the container is healthy. After a few seconds the status shows `(healthy)`:

    ```shell
    docker compose ps
    ```

The server keeps its data in the directory `data` next to `docker-compose.yml`:

| Directory on the server | Path in the container | Content |
|---|---|---|
| `./data/config` | `/etc/aspia` | Configuration files and keys |
| `./data/database` | `/var/lib/aspia` | The Router database |

Keep this directory. It holds the keys of the Router. If you lose the keys, you must configure every Host again.

To see the log:

```shell
docker compose logs aspia-server
```

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

On the first start the Router creates the user `admin` with the password `admin`. Change this password right after the first login.

1. Install the Aspia Client.
2. Add the Router in the Client. Use the address of your server. The Router accepts Clients on port 8062.
3. Log in as `admin` with the password `admin`.
4. Two-factor authentication is mandatory in Aspia 3.x. At the first login the Client asks you to set it up with an authenticator app.
5. Open the users of the Router and change the password of `admin`.

The Client documentation describes these steps: [Aspia Client](https://aspia.org/docs/client), section "Connection to a Router" and section "Users". Aspia 3.x has no command and no configuration setting for this password. You can change it only in the Client.

### Connect a Host

1. Install the Aspia Host on a computer.
2. In the settings of the Host, open the tab "Router". Enter the address of your server and the public key for Hosts.
3. The Router accepts Hosts of Aspia 3.x on port 8061.

A Host that connects for the first time appears in the Client in the section "Unapproved hosts". The Host documentation is here: [Aspia Host](https://aspia.org/docs/host), section "Router tab". The approval of Hosts is described in [Aspia Client](https://aspia.org/docs/client), section "Unapproved hosts".

## Ports

Publish every port with the same number on the server and in the container. The Relay gives its own port number to the Clients and the Hosts, so a different port on the server breaks relayed sessions. `docker-compose.yml` already does this.

| Port | Service | Purpose | Open to the internet |
|---|---|---|---|
| 8060/tcp | Router | Hosts of Aspia 2.x | Only if you still have Hosts of Aspia 2.x |
| 8061/tcp | Router | Hosts of Aspia 3.x | Yes |
| 8062/tcp | Router | Clients: the address book and the management of the Router | Yes, or only to the networks of your users |
| 8065/udp | Router | Built-in STUN server | Yes |
| 8070/tcp | Relay | Clients and Hosts in a relayed session | Yes |
| 8063/tcp | Router | Relays | No. `docker-compose.yml` does not publish it. Open it only to a Relay on another server (see [Running a Relay on a separate host](#running-a-relay-on-a-separate-host)). |

Docker adds its own firewall rules for published ports. Read [Docker and ufw](https://docs.docker.com/engine/network/packet-filtering-firewalls/#docker-and-ufw) if you use `ufw` on the server.

## Environment variables

Set the variables in the file `.env` next to `docker-compose.yml`. The file `.env.example` lists all of them with comments. After a change, apply it:

```shell
docker compose up -d
```

The rules:

- A variable that is set is written to the configuration file at every start.
- A variable that is not set does not change the configuration file. Your own changes in `router.conf` and `relay.conf` stay.
- An empty value counts as not set. For example, `ASPIA_ROUTER_CLIENT_ALLOWED_IPS=` does not clear an existing list. To clear a list, edit `router.conf`.
- An invalid value stops the container. The log names the variable. Nothing is changed.
- `docker-compose.yml` takes the port on the server and the port in the container from the same variable. If you change a port variable, the published port changes too.

| Variable | Default | What it sets |
|---|---|---|
| `EXTERNAL_IP` | none, required | The public address that the Relay gives to the Clients and the Hosts (`relay.conf`, `[peer] public_address`). An IP address, a DNS name of at most 64 characters, or `auto`. |
| `ASPIA_RELAY_PUBLIC_ADDRESS` | none | The new name of `EXTERNAL_IP`, with the same effect. If both are set to different values, this one is used. |
| `ASPIA_RELAY_PEER_PORT` | `8070` | The Relay port for Clients and Hosts (`relay.conf`, `[peer] port`). |
| `ASPIA_RELAY_IDLE_TIMEOUT` | `5` | Minutes that the Relay keeps an idle connection (`relay.conf`, `[peer] idle_timeout`). |
| `ASPIA_RELAY_MAX_PEERS` | `100` | The maximum number of Clients and Hosts that the Relay serves at the same time (`relay.conf`, `[peer] max_count`). |
| `ASPIA_ROUTER_HOST_PORT` | `8061` | The Router port for Hosts of Aspia 3.x (`router.conf`, `[host] port`). |
| `ASPIA_ROUTER_LEGACY_PORT` | `8060` | The Router port for Hosts of Aspia 2.x (`router.conf`, `[host] legacy_port`). |
| `ASPIA_ROUTER_CLIENT_PORT` | `8062` | The Router port for Clients (`router.conf`, `[client] port`). |
| `ASPIA_ROUTER_STUN_ENABLED` | `1` | `1` turns the built-in STUN server on, `0` turns it off (`router.conf`, `[stun] enabled`). |
| `ASPIA_ROUTER_STUN_PORT` | `8065` | The UDP port of the STUN server (`router.conf`, `[stun] port`). |
| `ASPIA_ROUTER_CLIENT_ALLOWED_IPS` | empty: all addresses | Addresses and subnets that may connect as Clients, separated by commas, for example `203.0.113.0/24` (`router.conf`, `[client] white_list`). |
| `ASPIA_ROUTER_HOST_ALLOWED_IPS` | empty: all addresses | Addresses and subnets that may connect as Hosts (`router.conf`, `[host] white_list`). |
| `ASPIA_ROUTER_RELAY_ALLOWED_IPS` | empty: all addresses | Addresses and subnets that may connect as Relays (`router.conf`, `[relay] white_list`). With `ASPIA_ROLE=all` the list must contain `127.0.0.1`, because the Relay in the same container connects from that address. |
| `ASPIA_ROLE` | `all` | What the container runs: `all` (Router and Relay), `router` or `relay`. See [Running a Relay on a separate host](#running-a-relay-on-a-separate-host). |
| `ASPIA_RELAY_ROUTER_ADDRESS` | none | Only for `ASPIA_ROLE=relay`, and required there: the address of the Router (`relay.conf`, `[router] address`). |
| `ASPIA_RELAY_ROUTER_PORT` | `8063` | Only for `ASPIA_ROLE=relay`: the Router port for Relays (`relay.conf`, `[router] port`). |
| `ASPIA_RELAY_ROUTER_PUBLIC_KEY` | none | Only for `ASPIA_ROLE=relay`, and required there: the content of the file `relay.pub` of the Router (`relay.conf`, `[router] public_key`). |
| `ASPIA_RELAY_ROUTER_PUBLIC_KEY_FILE` | none | Only for `ASPIA_ROLE=relay`: the path of a file with that key, instead of the key itself. |
| `PUID`, `PGID` | `0` (root) | Run the Router and the Relay as this user ID and group ID. Set both or neither. The container changes the owner of `./data/config` and `./data/database` at every start. |
| `TZ` | `UTC` | The time zone of the timestamps in the log, for example `Europe/Berlin`. |
| `ASPIA_LOG_LEVEL` | `1` | The minimum log level: `0` TRACE, `1` INFO, `2` WARNING, `3` ERROR, `4` FATAL. |
| `ASPIA_IMAGE` | `aspia-server:3.0.21` | The image that `docker compose` runs. The default is the name of a local build. |

Some settings have no variable: the Router port for Relays (`router.conf`, `[relay] port`) and the listen addresses (`listen_interface`). Edit `router.conf` or `relay.conf` for them. The container never overwrites such a change. There is also no variable for the password of `admin` (see [First login](#first-login)).

`ASPIA_ROUTER_CONFIG_FILE`, `ASPIA_ROUTER_DB_FILE` and `ASPIA_RELAY_CONFIG_FILE` are variables of the Aspia programs. This image does not support them yet. If one of them is set, the container does not start.

## Updating

The image never updates itself. You update by hand when you decide to.

1. Read the [Aspia changelog](https://aspia.org/changelog).
2. Make a backup (see [Backup and restore](#backup-and-restore)). A new version can convert the database, and an older version may not read it after that.
3. In `.env`, the line with the image looks like this:

    ```shell
    ASPIA_IMAGE=ghcr.io/<owner>/aspia-server:3.0.21
    ```

    Replace the version in the tag with the new version.

4. Download the image and create the container again:

    ```shell
    docker compose pull
    docker compose up -d
    ```

5. Check the status and the log:

    ```shell
    docker compose ps
    docker compose logs aspia-server
    ```

To go back, put the old tag into `.env` and run `docker compose up -d`. If the new version has converted the data, restore the backup too.

Do not run `aspia_router --check-update` or `aspia_router --install-update` in the container. An update that is installed in the container is lost when the container is created again.

### Tags and digests

| Tag | Changes? |
|---|---|
| `3.0.21` | Yes. The image is built again every week with the Debian security updates. The tag then points to the new build. |
| `3.0.21-YYYYMMDD`, for example `3.0.21-20261005` | No. Each weekly build gets its own dated tag. |

The image also has short tags without the full version, for example `3.0`. Do not use them on a server: they change on the next pull.

For an image that never changes, use its digest. Show the digest of the image that you have downloaded:

```shell
docker image inspect --format '{{index .RepoDigests 0}}' ghcr.io/<owner>/aspia-server:3.0.21
```

The command prints a reference such as `ghcr.io/<owner>/aspia-server@sha256:...`. Put this reference into `.env`:

```shell
ASPIA_IMAGE=ghcr.io/<owner>/aspia-server@sha256:2ff06f77e1e364bf03245bc5453646a62313a4b4dba0ae086c89446d4558d4a0
```

The digest in this example is only an example. The summary of each publish run on GitHub also shows the digest. [docs/ci.md](docs/ci.md) shows how to verify the signature of the image.

## Upgrading from 2.x

This section is for a server that runs `paprikkafox/aspia-server:2.7.0` with a `docker-compose.yml` and a `data` directory. The image 3.0.21 keeps your users, Hosts and keys.

1. Go to the directory of the old installation and stop the container:

    ```shell
    docker compose down
    ```

2. Make a backup of the old data and the old compose file:

    ```shell
    sudo tar -czf aspia-2.7.0-backup.tar.gz data docker-compose.yml
    ```

3. Download the new files. The new `docker-compose.yml` replaces the old one:

    ```shell
    curl -fsSLO https://raw.githubusercontent.com/<owner>/aspia-server-docker/main/docker-compose.yml
    curl -fsSL -o .env https://raw.githubusercontent.com/<owner>/aspia-server-docker/main/.env.example
    ```

4. In `.env`, set `EXTERNAL_IP` to the value from your old `docker-compose.yml`, and set the image:

    ```shell
    EXTERNAL_IP=203.0.113.10
    ASPIA_IMAGE=ghcr.io/<owner>/aspia-server:3.0.21
    ```

5. Start the new version:

    ```shell
    docker compose pull
    docker compose up -d
    docker compose logs aspia-server
    ```

6. Open the new ports in your firewall: 8061/tcp, 8062/tcp and 8065/udp. Keep 8060/tcp open for the Hosts of Aspia 2.x.

What happens on the first start:

- The container copies `router.json`, `relay.json` and `router.db3` to files with the suffix `.pre-3.0.21-<time>`, next to the originals.
- Aspia converts `router.json` to `router.conf` and `relay.json` to `relay.conf`. It renames the old files to `router.json.bak` and `relay.json.bak`.
- Aspia upgrades the database `router.db3`. Aspia 2.7.0 may not read it after that.
- The Router keeps its key. Hosts that use the key from `router.pub` keep working. The container copies `router.pub` to `host.pub` and `relay.pub`, the file names of Aspia 3.x. The log shows the key as `Public key for hosts`. It is the same key as in `router.pub`.
- Two settings are not carried over: the administrator allow-list (`AdminWhiteList`; Aspia 3.x has no such setting) and the Relay statistics settings.

Also read the official [migration guide](https://aspia.org/docs/migration). It says:

- Hosts of version 2.6.0 and later keep working. They connect on port 8060. You can update them later.
- The recommended order is: Router, then Relay, then Clients and Hosts.
- The Console is removed. The Client of Aspia 3.x manages the Router, the address book and the groups of computers. Old address books (`.aab` files) are imported by hand in the Client.
- Two-factor authentication is mandatory. Every user sets it up at the first connection.

To go back to 2.7.0, restore the backup from step 2 and start the old version:

```shell
docker compose down
sudo mv data data.3x
sudo tar -xzf aspia-2.7.0-backup.tar.gz
docker compose up -d
```

## Backup and restore

The directory `data` holds everything: the configuration, the keys and the database. Stop the container before the backup, so that the database files are complete.

The files in `data` belong to root (or to `PUID`, if you set it), so the commands use `sudo`.

Back up:

```shell
docker compose stop
sudo tar -czf aspia-backup-$(date +%Y%m%d-%H%M%S).tar.gz data .env docker-compose.yml
docker compose start
```

Restore. Use the name of your backup file:

```shell
docker compose down
sudo mv data data.old
sudo tar -xzf aspia-backup-20261002-114739.tar.gz
docker compose up -d
```

Store the backup on another machine. It contains the private keys of the Router.

## Running a Relay on a separate host

The same image can run the Router alone (`ASPIA_ROLE=router`) or a Relay alone (`ASPIA_ROLE=relay`). A Relay on another server can be closer to a group of users. It also takes the relayed traffic away from the server of the Router. One Router accepts at most five Relays at the same time.

Without `ASPIA_ROLE` nothing changes: the default `all` runs the Router and the Relay in one container.

Which port must be open, and from where:

| Port | On | Reachable from |
|---|---|---|
| 8060/tcp, 8061/tcp | the Router server | Hosts (2.x on 8060, 3.x on 8061) |
| 8062/tcp, 8065/udp | the Router server | Clients, and Hosts for STUN |
| 8063/tcp | the Router server | only the Relay servers |
| 8070/tcp | each Relay server | the Clients and the Hosts that use this Relay |

```
Clients, Hosts --8060-8062/tcp, 8065/udp--> Router server
Clients, Hosts --8070/tcp-----------------> Relay server --8063/tcp (outgoing)--> Router server
```

### On the Router server

1. Download `compose.router.yml` into the directory of the server. It uses the same `data` directory and the same `.env` as `docker-compose.yml`. The keys stay the same, so the Hosts and the Clients need no change.

    ```shell
    curl -fsSLO https://raw.githubusercontent.com/<owner>/aspia-server-docker/main/compose.router.yml
    ```

2. Stop the combined container and start the Router alone:

    ```shell
    docker compose down
    docker compose -f compose.router.yml up -d
    ```

3. Get the public key for Relays. The Router prints it in the log as `Public key for relays`. It is also in the file `./data/config/relay.pub`.

    ```shell
    docker compose -f compose.router.yml logs aspia-router | grep 'Public key for relays'
    ```

    This is not the key for Hosts. After an upgrade from 2.x both keys are the old `router.pub`.

4. Allow only your Relays. In `.env`, set the addresses of the Relays as the Router sees them. A Relay behind NAT has the public address of its NAT. Then apply the change:

    ```shell
    ASPIA_ROUTER_RELAY_ALLOWED_IPS=203.0.113.20
    ```

    ```shell
    docker compose -f compose.router.yml up -d
    ```

    Without this variable the Router accepts a Relay from any address that can reach port 8063 and has the key from step 3. The log of the Router shows a `WARNING` about this until you set the variable.

5. In the firewall, allow 8063/tcp only from the Relay servers.

To keep a Relay on the Router server too, keep `docker-compose.yml` instead of `compose.router.yml`. Add `"8063:8063"` to its `ports:` list. Then `ASPIA_ROUTER_RELAY_ALLOWED_IPS` must also contain `127.0.0.1`.

### On each Relay server

1. Create a directory and download `compose.relay.yml`:

    ```shell
    mkdir aspia-relay
    cd aspia-relay
    curl -fsSLO https://raw.githubusercontent.com/<owner>/aspia-server-docker/main/compose.relay.yml
    ```

2. Create a file `.env` in this directory with these lines. Use the address of your Router, the public address of this Relay server and the key from step 3 above:

    ```shell
    ASPIA_IMAGE=ghcr.io/<owner>/aspia-server:3.0.21
    EXTERNAL_IP=203.0.113.20
    ASPIA_RELAY_ROUTER_ADDRESS=203.0.113.10
    ASPIA_RELAY_ROUTER_PUBLIC_KEY=047d0004a25c7f61e501c3eadc701732ca94c6a2fb035b4935caf7da7b27c555
    ```

    The key in this example is only an example. Instead of the key itself, you can give the path of a copy of `relay.pub` in `ASPIA_RELAY_ROUTER_PUBLIC_KEY_FILE`. The comments in `compose.relay.yml` show how to mount the file.

3. Start the Relay:

    ```shell
    docker compose -f compose.relay.yml pull
    docker compose -f compose.relay.yml up -d
    ```

    If a required setting is missing, the container stops with a message that names it.

4. In the firewall, allow 8070/tcp from the Clients and the Hosts. The Relay connects out to port 8063/tcp of the Router.

### Check that the Relay is registered

On the Relay server:

```shell
docker compose -f compose.relay.yml ps
docker compose -f compose.relay.yml logs aspia-relay | grep 'Connection to the router'
```

The status is `(healthy)` when the Relay listens on 8070 and is connected to the Router. The log shows `Connection to the router is established`.

On the Router server:

```shell
docker compose -f compose.router.yml logs aspia-router | grep -E 'New relay session|Received key pool'
```

The log shows the address of the Relay, for example `New relay session: "203.0.113.20"`.

If the Relay does not connect, it tries again every 15 seconds. Its log shows the reason:

| Message in the Relay log | Cause |
|---|---|
| `ACCESS_DENIED` | Wrong key. Use `relay.pub` of the Router, not `host.pub`. |
| `SPECIFIED_HOST_NOT_FOUND` | The DNS name of the Router does not resolve. |
| `CONNECTION_REFUSED` | Nothing listens on that address and port. Check that port 8063 is published on the Router server. |
| `SOCKET_TIMEOUT`, after 30 seconds | A firewall drops the packets. |
| `REMOTE_HOST_CLOSED`, right after the connection | The Router refused the Relay: its address is not in `ASPIA_ROUTER_RELAY_ALLOWED_IPS`, or five Relays are already connected. |

A connected Relay can still be unused. If the Router does not accept the public address of the Relay, only the Router log shows it: `Ignoring key pool with invalid peer endpoint`. The container checks the format of the address before it starts, so this should not happen with a valid `EXTERNAL_IP`.

## Podman

To run the server under Podman as a systemd service (Quadlet), read [podman/README.md](podman/README.md). It needs Podman 4.5 or later. It covers installation as root and as a normal user, the network, the firewall, updating, and a Relay on its own server.

## Building locally

You can build the image yourself instead of using the published one. The build downloads the Aspia packages from the official releases and checks them against the checksums in `versions.env`.

```shell
git clone https://github.com/<owner>/aspia-server-docker.git
cd aspia-server-docker
cp .env.example .env
```

Set `EXTERNAL_IP` in `.env`, and leave `ASPIA_IMAGE` unset. Then build and start:

```shell
docker compose up -d --build
```

The image gets the name `aspia-server:3.0.21`. To build the image without starting it:

```shell
docker build -t aspia-server:3.0.21 .
```

To update a local build, get the new version of the repository and build again:

```shell
git pull
docker compose up -d --build
```

Two things to know about `docker-compose.yml` in a copy of the repository:

- With `ASPIA_IMAGE` set, do not add `--build`. Docker Compose then builds the image locally and gives it the name of the published image.
- If `docker compose pull` fails, for example because of a wrong image name, `docker compose up -d` builds the image locally under that name. Check the output of `docker compose pull` for errors.

The tests and the CI are described in [docs/ci.md](docs/ci.md).

## Troubleshooting

| Symptom | What to do |
|---|---|
| The container stops at once. The log says `ERROR: ASPIA_RELAY_PUBLIC_ADDRESS is not set`. | Set `EXTERNAL_IP` in `.env`. Then run `docker compose up -d`. |
| The container stops at once. The log names another variable. | Correct the value of that variable in `.env`. Then run `docker compose up -d`. |
| `docker compose pull` says `no matching manifest for linux/arm64`. | The server has an ARM processor. The image exists only for x86_64. |
| `EXTERNAL_IP=auto` stops the container with an error about the detection. | The server cannot reach the internet services that report its address. Set the address by hand. |
| The log shows `sd_login_monitor_new failed` or `Unable to install signal handler for SIGKILL`. | Nothing. These lines are normal in a container. |
| The status is `(unhealthy)`. | Read the log: `docker compose logs aspia-server`. Healthy means that the Router listens on its ports and the Relay is connected to the Router. |
| A Host does not connect. | Check that port 8061/tcp (8060/tcp for Aspia 2.x) is open. Check that the Host uses the key from `host.pub`, not from `relay.pub`. |
| The Client does not connect to the Router. | Check that port 8062/tcp is open. If `ASPIA_ROUTER_CLIENT_ALLOWED_IPS` is set, check that it contains the address of the Client. |
| Sessions work only in the local network, or relayed sessions fail. | Check that port 8070/tcp is open and that `EXTERNAL_IP` is the public address of the server. The port on the server must be the same as in the container. |
| A user lost the authenticator app. | Reset the two-factor authentication of that user, then restart: `docker compose exec aspia-server aspia_router --reset-otp admin` and `docker compose restart`. Replace `admin` with the user name. |
| You forgot the password of `admin`. | Another administrator can change it in the Client. Aspia 3.x has no command to set a password. |
| The Aspia 2.x Console does not work with the new Router. | The Console is removed in Aspia 3.x. Use the Client of Aspia 3.x. |
| The time in the log is wrong. | Set `TZ` in `.env`, for example `TZ=Europe/Berlin`. Then run `docker compose up -d`. |
| `Permission denied` when you read files in `data`. | The files belong to root. Use `sudo`. |
| A Relay on another server does not register. | See [Check that the Relay is registered](#check-that-the-relay-is-registered). |

## Licence and credits

This repository is licensed under the GNU General Public License v3.0: see [LICENSE](LICENSE). Aspia is licensed under the GNU General Public License v3.0 too.

Thanks to:

- Dmitry Chapyshev ([dchapyshev](https://github.com/dchapyshev)) for Aspia: [dchapyshev/aspia](https://github.com/dchapyshev/aspia).
- Dmitry Fox ([paprikkafox](https://github.com/paprikkafox)) for the original aspia-server Docker image: [paprikkafox/aspia-server-docker](https://github.com/paprikkafox/aspia-server-docker).
- [SinitsaDA](https://github.com/SinitsaDA) for [SinitsaDA/aspia-server-docker](https://github.com/SinitsaDA/aspia-server-docker) (GPL-3.0). The 3.x image of this project was ported from its 3.x server image, its handling of the 2.x migration and its health check that opens no connections.

The work on this repository was done with the help of Claude, the AI assistant by Anthropic, used through Claude Code.
