Task: harden the shipped container deployments: drop every Linux capability the server does not need, forbid privilege escalation, and make the image's own files read-only where the binaries allow it. Branch feat/hardening from feat/relay-standalone (PR 5); if PR 5 is merged, branch from main. The PR base is PR 5's branch until it is merged.

Read first: docs/dev/UPSTREAM-3.x-NOTES.md, Dockerfile, aspia_start (validate, prepare, drop_privileges, backup), aspia_health, docker-compose.yml, compose.router.yml, compose.relay.yml, podman/ (both units), .env.example, tests/run.sh, tests/podman.sh.

Who the user is: an administrator who wants the container to have as few privileges as possible without reading the code, and who starts it with the shipped compose file, the Quadlet unit or a plain `docker run`.

WHAT IS ASKED
- Compose files (all three): `cap_drop: [ALL]`, plus the minimum `cap_add` the entrypoint and the binaries really need; `security_opt: [no-new-privileges:true]`.
- If the binaries and the entrypoint allow it: `read_only: true` for the container's root filesystem, with `tmpfs` only for the paths that must be writable; the two volumes (/etc/aspia, /var/lib/aspia) stay writable. If something needs a writable path that cannot be a tmpfs, leave `read_only` out and say exactly why.
- A `pids_limit` with a value that leaves clear headroom over what the processes use (measure it).
- Podman Quadlet units (both): the same through `DropCapability=`, `AddCapability=`, `NoNewPrivileges=true`, `ReadOnly=true` / `Tmpfs=` and `PidsLimit=`, for the root and the rootless install. Rootless Podman already runs with fewer privileges; check what is still needed there and do not add what is not.
- README: the equivalent `docker run` flags, and one short paragraph on what is dropped and why each remaining capability is needed. Keep the existing README structure; the rewrite is PR 6.

HOW TO DECIDE THE CAPABILITIES
Measure, do not guess. The entrypoint runs as root and, depending on the settings, chowns the volumes for PUID/PGID, re-execs through setpriv, copies backups with their owner and mode, and writes files with restrictive modes. Start from nothing (`cap_drop: ALL`, no `cap_add`), run every mode and add back only what fails, with the exact error that showed it is needed. Modes to cover: role all, router and relay; new install, upgrade from 2.7.0 (the existing upgrade scenarios), existing install restarted; with and without PUID/PGID; a volume owned by another uid. The ports the server binds are all above 1024, so NET_BIND_SERVICE should not be needed; confirm it. If different modes need different capabilities, say whether one set for all is acceptable (fewer variants for the user) or whether the PUID/PGID case should document its extra capabilities separately; recommend one.

No behaviour change for existing users: an installation that works today must keep working after the update with the shipped files. If a hardening setting would break a supported setup (for example PUID/PGID on a volume owned by another user), that setup wins: document the trade-off and the override.

FILES
docker-compose.yml, compose.router.yml, compose.relay.yml, podman/aspia-server.container, podman/aspia-relay.container, README.md, docs/dev/UPSTREAM-3.x-NOTES.md (a new section with each measured fact: which capability, which operation needed it, the error without it), docs/dev/FOLLOWUPS.md, tests/. Change the Dockerfile or aspia_start only if a small change removes the need for a capability (for example a write to a path in the image), and say so.

TESTS
- tests/run.sh: run the scenarios with the hardening settings the compose files ship (the scenarios start containers with `docker run`, so pass the same flags there; one place in the test defines them). Every existing scenario must pass unchanged with them, including the 2.7.0 upgrade, PUID/PGID and the PR 5 role scenarios.
- One check that the shipped compose files really carry the settings (docker compose config), and one that a running container has exactly the expected capability set (/proc/1/status CapEff, or docker inspect).
- tests/podman.sh: the units with the new keys pass in the system and the rootless variant; the Quadlet generator accepts every key on Podman 4.5 (the documented minimum). If a key is newer than 4.5, say which version introduced it and what the unit does on older Podman.

OUT OF SCOPE
Seccomp or AppArmor/SELinux profiles of our own, user namespaces remapping, running as a non-root user by default (record it in FOLLOWUPS if the measurements show it is possible), Kubernetes securityContext, image signing (exists).

DELIVERABLE
The branch, the PR description (the final capability list with the reason for each, the read_only decision, the pids_limit value and how it was measured, what was not possible and why), the output of tests/lint.sh, tests/run.sh and tests/podman.sh.
