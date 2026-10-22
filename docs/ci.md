# CI and publishing

Five GitHub Actions workflows build, test and publish the image. The same files work in any
repository without edits: the image is published as `ghcr.io/<repository owner>/aspia-server`, and
to Docker Hub or Quay.io only when the owner has set their secrets.

| Workflow | Runs on | What it does |
|---|---|---|
| [`ci.yml`](../.github/workflows/ci.yml) | every pull request, weekly (Mondays), manual | `tests/lint.sh` (hadolint, shellcheck, actionlint, `scripts/versions.sh check`, the main-only checks of `publish.yml` and `dockerhub-description.yml`), builds the image and runs `tests/run.sh` against it in three shards side by side (`--shard 1/3` to `3/3`, each job builds the image itself), and scans it with Trivy in the first shard. The findings are reported in the log, the run summary and the Security tab; they never fail the run, but a scan that does not work does ([Tool images](#tool-images)). |
| [`publish.yml`](../.github/workflows/publish.yml) | push to `main` that changes `versions.env` or the image files; manual | Builds the image once, pushes it to GHCR by digest only, runs `tests/run.sh` against that digest, then tags it and copies it to the other registries. Signs it and attests its provenance. |
| [`upstream-watch.yml`](../.github/workflows/upstream-watch.yml) | every 6 hours; manual | Opens a pull request "chore: bump Aspia to X.Y.Z" when Aspia publishes a newer stable release with both x86_64 server packages. |
| [`rebuild.yml`](../.github/workflows/rebuild.yml) | daily; manual | Scans the published image with Trivy for vulnerabilities that have a fix, and starts `publish.yml` on `main` only if a rebuild would install such a fix. |
| [`dockerhub-description.yml`](../.github/workflows/dockerhub-description.yml) | push to `main` that changes `docs/dockerhub.md`; manual | Replaces the Docker Hub description with `docs/dockerhub.md` when the push starts no publish (see [Enabling Docker Hub](#enabling-docker-hub)). |

Dependabot ([`.github/dependabot.yml`](../.github/dependabot.yml)) opens pull requests, weekly, for
the pinned action SHAs, the pinned digest of the Debian base image and the pinned
[tool images](#tool-images). Nothing is updated silently. Security updates of Debian reach the image in two ways. A Dependabot pull request for the
base digest changes the Dockerfile; once merged, `publish.yml` publishes the new image. Between
those, the Dockerfile runs `apt-get upgrade`, so every build installs the current Debian packages,
and `rebuild.yml` starts a publish when the published image has a vulnerability that such a build
fixes (see [Rebuild for fixed vulnerabilities](#rebuild-for-fixed-vulnerabilities-rebuildyml)).
There is no rebuild on a timer alone: an image is published only when it changes.

## The version file

[`versions.env`](../versions.env) holds `ASPIA_VERSION` and the sha256 of both `.deb` packages. The
Dockerfile, the tests and the workflows read the version from there. Two places mirror it because
their syntax cannot read a file: the `ARG ASPIA_VERSION` default in the Dockerfile (the build fails
when it differs from `versions.env`) and the image tags in `docker-compose.yml` and the
documentation. `scripts/versions.sh check` (run by `tests/lint.sh` and CI) fails when any of them
differs; `scripts/versions.sh bump` changes all of them at once:

```shell
scripts/versions.sh bump 3.1.2 <router sha256> <relay sha256>
```

`scripts/aspia-release.sh fetch <version> <dir>` downloads both packages and prints their sha256
after checking them against the digest the GitHub API reports; it fails when the API reports no
digest. The digest shows that the download is the file GitHub stores for the release, not who built
it.

## Tool images

The images that the tests and CI run (hadolint, shellcheck, actionlint, Trivy, a Docker CLI with
Compose v2.31 for the Compose v2 check of `tests/run.sh`, and jq, which reads the `docker compose
config` output in `tests/run.sh`) are pinned by tag and digest in one file,
[`.github/tool-images/Dockerfile`](../.github/tool-images/Dockerfile), one
`FROM <image>:<tag>@sha256:<digest> AS <name>` line each. The file is never built; it is in the
format Dependabot's docker ecosystem reads, so Dependabot opens a weekly pull request (prefix `ci`)
when one of them has a new version or digest, and the CI run of that pull request shows whether the
new linter or scanner still passes. For Trivy this holds although its findings never fail CI: in
`ci.yml` and `rebuild.yml` the Trivy step fails when Trivy exits with an error or when its report is
not JSON or lists no OS packages (it did not scan the Debian packages). A failed download of the
Trivy database fails it too; run the job again. `tests/lint.sh`, `tests/run.sh`, `ci.yml` and
`rebuild.yml` read an image with `scripts/tool-image.sh <name>`. `tests/lint.sh` fails when a line
of the file is not pinned by tag and digest, when a name is used twice or a script or workflow asks
for a name the file does not have, or when a script or workflow pins an image of its own instead of
reading it from there.

One image is kept from moving on purpose: the Docker CLI stays on `docker:27.3-cli`. The check is
about the older Compose v2 still common on servers, so `.github/dependabot.yml` lets through digest
updates of that tag only. The tests no longer use an archived Aspia 2.7.0 image, because Aspia 3.1 does
not read 2.x data and no CI test upgrades from 2.x.

## Secrets and variables

Set them in **Settings > Secrets and variables > Actions** (secrets on the "Secrets" tab, variables
on the "Variables" tab). None is needed for GHCR.

| Secret or variable | Purpose | Required? |
|---|---|---|
| `GITHUB_TOKEN` (automatic) | Pushes to GHCR, signs, attests, opens the bump pull request. | Provided by GitHub |
| secret `DOCKERHUB_USERNAME` | Docker Hub account that pushes the image and edits its description. | Optional; Docker Hub is used only when both Docker Hub secrets are set |
| secret `DOCKERHUB_TOKEN` | Docker Hub personal access token of that account, scope **Read, Write, Delete** (the description update needs Delete). | Optional, together with `DOCKERHUB_USERNAME` |
| secret `QUAY_USERNAME` | Quay.io user or robot account (for a robot: `namespace+robotname`). | Optional; Quay.io is used only when both Quay secrets are set |
| secret `QUAY_TOKEN` | Password or robot token of that account, with write access to the repository. | Optional, together with `QUAY_USERNAME` |
| secret `UPSTREAM_WATCH_TOKEN` | Fine-grained personal access token for this repository with **Contents: write** and **Pull requests: write**. When set, the bump pull request is opened with it, so `ci.yml` runs on it. Only the job that pushes the branch and opens the pull request gets it. | Optional |
| variable `GHCR_IMAGE` | Image name on GHCR, without `ghcr.io/`, e.g. `my-org/aspia-server`. | Optional, default `<repository owner>/aspia-server` |
| variable `DOCKERHUB_IMAGE` | Image name on Docker Hub, without `docker.io/`. Set it when the Docker Hub account differs from the GitHub owner. | Optional, default `<repository owner>/aspia-server` |
| variable `QUAY_IMAGE` | Image name on Quay.io, without `quay.io/`. | Optional, default `<repository owner>/aspia-server` |

The default names are lowercased, as registries require. Each job of `publish.yml` computes the names itself with `scripts/image-names.sh`: GitHub drops a job output whose value contains a secret, and `<owner>/aspia-server` contains `DOCKERHUB_USERNAME` whenever the Docker Hub user is named like the GitHub owner. In the run log such names appear as `***`. Missing Docker Hub or Quay secrets are not
an error: the run logs "Docker Hub skipped" or "Quay.io skipped" and continues.

## Repository settings

- **Actions in a fork.** GitHub does not run workflows in a new fork until someone opens the
  **Actions** tab and enables them. Scheduled workflows do not run before that either.
- **Default branch.** Manual runs (`workflow_dispatch`) and schedules work only for workflow files
  that exist on the default branch; a manual run can then use the file from another branch
  (`--ref`), except `publish.yml`, which stops unless it runs from `main`. Until these workflows are
  merged, only `ci.yml` runs (on pull requests).
- **Pull requests from Actions.** For the bump pull request with `GITHUB_TOKEN`, enable
  **Settings > Actions > General > Workflow permissions > Allow GitHub Actions to create and
  approve pull requests** (or set `UPSTREAM_WATCH_TOKEN`). The workflows declare their own
  permissions, so the default "Read repository contents" setting can stay.
- **Package visibility.** The first push creates the GHCR package as private. Make it public once in
  the package settings (your profile or organisation > **Packages** > `aspia-server` > **Package
  settings** > **Change visibility**), so that users can pull without logging in.
- **Package created outside Actions.** If the `aspia-server` package was first pushed by hand (with a
  personal token, `docker push` or a local `act` run), the workflows get
  `denied: permission_denied: write_package` until the repository is given access: **Package
  settings** > **Manage Actions access** > **Add Repository** > this repository, role **Write**. A
  package created by `publish.yml` itself has that access already.
- **Branch protection on `main`.** Merges only through a pull request; the three CI checks (Lint, Build, test
  and scan, Podman Quadlet) must pass and the branch must be up to date with `main`; no force pushes, no
  deletion. "Build, test and scan (linux/amd64)" is a job that only collects the test shards: it passes when
  every shard passed, so adding or removing a shard needs no change here. No approval is required (a single
  maintainer cannot approve their own pull requests), and admins can bypass the rules. A bump pull request
  opened with `GITHUB_TOKEN` gets no CI run, so its checks stay missing:
  approve the run in the merge box (if shown), close and reopen the pull request, push a commit to the branch,
  or set `UPSTREAM_WATCH_TOKEN`. Do not merge it as admin on the upstream-watch result alone: that run has no
  Podman test and no Trivy scan, and its result is reported by the job that ran the new packages.
- **Code scanning.** The Trivy report in the Security tab needs code scanning, which is free for
  public repositories. On a private repository without GitHub Advanced Security the upload step
  fails without failing the run.

## Enabling Docker Hub

1. Create the repository on Docker Hub (e.g. `<account>/aspia-server`), or let the first push create it.
2. Create a personal access token (Docker Hub > Account settings > Personal access tokens) with
   scope Read, Write, Delete.
3. Add the secrets `DOCKERHUB_USERNAME` and `DOCKERHUB_TOKEN`. If the Docker Hub repository is not
   `<GitHub owner>/aspia-server`, add the variable `DOCKERHUB_IMAGE`.
4. Run a publish manually (below). The run copies the tested image to Docker Hub with the same
   digest, signs it there, and a separate job replaces the Docker Hub description with `docs/dockerhub.md`: a short page (Docker Hub cuts a description at 25,000 bytes, and the action truncates without an error) that links to the full `README.md` on GitHub. Its links are relative to the repository root, and the action completes them. Keep it in sync with `README.md` by hand.

A change to `docs/dockerhub.md` alone does not publish an image. `dockerhub-description.yml` updates
the description then, with the same job. When the push also changes a file that starts
`publish.yml` (a bump pull request changes both), it does nothing and leaves the update to
`publish.yml`, which makes it only after the image is published, so the page never names a version
that does not exist yet. It runs from `main` only and does nothing without the Docker Hub secrets.
If it has waited for a publish and `docs/dockerhub.md` on `main` has changed since its push, it
leaves the update to the run of that newer push, so an older file never replaces a newer one.
To update the description by hand:

```shell
gh workflow run dockerhub-description.yml --ref main
```

## Enabling Quay.io

1. Create the repository on Quay.io, and a robot account with write permission to it.
2. Add the secrets `QUAY_USERNAME` (`namespace+robot`) and `QUAY_TOKEN`. If the repository is not
   `<GitHub owner>/aspia-server`, add the variable `QUAY_IMAGE`.
3. Run a publish manually. Quay.io has no description sync; edit it on quay.io if you want one.

## Publishing manually

In **Actions > Publish > Run workflow**, leave the branch on `main` and enter the version that its
`versions.env` contains (the run stops if they differ, because checksums exist for that version
only). Tick "dated tag" to also push `X.Y.Z-YYYYMMDD`. With the GitHub CLI:

```shell
gh workflow run publish.yml --ref main -f version=3.1.2
gh workflow run publish.yml --ref main -f version=3.1.2 -f dated_tag=true
```

A run from any other branch or tag stops in its Plan step, before anything is built, so untested
code cannot move `latest` or the version tags. This guards against mistakes, not against someone with
write access: a manual run uses the copy of `publish.yml` from its own branch, and that copy can be
edited (its signature still fails the `cosign verify` below). For a hard barrier (optional), move the
Docker Hub and Quay.io secrets into a GitHub Environment limited to `main` and add `environment:` to
the jobs that use them; GHCR uses `GITHUB_TOKEN`, which an environment does not restrict.

## Tags

| Tag | Moves? | Pushed by |
|---|---|---|
| `X.Y.Z` (e.g. 3.1.2) | Yes: every new build of that version replaces it | every publish |
| `X.Y.Z-YYYYMMDD` (e.g. 3.1.2-20261005) | Never: an existing dated tag is not overwritten | every publish after a merge, or a manual run with "dated tag" |
| `X.Y`, `X`, `latest` | Yes, to the newest publish | every publish; for convenience only, nothing in this repository refers to them |

The digest of every publish is in the run summary, with the commands to verify it. Pin by digest for
an image that never changes. Only linux/amd64 is published, because Aspia publishes no arm64 server
packages.

## What a publish does

1. `scripts/versions.sh check`, then build the image once (no cache, fresh base pull) with an SBOM and
   `mode=max` provenance attached by BuildKit, and push it to GHCR **by digest only**: no tag points
   at it yet.
2. Run `tests/run.sh` against `ghcr.io/<owner>/aspia-server@<digest>`, the image that will be
   published.
3. Give that digest the tags in GHCR with `docker buildx imagetools create`, and copy it to Docker Hub
   and Quay.io the same way. This copies the image index unchanged, so the digest is identical
   everywhere; a later step checks every tag and fails if one differs.
4. Sign the digest in each registry with cosign (keyless, through the workflow's GitHub OIDC
   identity), and store a SLSA build provenance attestation in GitHub and in GHCR.

If the tests fail, the untagged digest stays in GHCR and nothing refers to it; delete it from the
package's version list if you like.

Two publishes never run at the same time, whatever their versions: the whole workflow, including
the Docker Hub description job, is in one concurrency group, so a second run waits until the first
has finished. GitHub keeps only the newest waiting run; an older waiting run is cancelled. The
description job of `dockerhub-description.yml` is in the same group, so it never edits the
description during a publish. Because a new waiting run would cancel a waiting publish, it does not
join the group while any publish waits to start (behind another publish or another description
update): the run fails with an error instead, and you re-run it once that publish has started. A
running publish is no reason to stop: the description job just waits for it. The check and the
moment the job joins the group are a few seconds apart, so a publish queued in exactly that gap can
still be cancelled; re-run it if that happens.

## Verifying a published image

The signature identity is pinned to `publish.yml` on `main`; a signature made by a run from any other
branch or tag does not verify.

```shell
cosign verify ghcr.io/<owner>/aspia-server@sha256:<digest> \
  --certificate-identity-regexp '^https://github.com/<owner>/aspia-server-docker/\.github/workflows/publish\.yml@refs/heads/main$' \
  --certificate-oidc-issuer https://token.actions.githubusercontent.com
gh attestation verify oci://ghcr.io/<owner>/aspia-server@sha256:<digest> -R <owner>/aspia-server-docker
docker buildx imagetools inspect ghcr.io/<owner>/aspia-server@sha256:<digest> --format '{{ json .SBOM }}'
```

The package pages on GHCR and Docker Hub list two platforms for each tag: `linux/amd64` and
`unknown/unknown`. The second one is not a second image. It is the attestation manifest that
BuildKit stores next to the image (the SBOM and the provenance), marked with the annotation
`vnd.docker.reference.type: attestation-manifest`. It cannot be run, and `docker pull` always takes
`linux/amd64`. The `docker pull ...@sha256:<index>@sha256:<entry>` commands that GHCR shows for each
platform are not valid; pin the index digest from the publish run summary instead.

## The bump pull request (upstream-watch.yml)

Every 6 hours the workflow lists the releases of `dchapyshev/aspia`, ignores drafts, pre-releases and
tags that are not `vX.Y.Z`, and compares the newest with `versions.env` of the branch it runs on. If
the release is newer and has both `aspia-router-X.Y.Z-x86_64.deb` and `aspia-relay-X.Y.Z-x86_64.deb`,
it opens a pull request from the branch `aspia-bump/X.Y.Z` with the test result. If the tests fail, the
pull request is a draft with the failure log, and the run fails so that the owner is notified.

The new packages are code from another repository: the image build installs them as root and
`tests/run.sh` runs them. So the work is split into three jobs, and only one of them runs that code:

| Job | Permissions | What it does |
|---|---|---|
| `check` | `contents: read`, `pull-requests: read` | Finds the release, downloads both packages without running them, and checks their sha256 against the GitHub API digest. |
| `test` | `contents: read`, no secrets | Runs `scripts/versions.sh bump`, `tests/lint.sh`, builds the image and runs `tests/run.sh`. Keeps the log as an artifact and reports the exit codes. |
| `open-pr` | `contents: write`, `pull-requests: write`, `UPSTREAM_WATCH_TOKEN` | Starts from a clean checkout, runs `scripts/versions.sh bump` again with the checksums from `check` (and stops if `test` reports others), commits, pushes the branch and opens the pull request. It never builds the image or runs the packages. |

What `test` reports is treated as untrusted: an exit code that is not a number counts as a failure,
and the log goes into the description inside a code block that it cannot close. A compromised
release could still make `test` report success, which is one more reason to let `ci.yml` run on the
pull request before merging. The branch is pushed with `--force-with-lease` against the state the
job has just read, so a rerun with "force" replaces the branch of a closed pull request but not a
push that lands in between.

It does nothing when a pull request for that version is already open. It also does nothing when one
was closed without merging, so that a rejected version is not proposed again every 6 hours; a manual
run with "force" opens a new one. Nothing is merged automatically: a new Aspia version has changed
the configuration format before, so a person reads the changelog and merges.

Two GitHub limitations, and how they are handled:

- **A pull request opened with `GITHUB_TOKEN` does not start workflows on its own**, so `ci.yml`
  does not simply run on the bump pull request. GitHub's current documentation says such a run is
  created but waits until someone with write access selects **Approve workflows to run** in the
  merge box; before that change it was not created at all. Either way, the workflow builds and tests
  in its own `test` job and puts the result into the pull request description (the full log is an artifact
  of the run). To get `ci.yml` as well: approve the run if the banner is shown, close and reopen the
  pull request (a person's action starts CI), or set `UPSTREAM_WATCH_TOKEN`. Merging it is a
  person's push to `main`, so `publish.yml` runs normally.
- **Scheduled workflows are disabled after 60 days without activity in the repository** (GitHub
  emails the owner before), and in a fork they do not run until Actions is enabled. Merged bump
  pull requests count as activity. If it happens, re-enable the workflows in the Actions tab or with
  `gh workflow enable upstream-watch.yml`, `gh workflow enable rebuild.yml` and
  `gh workflow enable publish.yml`. A manual run always works:

```shell
gh workflow run upstream-watch.yml --ref main
```

## Rebuild for fixed vulnerabilities (rebuild.yml)

Once a day the workflow takes the digest that the tag `X.Y.Z` (the version in `versions.env` of
`main`) has in GHCR. If that tag is not in GHCR yet (a version bump that `publish.yml` has not
published yet), the run ends there with a notice and succeeds. This applies only when the error is
"not found" and the image has a tag `latest`; every other error fails the run. Then it runs
`apt-get update` and `apt-get -s upgrade` in the image, which shows the packages that a new build
would upgrade. If there are none, it stops there. Otherwise it scans the image with Trivy
(`--ignore-unfixed`: only findings that have a fixed version); a Trivy error, or a report without
OS packages, fails the run instead of reading as "nothing to fix". Only when one of the upgradable
packages has a finding with a fix does it start `publish.yml` on `main`, with the version of
`versions.env` and a dated tag. The run summary lists the findings and the packages.

Why it is built like this:

- **No rebuild on a timer.** The weekly rebuild was removed (PR 15) because it changed nothing: the
  base image is pinned by digest, and the Dockerfile ran no `apt-get upgrade`. The Dockerfile now
  runs `apt-get upgrade`, so a build does install fixed Debian packages. A rebuild is started only
  when it fixes a known vulnerability. A finding without a fix, or a fix that is not in the Debian
  archive yet, starts nothing, and the next day's run checks again.
- **An ordinary publish.** The started run is `publish.yml` on `main` like a manual run: the Plan
  step accepts only `main` and the version of its `versions.env`, `tests/run.sh` runs against the
  new digest, the signature identity is `publish.yml@refs/heads/main`, and the run is in the
  concurrency group `publish`. The tag `X.Y.Z` moves to the new digest, and a new dated tag is the
  rollback point (an existing dated tag of the same day is kept).
- **No second publish.** If a publish is already queued or running, nothing is started: that run
  builds `main` with the current packages anyway, and a new waiting run would cancel a waiting one.
- **Least privilege.** The job `scan` has `contents: read` and `packages: read`; the job that starts
  the publish has only `actions: write` and runs no code from the repository. `tests/lint.sh` checks
  that the workflow starts `publish.yml` with `--ref main` only. It scans with the same pinned Trivy
  image as `ci.yml`, read from [`.github/tool-images/Dockerfile`](#tool-images).

A manual run checks at once:

```shell
gh workflow run rebuild.yml --ref main
```

## Running the checks locally

```shell
tests/lint.sh    # hadolint, shellcheck, actionlint (pinned containers), the tool image pins and scripts/versions.sh check
tests/run.sh     # builds the image and runs the behaviour tests (needs Docker)
ASPIA_TEST_IMAGE=ghcr.io/<owner>/aspia-server:3.1.2 tests/run.sh   # tests a published image
tests/run.sh --list              # the scenario groups with their weights (seconds in CI)
tests/run.sh --shard 2/3         # only the groups of shard 2 of 3, as the CI job for that shard
tests/run.sh upgrade split       # only these groups
```

The scenarios are in groups; the scenarios of a group share containers or volumes, so a group is
the unit of selection. `--shard` spreads the groups over the shards by the weights in `GROUP_TABLE`
at the end of `tests/run.sh`, the same way on every machine; update a weight when a group's time
in CI changes much (after each group the log prints `time <group>: N s (weight in GROUP_TABLE: W)`).
Shard 1 also runs the Trivy scan, so `SCAN_WEIGHT` (its time in CI) counts as its first load.
Every run has its own container, volume and network names, image tags and subnet, so several runs
(other worktrees, shards) can share one Docker host. `publish.yml` and `upstream-watch.yml` run the
whole suite, unsharded.
