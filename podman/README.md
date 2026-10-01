# Aspia server under Podman (systemd, Quadlet)

Run the Aspia Router and Relay as a systemd service on a machine that has Podman and no Docker
(RHEL, AlmaLinux, Rocky, Fedora, Debian, Ubuntu). Copy a few files, `systemctl daemon-reload`,
`systemctl start`: the service restarts when it fails and starts again after a reboot.

- Requires **Podman 4.5 or later** (Quadlet with health checks) and systemd. Lowest version tested: 4.5.1.
  Podman 4.4 and older do not work with these files, see "Older Podman" below.
- The image is linux/amd64 only, like the rest of this repository.
- Nothing here updates a running container. You change the version tag and restart when you decide to.

| File | What it is |
|---|---|
| `aspia-server.container` | The Quadlet unit: image, ports, volumes, environment, health check, restart policy. |
| `aspia-config.volume`, `aspia-data.volume` | Named volumes for `/etc/aspia` (configuration and keys) and `/var/lib/aspia` (database). |
| `aspia-server.env.example` | The environment file. Copy it to `aspia-server.env`. The variables are the ones in the table in the [main README](../README.md#configuration). |

## 1. Choose the image (one line)

The image is the `Image=` line of `aspia-server.container`. It is the only place to change.

```ini
Image=localhost/aspia-server:3.0.21
```

The name of a published image depends on who publishes it, so the file does not hard-code a registry.
The default is the name you get from building the image from this repository on the machine itself:

```shell
# in a checkout of this repository, as the user that will run the service (root for the system-wide install)
podman build -t aspia-server:3.0.21 .
```

To use a published image instead, put its full name into that one line. Podman pulls it when the service
starts, no registry login is needed for a public image:

```ini
Image=ghcr.io/<owner>/aspia-server:3.0.21
```

`<owner>` is the account that publishes the image (the one whose repository you use; see
[docs/ci.md](../docs/ci.md)). Always use an exact version tag, never `latest`: `latest` and the
floating `3` and `3.0` tags change under you on the next pull. For an image that can never change, pin
the digest (the digest of each release is in the summary of its publish run):

```ini
Image=ghcr.io/<owner>/aspia-server@sha256:<digest>
```

The image is signed with cosign; [docs/ci.md](../docs/ci.md) shows how to verify it before you use it.

## 2. Install system-wide (as root)

```shell
sudo install -d /etc/containers/systemd
sudo install -m 0644 podman/aspia-server.container podman/aspia-config.volume podman/aspia-data.volume /etc/containers/systemd/
sudo install -m 0644 podman/aspia-server.env.example /etc/containers/systemd/aspia-server.env
sudoedit /etc/containers/systemd/aspia-server.env      # set EXTERNAL_IP (or 'auto')
sudoedit /etc/containers/systemd/aspia-server.container   # only if you use a published image: the Image= line
sudo systemctl daemon-reload
sudo systemctl start aspia-server.service
```

There is no `systemctl enable`: Quadlet generates the service from the `.container` file, and its
`[Install]` section makes it start at boot by itself. Check:

```shell
systemctl status aspia-server.service
sudo podman healthcheck run aspia-server     # exit status 0 and no output when healthy
sudo podman ps                               # STATUS shows (healthy) after the first check
sudo podman logs aspia-server                # the Router's public key for hosts is printed at the first start
sudo podman exec aspia-server cat /etc/aspia/host.pub   # the same key, any time
```

Stop with `sudo systemctl stop aspia-server.service`; it takes about a second. The first start prints the
initial administrator login (`admin`/`admin`): change it in the Client (see the main README).

## 3. Install rootless (a normal user)

Rootless means the container runs as an unprivileged user with no root on the host. Do this as that user,
in a real login session (ssh or a console), not through `sudo su`, so that `systemctl --user` works.

```shell
# once, as root: keep the user's services running without a login session, and start them at boot
sudo loginctl enable-linger "$USER"

# as the user
mkdir -p ~/.config/containers/systemd
install -m 0644 podman/aspia-server.container podman/aspia-config.volume podman/aspia-data.volume ~/.config/containers/systemd/
install -m 0644 podman/aspia-server.env.example ~/.config/containers/systemd/aspia-server.env
$EDITOR ~/.config/containers/systemd/aspia-server.env       # set EXTERNAL_IP (or 'auto')
systemctl --user daemon-reload
systemctl --user start aspia-server.service
podman healthcheck run aspia-server
```

The unit is the same file as for the system-wide install. Notes for rootless:

- Images are per user: build or pull as that user (`podman build ...` without `sudo`).
- All Aspia ports are above 1024, so no `net.ipv4.ip_unprivileged_port_start` change is needed.
- UDP works the same way: the STUN port 8065/udp answered requests in every rootless test below.
- **Client addresses: read "Networking" below before you use IP allow-lists.** On Podman 4.x a
  rootless container does not see the real address of the clients.
- `PUID`/`PGID` are not needed: the container's root is your unprivileged user on the host. They were not
  tested under Podman.

## 4. Networking: published ports or `Network=host`

The unit **publishes the ports one-to-one** (host port = container port) with `PublishPort=`. The Relay
tells every client and host its own port (`ASPIA_RELAY_PEER_PORT`), so a mapping such as `9070:8070`
would break relayed connections. Port 8063 (Router to Relay) is not published: the Relay in the same
container uses it internally.

Why published ports are the default: the container's ports are listed in one place, 8063 stays private,
and the service does not depend on the host's network layout. When the host-network alternative is better:

| Setup | What the Router sees as the client address | Use |
|---|---|---|
| System-wide (root) | The real address (netavark does not rewrite it). Tested on Podman 4.9.3 (Router log) and 5.8.7 (STUN reply). | Published ports. |
| Rootless, Podman 5.x (pasta, the default there; `podman info --format '{{.Host.RootlessNetworkCmd}}'` prints `pasta`) | The real address for clients on other machines. Tested on 5.4.2 (Router log) and 5.8.7 (STUN). A client on the same machine shows up as the machine's own address. | Published ports. |
| Rootless, Podman 4.x (slirp4netns, the default there) | **Not the real address: `10.0.2.100` for every client.** Tested on 4.9.3, with the Router log and with the STUN reply. | `Network=host`. |

What the shared address breaks (all measured on Podman 4.9.3, rootless, published ports):

- **IP allow-lists.** `ASPIA_ROUTER_CLIENT_ALLOWED_IPS` and `ASPIA_ROUTER_HOST_ALLOWED_IPS` compare the
  address the Router sees, so every client looks like `10.0.2.100`: the list either lets everyone in or
  nobody.
- **The per-address rate limit.** The Router has no ban for wrong passwords, but it limits connections per
  source address and per port (60 per minute on the client port 8062, 300 on the host ports 8060/8061, 60 on
  the Relay port 8070; see `docs/dev/UPSTREAM-3.x-NOTES.md`, section 13.2). With one shared address all clients
  share one budget. Two machines making 40 connections each to port 8062 got about 20 of the 80 rejected
  ("Per-address rate limit hit for ::ffff:10.0.2.100"); with `Network=host` and the same two machines,
  none.
- **STUN.** The built-in STUN server tells a peer which address it is seen as. In the rootless Podman 4.9.3
  test it answered `10.0.2.100` instead of the client's address, which is useless for direct connections.

**Solution: host networking.** The container then uses the host's network and the Router sees real
addresses on every Podman version, rootful or rootless (tested on 4.9.3, rootless: the Router log and the
STUN reply show the real address; the service passes `tests/podman.sh` with this edit, see "What was
tested"). Edit `aspia-server.container`: delete the `PublishPort=` lines and add two lines in `[Container]`:

```shell
sed -i -e '/^PublishPort=/d' \
    -e 's/^ContainerName=.*/&\nNetwork=host\nEnvironment=ASPIA_ROUTER_RELAY_ALLOWED_IPS=127.0.0.1/' \
    /etc/containers/systemd/aspia-server.container      # rootless: ~/.config/containers/systemd/...
systemctl daemon-reload && systemctl restart aspia-server.service     # rootless: systemctl --user
```

The result in the `[Container]` section:

```ini
Network=host
Environment=ASPIA_ROUTER_RELAY_ALLOWED_IPS=127.0.0.1
```

The second line matters: with host networking **port 8063 is open on every interface of the host**, and
without a Relay allow-list anyone who can reach it may register as a Relay (the Router accepts up to five).
`ASPIA_ROUTER_RELAY_ALLOWED_IPS=127.0.0.1` lets only the Relay inside this container in; the sed command above
sets it (tested on 4.9.3: a connection to 8063 from another machine is rejected, the Relay still connects).
If you also set `ASPIA_ROUTER_RELAY_ALLOWED_IPS` in `aspia-server.env`, give both the same value. With host
networking a change of a port variable in the env file needs no matching change in the unit. Open the same
ports in your firewall as for published ports (section 7), and leave 8063 closed.

If you do not know which case applies, use `Network=host`; it is the safe choice. To go back, restore the
`PublishPort=` lines from `podman/aspia-server.container`.

## 5. Volumes: named volumes (default) or host directories

The default is two **named volumes**, created by `aspia-config.volume` and `aspia-data.volume`. Podman
calls them `systemd-aspia-config` and `systemd-aspia-data` (`podman volume ls`). They work the same for
root and rootless, and need no SELinux or ownership handling.

```shell
sudo podman volume inspect systemd-aspia-config --format '{{.Mountpoint}}'   # where the files are on the host
sudo podman volume export systemd-aspia-config > aspia-config-backup.tar     # a backup of the keys and configuration
```

**Alternative: host directories**, if you want the files in a place you choose. Create the directories,
delete the two `.volume` files, and replace the two `Volume=` lines of the unit:

```ini
Volume=/var/lib/aspia-server/config:/etc/aspia:Z
Volume=/var/lib/aspia-server/data:/var/lib/aspia:Z
```

```shell
sudo install -d /var/lib/aspia-server/config /var/lib/aspia-server/data
```

The `:Z` suffix is for SELinux, which is enforcing on RHEL, AlmaLinux, Rocky and Fedora: it labels the
directory for this container alone, and without it the container is denied access to a host directory.
It is harmless where SELinux is off (Debian, Ubuntu). Tested: the system-wide unit with these two lines on
Fedora (Podman 5.8.7) started, became healthy and kept its keys across a restart; that machine had no
SELinux, so the effect of `:Z` itself was not tested. Rootless: use directories inside the user's home.

## 6. Configuration

Edit `aspia-server.env` (next to the `.container` file), then `systemctl restart aspia-server.service`.
Every variable, its default and what it does is in the table in the
[main README](../README.md#configuration); the rules there apply unchanged: a variable that is set is
written to the configuration file on every start, an unset one leaves the file alone.

Podman reads this file itself, not systemd: one `VAR=value` per line, no quotes, no trailing comments.

If you change a port variable, also change the matching `PublishPort=` line (host port = container port),
or use `Network=host`, which needs no change.

## 7. Firewall

Open the ports the clients and hosts need. 8060 is only for hosts of Aspia 2.x. Do not open 8063.

firewalld (RHEL, AlmaLinux, Rocky, Fedora):

```shell
sudo firewall-cmd --permanent --add-port=8060-8062/tcp --add-port=8070/tcp --add-port=8065/udp
sudo firewall-cmd --reload
```

ufw (Debian, Ubuntu):

```shell
sudo ufw allow 8060:8062/tcp
sudo ufw allow 8070/tcp
sudo ufw allow 8065/udp
```

Nothing in this directory changes your firewall; these are instructions, and the rules above were not
tested here. Be aware that published ports of a root container are forwarded by Podman's own
firewall rules and may be reachable even where the host firewall says they are closed (as with Docker); a
closed firewall port is not protection for a published port. Not tested here.

## 8. Update (by hand, when you decide to)

Nothing updates the container for you: the unit has no `io.containers.autoupdate` label and you should not
enable `podman-auto-update.timer` for it.

1. Read the release notes, and back up the volumes (`podman volume export`, section 5) or the directories.
2. Change the tag in the `Image=` line of the unit, for example `3.0.21` to the next version (a new digest
   for a digest pin). With a local build, build the new image first: `podman build -t aspia-server:<version> .`.
3. `systemctl daemon-reload`
4. `systemctl restart aspia-server.service` (rootless: `systemctl --user ...`)

The first start of a new image may convert the database; see the main README for what happens to your data.
To go back, put the old tag in the unit and repeat steps 3 and 4 (the data may not go back with it, which is
why step 1 is there). Remove an unused old image with `podman image rm`, when you want.

`scripts/versions.sh bump` keeps the tag in `aspia-server.container` and in the examples of this file in step
with `versions.env` in this repository.

## 9. Older Podman: no Quadlet (fallback)

Quadlet needs Podman 4.4 or later, and this unit's health check keys need 4.5 (a 4.4.1 generator rejects
`HealthCmd`: `unsupported key 'HealthCmd'`). On Debian 12 (Podman 4.3), Ubuntu 22.04 (Podman 3.4) and RHEL 8
before 8.10 use `podman run`, then let Podman write a systemd unit, as root:

```shell
sudo install -d /etc/aspia-server
sudo install -m 0644 podman/aspia-server.env.example /etc/aspia-server/aspia-server.env
sudo podman volume create aspia-config
sudo podman volume create aspia-data
sudo podman run -d --name aspia-server --env-file /etc/aspia-server/aspia-server.env \
  -p 8060:8060 -p 8061:8061 -p 8062:8062 -p 8065:8065/udp -p 8070:8070 \
  -v aspia-config:/etc/aspia -v aspia-data:/var/lib/aspia \
  --health-cmd /usr/bin/aspia_health --health-interval 30s --health-timeout 10s \
  --health-retries 3 --health-start-period 60s \
  localhost/aspia-server:3.0.21
cd /etc/systemd/system
sudo podman generate systemd --new --files --name --restart-policy=always aspia-server
sudo podman rm -f aspia-server
sudo systemctl daemon-reload
sudo systemctl enable --now container-aspia-server.service
```

The image is the last line of the command, pinned to a version like everywhere else. Tested on Podman 3.4.4
(Ubuntu 22.04) with a stand-in image (see "What was tested"): the unit started, reported healthy, stopped in under
a second and started again. To update, change the tag in the generated
`/etc/systemd/system/container-aspia-server.service`, then `systemctl daemon-reload` and `systemctl restart
container-aspia-server.service`. `podman generate systemd` is deprecated in newer Podman in favour of Quadlet.

## 10. Troubleshooting

- `Unit aspia-server.service not found`: run `systemctl daemon-reload`; for a syntax problem in the
  unit, run the generator in dry-run mode and read its messages:
  `/usr/lib/systemd/system-generators/podman-system-generator --dryrun` (rootless: add `--user`; on some
  distributions the generator is `/usr/libexec/podman/quadlet`).
- Start fails with `image not known` or a pull error: the `Image=` name is not in this user's image store
  (build or load it as the same user, section 1) or is not a pullable name.
- `netavark: nftables error: unable to execute nft` (seen on Debian 13 installed without recommended
  packages): install the `nftables` package.
- `EXTERNAL_IP ... is not set`: the container exits on purpose without it. Set it in `aspia-server.env`.
- Rootless service stops when you log out: run `sudo loginctl enable-linger <user>`.
- `systemctl --user` says "Failed to connect to bus": you are not in a login session; log in over ssh or
  use `machinectl shell <user>@`.

## What was tested

By `tests/podman.sh`, which runs in CI on an Ubuntu 24.04 runner and was also run locally in a privileged
container with systemd for each variant (system-wide and rootless): the unit is generated without errors,
the container becomes healthy, the unit is wanted by `default.target`, `systemctl stop` finishes in well
under a second with the container exiting 0 on SIGTERM, the keys are identical after `systemctl restart`,
after a stop and start, and after systemd restarts a killed container, and the host-network edit of
section 4 works.

| Podman | Distribution | Image |
|---|---|---|
| 4.5.1 | Fedora 38 userland (quay.io/podman/stable:v4.5.1) | stand-in image |
| 4.9.3 | Ubuntu 24.04 | the real image |
| 5.4.2 | Debian 13 | the real image |
| 5.8.7 | Fedora 44 | the real image |

Not tested: a real reboot (a container restart stands in for it); SELinux enforcing; ufw and firewalld rules;
RHEL-family distributions themselves (the packages in AlmaLinux 8/9/10 are Podman 4.9.4 and 5.8.2, and Fedora
covers their Podman versions); Podman 4.5.0 (4.5.1 is the lowest tested); several Aspia clients and hosts
connecting through the Relay (no Client or Host was used).
