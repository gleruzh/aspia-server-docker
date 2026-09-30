Task: upgrade the Aspia server Docker image (Router + Relay in one container) from 2.7.0 to 3.0.21. Branch feat/aspia-3.0.21 from main.

Read first: docs/dev/UPSTREAM-3.x-NOTES.md (verified facts about the 3.0.21 binaries: config format, ports, paths, CLI flags), then the current Dockerfile, aspia_start, docker-compose.yml and README.md. If a decision needs a fact about 3.x that is not in the notes, verify it on the real binary and add it to the notes. Do not guess.

Starting point: do not write the image from scratch. Port the server image from SinitsaDA/aspia-server-docker (server/Dockerfile, server/aspia_start, server/aspia_health; GPL-3.0, cloned next to the working tree; see its assessment in the notes). Read every line you take and keep only what you understand and can justify against the requirements below; where its code and these requirements disagree, the requirements win. Keep this repository's layout and file names (Dockerfile, aspia_start and docker-compose.yml in the root) so existing users and links keep working. Do not port its updater/ directory, its import script, or anything that manages or updates containers from inside a container. Credit the source in the header of each ported file and in the PR description.

Who uses the result: administrators who run paprikkafox/aspia-server 2.7.0 today with data in ./data/config and ./data/database. They will switch the image, pull and run up -d. Afterwards their hosts and users must still be there, and the key configured on their hosts must keep working. This is the main acceptance criterion.

WHAT TO DO

Dockerfile
- ASPIA_VERSION is an ARG defaulting to 3.0.21. Pin the base image to a specific release by tag and digest (debian:<release>-slim@sha256:..., not stable) so builds are reproducible.
- Install Router and Relay from upstream GitHub Releases. Verify checksums: use upstream's if it publishes them, otherwise commit the sha256 values to the repository and check them at build time. Reason: the image installs third-party binaries as root, and a swapped release asset must not pass silently.
- Install with apt install ./file.deb so apt resolves dependencies. apt lists and the downloaded .deb files must not end up in the final layer.
- Remove what is not needed at runtime (htop and the like). Keep jq and moreutils only if the new entrypoint uses them.
- OCI labels: source, version, licenses, description. EXPOSE and VOLUME according to the notes.
- ENTRYPOINT in exec form. The current shell-form CMD with nohup does not forward signals, so docker stop waits for the timeout and kills the processes.
- HEALTHCHECK, see below.

Entrypoint (new aspia_start)
- First start on empty volumes: generate the Router and Relay configs, write the Router address and public key and the external address from EXTERNAL_IP into the Relay config, then start both processes. The current script generates configs on first start and exits, requiring a second start. Remove that behaviour.
- Start on 2.7.0 data: let upstream's own migration run (if it exists, see the notes), delete nothing, and make a copy next to any file before changing it. The script must not rename "corrupt" configs and generate new ones the way the current one does: that is how a user loses their keys.
- Later starts: idempotent. User configs are not overwritten, except for values explicitly set through variables.
- Both processes are children with proper SIGTERM and SIGINT handling: the signal is forwarded to both and the script waits for them to exit. If either process dies, the container exits non-zero so the restart policy applies.
- If the image has no init, either add tini or document the --init flag in the README. Pick one and explain why in the PR description.
- Log at startup: Aspia version, external address, the public key for hosts, the list of ports. Never print passwords.
- Keep the decision of which processes to start in one place in the script. A later PR adds a role switch (Router only, Relay only); it should be a small change, not a rewrite. Do not add the switch itself here.
- set -euo pipefail; shellcheck with no warnings.

Healthcheck
- healthy means: the Router is listening on its ports and the Relay is connected to the Router. Prefer a method that opens no network connections to the Router, so it neither pollutes the Router log nor trips its brute-force protection; for example, inspect socket state. If that cannot be made reliable, stop and describe the options.

docker-compose.yml
- Ports and volumes according to the notes. The Relay tells clients its own port, so ports must be published one-to-one; say so in a comment in the file.
- Keep the existing volume paths (./data/config -> /etc/aspia, ./data/database -> /var/lib/aspia).
- The image reference uses the exact version tag (3.0.21), not latest.
- restart: unless-stopped. EXTERNAL_IP has no default pointing at someone else's address; fail with a clear error if it is unset.

Tests (tests/)
One entry script, tests/run.sh, that builds the image and runs the scenarios on plain Docker with no external services. CI will call the same script later. Scenarios:
1. Clean start: the container becomes healthy, configs are created, the log contains the public key, the expected ports are listening.
2. Restart: keys and configs are unchanged (compare sha256).
3. Upgrade from 2.7.0: start the currently published 2.7.0 image, let it create data, stop it, start the new image on the same volumes. It becomes healthy, the public key for hosts is the same, the database is readable.
4. Stop: docker stop completes in under 10 seconds with exit code 0 or 143.
5. Process crash: kill the Relay inside the container; the container exits non-zero.
6. EXTERNAL_IP unset: a clear message and a non-zero exit code, with no junk configs generated.
The tests must check behaviour, not be fitted to the implementation. If scenario 3 fails, that is a finding to report, not a check to weaken.
Also: hadolint for the Dockerfile, shellcheck for every script.

README
Only the minimum so that it does not lie: version 3.0.21, the new ports, and an "Upgrading from 2.x" section (what happens to the data, which extra ports to open, which host and console versions are compatible, all per the notes). Do not restructure the existing bilingual README; the documentation rewrite is a separate PR.

OUT OF SCOPE
GitHub Actions, new environment variables other than EXTERNAL_IP, Podman, translations, running Router and Relay separately, container self-update. Write ideas to docs/dev/FOLLOWUPS.md.

DELIVERABLE
The branch with commits, a file with the PR description (Summary, Why, Changes, Breaking changes, How to test, Out of scope), and a report: full output of tests/run.sh, hadolint and shellcheck; image size before and after; a list of everything you could not verify.
