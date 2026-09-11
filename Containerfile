# SPDX-License-Identifier: BSD-2-Clause
# SPDX-FileCopyrightText: 2026 Aryan Ameri <github@aryan.ameri.coffee>

# Only the twenty extensions which Baikal needs are included.
ARG PHP_EXTENSIONS="dom,pdo,pdo_sqlite,sqlite3,zlib,mbstring,mbregex,iconv,session,xml,xmlreader,xmlwriter,simplexml,filter,tokenizer,ctype,pcntl,posix,opcache,openssl"
ARG BUILDER_IMAGE=dunglas/frankenphp:static-builder-gnu@sha256:24532f4de8d358a6f773dd347a20c343a30c0c68783be9a223ecba1ea2ccfa0f
ARG BAIKAL_VERSION=0.12.1
ARG BAIKAL_SHA256=0449abb72b151d39d9c08c63cb83a05d9e9adb065b1165ef6786b0b6a13d203c
ARG RUNTIME_IMAGE=gcr.io/distroless/cc-debian13:nonroot@sha256:c31ff9abcb1910f3ab25c7957bdaf0bfe12a01eb546e8df2282f1c8f682b606c

FROM ${BUILDER_IMAGE} AS frankenphp-build
ARG PHP_EXTENSIONS
WORKDIR /go/src/app
# glibc
RUN PHP_EXTENSIONS="${PHP_EXTENSIONS}" ./build-static.sh
RUN cp "$(ls /go/src/app/dist/frankenphp-linux-*)" /go/src/app/dist/frankenphp

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
COPY test/upstream-migrations.sh /tmp/upstream-migrations.sh
RUN /tmp/upstream-migrations.sh \
    /build/baikal/Core/Frameworks/BaikalAdmin/Controller/Install/VersionUpgrade.php

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
USER 65532:65532
ENTRYPOINT ["/usr/local/bin/frankenphp", "php-cli", "/usr/local/bin/baikal-bootstrap"]
