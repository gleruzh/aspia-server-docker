**English** | [Русский](README.ru.md)

# Aspia server under Podman (systemd, Quadlet)

Run the Aspia Router and Relay as a systemd service on a machine that has Podman and no Docker
(RHEL, AlmaLinux, Rocky, Fedora, Debian, Ubuntu). Copy a few files, `systemctl daemon-reload`,
`systemctl start`: the service restarts when it fails and starts again after a reboot.

- Needs **Podman 4.5 or later** and systemd. Older Podman: see section 9.
- The image is linux/amd64 only. Nothing here updates a running container: you change the version and restart.
- Tested with Podman 4.5.1, 4.9.3, 5.4.2 and 5.8.7 by `tests/podman.sh` (measurements: `docs/dev/UPSTREAM-3.x-NOTES.md`, section 18).

| File | What it is |
|---|---|
| `aspia-server.container` | The Quadlet unit: image, ports, volumes, environment, health check, restart policy. |
| `aspia-config.volume`, `aspia-data.volume` | Named volumes for `/etc/aspia` (configuration and keys) and `/var/lib/aspia` (database). |
| `aspia-server.env.example` | The environment file. Copy it to `aspia-server.env`. The variables are in the tables [Ports](../README.md#ports) and [Environment variables](../README.md#environment-variables) of the main README. |
| `aspia-relay.container`, `aspia-relay-config.volume`, `aspia-relay.env.example` | A Relay on its own, connected to a Router on another machine (section 11). |

## 1. Choose the image (one line)

The image is the `Image=` line of `aspia-server.container`, the only place to change. **Use the published
image**, pinned to the exact version tag (or to a digest):

```ini
Image=ghcr.io/<owner>/aspia-server:3.0.23
Image=ghcr.io/<owner>/aspia-server@sha256:<digest>
```

`<owner>` is the account that publishes the image (see [docs/ci.md](../docs/ci.md), which also shows how to
verify the cosign signature). The digest of each release is in the summary of its publish run and in
docs/ci.md. Never use `latest`, `3` or `3.0`: they change under you on the next pull. Podman pulls a public
image when the service starts, no login needed.

The default in the file, `localhost/aspia-server:3.0.23`, is the name a local build gives. To build locally,
in a checkout of this repository, as the user that will run the service (root for the system-wide install):

```shell
podman build -t aspia-server:3.0.23 .
```

A local `podman build` needs **Podman 5.1 or later**: the Dockerfile's `HEALTHCHECK --start-interval` makes
older Podman fail with `flag provided but not defined: -start-interval`. On older Podman use the published
image, or build with Docker and move the image over: `docker save aspia-server:3.0.23 | podman load`
(then `Image=localhost/aspia-server:3.0.23` fits only if `podman images` shows that name; otherwise tag it).

## 2. Install system-wide (as root)

```shell
sudo install -d /etc/containers/systemd
sudo install -m 0644 podman/aspia-server.container podman/aspia-config.volume podman/aspia-data.volume /etc/containers/systemd/
sudo install -m 0644 podman/aspia-server.env.example /etc/containers/systemd/aspia-server.env
sudoedit /etc/containers/systemd/aspia-server.env         # set EXTERNAL_IP (or 'auto')
sudoedit /etc/containers/systemd/aspia-server.container   # the Image= line (section 1)
sudo systemctl daemon-reload
sudo systemctl start aspia-server.service
```

There is no `systemctl enable`: Quadlet generates the service from the `.container` file, and its
`[Install]` section makes it start at boot. Check:

```shell
systemctl status aspia-server.service
sudo podman healthcheck run aspia-server     # exit status 0 and no output when healthy
sudo podman ps                               # STATUS shows (healthy) after the first check
sudo podman logs aspia-server                # the Router's public key for hosts is printed at the first start
sudo podman exec aspia-server cat /etc/aspia/host.pub   # the same key, any time
```

Stop with `sudo systemctl stop aspia-server.service`. For the first login (the administrator account and the public
key for Hosts) see [First login](../README.md#first-login) in the main README.

## 3. Install rootless (a normal user)

The container runs as an unprivileged user. Do this as that user in a real login session (ssh or a
console, not `sudo su`), so that `systemctl --user` works.

```shell
# once, as root: keep the user's services running without a login session, and start them at boot
sudo loginctl enable-linger "$USER"

# as the user
mkdir -p ~/.config/containers/systemd
install -m 0644 podman/aspia-server.container podman/aspia-config.volume podman/aspia-data.volume ~/.config/containers/systemd/
install -m 0644 podman/aspia-server.env.example ~/.config/containers/systemd/aspia-server.env
$EDITOR ~/.config/containers/systemd/aspia-server.env         # set EXTERNAL_IP (or 'auto')
$EDITOR ~/.config/containers/systemd/aspia-server.container   # the Image= line (section 1)
systemctl --user daemon-reload
systemctl --user start aspia-server.service
podman healthcheck run aspia-server
```

Same unit file as the system-wide install. Images are per user: build or pull as that user. All ports are
above 1024, so no sysctl is needed. `PUID`/`PGID` are not needed (the container's root is your user) and were
not tested under Podman. **On Podman 4.x a rootless container does not see the clients' real addresses:
read section 4.**

## 4. Networking: published ports or `Network=host`

The unit publishes the ports one-to-one (host port = container port) with `PublishPort=`: the Relay tells
every client its own port, so `9070:8070` would break relayed connections. Port 8063 (Router to Relay) is
not published.

| Setup | Address the Router sees for a client | Use |
|---|---|---|
| System-wide (root) | The real address. | Published ports. |
| Rootless, Podman 5.x (pasta; `podman info --format '{{.Host.RootlessNetworkCmd}}'` prints `pasta`) | The real address for clients on other machines. | Published ports. |
| Rootless, Podman 4.x (slirp4netns) | **`10.0.2.100` for every client.** | `Network=host`. |

Network=host opens 8063 on all interfaces, so it is not the safe default.

The shared address breaks IP allow-lists (`ASPIA_ROUTER_CLIENT_ALLOWED_IPS`, `ASPIA_ROUTER_HOST_ALLOWED_IPS`:
every client looks the same), makes all clients share the Router's per-address rate limit, and makes the
built-in STUN server answer `10.0.2.100`. Measurements: `docs/dev/UPSTREAM-3.x-NOTES.md`, section 18.

### Network=host

In `aspia-server.container`, delete the `PublishPort=` lines and uncomment the two marked lines
(`Network=host` and `Environment=ASPIA_ROUTER_RELAY_ALLOWED_IPS=127.0.0.1`). Then apply:

```shell
sudo systemctl daemon-reload && sudo systemctl restart aspia-server.service    # rootless: systemctl --user ...
```

The second line matters: without a Relay allow-list anyone who can reach 8063 may register as a Relay (the Router accepts up to five).
`ASPIA_ROUTER_RELAY_ALLOWED_IPS=127.0.0.1` lets only the Relay inside this container in (tested on 4.9.3: a
connection to 8063 from another machine is rejected, the Relay still connects). If you also set that variable
in `aspia-server.env`, give both the same value. Open the same ports in your firewall as for published
ports (section 7). To go back, restore the `PublishPort=` lines from
`podman/aspia-server.container` and comment the two lines out.

## 5. Volumes: named volumes (default) or host directories

The default is two **named volumes**, created by the two `.volume` files and called `systemd-aspia-config` and
`systemd-aspia-data` (`podman volume ls`). They work the same for root and rootless, with no SELinux or
ownership handling.

```shell
sudo podman volume inspect systemd-aspia-config --format '{{.Mountpoint}}'   # where the files are on the host
sudo podman volume export systemd-aspia-config > aspia-config-backup.tar     # a backup of the keys and configuration
```

**Alternative: host directories.** Create them, delete the two `.volume` files, and replace the two
`Volume=` lines of the unit:

```ini
Volume=/var/lib/aspia-server/config:/etc/aspia:Z
Volume=/var/lib/aspia-server/data:/var/lib/aspia:Z
```

```shell
sudo install -d /var/lib/aspia-server/config /var/lib/aspia-server/data
```

`:Z` is for SELinux (enforcing on RHEL, AlmaLinux, Rocky, Fedora): it labels the directory for this container,
and without it access is denied. It is harmless where SELinux is off. Tested without SELinux, so the effect
of `:Z` itself was not tested. Rootless: use directories inside the user's home.

## 6. Configuration

Edit `aspia-server.env` (next to the `.container` file), then `sudo systemctl restart aspia-server.service`
(rootless: `systemctl --user restart ...`). Every variable and its default is in the tables
[Ports](../README.md#ports) and [Environment variables](../README.md#environment-variables) of the main README.
The rules there apply unchanged.

Podman reads this file itself, not systemd: one `VAR=value` per line, no quotes, no trailing comments.
A changed port variable needs the matching `PublishPort=` line (see the comments in the unit).
The default ports are all above 1024; for a port below 1024 also add `AddCapability=NET_BIND_SERVICE` to the unit.
The units do not set `NoNewPrivileges`: on Ubuntu 24.04 (AppArmor, crun profile) it blocks the clean stop. The compose files keep `no-new-privileges`; Docker is not affected.

## 7. Firewall

Open the ports the clients and hosts need. 8060 is only for hosts of Aspia 2.x. Do not open 8063.

```shell
# firewalld (RHEL, AlmaLinux, Rocky, Fedora)
sudo firewall-cmd --permanent --add-port=8060-8062/tcp --add-port=8070/tcp --add-port=8065/udp
sudo firewall-cmd --reload

# ufw (Debian, Ubuntu)
sudo ufw allow 8060:8062/tcp
sudo ufw allow 8070/tcp
sudo ufw allow 8065/udp
```

These rules were not tested. Published ports of a root container are forwarded by Podman's own firewall
rules and may be reachable even where the host firewall says they are closed (as with Docker).

## 8. Update (by hand, when you decide to)

The unit has no `io.containers.autoupdate` label; do not enable `podman-auto-update.timer` for it.

1. Read the release notes, and back up the volumes (section 5) or the directories.
2. Change the tag (or digest) in the `Image=` line, for example `3.0.23` to the next version. With a local
   build, build the new image first.
3. `sudo systemctl daemon-reload`
4. `sudo systemctl restart aspia-server.service`

Rootless: the same without `sudo`, and `systemctl --user ...`. The files are in `~/.config/containers/systemd/`,
not `/etc/containers/systemd/`. The first start of a new image may convert the database; see the main README, [Updating](../README.md#updating).
To go back, put the old tag in the unit and repeat steps 3 and 4 (the data may not go back with it, which is
why step 1 is there). Remove an unused old image with `podman image rm`.

## 9. Older Podman: no Quadlet (fallback)

Podman 4.4 and older cannot use the unit: its health check keys need 4.5 (Quadlet itself appeared in 4.4). On Debian 12
(Podman 4.3), Ubuntu 22.04 (3.4) and RHEL 8 before 8.10 use `podman run`, then let Podman write a systemd
unit, as root. Replace `<owner>` in the last line with the account that publishes the image (section 1; a local
build is not possible on these versions). A Docker-built image moved over with `docker save | podman load`
can be used instead.

```shell
sudo install -d /etc/aspia-server
sudo install -m 0644 podman/aspia-server.env.example /etc/aspia-server/aspia-server.env
sudoedit /etc/aspia-server/aspia-server.env      # set EXTERNAL_IP (or 'auto')
sudo podman volume create aspia-config
sudo podman volume create aspia-data
sudo podman run -d --name aspia-server --env-file /etc/aspia-server/aspia-server.env \
  -p 8060:8060 -p 8061:8061 -p 8062:8062 -p 8065:8065/udp -p 8070:8070 \
  -v aspia-config:/etc/aspia -v aspia-data:/var/lib/aspia \
  --health-cmd /usr/bin/aspia_health --health-interval 30s --health-timeout 10s \
  --health-retries 3 --health-start-period 60s \
  ghcr.io/<owner>/aspia-server:3.0.23
cd /etc/systemd/system
sudo podman generate systemd --new --files --name --restart-policy=always aspia-server
sudo podman rm -f aspia-server
sudo systemctl daemon-reload
sudo systemctl enable --now container-aspia-server.service
```

To update, change the tag in `/etc/systemd/system/container-aspia-server.service`, then
`sudo systemctl daemon-reload && sudo systemctl restart container-aspia-server.service`.
`podman generate systemd` is deprecated in newer Podman in favour of Quadlet.

## 10. Troubleshooting

- `Unit aspia-server.service not found`: run `systemctl daemon-reload`; for a syntax problem in the
  unit, run the generator in dry-run mode: `/usr/lib/systemd/system-generators/podman-system-generator --dryrun`
  (rootless: add `--user`; on some distributions the generator is `/usr/libexec/podman/quadlet`).
- Start fails with `image not known` or a pull error: the `Image=` name is not in this user's image store
  or is not a pullable name (section 1).
- `netavark: nftables error: unable to execute nft` (Debian 13 without recommended packages): install `nftables`.
- `EXTERNAL_IP ... is not set`: the container exits on purpose without it. Set it in `aspia-server.env`.
- Rootless service stops when you log out: run `sudo loginctl enable-linger <user>`.
- `systemctl --user` says "Failed to connect to bus": you are not in a login session; log in over ssh or
  use `machinectl shell <user>@`.

## 11. A Relay on its own host, or the Router alone

The steps for both sides, the ports and how to confirm that the Relay registered are in the main README,
["Running a Relay on a separate host"](../README.md#running-a-relay-on-a-separate-host). Under Podman:

**Relay host.** Install `aspia-relay.container`, `aspia-relay-config.volume` and `aspia-relay.env.example` (as
`aspia-relay.env`) the way section 2 (or 3) installs the server files, set the `Image=` line (section 1), and set
`ASPIA_RELAY_ROUTER_ADDRESS`, `ASPIA_RELAY_ROUTER_PUBLIC_KEY` (the Router's `relay.pub`) and `EXTERNAL_IP` in
`aspia-relay.env` (the first two are commented out in the example, so uncomment them; instead of the key you can
mount a copy of `relay.pub` at `/run/aspia/router-relay.pub` and set `ASPIA_RELAY_ROUTER_PUBLIC_KEY_FILE` to that
path, as the commented `Volume=` line in the unit shows; not under `/etc/aspia`). Optional: `ASPIA_RELAY_ROUTER_PORT`. Then `systemctl daemon-reload` and `systemctl start aspia-relay.service` (rootless:
`systemctl --user ...`). The unit sets `ASPIA_ROLE=relay`, publishes only 8070/tcp, and is healthy once the Relay is
connected to the Router: `podman healthcheck run aspia-relay`. Open 8070/tcp in the firewall (section 7); the
connection to the Router's 8063/tcp is outgoing.

**Router host.** Keep `aspia-server.container`, set `ASPIA_ROLE=router` and `ASPIA_ROUTER_RELAY_ALLOWED_IPS` (your
Relays' addresses) in `aspia-server.env`, add `PublishPort=8063:8063/tcp` to the unit, and open 8063/tcp to the
Relay hosts only. Also comment out `EXTERNAL_IP` in `aspia-server.env` (a Router-only container has no Relay, and
leaves `WARNING: Ignored: EXTERNAL_IP` in the log at every start otherwise), and the `PublishPort=8070:8070/tcp` line
can go from the unit for the same reason. A rootless Router on Podman 4.x sees every connection as coming from `10.0.2.100` (section 4,
measured for clients; the published 8063 goes through the same forwarding), so the allow-list
cannot tell them apart there: use root, Podman 5, or the firewall.

`tests/podman.sh relay` tests the relay unit (system-wide and rootless, against a Router on the same machine). It
does not test the Router-only setup under Podman, or two machines.
