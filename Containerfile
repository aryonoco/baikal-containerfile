# SPDX-License-Identifier: BSD-2-Clause
# SPDX-FileCopyrightText: 2026 Aryan Ameri <github@aryan.ameri.coffee>

ARG BAIKAL_VERSION=0.12.1
ARG BAIKAL_SHA256=0449abb72b151d39d9c08c63cb83a05d9e9adb065b1165ef6786b0b6a13d203c
ARG BASE_IMAGE=docker.io/library/php:8.5-apache@sha256:609de4eac65a03f20975441c9c3f313811d785575f0d02413c630753ab5c5532

FROM ${BASE_IMAGE} AS fetch
ARG BAIKAL_VERSION
ARG BAIKAL_SHA256
# The release archive is self-contained and ships vendor/, so no Composer runs
# here and no build toolchain reaches the final image.
SHELL ["/bin/bash", "-o", "pipefail", "-c"]
# Unpinned deliberately: this stage is discarded and none of these packages
# reach the final image, so nothing here ships. Pinning would instead
# guarantee a hard failure the first time Debian supersedes one of these
# builds, which is exactly the moment the weekly rebuild most needs to keep
# working.
# hadolint ignore=DL3008
RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends \
      unzip \
      ca-certificates \
      curl; \
    rm -rf /var/lib/apt/lists/*; \
    curl -fsSL -o /tmp/baikal.zip \
      "https://github.com/sabre-io/Baikal/releases/download/${BAIKAL_VERSION}/baikal-${BAIKAL_VERSION}.zip"; \
    echo "${BAIKAL_SHA256}  /tmp/baikal.zip" | sha256sum -c -; \
    unzip -q /tmp/baikal.zip -d /build; \
    test -f /build/baikal/Core/Distrib.php; \
    test -d /build/baikal/vendor

FROM ${BASE_IMAGE}
ARG BAIKAL_VERSION

# libsqlite3-dev is required to build pdo_sqlite; it is purged again once
# the extension is linked, and pdo_sqlite still loads afterwards because the
# runtime library (libsqlite3-0) is not removed with it. Left unpinned for
# the same reason as the fetch stage: it is purged before this layer is
# done, so it never ships, and a pin would fail outright once Debian
# supersedes the build, defeating the weekly rebuild it's meant to serve.
# hadolint ignore=DL3008
RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends libsqlite3-dev; \
    docker-php-ext-install pdo_sqlite; \
    apt-get purge -y --auto-remove libsqlite3-dev; \
    rm -rf /var/lib/apt/lists/*; \
    rm -rf /var/www/html

COPY --from=fetch --chown=root:root /build/baikal /var/www/baikal
COPY --chown=root:root rootfs/ /

# Trailing slashes are mandatory: Flake/Framework.php concatenates these
# directly with "baikal.yaml" and "db/db.sqlite".
ENV BAIKAL_PATH_CONFIG=/data/config/ \
    BAIKAL_PATH_SPECIFIC=/data/Specific/

EXPOSE 8080
USER 33:33
ENTRYPOINT ["/usr/local/bin/docker-entrypoint.sh"]
CMD ["apache2-foreground"]
