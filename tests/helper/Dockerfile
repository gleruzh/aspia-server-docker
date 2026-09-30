# syntax=docker/dockerfile:1
# Test helper: tools the product image does not ship (sqlite3 to read the Router database,
# openssl to derive X25519 public keys from private keys). Used only by tests/run.sh.
FROM debian:trixie-slim@sha256:a99cfc517144bc59b1978475ec53b46ecabec7e43635402ee5b77cc54cd1b20a

# Versions are not pinned: this image never ships, and the base image is pinned by digest.
# hadolint ignore=DL3008
RUN apt-get update \
    && apt-get install -y --no-install-recommends sqlite3 openssl \
    && rm -rf /var/lib/apt/lists/*

COPY x25519_pub /usr/local/bin/x25519_pub
