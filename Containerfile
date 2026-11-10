# SPDX-License-Identifier: BSD-2-Clause
# SPDX-FileCopyrightText: 2026 Aryan Ameri <github@aryan.ameri.coffee>

# Only the twenty extensions which Baikal needs are included.
ARG PHP_EXTENSIONS="dom,pdo,pdo_sqlite,sqlite3,zlib,mbstring,mbregex,iconv,session,xml,xmlreader,xmlwriter,simplexml,filter,tokenizer,ctype,pcntl,posix,opcache,openssl"
ARG BUILDER_IMAGE=dunglas/frankenphp:static-builder-gnu@sha256:4dcdd53971ba1f373c3eb90e393dd3944687938c5c03494ab684921594905fc7
# The binary's own roots. Unset, build-static.sh takes the newest PHP 8.5 from
# php.net and xcaddy the newest Caddy and plugins, so two builds of one commit
# ship different binaries. test/pinned-versions.sh checks the binary agrees.
ARG PHP_VERSION=8.5.12
ARG CADDY_VERSION=v2.11.9
ARG CBROTLI_VERSION=v1.0.1
ARG MERCURE_VERSION=v1.1.6
ARG VULCAIN_VERSION=v1.4.6
# static-php-cli, which build-static.sh would otherwise download as an
# unchecked nightly binary on every build. Its v3 branch has no tags, so
# Renovate follows the branch head by commit. test/pinned-spc.sh checks it ran.
ARG SPC_COMMIT=ff04d4af9ba44f6c194239d733e0529cc6ddecea
# Renovate moves these two in one PR and computes the checksum itself; its
# regex needs them adjacent and in this order.
ARG BAIKAL_VERSION=0.13.0
ARG BAIKAL_SHA256=81e74df123230e863f608d228fdd7b9a1a788f60b04d37e6973c302192e83f32
ARG RUNTIME_IMAGE=gcr.io/distroless/cc-debian13:nonroot@sha256:cc66d222f0a7ec996b78a99fe76a969bc80b539a5016ad866c14d1949bc6d0ab

FROM ${BUILDER_IMAGE} AS frankenphp-build
ARG PHP_EXTENSIONS
ARG PHP_VERSION
ARG CADDY_VERSION
ARG CBROTLI_VERSION
ARG MERCURE_VERSION
ARG VULCAIN_VERSION
ARG SPC_COMMIT
# No WORKDIR: BuildKit stamps the directory one creates with
# SOURCE_DATE_EPOCH, which build.yml sets to the commit time, and that gave
# this whole stage a new cache key on every commit. Every path below is
# absolute instead.
# spc from source at the pinned commit: git checks a fetch by commit against
# its hash, and composer installs from that commit's own lock file.
# build-static.sh skips its nightly download when dist/spc is executable, so
# the wrapper there runs this checkout instead, and records each subcommand
# for test/pinned-spc.sh. Both downloads get three retries, 10s, 30s and 90s
# apart, so one dropped connection does not cost the daily slot.
RUN set -eux; \
    retry() { \
        for delay in 10 30 90; do "$@" && return 0; sleep "${delay}"; done; \
        "$@"; \
    }; \
    git init -q /opt/static-php-cli; \
    retry git -C /opt/static-php-cli fetch -q --depth 1 \
        https://github.com/crazywhalecc/static-php-cli.git "${SPC_COMMIT}"; \
    git -C /opt/static-php-cli checkout -q --detach FETCH_HEAD; \
    retry composer install --working-dir=/opt/static-php-cli \
        --no-dev --no-interaction --prefer-dist; \
    mkdir -p /go/src/app/dist; \
    printf '%s\n' '#!/bin/sh' \
        "echo \"\$1\" >>/go/src/app/dist/spc.calls" \
        "exec php /opt/static-php-cli/bin/spc \"\$@\"" >/go/src/app/dist/spc; \
    chmod 0755 /go/src/app/dist/spc
# glibc
# The plugins go through XCADDY_ARGS, which build-static.sh writes into
# craft.yml. spc applies craft.yml's extra-env over the environment, so
# SPC_CMD_VAR_FRANKENPHP_XCADDY_MODULES set here would lose to its unversioned
# default and xcaddy would fetch the newest release of every plugin.
# PHP_EXTENSION_LIBS replaces craft.yml's extra libraries, whose libavif and
# nghttp2/3 and ngtcp2 serve extensions this build leaves out and are linked
# by nothing. watcher is FrankenPHP's file watcher; build-static.sh appends
# brotli, which caddy-cbrotli needs, whatever this says.
# spc asks the GitHub API which release of each library to fetch, and a call
# refused at the unauthenticated rate limit fails the build. The token comes
# as a secret, which no layer, history entry or cache key ever holds, as they
# would an ARG or ENV. Without the secret GITHUB_TOKEN is empty, and spc then
# sends no token at all.
RUN --mount=type=secret,id=github_token,env=GITHUB_TOKEN \
    PHP_EXTENSIONS="${PHP_EXTENSIONS}" \
    PHP_EXTENSION_LIBS=watcher \
    PHP_VERSION="${PHP_VERSION}" \
    CADDY_VERSION="${CADDY_VERSION}" \
    XCADDY_ARGS="--with github.com/dunglas/caddy-cbrotli@${CBROTLI_VERSION} --with github.com/dunglas/mercure/caddy@${MERCURE_VERSION} --with github.com/dunglas/vulcain/caddy@${VULCAIN_VERSION}" \
    /go/src/app/build-static.sh
RUN cp "$(ls /go/src/app/dist/frankenphp-linux-*)" /go/src/app/dist/frankenphp
COPY test/pinned-versions.sh /tmp/pinned-versions.sh
RUN /tmp/pinned-versions.sh /go/src/app/dist/frankenphp "${PHP_VERSION}" \
    "${CADDY_VERSION}" "${CBROTLI_VERSION}" "${MERCURE_VERSION}" "${VULCAIN_VERSION}"
COPY test/pinned-spc.sh /tmp/pinned-spc.sh
RUN /tmp/pinned-spc.sh /go/src/app/dist /opt/static-php-cli "${SPC_COMMIT}"

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

LABEL org.opencontainers.image.source="https://github.com/divbast/baikal-oci-image" \
    org.opencontainers.image.url="https://github.com/divbast/baikal-oci-image" \
    org.opencontainers.image.documentation="https://github.com/divbast/baikal-oci-image#readme" \
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
