You are leading the upgrade of aspia-server-docker (a Docker image of the Aspia server: Router + Relay) from Aspia 2.7.0 to 3.0.21. You work in a clone of my fork, gleruzh/aspia-server-docker. Remote origin is the fork; remote upstream is paprikkafox/aspia-server-docker.

OWNERSHIP MODEL
The fork is the project's home. The original repository has been dormant since 2.7.0 (May 2024) and is not mine. All work lands in the fork: branches are pushed to origin, pull requests are opened against the fork's main, and I merge them. At the very end we offer the result to upstream. If upstream never responds, the fork must already be a complete, self-sufficient project. For the same reason nothing in the code may be tied to a specific owner: the same files must work unchanged in my fork and in paprikkafox's repository.

CONTEXT
Aspia is an open-source remote desktop system (github.com/dchapyshev/aspia, GPL-3.0). Its server side is Router and Relay; upstream publishes them as .deb and .rpm packages for Linux x86_64 in GitHub Releases. The current image installs the 2.7.0 .deb packages on debian:stable and starts both processes with the aspia_start script, which edits router.json and relay.json with jq. In 3.x the config format, key file names and port set changed, so the script must be rewritten, not just version-bumped. A third-party fork, SinitsaDA/aspia-server-docker, already packages 3.0.18. It has already solved the 2.x to 3.x config migration and a connection-free healthcheck, under the same GPL-3.0 licence, so PR 1 ports its server image code instead of writing from scratch. It is still not ground truth: it targets 3.0.18, and anything we take must be read, understood and verified against the real 3.0.21 binaries. Its updater container is not ported.

GOAL
Six pull requests in the fork, each self-contained and reviewable on its own:
1. feat/aspia-3.0.21 - image, entrypoint, healthcheck, compose, migration from 2.x, smoke tests.
2. ci/build-publish - CI: linters, tests, Aspia release tracking, publishing to registries.
3. feat/env-config - configuration through environment variables.
4. feat/podman-quadlet - running under Podman as a systemd service.
5. feat/relay-standalone - a role switch (all, router, relay) so a Relay can run on a separate host.
6. docs/i18n - documentation in several languages.
Then a prepared, not submitted, proposal for upstream.

HOW TO WORK
Step 0, reconnaissance - do this yourself, without subagents, because every later prompt depends on it. Use gh api to list the assets of releases v3.0.21 and v3.0.18. Download the Router and Relay .deb for 3.0.21, unpack them (dpkg-deb -x and -e), and record: package dependencies, binary paths, systemd units, postinst scripts. In a clean debian container run both binaries with --help, generate configs, and record their format, keys, defaults, listening ports, and the paths of keys, database and logs. Check what happens when /etc/aspia and /var/lib/aspia contain files produced by 2.7.0 (obtain them by running the current 2.7.0 image). Clone SinitsaDA/aspia-server-docker next to the working tree, read its README and everything under server/ (Dockerfile, aspia_start, aspia_health) and its publish workflow, and compare them with what you observed. Add a section to the notes: what each of its files does, what is sound and can be ported, what is wrong or outdated for 3.0.21, and what we deliberately leave behind. Write the result to docs/dev/UPSTREAM-3.x-NOTES.md: verified facts only, each with the command that verified it. This file is the single source of truth for all subagents.

Step 1 - PR 1, one Opus subagent. When it reports done, run the tests yourself and read the whole diff. Open the PR against the fork's main, then STOP and wait for me to review and merge it. Everything else builds on this PR, so I want to look at it before more work piles on top.
Step 2 - PR 2 (Opus) and PR 3 (Sonnet) in parallel, each in its own git worktree, branched from the fork's main.
Step 3 - PR 4 (Sonnet), after PR 3.
Step 4 - PR 5 (Opus), after PR 3 and PR 4: it touches the entrypoint and healthcheck again and adds a Relay-only compose file and Quadlet unit.
Step 5 - PR 6: one Sonnet subagent per language, in parallel, once the English README is frozen.
Step 6 - upstream proposal, see below.

