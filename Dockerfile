# syntax=docker/dockerfile:1
#
# Aspia Server: Aspia Router and Aspia Relay in one container.
#
# Parts of this file are ported from SinitsaDA/aspia-server-docker (server/Dockerfile,
# commit de15b99, GPL-3.0), https://github.com/SinitsaDA/aspia-server-docker
# Ported: LANG=C.UTF-8, installing the release .deb files with apt, the EXPOSE list, a
# HEALTHCHECK script. Changed: pinned base image, checksum verification, no curl in the image,
# an init process, logs to stdout.

# The version and the package checksums come from versions.env. Dockerfile syntax cannot read a
# file into an ARG, so this default mirrors versions.env for a plain "docker build ." (CI passes
# --build-arg ASPIA_VERSION from versions.env). The fetch stage fails when the two differ, and
# scripts/versions.sh bump updates both.
ARG ASPIA_VERSION=3.0.24

# Debian 13 (trixie) slim, pinned by tag and index digest so that builds are reproducible.
FROM debian:trixie-slim@sha256:a99cfc517144bc59b1978475ec53b46ecabec7e43635402ee5b77cc54cd1b20a AS base

# ---------------------------------------------------------------------------------------------
# Stage 1: download the release packages and verify them against versions.env.
# Upstream publishes no checksums for the Linux packages, so the values are committed to this
# repository. A replaced release asset, or a version other than the one in versions.env, fails
# the build.
FROM base AS fetch
ARG ASPIA_VERSION

WORKDIR /pkg
COPY versions.env /pkg/versions.env
RUN pinned="$(sed -n 's/^ASPIA_VERSION=//p' versions.env)"; \
    if [ "${pinned}" != "${ASPIA_VERSION}" ]; then \
        echo "ASPIA_VERSION=${ASPIA_VERSION}, but versions.env pins Aspia ${pinned} (checksums exist only for that version)" >&2; \
        exit 1; \
    fi

ADD https://github.com/dchapyshev/aspia/releases/download/v${ASPIA_VERSION}/aspia-router-${ASPIA_VERSION}-x86_64.deb /pkg/
ADD https://github.com/dchapyshev/aspia/releases/download/v${ASPIA_VERSION}/aspia-relay-${ASPIA_VERSION}-x86_64.deb /pkg/

RUN printf '%s  %s\n' \
        "$(sed -n 's/^ASPIA_ROUTER_SHA256=//p' versions.env)" "aspia-router-${ASPIA_VERSION}-x86_64.deb" \
        "$(sed -n 's/^ASPIA_RELAY_SHA256=//p' versions.env)" "aspia-relay-${ASPIA_VERSION}-x86_64.deb" \
        > SHA256SUMS \
    && sha256sum --strict -c SHA256SUMS

# ---------------------------------------------------------------------------------------------
# Stage 2: the runtime image.
FROM base
ARG ASPIA_VERSION
# The repository the image is built from; the publish workflow passes it. Empty for local builds.
ARG IMAGE_SOURCE=""

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
# before upstream's migration. curl and ca-certificates are only for ASPIA_RELAY_PUBLIC_ADDRESS
# (EXTERNAL_IP)=auto (aspia_start queries a public "what is my IP" endpoint over HTTPS); curl was
# removed from this image in PR 1 and is reintroduced for this one feature (PR 3). The package
# postinst runs "--install", a no-op while no configuration exists; no user data is mounted during
# the build.
# Package versions are not pinned: the base image is pinned by digest, and Debian stable
# only receives security fixes.
# hadolint ignore=DL3008
RUN --mount=type=bind,from=fetch,source=/pkg,target=/tmp/pkg \
    apt-get update \
    && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
        ca-certificates \
        curl \
        jq \
        tini \
        "/tmp/pkg/aspia-router-${ASPIA_VERSION}-x86_64.deb" \
        "/tmp/pkg/aspia-relay-${ASPIA_VERSION}-x86_64.deb" \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/*

COPY --chmod=0755 aspia_start aspia_health /usr/bin/
# The directory is created first and separately: "COPY --chmod=0644" would otherwise apply that
# same mode to the new directory too (a buildkit quirk), leaving it without an execute bit and
# unreadable by anyone but root -- invisible until PR 3's PUID/PGID made a non-root user read it.
RUN mkdir -m 0755 /usr/lib/aspia-server
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
# The server is the default command; a command given to "docker run <image> ..." runs instead
# (for example "aspia_router --reset-otp admin" or "bash"), still under tini.
ENTRYPOINT ["/usr/bin/tini", "-s", "--"]
CMD ["/usr/bin/aspia_start"]
