# SPDX-License-Identifier: BSD-2-Clause
# SPDX-FileCopyrightText: 2026 Aryan Ameri <github@aryan.ameri.coffee>

# Every recipe runs through `mise exec`, so a gate uses the binary mise.toml
# pins and never whatever the machine happens to carry on PATH. A developer who
# has not run `mise activate` and a CI runner that has done nothing but install
# mise therefore reach the same verdict, which is the whole point of pinning.
set shell := ["mise", "exec", "--", "bash", "-euo", "pipefail", "-c"]

ENGINE := env_var_or_default("ENGINE", "docker")
IMAGE := "localhost/baikal:dev"

# Every gate below is pinned to an exact version, and CI runs these same
# invocations rather than its own. Two reasons, both of which have bitten this
# kind of setup before: an unpinned linter turns a green branch red on a day
# nobody changed anything, which trains everyone to re-run the job instead of
# reading it; and a gate configured differently in the two places makes
# `just ci` a statement about a pipeline that does not exist. Bumping a pin is
# then a commit, reviewed like any other, with the new findings in the diff.
# The pins themselves live in mise.toml, bar PHPStan's, which composer.lock
# holds because mise's only PHP backend builds PHP from source.

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

# Every static gate CI runs
lint:
    # By path, not piped over stdin. This used to run the official hadolint
    # image because mise had no native macOS build; the aqua backend has one,
    # so the container is gone and the file is named on the command line -
    # which also means a finding reports `Containerfile:12` rather than `-:12`.
    hadolint Containerfile
    # Piped with -r so an empty match is a pass. A bare `shellcheck test/*.sh`
    # exits 123 ("No files specified") before test/ exists, which would make
    # `just lint` fail for every task up to Task 5.
    #
    # enable=all and severity=style live in .shellcheckrc rather than on this
    # line, so an editor's ShellCheck and CI's reach the same verdict. Nothing
    # in this tree carries a `shellcheck disable=` directive and nothing may.
    git ls-files '*.sh' | xargs -r shellcheck
    reuse lint
    # level max plus bleedingEdge, over the two PHP files this repository owns
    # and no others - see phpstan.neon. No baseline and no ignoreErrors: both
    # would silence our own code along with the two symbols the image supplies,
    # which stubs/baikal-image.php declares properly instead.
    #
    # From vendor/, not the phpstan container it used to run in, and pinned by
    # composer.lock rather than an image digest. The host's PHP is the same 8.5
    # the image ships, so the analyser meets the language the entrypoint will
    # actually run on - and phpstan.neon fixes the analysis target anyway.
    # `just setup` is what puts this binary there.
    vendor/bin/phpstan analyse --no-progress

# Everything CI runs
ci: lint test
