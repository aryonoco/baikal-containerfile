# SPDX-License-Identifier: BSD-2-Clause
# SPDX-FileCopyrightText: 2026 Aryan Ameri <github@aryan.ameri.coffee>

set shell := ["mise", "exec", "--", "bash", "-euo", "pipefail", "-c"]

ENGINE := env_var_or_default("ENGINE", "docker")
IMAGE := "localhost/baikal:dev"
ARCHIVE := env_var_or_default("ARCHIVE", "/tmp/baikal-image.tar")
LAYOUT := ARCHIVE + ".layout"
REPORT := ARCHIVE + ".report.json"
SARIF := ARCHIVE + ".sarif"
PUBLISHED := env_var_or_default("PUBLISHED", "ghcr.io/aryonoco/baikal:latest")
BASELINE := ARCHIVE + ".published.json"

# Tool versions live in mise.toml

default:
    @just --list

setup:
    #!/usr/bin/env bash
    # This is the one recipe that must not run through `mise exec` shell 
    set -euo pipefail
    mise install
    composer install

# Build the image locally
build:
    # Docker only auto-discovers `Dockerfile`. Podman finds either
    {{ ENGINE }} build -f Containerfile -t {{ IMAGE }} .

acceptance:
    ENGINE={{ ENGINE }} IMAGE={{ IMAGE }} ./test/acceptance.sh

# Build the image, then run the acceptance suite against it
test: build acceptance

# Write the image
archive:
    {{ ENGINE }} image save -o {{ ARCHIVE }} {{ IMAGE }}

# Fail on any HIGH or CRITICAL vulnerability the published image does not have
scan:
    rm -rf {{ LAYOUT }} && mkdir {{ LAYOUT }} && tar xf {{ ARCHIVE }} -C {{ LAYOUT }}
    ./test/scan.sh {{ LAYOUT }} {{ REPORT }} {{ PUBLISHED }} {{ BASELINE }} {{ SARIF }}

# Verify every action is a SHA
actions-check:
    GITHUB_TOKEN="${GITHUB_TOKEN:-$(gh auth token)}" pinact run --verify --check

# Rewrite tag references to the SHA
actions-pin:
    GITHUB_TOKEN="${GITHUB_TOKEN:-$(gh auth token)}" pinact run

# Move every action to latest release
actions-update:
    GITHUB_TOKEN="${GITHUB_TOKEN:-$(gh auth token)}" pinact run --update

workflow-audit:
    GITHUB_TOKEN="${GITHUB_TOKEN:-$(gh auth token)}" \
      zizmor --persona=auditor .github/workflows

lint: actions-check workflow-audit
    hadolint Containerfile
    # BuildKit's own linter
    docker build --check -f Containerfile .
    # Piped with -r so an empty match is a pass
    git ls-files '*.sh' | xargs -r shellcheck
    reuse lint
    vendor/bin/phpstan analyse --no-progress

ci: lint test archive scan
