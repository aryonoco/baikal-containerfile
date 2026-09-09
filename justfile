# SPDX-License-Identifier: BSD-2-Clause
# SPDX-FileCopyrightText: 2026 Aryan Ameri <github@aryan.ameri.coffee>

set shell := ["bash", "-euo", "pipefail", "-c"]

ENGINE := env_var_or_default("ENGINE", "docker")
IMAGE := "localhost/baikal:dev"

default:
    @just --list

# Build the image locally
build:
    # -f is required: Docker only auto-discovers `Dockerfile`, never
    # `Containerfile`. Podman finds either, and accepts -f too, so naming it
    # explicitly is the one form that works on both engines.
    {{ENGINE}} build -f Containerfile -t {{IMAGE}} .

# Run the acceptance suite against a locally built image
test: build
    ENGINE={{ENGINE}} IMAGE={{IMAGE}} ./test/acceptance.sh

# Every static gate CI runs
lint:
    # No native macOS hadolint in mise; the official image needs nothing
    # installed and is what CI runs too.
    {{ENGINE}} run --rm -i ghcr.io/hadolint/hadolint:latest < Containerfile
    # Piped with -r so an empty match is a pass. A bare `shellcheck test/*.sh`
    # exits 123 ("No files specified") before test/ exists, which would make
    # `just lint` fail for every task up to Task 5.
    git ls-files '*.sh' | xargs -r shellcheck
    reuse lint

# Everything CI runs
ci: lint test