Branching: create each branch from the fork's main. If a dependency is not merged yet, branch from the dependency's branch and set it as the PR base, so the diff shows only that PR's changes.

The subagent prompts are files in docs/dev/prompts/: 01-pr1-image-3.0.21.md, 02-pr2-ci-publish.md, 03-pr3-env-config.md, 04-pr4-podman-quadlet.md, 05-pr5-relay-standalone.md, 06a-pr6-docs-english.md, 06b-pr6-docs-translation.md. Pass the matching file's content to the subagent verbatim. If these files are not committed yet, commit them to main first (docs: add agent prompts) so worktrees can see them.

Give every subagent: its full prompt, the path to UPSTREAM-3.x-NOTES.md, its branch name and base branch, and the list of files it may change. A subagent cannot see this conversation; everything it needs must be in its prompt or in the repository.

RULES FOR ALL PRS
- Do not state anything about Aspia 3.x behaviour from memory or from someone else's README. If a fact is not in UPSTREAM-3.x-NOTES.md, verify it and add it there.
- linux/amd64 only. Upstream ships no ARM server packages; do not add arm64 to any matrix and do not emulate.
- No secrets, logins or owner names in code. Image names default to the repository owner (github.repository_owner) and can be overridden by repository variables; registries are enabled by the presence of secrets.
- Keep backward compatibility for users of paprikkafox/aspia-server:2.7.0: same volume paths, the EXTERNAL_IP variable, and their data must survive the upgrade. Anything that cannot be preserved becomes an explicit item under Breaking changes in the PR description.
- If you take code or ideas from the SinitsaDA fork (GPL-3.0, compatible licence), credit it in the PR description and in the file header.
- Keep the existing credits to Dmitry Chapyshev and paprikkafox in README and LICENSE.
- Commits: Conventional Commits, in English. PR descriptions in English: what, why, how to test, breaking changes, what was deliberately left out.
- No auto-update of running containers, anywhere: no updater container, no Watchtower in examples, no podman auto-update label or timer, nothing that mounts the Docker socket. Users pin a version tag and update by hand when they decide to. Building and publishing a new image when Aspia releases is fine; changing what runs on someone's server without them is not.
- Pin everything. Every image reference we ship (compose files, Quadlet units, docker run examples, README in every language) uses an exact version tag such as 3.0.21, never latest and never a floating 3 or 3.0. The base image in the Dockerfile is pinned by tag and digest. GitHub Actions are pinned by commit SHA. The docs also show how to pin our image by digest for those who want immutability. Reason: in production an unpinned image changes under you on the next pull.
- Each PR is exactly as large as its stated scope. Write unrelated improvements to docs/dev/FOLLOWUPS.md instead of making them.

DEFINITION OF DONE
For each PR: the tests in tests/ pass locally; hadolint and shellcheck are clean; you have read the diff and can explain every line; the PR description is written. A subagent that says "done" must attach the output of the verification commands. Do not accept a result without that output.

WHAT YOU MAY DO WITHOUT ASKING
Push branches to origin and open pull requests in the fork. Do not merge pull requests and do not push to main: merging triggers publishing, and I want to be the one who decides that.

UPSTREAM PROPOSAL (Step 6)
Do not open anything in paprikkafox's repository. It is an action in my name in someone else's repository and cannot be taken back. Instead write docs/dev/UPSTREAMING.md containing: the text of an issue that describes what the fork offers and asks whether the maintainer wants it as one PR or as a series; ready PR titles and descriptions for both options; and a list of everything in the fork that is fork-specific (README links, badges, image names in examples) with the exact change needed for upstream. Show me the file and stop.

STOP AND ASK ME if: 3.0.21 cannot read 2.7.0 data; the healthcheck cannot be done without opening network connections to the Router; something needs secrets or permissions you do not have; you conclude that one of the six PRs is unnecessary or should be split.

When everything is finished, give me a summary: branches, links to the PRs in the fork, what was verified and with which command, what remains in FOLLOWUPS.md, and what I have to do by hand.
