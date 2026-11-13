# SPDX-License-Identifier: BSD-2-Clause
# SPDX-FileCopyrightText: 2026 Aryan Ameri <github@aryan.ameri.coffee>

set shell := ["mise", "exec", "--", "bash", "-euo", "pipefail", "-c"]

ENGINE := env_var_or_default("ENGINE", "docker")
IMAGE := "localhost/baikal:dev"
ARCHIVE := env_var_or_default("ARCHIVE", "/tmp/baikal-image.tar")
LAYOUT := ARCHIVE + ".layout"
REPORT := ARCHIVE + ".report.json"
SARIF := ARCHIVE + ".sarif"
PUBLISHED := env_var_or_default("PUBLISHED", "ghcr.io/divbast/baikal:latest")
BASELINE := ARCHIVE + ".published.json"

# The lint recipes, and _github-token, come from divbast/ci's common.just.
# Each is run from a recipe's body, never named as a dependency, so
# `just setup` still runs before .ci exists.
import? '.ci/just/common.just'

# Tool versions live in mise.toml

default:
    @just --list

# Fetch divbast/ci at the commit the workflows pin, then install the toolchain
setup: ci-checkout
    #!/usr/bin/env bash
    # Not through the mise exec shell: this is what installs what it runs
    set -euo pipefail
    mise install
    composer install

# Fetch divbast/ci at the commit the workflows pin, into .ci, and nothing else
ci-checkout:
    #!/usr/bin/env bash
    # Not through the mise exec shell, which would first install what is missing
    set -euo pipefail
    # The one commit the workflows call divbast/ci at, spelt in any case
    uses="^[[:space:]]*(-[[:space:]]+)?uses:[[:space:]]*[\"']?divbast/ci/[^@[:space:]\"']+@[^[:space:]\"'#]+"
    sha=$(grep -hoiE "${uses}" .github/workflows/*.y*ml | sed 's/.*@//' | sort -u | paste -sd ' ' - || true)
    if [[ ! "${sha}" =~ ^[0-9a-f]{40}$ ]]; then
        echo "ci-checkout: the workflows must call divbast/ci at one full commit SHA, not at: ${sha:-none}" >&2
        exit 1
    elif [[ "$(git -C .ci rev-parse HEAD 2>/dev/null || true)" == "${sha}" ]]; then
        echo "ci-checkout: .ci is already at ${sha}"
        exit 0
    fi
    changed=$([[ ! -e .ci/.git ]] || git -C .ci status --porcelain)
    if [[ -n "${changed}" ]]; then
        printf 'ci-checkout: moving .ci to %s would carry its own changes across, or stop on them; save or discard them first:\n%s\n' "${sha}" "${changed}" >&2
        exit 1
    fi
    git init -q .ci
    git -C .ci fetch -q --depth 1 https://github.com/divbast/ci "${sha}"
    git -C .ci checkout -q FETCH_HEAD && rm -rf .ci/bin

# Build the image locally
build:
    # GITHUB_TOKEN reaches spc as a build secret, not a build argument, so
    # its GitHub API calls escape the unauthenticated rate limit. It is
    # refused unless it is a fine-grained token or CI's job token. Docker
    # only auto-discovers `Dockerfile`.
    {{ just_executable() }} _github-token
    {{ ENGINE }} build --secret id=github_token,env=GITHUB_TOKEN -f Containerfile -t {{ IMAGE }} .

acceptance:
    ENGINE={{ ENGINE }} IMAGE={{ IMAGE }} ./test/acceptance.sh

# The Go acceptance suite, which runs beside the bash one above until it
# replaces it: app.just's acceptance line, since app.just cannot be
# imported while this file keeps its own build and scan. It names .ci
# where app.just has common.just's ci_dir, which is undefined until .ci
# is checked out, and this file must parse before then for just setup.
go-acceptance:
    [ -x .ci/bin/divbast-testcount ] || {{ just_executable() }} ci-tools
    set -o pipefail; ENGINE={{ ENGINE }} IMAGE={{ IMAGE }} go test -json -count=1 -timeout 90m ./test/acceptance/... | .ci/bin/divbast-testcount

# Build the image, then run the acceptance suite against it
test: build acceptance

# Write the image
archive:
    {{ ENGINE }} image save -o {{ ARCHIVE }} {{ IMAGE }}

# Fail on any HIGH or CRITICAL vulnerability the published image does not have
scan:
    rm -rf {{ LAYOUT }} && mkdir {{ LAYOUT }} && tar xf {{ ARCHIVE }} -C {{ LAYOUT }}
    ./test/scan.sh {{ LAYOUT }} {{ REPORT }} {{ PUBLISHED }} {{ BASELINE }} {{ SARIF }}

# Every lint gate. Needs a running Docker daemon, for docker build --check
lint:
    {{ just_executable() }} ci-fresh actions-check workflow-audit actionlint shell-lint go-lint go-test reuse-lint
    hadolint Containerfile
    # BuildKit's own linter
    docker build --check -f Containerfile .
    vendor/bin/phpstan analyse --no-progress

# Every gate. Run before committing
ci:
    {{ just_executable() }} lint test archive scan
