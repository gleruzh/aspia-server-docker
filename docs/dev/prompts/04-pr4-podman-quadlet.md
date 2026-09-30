Task: add a ready-made way to run aspia-server under Podman as a systemd service. Branch feat/podman-quadlet from main if feat/env-config is merged; otherwise branch from feat/env-config and use it as the PR base.

Read first: docs/dev/UPSTREAM-3.x-NOTES.md, docker-compose.yml, .env.example, aspia_start (how it handles signals and what it treats as healthy).

Who the user is: a server administrator on a RHEL-compatible distribution, Fedora or Debian, where Docker is not installed but Podman ships with the system. They want to copy a couple of files, run systemctl daemon-reload and start, and get a service that survives reboots.

WHAT TO DO (directory podman/)
- aspia-server.container - a Quadlet unit: image, ports, volumes, EnvironmentFile, HealthCmd, restart policy, [Install] WantedBy. Reference the image by a version tag, not latest, and do not add the io.containers.autoupdate label: this project does not auto-update running containers. In the README give the manual update steps: change the tag, systemctl daemon-reload, restart.
- Volumes as separate .volume units or as host directories. Pick one as the primary path and show the other in the README. For host directories use the :Z suffix and explain SELinux in a sentence.
- aspia-server.env.example with the same variables as .env.example. Do not duplicate the descriptions; link to the table in the README.
- Two install variants, both tested: system-wide (/etc/containers/systemd/, as root) and rootless (~/.config/containers/systemd/, systemctl --user, loginctl enable-linger). For rootless, check and document what happens to ports, to the STUN UDP port, and to client source addresses. If the Router applies IP allow-lists or per-address brute-force protection and rootless networking rewrites the source address, say so explicitly and offer a solution.
- Networking: choose between published ports and Network=host and explain the choice. Remember that the Relay tells clients its own port.
- Determine by testing the minimum Podman version the unit works with, and record it.
- Fallback for older Podman without Quadlet: a short README section with podman run and podman generate systemd, no extra files.
- If you write an install script, it only copies files and prints the next commands. It enables nothing and does not touch the firewall; firewalld and ufw rules go into the README as text.
- The image reference in the unit must be easy to change in one place, and the README must say so: the image name depends on who publishes it.

VERIFICATION
- Validate the generated systemd unit with a dry run of the Quadlet generator (podman-system-generator --dryrun, or its path on your distribution). No errors.
- On a machine with Podman: the service starts, podman healthcheck run reports healthy, systemctl stop finishes without a timeout, keys are the same after systemctl restart.
- If your environment has no systemd or no Podman, say so plainly and list what remains unverified. Do not substitute reasoning for a test.
- Add tests/podman.sh with these checks. If the CI workflows are already on main, add a separate job for it (GitHub's ubuntu runners have Podman preinstalled); otherwise leave instructions in FOLLOWUPS.

OUT OF SCOPE
Kubernetes manifests and podman kube play, Helm, image changes. If Podman needs a change in the image or entrypoint, stop and describe exactly what and why.

DELIVERABLE
The branch, the PR description, the verification output with the Podman version and distribution, and the list of what was not verified.
