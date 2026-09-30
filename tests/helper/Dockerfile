# syntax=docker/dockerfile:1
# Test helper: tools the product image does not ship (sqlite3 to read the Router database,
# openssl to derive X25519 public keys from private keys). Used only by tests/run.sh.
# BASE_IMAGE: the product base image; tests/run.sh passes it from the product Dockerfile.
ARG BASE_IMAGE
FROM ${BASE_IMAGE}

# Versions are not pinned: this image never ships, and the base image is pinned by digest.
# hadolint ignore=DL3008
RUN apt-get update \
    && apt-get install -y --no-install-recommends sqlite3 openssl \
    && rm -rf /var/lib/apt/lists/*

COPY x25519_pub /usr/local/bin/x25519_pub
