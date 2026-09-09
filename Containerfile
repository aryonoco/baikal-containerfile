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

FROM ${BUILDER_IMAGE} AS frankenphp-build
ARG PHP_EXTENSIONS
WORKDIR /go/src/app
# glibc rather than musl, deliberately: musl's iconv is materially weaker and
# sabre/vobject converts charsets on vCards. Upstream recommends this build.
RUN PHP_EXTENSIONS="${PHP_EXTENSIONS}" ./build-static.sh
# Normalise the architecture-specific output name. static-php-cli emits
# frankenphp-linux-x86_64 or frankenphp-linux-aarch64 depending on the build
# platform, and the stage that consumes this must not have to know which.
RUN cp "$(ls /go/src/app/dist/frankenphp-linux-*)" /go/src/app/dist/frankenphp
