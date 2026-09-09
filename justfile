# SPDX-License-Identifier: BSD-2-Clause
# SPDX-FileCopyrightText: 2026 Aryan Ameri <github@aryan.ameri.coffee>

# Every recipe runs through `mise exec`, so a recipe resolves the tools
# mise.toml lists rather than whatever is on PATH. A recipe that needs
# something not listed there will not find it.
set shell := ["mise", "exec", "--", "bash", "-euo", "pipefail", "-c"]

ENGINE := env_var_or_default("ENGINE", "docker")
IMAGE := "localhost/baikal:dev"

# The file `just scan` reads. CI sets it to the OCI layout its build job
# exported and its test legs loaded, so the bytes scanned are the bytes tested;
# locally `just archive` writes one from the image the suite has just run
# against.
ARCHIVE := env_var_or_default("ARCHIVE", "/tmp/baikal-image.tar")

# Tool versions live in mise.toml, bar PHPStan's, which composer.lock holds
# because mise's only PHP backend builds PHP from source.

default:
    @just --list

# Install the pinned toolchain
setup:
    #!/usr/bin/env bash
    # A shebang recipe deliberately: this is the one recipe that must not run
    # through the `mise exec` shell above, because on a fresh clone the tools
    # that wrapper resolves are precisely what is missing.
    #
    # PHP and Composer themselves are not installed here and are expected on
    # PATH. mise can only offer a PHP it compiles from source, which is minutes
    # of every CI run to analyse two files.
    set -euo pipefail
    mise install
    composer install

# Build the image locally
build:
    # -f is required: Docker only auto-discovers `Dockerfile`, never
    # `Containerfile`. Podman finds either, and accepts -f too, so naming it
    # explicitly is the one form that works on both engines.
    {{ENGINE}} build -f Containerfile -t {{IMAGE}} .

# Run the acceptance suite against an image that already exists
acceptance:
    # Split out of `test` for CI, which builds each architecture once in a job
    # of its own and then hands that one image to that architecture's docker
    # and podman legs. This recipe is how a leg runs the suite against an image
    # it did not build.
    #
    # Without the split CI would have to rebuild inside each leg, and a
    # from-source PHP build is not bit-reproducible - so the engines would be
    # compared across two different images rather than one, which is the single
    # thing that matrix exists to rule out. The other way out would be a copy
    # of the line below living in YAML, free to drift from this file in
    # silence.
    ENGINE={{ENGINE}} IMAGE={{IMAGE}} ./test/acceptance.sh

# Build the image, then run the acceptance suite against it
test: build acceptance

# Write the image the suite ran against to {{ARCHIVE}}
archive:
    # The scanner reads a file rather than a name so that what it reads is the
    # artifact the suite ran against, not whatever the engine holds under that
    # tag by the time it is asked. CI downloads that file and never runs this.
    {{ENGINE}} image save -o {{ARCHIVE}} {{IMAGE}}

# Fail on any HIGH or CRITICAL vulnerability in {{ARCHIVE}}
scan:
    # Each statement in the VEX document names one advisory and one grpc
    # version, so a FrankenPHP bump that moves grpc stops them matching and the
    # findings come back rather than staying hidden behind the old argument.
    trivy image --input {{ARCHIVE}} --vex baikal.openvex.json \
      --severity HIGH,CRITICAL --exit-code 1

# Verify every action reference is a SHA and matches the tag its comment names
actions-check:
    # `gh` is the one tool here that mise does not provide, and it is only a
    # local fallback for the API token: CI passes GITHUB_TOKEN itself, and
    # nothing but pinact's GitHub API calls consumes it.
    GITHUB_TOKEN="${GITHUB_TOKEN:-$(gh auth token)}" pinact run --verify --check

# Rewrite tag references to the SHA they resolve to today
actions-pin:
    GITHUB_TOKEN="${GITHUB_TOKEN:-$(gh auth token)}" pinact run

# Move every pin to the action's latest release
actions-update:
    GITHUB_TOKEN="${GITHUB_TOKEN:-$(gh auth token)}" pinact run --update

# Every static gate CI runs
lint: actions-check
    # By path, not piped over stdin. This used to run the official hadolint
    # image because mise had no native macOS build; the aqua backend has one,
    # so the container is gone and the file is named on the command line -
    # which also means a finding reports `Containerfile:12` rather than `-:12`.
    hadolint Containerfile
    # BuildKit's own linter, over the same file the build parses. `docker`
    # rather than {{ENGINE}} because --check is a buildx flag and podman has no
    # equivalent; it resolves the base images' metadata, so it needs a network.
    docker build --check -f Containerfile .
    # Piped with -r so an empty match is a pass. A bare `shellcheck test/*.sh`
    # exits 123 ("No files specified") before test/ exists, which would make
    # `just lint` fail for every task up to Task 5.
    #
    # enable=all and severity=style live in .shellcheckrc rather than on this
    # line, so an editor's ShellCheck and this one read the same settings.
    git ls-files '*.sh' | xargs -r shellcheck
    reuse lint
    # level max plus bleedingEdge, over the two PHP files this repository owns
    # and no others - see phpstan.neon. No baseline and no ignoreErrors: both
    # would silence our own code along with the two symbols the image supplies,
    # which stubs/baikal-image.php declares properly instead.
    #
    # From vendor/, where `just setup` puts it; composer.lock is the version.
    # phpstan.neon fixes the analysis target, whichever PHP runs the analyser.
    vendor/bin/phpstan analyse --no-progress

# Every gate, locally
ci: lint test archive scan
