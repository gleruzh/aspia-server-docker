# CI and publishing

Three GitHub Actions workflows build, test and publish the image. The same files work in any
repository without edits: the image is published as `ghcr.io/<repository owner>/aspia-server`, and
to Docker Hub or Quay.io only when the owner has set their secrets.

| Workflow | Runs on | What it does |
|---|---|---|
| [`ci.yml`](../.github/workflows/ci.yml) | every pull request, weekly (Mondays), manual | `tests/lint.sh` (hadolint, shellcheck, actionlint, `scripts/versions.sh check`), builds the image, runs `tests/run.sh` against it, and scans it with Trivy. The scan is reported in the log, the run summary and the Security tab; it never fails the run. |
| [`publish.yml`](../.github/workflows/publish.yml) | push to `main` that changes `versions.env` or the image files; manual | Builds the image once, pushes it to GHCR by digest only, runs `tests/run.sh` against that digest, then tags it and copies it to the other registries. Signs it and attests its provenance. |
| [`upstream-watch.yml`](../.github/workflows/upstream-watch.yml) | every 6 hours; manual | Opens a pull request "chore: bump Aspia to X.Y.Z" when Aspia publishes a newer stable release with both x86_64 server packages. |

Dependabot ([`.github/dependabot.yml`](../.github/dependabot.yml)) opens pull requests, weekly, for
the pinned action SHAs and for the pinned digest of the Debian base image. Nothing is updated
silently. There is no scheduled rebuild: the base image is pinned by digest, so a rebuild would not
update it. Security updates of Debian arrive as a Dependabot pull request for the base digest; once
merged, it changes the Dockerfile and `publish.yml` publishes the new image.

## The version file

[`versions.env`](../versions.env) holds `ASPIA_VERSION` and the sha256 of both `.deb` packages. The
Dockerfile, the tests and the workflows read the version from there. Two places mirror it because
their syntax cannot read a file: the `ARG ASPIA_VERSION` default in the Dockerfile (the build fails
when it differs from `versions.env`) and the image tags in `docker-compose.yml` and the
documentation. `scripts/versions.sh check` (run by `tests/lint.sh` and CI) fails when any of them
differs; `scripts/versions.sh bump` changes all of them at once:

```shell
scripts/versions.sh bump 3.0.25 <router sha256> <relay sha256>
```

`scripts/aspia-release.sh fetch <version> <dir>` downloads both packages and prints their sha256
after checking them against the digest the GitHub API reports.

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
| secret `UPSTREAM_WATCH_TOKEN` | Fine-grained personal access token for this repository with **Contents: write** and **Pull requests: write**. When set, the bump pull request is opened with it, so `ci.yml` runs on it. | Optional |
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
  (`--ref`). Until these workflows are merged, only `ci.yml` runs (on pull requests).
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
  deletion. No approval is required (a single maintainer cannot approve their own pull requests), and admins can
  bypass the rules. A bump pull request opened with `GITHUB_TOKEN` gets no CI run, so its checks stay missing:
  set `UPSTREAM_WATCH_TOKEN`, push a commit to the branch, or merge as admin after reading the upstream-watch
  test result in the pull request.
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

## Enabling Quay.io

1. Create the repository on Quay.io, and a robot account with write permission to it.
2. Add the secrets `QUAY_USERNAME` (`namespace+robot`) and `QUAY_TOKEN`. If the repository is not
   `<GitHub owner>/aspia-server`, add the variable `QUAY_IMAGE`.
3. Run a publish manually. Quay.io has no description sync; edit it on quay.io if you want one.

## Publishing manually

In **Actions > Publish > Run workflow**, pick the branch and enter the version that its
`versions.env` contains (the run stops if they differ, because checksums exist for that version
only). Tick "dated tag" to also push `X.Y.Z-YYYYMMDD`. With the GitHub CLI:

```shell
gh workflow run publish.yml --ref main -f version=3.0.25
gh workflow run publish.yml --ref main -f version=3.0.25 -f dated_tag=true
```

A manual run publishes whatever the selected branch contains, including the floating tags. Run it
from `main` unless you are testing the workflow itself.

## Tags

| Tag | Moves? | Pushed by |
|---|---|---|
| `X.Y.Z` (e.g. 3.0.25) | Yes: every new build of that version replaces it | every publish |
| `X.Y.Z-YYYYMMDD` (e.g. 3.0.25-20261005) | Never: an existing dated tag is not overwritten | every publish after a merge, or a manual run with "dated tag" |
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

Two publishes of the same version never run at the same time (a second one waits).

## Verifying a published image

```shell
cosign verify ghcr.io/<owner>/aspia-server@sha256:<digest> \
  --certificate-identity-regexp '^https://github.com/<owner>/aspia-server-docker/\.github/workflows/publish\.yml@' \
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
it downloads them, checks their sha256 against the GitHub API digest, runs `scripts/versions.sh bump`,
builds the image, runs `tests/run.sh`, pushes the branch `aspia-bump/X.Y.Z` and opens the pull
request with the test result. If the tests fail, the pull request is a draft with the failure log,
and the run fails so that the owner is notified.

It does nothing when a pull request for that version is already open. It also does nothing when one
was closed without merging, so that a rejected version is not proposed again every 6 hours; a manual
run with "force" opens a new one. Nothing is merged automatically: a new Aspia version has changed
the configuration format before, so a person reads the changelog and merges.

Two GitHub limitations, and how they are handled:

- **A pull request opened with `GITHUB_TOKEN` does not start workflows on its own**, so `ci.yml`
  does not simply run on the bump pull request. GitHub's current documentation says such a run is
  created but waits until someone with write access selects **Approve workflows to run** in the
  merge box; before that change it was not created at all. Either way, the workflow builds and tests
  in its own job and puts the result into the pull request description (the full log is an artifact
  of the run). To get `ci.yml` as well: approve the run if the banner is shown, close and reopen the
  pull request (a person's action starts CI), or set `UPSTREAM_WATCH_TOKEN`. Merging it is a
  person's push to `main`, so `publish.yml` runs normally.
- **Scheduled workflows are disabled after 60 days without activity in the repository** (GitHub
  emails the owner before), and in a fork they do not run until Actions is enabled. Merged bump
  pull requests count as activity. If it happens, re-enable the workflows in the Actions tab or with
  `gh workflow enable upstream-watch.yml` and `gh workflow enable publish.yml`. A manual run always
  works:

```shell
gh workflow run upstream-watch.yml --ref main
```

## Running the checks locally

```shell
tests/lint.sh    # hadolint, shellcheck, actionlint (pinned containers) and scripts/versions.sh check
tests/run.sh     # builds the image and runs the behaviour tests (needs Docker)
ASPIA_TEST_IMAGE=ghcr.io/<owner>/aspia-server:3.0.25 tests/run.sh   # tests a published image
```
