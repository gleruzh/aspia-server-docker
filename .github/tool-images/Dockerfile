# The tool images that tests/lint.sh, tests/run.sh and ci.yml run, pinned by tag and digest. This file
# is never built: it is a list in the one format Dependabot's docker ecosystem reads, so these pins
# get update pull requests like the base image. scripts/tool-image.sh NAME prints the image of
# "FROM <image> AS NAME"; tests/lint.sh checks the pins (docs/ci.md, "Tool images").
# Not here: the archived Aspia 2.7.0 image of tests/run.sh, a fixed test fixture that must not change.
FROM hadolint/hadolint:v2.14.0@sha256:27086352fd5e1907ea2b934eb1023f217c5ae087992eb59fde121dce9c9ff21e AS hadolint
FROM koalaman/shellcheck:v0.11.0@sha256:61862eba1fcf09a484ebcc6feea46f1782532571a34ed51fedf90dd25f925a8d AS shellcheck
FROM rhysd/actionlint:1.7.12@sha256:b1934ee5f1c509618f2508e6eb47ee0d3520686341fec936f3b79331f9315667 AS actionlint
FROM aquasec/trivy:0.74.0@sha256:62b1e65e8869bc4b4c6aa4fa2b21595256c7c2f6018a9d9ad61caf87187c1969 AS trivy
# Docker CLI with Compose v2.31, to check docker-compose.yml against the Compose v2 still common on
# servers. It stays on 27.3 on purpose (.github/dependabot.yml proposes digest updates only).
FROM docker:27.3-cli@sha256:328eb399a065780c2cebe9224de003aa14084cf69efae882ac27430f921819b7 AS compose-v2
