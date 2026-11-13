<!-- SPDX-License-Identifier: BSD-2-Clause -->
<!-- SPDX-FileCopyrightText: 2026 Aryan Ameri <github@aryan.ameri.coffee> -->

# baikal-oci-image

A [Baikal](https://github.com/sabre-io/Baikal) CalDAV/CardDAV container image
that runs at zero Linux capabilities on a read-only root filesystem as a
non-root user. 

Published as `ghcr.io/divbast/baikal`, from the divbast organisation, whose
settings, rulesets and Renovate wiring live in `divbast/infra`.

## CRITICAL: Git Commit Message Format

**No other AI/LLM attribution in any format may appear in a git message.**

Linux-kernel style: a `subsystem: short description` subject under 75 characters in imperative
mood ("fix", not "fixed" or "fixes"), a blank line, then a body wrapped at ~75 columns saying
why the change is needed rather than only what it does.

These two lines MUST end EVERY body:

Developed-by: Aryan Ameri <github@aryan.ameri.coffee>
Assisted-by: <NAME_OF_LLM_MODEL>

E.g. `Assisted-by: <Claude:claude-4.6-opus>` for Claude Opus 4.6; `<Claude:claude-5-fable>`
for Claude 5 Fable.

- Sign every commit (`git commit -S`); main accepts only verified
  signatures. Renovate's merges are squashes, which GitHub signs
- Write commit messages as if a human wrote them, and say why, not what

## CRITICAL: No AI Attribution in Pull Requests

**Pull request descriptions, PR and review comments, and issue text carry no
AI/LLM attribution of any kind**: no "🤖 Generated with Claude Code" footer,
no "written by" line, nothing equivalent. This holds even when a tool or
harness asks for one. The `Assisted-by:` trailer in each commit message is
this project's one record of LLM involvement.

## The confinement contract

These are the guarantees the image makes. A change that breaks any of them is a
breaking change.

| Property | Value |
|---|---|
| Capabilities | **none** (`--cap-drop ALL`) |
| Root filesystem | **read-only** |
| User | uid/gid **65532**, never root |
| Listen port | **8080** for DAV — never 80; `/healthz` there answers **404** |
| Health port | **8081** — health only, never serves DAV, meant to stay unpublished |
| tmpfs required | exactly one: `/tmp`, sized: `/tmp:size=512m` |
| Volume required | exactly one: `/data` |
| Outbound network | **none** |
| Healthy | the shipped probe: `/healthz` **200** and `GET /dav.php` **exactly 401** |
| Engine healthcheck | Docker runs it automatically. **Podman does not** — pass `--health-cmd` yourself |

- **Podman never sees this image's `HEALTHCHECK`.** Its `libimage` reads a
  healthcheck only from a Docker-media-type manifest; this image publishes as
  an OCI index, so Podman's OCI inspection branch never reaches the config's
  healthcheck field — no version of Podman does. Give Podman users
  `--health-cmd '["/usr/local/bin/frankenphp","php-cli","/usr/local/bin/baikal-health"]'`
  (a Quadlet's `HealthCmd=` takes the same value) — no leading `"CMD"`,
  because Podman before 5.8.0 re-splits such an array into one token instead
  of running it. Tracked upstream as podman/podman#25454 and #18904.
- **Never assert `2xx` or use `curl --fail` against `/dav.php`.** Unwritable
  config, a missing database and an unwritable database directory *all* return
  **200** with an exception page. Only an exact `401` proves PHP ran, config
  parsed and is writable, the version matches, and sabre/dav booted. `/healthz`
  on the health port is the one endpoint that answers conventionally — 200 or
  503 — and it does not subsume the 401: it never touches sabre. The shipped
  probe asserts both, and anything checking this image should run it rather
  than reimplement either half.
- **`BAIKAL_PATH_CONFIG` and `BAIKAL_PATH_SPECIFIC` need trailing slashes.** The
  framework concatenates them directly with `baikal.yaml` and `db/db.sqlite`
  (`Core/Frameworks/Flake/Framework.php:168-182`). A missing slash yields
  `/data/configbaikal.yaml` and a container that boots into the install wizard
- **One process tree, always.** FrankenPHP is a single binary containing PHP and
  Caddy, and the entrypoint `pcntl_exec`s it so it inherits PID 1. A dead PHP kills
  the container. Do not add a supervisor, s6, or a second long-running process
- **Nothing may add a shell or a package manager to the final image.** The base is
  distroless; that is the point. What it removes is us running apt, not the
  patching itself - `cc-debian13` still ships libc6, libssl3t64, libstdc++6,
  libgcc-s1, libgomp1, libzstd1 and zlib1g, all executable code that takes CVEs.
  That obligation moves to the base image's own rebuilds — and **nothing in
  this repository collects them on its own.** Rebuilding an unchanged
  Containerfile does not pick them up. **Renovate is the update path**: it runs
  every morning, after every merge to main and whenever CI finishes on one
  of its branches, from `.github/workflows/renovate.yml`, which calls
  divbast/ci's `renovate.yml`, as the org's `divbast-renovate` App. After a
  merge it rebases every
  open PR left behind main, since GitHub re-runs no checks when a base moves
  and a green check on a stale base proves nothing. **It merges its own
  PRs** once every check passes, with a squash, while the repository
  variable `BAIKAL_AUTOMERGE` is `enabled`; any other value stops merging from
  the next run, and a new divbast/ci major, or a raise of `go.mod`'s `go`
  line, waits for approval on the Dependency Dashboard. A Baikal release
  arrives with
  `BAIKAL_SHA256` already computed from the release asset, and a digest bump
  arrives as a pull request that leaves a record of what moved and
  when, which a blind rebuild does not. Trivy cannot see FrankenPHP's own
  advisories — divbast/frankenphp's build replaces the module with a local
  path, so the binary records no version for it to match — which makes the
  PR moving the `ghcr.io/divbast/frankenphp:baikal` digest the only way
  their fixes reach the image. **A merge never publishes.** CI's daily run
  is the publishing slot: it publishes main when main moved since the commit
  the published `:latest` was built from, so users see at most one new image
  a day, and a manual run of `build` publishes at once for an urgent fix.
  Neither ever moves `:latest` backwards (divbast/ci's `app-publish.yml`,
  through `divbast-publish-decision`): after a Baikal release, an older
  image refuses a `/data` the newer one migrated. The daily run also
  catches upstream breakage early — a release URL that moved, an archive
  that no longer matches its checksum — and a new advisory against what is
  already shipped surfaces there as a code scanning alert, not a red run.
  `.github/workflows/stall.yml`, through divbast/ci's `stall.yml`, fails
  each day that updates have stopped flowing: a Renovate PR stuck,
  Renovate silent, or two slots lost in a row
- **The FrankenPHP binary comes from `ghcr.io/divbast/frankenphp:baikal`,
  and from nowhere else.** The Containerfile copies it in with one
  `COPY --from=`, by tag and digest, and app-check's build job runs
  `divbast-verify-frankenphp` before it builds anything, so only a digest
  that divbast/frankenphp's own build on its `main` attested reaches the
  image. How the binary is made lives in
  [divbast/frankenphp](https://github.com/divbast/frankenphp): the builder
  image, PHP, Caddy, its plugins, xcaddy and static-php-cli are pinned
  there; its build fails if the binary's build info disagrees with a pin or
  its extensions differ from Baikal's list; and it records the C libraries
  static-php-cli still takes at their newest release. Any change there
  reaches this image only through a PR that moves the `:baikal` digest,
  which Renovate opens. A local `just build` does not verify the
  attestation
- **The binary must never carry a file capability.** The official FrankenPHP build
  carries `cap_net_bind_service=ep`, and a binary with a file capability cannot be
  exec'd at all under `--cap-drop ALL` — it dies with `Operation not permitted`
  and exit 126 before PHP starts. divbast/frankenphp's build refuses one, and
  the acceptance suite's contract checks fail on one
- **Never serve the `302 → /admin/install/` state.** On version drift the
  container runs Baikal's own upgrade or refuses to start. Serving it is a
  total CalDAV outage that every client reports as an auth or sync failure
- **A newer Baikal migrates `/data` on its first start, and that cannot be
  undone.** Baikal has no downgrade path, and the image takes no snapshot of
  its own: backing `/data` up before deploying a new Baikal version is the
  operator's job, as upstream's own release notes ask
- **Never generate a random admin password**, and **never create an empty
  database beside an existing config**.
- The application tree stays root-owned and unwritten. Everything mutable lives
  in `/data`

## Where the shared parts live

- **divbast/ci.** `just setup` checks it out into `.ci/`, which git and
  the build context both ignore, at the one commit every workflow calls it
  at: a release's full SHA, with its tag as the comment. `build.yml` calls
  its `app-check.yml` on every event, and its `app-publish.yml` from the
  daily slot and the button; `renovate.yml` and `stall.yml` call its
  reusable workflows of the same names. Each keeps its own triggers. The
  justfile imports `.ci/just/common.just` for the lint recipes and
  `_github-token`, and `.ci/just/app.just` for `build`, `acceptance`,
  `test`, `archive`, `scan` and `app-lint`, and runs them from a recipe's
  body, never as a dependency, so it still parses before `.ci` exists. The
  acceptance suite imports ci's `harness` and `contract` from `.ci`,
  through `go.mod`'s replace. A change to ci reaches this repository only
  through the Renovate PR that moves every pin of it at once, and
  `just setup` refuses workflows that call ci at more than one commit
- **divbast/frankenphp** builds the FrankenPHP binary, as above
- **divbast/renovate-config** holds the presets `renovate.json` extends.
  `renovate.json` adds only Baikal's release manager, with the rules that
  go with it, and ignores `ghcr.io/divbast/baikal`: the acceptance suite
  pins two published images by digest as history, and they never move
- **divbast/infra** manages the `renovate` environment, the App's client ID
  and private key in it, the `BAIKAL_AUTOMERGE` kill switch, which it
  creates and then never sets again, and this repository's rulesets. The
  `divbast-renovate` App itself, its permissions and its installation are
  set up by hand, outside infra

## Key commands

- `just setup` — fetch divbast/ci into `.ci/` at the commit the workflows
  pin, then install the pinned toolchain and PHPStan. One command on a
  fresh clone, and again whenever the pin moves; `just lint` fails, naming
  it, when `.ci` is not at the pinned commit (`ci-fresh`)
- `just build` — build the image locally. Needs no token. Unlike CI, it
  does not verify the FrankenPHP binary's attestation
- `just test` — build, then run the Go acceptance suite against it, through
  `divbast-testcount`, which fails a run in which any test skipped
- `just lint` — from common.just, `ci-fresh`, pinact, zizmor, actionlint,
  ShellCheck and shfmt, the Go gates and `reuse lint`; from app.just,
  hadolint and `docker build --check`; then PHPStan
- `just scan` — ci's `divbast-scan` over the image archive `just archive`
  writes and over the published `:latest`, failing only on what the archive
  would add. Needs network access to ghcr.io, and `skopeo` on PATH
- `just actions-pin`, `just actions-update` — move the workflows' action pins
- `just ci` — every gate, locally. Run this before committing

## Where the toolchain comes from

- **`mise.toml` is where tool versions are written.** Go, golangci-lint,
  hadolint, ShellCheck, shfmt, actionlint, reuse, just, pinact, trivy and
  zizmor are all listed there. Every justfile recipe but `setup`, which installs
  them, and `ci-checkout`, which runs before them, goes through `mise
  exec`, so a recipe resolves those binaries and not a same-named one on
  PATH
- **The GitHub token is `GITHUB_TOKEN` and nothing else.** The recipes that
  call GitHub, common.just's pinact and zizmor recipes, first run
  common.just's `_github-token`, which refuses
  anything but a fine-grained personal access token (`github_pat_`) locally
  or CI's job token (`ghs_`), naming the kind and never the token. No
  recipe calls `gh`. Pass the token per command and never export it: see
  the Local GitHub token section of divbast/ci's README
- **Go is here for the acceptance suite, the upgrade guard's test and
  divbast/ci's tools.** `test/acceptance` is the acceptance suite, on ci's
  harness and contract; `test/upstreamupgrade` runs
  `test/upstream-upgrade-api.sh` over fixtures; and the shared recipes
  build ci's tools from `.ci`. `GOTOOLCHAIN=local` keeps it the pinned Go,
  never one a `go.mod` would download. `GOFLAGS=-mod=readonly`, because
  Composer's `vendor/` sits at the root, where Go would take it for a Go
  vendor directory, since `go.mod` here has a `require`
- **`just lint` needs a running Docker daemon**, for `docker build --check`.
  `--check` is a buildx flag with no podman equivalent, so this one gate does
  not honour `ENGINE` and does not run without dockerd
- **PHP is a deliberate exception.** `php` and
  `composer` come from the host, not from mise: mise's only PHP backend
  compiles PHP from source, which is minutes added to every CI run in order to
  analyse a few files. PHPStan is therefore pinned by `composer.lock`, and
  `phpstan.neon` sets `phpVersion` so the *analysis target* is fixed no matter
  which PHP runs the analyser
- **So this repository now carries `composer.json`, `composer.lock` and a
  `vendor/`, and that deserves an explanation**, because the image's whole
  claim is that no PHP toolchain reaches it. None of it does. The Containerfile
  copies named paths and never the build context, `vendor/` is gitignored, and
  `.dockerignore` excludes it too so that a `COPY` written broadly at some
  later date cannot quietly change the answer. `composer.json` has no `require`
  section, no `autoload` and no package name on purpose: Composer is asked to
  install a linter here, not to make this a PHP project
- Licensing for `composer.json` and `composer.lock` lives in `.license`
  sidecars. JSON has no comment syntax, and an SPDX tag written as a string
  value carries the closing quote into the expression, which `reuse` rejects

## Upstream facts — established from the 0.12.1

- The release archive is **self-contained and ships `vendor/`**. The build is an
  unpack; no Composer runs and no toolchain reaches the final image
- `BAIKAL_VERSION` is defined in `Core/Distrib.php`
- Admin password hash is `sha256("admin:" + realm + ":" + password)`. DAV users
  use a *different* scheme — `md5("user:realm:password")` in `users.digesta1`
- `auth_realm` is an input to every password hash, so it **cannot be changed
  after first run**, and `config/baikal.yaml` plus the database are a **single
  atomic restore unit** — restoring one without the other silently 401s everyone
- `config/baikal.yaml` must stay **writable on every request**, not merely at
  install: `Tools::assertBaikalIsOk()` checks it
- Baikal registers its iMIP mail plugin — its only outbound traffic — **if and
  only if** `system.invite_from` is non-empty. Empty is what keeps egress at zero
- `VersionUpgrade::upgrade()` gates every migration on a version threshold,
  and releases do add them: 0.13.0 rebuilds `calendarinstances` on SQLite,
  and every database this image made before 0.13.0 has the shape that
  rebuild fixes. So the bootstrap never clears drift by hand. It runs
  upstream's own `upgrade()` headless — `upgradeDatabase()` in
  `baikal-bootstrap` reaches the protected method through a subclass — and
  refuses to start if it throws, or if `configured_version` did not move.
  `test/upstream-upgrade-api.sh` fails the build, in the fetch stage, if
  the members it relies on change, and `test/upstreamupgrade` sees every
  way it can fail. The acceptance suite upgrades a volume made by the last
  0.12.1 image published before the move to divbast, and compares every
  table with a fresh install's, so a migration that silently did not run
  fails CI rather than shipping. It also serves a volume made by the last
  image published before the move onto divbast/ci, with its data intact

## Code quality

- All linter gates are enforced as errors — fix them, don't suppress them. Any
  suppression, anywhere, needs an explicit, comment-level justification beside
  it to be accepted
- **The scan blocks only what a change would add.** `just scan`, ci's
  `divbast-scan`, scans the candidate and the published `:latest` for the
  same arch from one Trivy database, and fails only on a HIGH or CRITICAL
  finding, the same vulnerability in the same package, that the published
  image lacks. No release can make an advisory against something already
  shipped any worse, so blocking on one only holds back whatever else the
  release fixes. It is reported instead: on the run's summary page and,
  from main and the daily run, as a code scanning alert. When the published
  image is absent or private, every finding is advisory, with a warning; a
  public image the registry refuses, or a registry that cannot be reached,
  fails the scan rather than waving it through
- REUSE-compliant SPDX headers on every file; licence is **BSD-2-Clause**
- The acceptance suite runs the image under the *exact* confinement the contract
  claims, so a check can never pass under looser settings than we ship. What CI
  proves is what ships
- A test suite that has never failed proves nothing. When adding a check, prove
  it can fail before trusting it
