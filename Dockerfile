# syntax=docker/dockerfile:1
#
# Aspia Server: Aspia Router and Aspia Relay in one container.
#
# Parts of this file are ported from SinitsaDA/aspia-server-docker (server/Dockerfile,
# commit de15b99, GPL-3.0), https://github.com/SinitsaDA/aspia-server-docker
# Ported: LANG=C.UTF-8, installing the release .deb files with apt, the EXPOSE list, a
# HEALTHCHECK script. Changed: pinned base image, checksum verification, no curl in the image,
# an init process, logs to stdout.

ARG ASPIA_VERSION=3.0.21

# Debian 13 (trixie) slim, pinned by tag and index digest so that builds are reproducible.
FROM debian:trixie-slim@sha256:a99cfc517144bc59b1978475ec53b46ecabec7e43635402ee5b77cc54cd1b20a AS base

# ---------------------------------------------------------------------------------------------
# Stage 1: download the release packages and verify them against checksums.sha256.
# Upstream publishes no checksums for the Linux packages, so the values are committed to this
# repository. A replaced release asset, or a version with no committed checksums, fails the build.
FROM base AS fetch
ARG ASPIA_VERSION

ADD https://github.com/dchapyshev/aspia/releases/download/v${ASPIA_VERSION}/aspia-router-${ASPIA_VERSION}-x86_64.deb /pkg/
ADD https://github.com/dchapyshev/aspia/releases/download/v${ASPIA_VERSION}/aspia-relay-${ASPIA_VERSION}-x86_64.deb /pkg/
COPY checksums.sha256 /pkg/checksums.sha256

WORKDIR /pkg
RUN grep -E "  aspia-(router|relay)-${ASPIA_VERSION}-x86_64\.deb$" checksums.sha256 > SHA256SUMS || true; \
    if [ "$(wc -l < SHA256SUMS)" -ne 2 ]; then \
        echo "checksums.sha256 has no entries for Aspia ${ASPIA_VERSION}" >&2; exit 1; \
    fi; \
    sha256sum --strict -c SHA256SUMS

# ---------------------------------------------------------------------------------------------
# Stage 2: the runtime image.
FROM base
ARG ASPIA_VERSION
ARG IMAGE_SOURCE=https://github.com/paprikkafox/aspia-server-docker

LABEL org.opencontainers.image.title="Aspia Server" \
      org.opencontainers.image.description="Aspia Router and Aspia Relay in one container" \
      org.opencontainers.image.version="${ASPIA_VERSION}" \
      org.opencontainers.image.source="${IMAGE_SOURCE}" \
      org.opencontainers.image.licenses="GPL-3.0-only"

# LANG: avoids Qt's warning about the "C" locale.
# ASPIA_LOG_*: read by the Aspia binaries. Send the full log to docker logs, write no log files.
ENV ASPIA_VERSION=${ASPIA_VERSION} \
    LANG=C.UTF-8 \
    ASPIA_LOG_TO_STDOUT=1 \
    ASPIA_LOG_TO_FILE=0

# The packages are bind-mounted from the fetch stage, so they never become part of a layer.
# apt resolves their dependencies (libdbus-1-3). tini is PID 1, jq edits the 2.x relay.json
# before upstream's migration. The package postinst runs "--install", a no-op while no
# configuration exists; no user data is mounted during the build.
# Package versions are not pinned: the base image is pinned by digest, and Debian stable
# only receives security fixes.
# hadolint ignore=DL3008
RUN --mount=type=bind,from=fetch,source=/pkg,target=/tmp/pkg \
    apt-get update \
    && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
        jq \
        tini \
        "/tmp/pkg/aspia-router-${ASPIA_VERSION}-x86_64.deb" \
        "/tmp/pkg/aspia-relay-${ASPIA_VERSION}-x86_64.deb" \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/*

COPY --chmod=0755 aspia_start aspia_health /usr/bin/
COPY --chmod=0644 aspia_common.sh /usr/lib/aspia-server/aspia_common.sh

# Configuration and keys; database.
VOLUME ["/etc/aspia", "/var/lib/aspia"]

# 8060 2.x hosts | 8061 3.x hosts | 8062 clients | 8063 relays -> router | 8065/udp STUN
# 8070 relay peers. Publish ports one-to-one: the Relay announces its own port to peers.
EXPOSE 8060 8061 8062 8063 8065/udp 8070

HEALTHCHECK --interval=30s --timeout=10s --start-period=60s --start-interval=2s --retries=3 \
    CMD ["/usr/bin/aspia_health"]

# tini reaps zombies and passes signals to aspia_start, which forwards them to both processes.
# -s: also works when started with "docker run --init" (tini is then not PID 1).
ENTRYPOINT ["/usr/bin/tini", "-s", "--", "/usr/bin/aspia_start"]
