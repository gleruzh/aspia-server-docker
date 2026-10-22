# Aspia Server (Router + Relay) in one container

Unofficial packaging of the server programs of [Aspia](https://github.com/dchapyshev/aspia), the open source remote desktop software by Dmitry Chapyshev: the Aspia Router and the Aspia Relay in one linux/amd64 image. It is not made or supported by the Aspia author.

**The full documentation is on GitHub: [README.md](README.md).** It covers the quick start, the first login, the environment variables, the security settings, upgrading from Aspia 2.x, running a Relay on a separate host, backups and troubleshooting. Read it before you run the image. This page is only a short summary.

## Tags

Use an exact version tag, for example `3.1.2`. Do not use `latest` or a short tag such as `3.0`: they change on the next pull, and an Aspia update can need action from you.

```shell
docker pull <namespace>/aspia-server:3.1.2
```

`<namespace>` is the Docker Hub account name in the address of this page.

The tag `3.1.2` points to the newest build of that version: it moves when the image changes (a Debian base update, a Debian security fix or a fix). `3.1.2-YYYYMMDD` (a dated tag) never changes. To pin an image exactly, use its digest: `<namespace>/aspia-server@sha256:...`. The digest is the same in every registry the image is published to, and the images are signed (see [docs/ci.md](docs/ci.md)).

## Quick start

Follow the "Quick start" section of [README.md](README.md). In short, a `docker-compose.yml` and a `.env` file from the repository, with these two lines in `.env`:

```shell
EXTERNAL_IP=203.0.113.10
ASPIA_IMAGE=<namespace>/aspia-server:3.1.2
```

`EXTERNAL_IP` is the public address of your server. Replace the example address `203.0.113.10`.

## Ports

| Port | Service | Purpose |
|---|---|---|
| 8061/tcp | Router | Hosts of Aspia 3.x |
| 8062/tcp | Router | Clients |
| 8065/udp | Router | Built-in STUN server |
| 8070/tcp | Relay | Relayed sessions |
| 8063/tcp | Router | Relays on other servers (not published by default) |

Aspia 3.1 supports Aspia 3.x only: Hosts, Consoles and Clients older than 3.0.0 cannot connect, and the image refuses to start on Aspia 2.x data. Version 3.0.37 is the last with 2.x support, and `gleruzh/aspia-server:3.0.37` stays available. To upgrade from 2.x, see "Upgrading from 2.x" in [README.md](README.md).

The first start creates the user `admin` with a random password. The image saves it in `/etc/aspia/initial-admin-password` and does not print it to the log: read it with `docker exec <container> cat /etc/aspia/initial-admin-password`, log in, change the password and delete the file. The file is a plaintext credential on the configuration volume and ends up in any backup of it, so delete it before backing up the volume. See "First login" in [README.md](README.md).

## Licence and credits

Licensed under the GNU General Public License v3.0: see [LICENSE](LICENSE). Aspia is licensed under the GPL-3.0 too.

Thanks to:

- Dmitry Chapyshev ([dchapyshev](https://github.com/dchapyshev)) for [Aspia](https://github.com/dchapyshev/aspia).
- Dmitry Fox ([paprikkafox](https://github.com/paprikkafox)) for the original aspia-server Docker image (removed from Docker Hub in October 2026).
- [SinitsaDA](https://github.com/SinitsaDA) for [SinitsaDA/aspia-server-docker](https://github.com/SinitsaDA/aspia-server-docker), which the 3.x image was ported from.

The work on this repository was done with the help of Claude, the AI assistant by Anthropic, used through Claude Code.
