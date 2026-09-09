# SPDX-License-Identifier: BSD-2-Clause
# SPDX-FileCopyrightText: 2026 Aryan Ameri <github@aryan.ameri.coffee>

set shell := ["bash", "-euo", "pipefail", "-c"]

ENGINE := env_var_or_default("ENGINE", "docker")
IMAGE := "localhost/baikal:dev"

# Every gate below is pinned to an exact version, and CI runs these same
# invocations rather than its own. Two reasons, both of which have bitten this
# kind of setup before: an unpinned linter turns a green branch red on a day
# nobody changed anything, which trains everyone to re-run the job instead of
# reading it; and a gate configured differently in the two places makes
# `just ci` a statement about a pipeline that does not exist. Bumping a pin is
# then a commit, reviewed like any other, with the new findings in the diff.
HADOLINT := "ghcr.io/hadolint/hadolint@sha256:32dac94127fd60b7b7e3fbfc65e1383b9b5e25c9bfd7b8536de7a539fe68a12d"
PHPSTAN := "ghcr.io/phpstan/phpstan:2.2.13@sha256:fda102448a1f9a771bc082edf5e0d04d96491f72d5d25edf7499ae94c14b08a7"
SHELLCHECK := "shellcheck-py==0.11.0.1"
REUSE := "reuse==6.2.0"

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
    # installed and is what CI runs too. By digest, not :latest - a tag that
    # moves on its own is not a gate, it is a schedule.
    {{ENGINE}} run --rm -i {{HADOLINT}} < Containerfile
    # Piped with -r so an empty match is a pass. A bare `shellcheck test/*.sh`
    # exits 123 ("No files specified") before test/ exists, which would make
    # `just lint` fail for every task up to Task 5.
    #
    # enable=all and severity=style live in .shellcheckrc rather than on this
    # line, so an editor's ShellCheck and CI's reach the same verdict. Nothing
    # in this tree carries a `shellcheck disable=` directive and nothing may.
    git ls-files '*.sh' | xargs -r uvx --from {{SHELLCHECK}} shellcheck
    uvx --from {{REUSE}} reuse lint
    # level max plus bleedingEdge, over the two PHP files this repository owns
    # and no others - see phpstan.neon. No baseline and no ignoreErrors: both
    # would silence our own code along with the two symbols the image supplies,
    # which stubs/baikal-image.php declares properly instead.
    {{ENGINE}} run --rm -v "{{justfile_directory()}}:/app" -w /app {{PHPSTAN}} analyse --no-progress

# Everything CI runs
ci: lint test
