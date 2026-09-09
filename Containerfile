# SPDX-License-Identifier: BSD-2-Clause
# SPDX-FileCopyrightText: 2026 Aryan Ameri <github@aryan.ameri.coffee>

# Twenty extensions, against the ~70 in upstream's default static build. gd,
# intl, ldap, soap, redis, imagick and both MySQL and PostgreSQL drivers are
# absent on purpose: a vulnerability in any of them is then not this image's
# problem. pcntl is here because the entrypoint execs the server with it.
# xmlreader and xmlwriter are both required by sabre/xml
# (vendor/sabre/xml/composer.json), whose Writer class extends \XMLWriter and
# sits on every DAV response path; xml and simplexml alone are not enough.
ARG PHP_EXTENSIONS="dom,pdo,pdo_sqlite,sqlite3,zlib,mbstring,mbregex,iconv,session,xml,xmlreader,xmlwriter,simplexml,filter,tokenizer,ctype,pcntl,posix,opcache,openssl"
ARG BUILDER_IMAGE=dunglas/frankenphp:static-builder-gnu@sha256:24532f4de8d358a6f773dd347a20c343a30c0c68783be9a223ecba1ea2ccfa0f
ARG BAIKAL_VERSION=0.12.1
ARG BAIKAL_SHA256=0449abb72b151d39d9c08c63cb83a05d9e9adb065b1165ef6786b0b6a13d203c
ARG RUNTIME_IMAGE=gcr.io/distroless/cc-debian13:nonroot@sha256:c31ff9abcb1910f3ab25c7957bdaf0bfe12a01eb546e8df2282f1c8f682b606c

FROM ${BUILDER_IMAGE} AS frankenphp-build
ARG PHP_EXTENSIONS
WORKDIR /go/src/app
# glibc rather than musl, deliberately, for performance: musl's allocator is
# markedly slower under allocation-heavy workloads, and serving a PHP request is
# thousands of small allocations. Upstream recommends this build for production.
RUN PHP_EXTENSIONS="${PHP_EXTENSIONS}" ./build-static.sh
# Normalise the architecture-specific output name. static-php-cli emits
# frankenphp-linux-x86_64 or frankenphp-linux-aarch64 depending on the build
# platform, and the stage that consumes this must not have to know which.
RUN cp "$(ls /go/src/app/dist/frankenphp-linux-*)" /go/src/app/dist/frankenphp

# The archive ships vendor/ complete, so this is an unpack rather than a
# Composer run, and no build toolchain reaches the final image.
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

FROM ${RUNTIME_IMAGE}

COPY --from=frankenphp-build --chmod=0755 /go/src/app/dist/frankenphp /usr/local/bin/frankenphp
COPY --from=fetch --chown=root:root /build/baikal /var/www/baikal
COPY --chown=root:root caddy/Caddyfile /etc/caddy/Caddyfile
# An empty, pre-owned mount point rather than a runtime chown: this image has
# no shell and no CAP_CHOWN to fix ownership at start. A fresh named volume
# mounted over an image path that already exists inherits that path's
# ownership on its first mount (Docker's and Podman's shared "copy-up"
# behaviour) - without this the volume is created root:root and the
# entrypoint's own mkdir into it fails under --user 65532:65532.
COPY --from=fetch --chown=65532:65532 /data /data

# Trailing slashes are mandatory: the framework concatenates these directly
# with "baikal.yaml" and "db/db.sqlite" (Flake/Framework.php:168-182).
# XDG_* send Caddy's own state to the tmpfs, which is why /run is not needed.
ENV BAIKAL_PATH_CONFIG=/data/config/ \
    BAIKAL_PATH_SPECIFIC=/data/Specific/ \
    XDG_DATA_HOME=/tmp \
    XDG_CONFIG_HOME=/tmp

COPY --chown=root:root --chmod=0755 rootfs/usr/local/bin/baikal-bootstrap /usr/local/bin/baikal-bootstrap

EXPOSE 8080
USER 65532:65532
ENTRYPOINT ["/usr/local/bin/frankenphp", "php-cli", "/usr/local/bin/baikal-bootstrap"]
