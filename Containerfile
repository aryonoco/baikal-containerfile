# SPDX-License-Identifier: BSD-2-Clause
# SPDX-FileCopyrightText: 2026 Aryan Ameri <github@aryan.ameri.coffee>

# Renovate moves these two in one PR and computes the checksum itself; its
# regex needs them adjacent and in this order.
ARG BAIKAL_VERSION=0.13.0
ARG BAIKAL_SHA256=81e74df123230e863f608d228fdd7b9a1a788f60b04d37e6973c302192e83f32
ARG RUNTIME_IMAGE=gcr.io/distroless/cc-debian13:nonroot@sha256:cb87acc574abe719b6e5c547384defa2f7b1f24af9605d3f618cf852495d8be2

FROM debian:13-slim@sha256:a72b4433de1cf7d6bae0c4cee74d0547f58601a643b3375f070c51600d63b6b2 AS fetch
ARG BAIKAL_VERSION
ARG BAIKAL_SHA256
# DL3008 asks for apt versions to be pinned. The base is pinned by digest, and
# unzip, curl and their certificates only fetch and unpack Baikal here: the
# image takes nothing from this stage but Baikal's own files and /data.
# hadolint ignore=DL3008
RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends unzip ca-certificates curl; \
    rm -rf /var/lib/apt/lists/*; \
    curl -fsSL -o /tmp/baikal.zip \
    "https://github.com/sabre-io/Baikal/releases/download/${BAIKAL_VERSION}/baikal-${BAIKAL_VERSION}.zip"; \
    printf '%s  /tmp/baikal.zip\n' "${BAIKAL_SHA256}" > /tmp/baikal.zip.sha256; \
    sha256sum -c /tmp/baikal.zip.sha256; \
    unzip -q /tmp/baikal.zip -d /build; \
    test -f /build/baikal/Core/Distrib.php; \
    test -d /build/baikal/vendor; \
    mkdir -p /data
COPY test/upstream-upgrade-api.sh /tmp/upstream-upgrade-api.sh
RUN /tmp/upstream-upgrade-api.sh /build/baikal

FROM ${RUNTIME_IMAGE}

# The binary divbast/frankenphp builds for this image, by digest. CI
# refuses it unless that repository's own build on main attested it.
COPY --from=ghcr.io/divbast/frankenphp:baikal@sha256:306d2a9ea0fac662f0109f71cfb3d7edbe295b7c617cbfdce7464913d1a61116 --chmod=0755 /frankenphp /usr/local/bin/frankenphp
COPY --from=fetch --chown=root:root /build/baikal /var/www/baikal
COPY --chown=root:root caddy/Caddyfile /etc/caddy/Caddyfile
COPY --chown=root:root php/baikal.ini /etc/frankenphp/php.d/baikal.ini
COPY --from=fetch --chown=65532:65532 /data /data

# Trailing slashes are mandatory
ENV BAIKAL_PATH_CONFIG=/data/config/ \
    BAIKAL_PATH_SPECIFIC=/data/Specific/ \
    XDG_DATA_HOME=/tmp \
    XDG_CONFIG_HOME=/tmp

COPY --chown=root:root --chmod=0755 rootfs/usr/local/bin/baikal-bootstrap /usr/local/bin/baikal-bootstrap
COPY --chown=root:root rootfs/usr/local/share/baikal-health /usr/local/share/baikal-health
COPY --chown=root:root --chmod=0755 rootfs/usr/local/bin/baikal-health /usr/local/bin/baikal-health

# The licences: this repository's, Baikal's, those of the libraries and
# assets Baikal's release ships in vendor/ and html/res/, and FrankenPHP's.
# The README's "Licences in the image" says which file carries which.
ARG BAIKAL_VERSION
LABEL org.opencontainers.image.source="https://github.com/divbast/baikal-oci-image" \
    org.opencontainers.image.url="https://github.com/divbast/baikal-oci-image" \
    org.opencontainers.image.title="Baikal" \
    org.opencontainers.image.version="${BAIKAL_VERSION}" \
    org.opencontainers.image.licenses="BSD-2-Clause AND GPL-3.0-only AND BSD-3-Clause AND MIT AND OFL-1.1"

EXPOSE 8080 8081
# --timeout must clear baikal-health's own budget: it allows each of its two
# sockets 4s and runs them in sequence, so a listener that accepts and never
# answers costs 8s. A shorter timeout kills the probe mid-flight and records a
# bare engine timeout instead of the probe's own stderr line, and with no shell
# and no access log on :8081 that line is the only diagnostic there is.
HEALTHCHECK --interval=30s --timeout=10s --start-period=60s --retries=3 \
    CMD ["/usr/local/bin/frankenphp", "php-cli", "/usr/local/bin/baikal-health"]
USER 65532:65532
ENTRYPOINT ["/usr/local/bin/frankenphp", "php-cli", "/usr/local/bin/baikal-bootstrap"]
