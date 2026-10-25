# SPDX-License-Identifier: BSD-2-Clause
# SPDX-FileCopyrightText: 2026 Aryan Ameri <github@aryan.ameri.coffee>

# Only the twenty extensions which Baikal needs are included.
ARG PHP_EXTENSIONS="dom,pdo,pdo_sqlite,sqlite3,zlib,mbstring,mbregex,iconv,session,xml,xmlreader,xmlwriter,simplexml,filter,tokenizer,ctype,pcntl,posix,opcache,openssl"
ARG BUILDER_IMAGE=dunglas/frankenphp:static-builder-gnu@sha256:669ae28dbffe76ea4f498016d675824f87d750878c2181b5e19eae333a0d7333
# The binary's own roots. Unset, build-static.sh takes the newest PHP 8.5 from
# php.net and xcaddy the newest Caddy and plugins, so two builds of one commit
# ship different binaries. test/pinned-versions.sh checks the binary agrees.
ARG PHP_VERSION=8.5.12
ARG CADDY_VERSION=v2.11.7
ARG CBROTLI_VERSION=v1.0.1
ARG MERCURE_VERSION=v1.1.5
ARG VULCAIN_VERSION=v1.4.5
# Renovate moves these two in one PR and computes the checksum itself; its
# regex needs them adjacent and in this order.
ARG BAIKAL_VERSION=0.13.0
ARG BAIKAL_SHA256=81e74df123230e863f608d228fdd7b9a1a788f60b04d37e6973c302192e83f32
ARG RUNTIME_IMAGE=gcr.io/distroless/cc-debian13:nonroot@sha256:83b9b50586253821cf63ffcec87d3d94265a093ad30da232039af962dd8f4edf

FROM ${BUILDER_IMAGE} AS frankenphp-build
ARG PHP_EXTENSIONS
ARG PHP_VERSION
ARG CADDY_VERSION
ARG CBROTLI_VERSION
ARG MERCURE_VERSION
ARG VULCAIN_VERSION
WORKDIR /go/src/app
# glibc
RUN PHP_EXTENSIONS="${PHP_EXTENSIONS}" \
    PHP_VERSION="${PHP_VERSION}" \
    CADDY_VERSION="${CADDY_VERSION}" \
    SPC_CMD_VAR_FRANKENPHP_XCADDY_MODULES="--with github.com/dunglas/caddy-cbrotli@${CBROTLI_VERSION} --with github.com/dunglas/mercure/caddy@${MERCURE_VERSION} --with github.com/dunglas/vulcain/caddy@${VULCAIN_VERSION}" \
    ./build-static.sh
RUN cp "$(ls /go/src/app/dist/frankenphp-linux-*)" /go/src/app/dist/frankenphp
COPY test/pinned-versions.sh /tmp/pinned-versions.sh
RUN /tmp/pinned-versions.sh /go/src/app/dist/frankenphp "${PHP_VERSION}" \
    "${CADDY_VERSION}" "${CBROTLI_VERSION}" "${MERCURE_VERSION}" "${VULCAIN_VERSION}"

FROM debian:13-slim AS fetch
ARG BAIKAL_VERSION
ARG BAIKAL_SHA256
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

COPY --from=frankenphp-build --chmod=0755 /go/src/app/dist/frankenphp /usr/local/bin/frankenphp
COPY --from=fetch --chown=root:root /build/baikal /var/www/baikal
COPY --chown=root:root caddy/Caddyfile /etc/caddy/Caddyfile
COPY --from=fetch --chown=65532:65532 /data /data

# Trailing slashes are mandatory
ENV BAIKAL_PATH_CONFIG=/data/config/ \
    BAIKAL_PATH_SPECIFIC=/data/Specific/ \
    XDG_DATA_HOME=/tmp \
    XDG_CONFIG_HOME=/tmp

COPY --chown=root:root --chmod=0755 rootfs/usr/local/bin/baikal-bootstrap /usr/local/bin/baikal-bootstrap
COPY --chown=root:root rootfs/usr/local/share/baikal-health /usr/local/share/baikal-health
COPY --chown=root:root --chmod=0755 rootfs/usr/local/bin/baikal-health /usr/local/bin/baikal-health

LABEL org.opencontainers.image.source="https://github.com/aryonoco/baikal-containerfile" \
    org.opencontainers.image.url="https://github.com/aryonoco/baikal-containerfile" \
    org.opencontainers.image.documentation="https://github.com/aryonoco/baikal-containerfile#readme" \
    org.opencontainers.image.title="Baikal" \
    org.opencontainers.image.description="Hardened Baikal CalDAV/CardDAV server on FrankenPHP and distroless" \
    org.opencontainers.image.licenses="BSD-2-Clause" \
    org.opencontainers.image.vendor="Aryan Ameri"

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
