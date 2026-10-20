<!-- SPDX-License-Identifier: BSD-2-Clause -->
<!-- SPDX-FileCopyrightText: 2026 Aryan Ameri <github@aryan.ameri.coffee> -->

# baikal-containerfile

A [Baikal](https://github.com/sabre-io/Baikal) CalDAV/CardDAV container image
that runs at zero Linux capabilities on a read-only root filesystem as a
non-root user. 

Published as `ghcr.io/aryonoco/baikal`.

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

- Sign every commit (`git commit -S`)
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
| Listen port | **8080** for DAV — never 80 |
| Health port | **8081** — health only, never serves DAV, meant to stay unpublished |
| tmpfs required | exactly one: `/tmp` |
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
  every morning and after every merge to main, from
  `.github/workflows/renovate.yml`, as a GitHub App installed on this
  repository alone (setup in the README). After a merge it rebases every
  open PR left behind main, since GitHub re-runs no checks when a base moves
  and a green check on a stale base proves nothing. A Baikal release arrives with
  `BAIKAL_SHA256` already computed from the release asset, and a digest bump
  arrives as a reviewable pull request that leaves a record of what moved and
  when, which a blind rebuild does not. Trivy cannot see FrankenPHP's own advisories — the
  build replaces the module with a local path, so the binary records no
  version for it to match — which makes the builder-digest PR the only way
  their fixes reach the image. CI's daily run exists to catch
  upstream breakage early — a release URL that moved, a builder that changed
  behaviour — and deliberately does not publish
- **Every root of the FrankenPHP binary is pinned in the Containerfile**, not
  resolved at build time. Left alone, `build-static.sh` asks php.net for the
  newest PHP 8.5 and xcaddy asks the Go proxy for the newest Caddy and
  plugins, so two builds of one commit shipped different binaries.
  `PHP_VERSION`, `CADDY_VERSION` and the three plugin ARGs fix them; Renovate
  moves the builder digest, Caddy and the plugins together as one `frankenphp`
  group; and `test/pinned-versions.sh` fails the build if the binary's own
  build info disagrees with any pin, because minimum version selection lifts a
  module above its pin without a word. **One input is still not pinned:**
  `build-static.sh` downloads a nightly `spc` from dl.static-php.dev on every
  build, with no checksum, over the copy the builder image ships. spc decides
  how PHP and its libraries are fetched and built, so that download is the
  build's remaining moving part, and an unverified binary run in the stage
  that produces the published one
- **The binary must never carry a file capability.** The official FrankenPHP build
  carries `cap_net_bind_service=ep`, and a binary with a file capability cannot be
  exec'd at all under `--cap-drop ALL` — it dies with `Operation not permitted`
  and exit 126 before PHP starts
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

## Key commands

- `just setup` — install the pinned toolchain. One command on a fresh clone
- `just build` — build the image locally
- `just test` — build, then run the acceptance suite against it
- `just lint` — pinact, zizmor, hadolint, `docker build --check`, ShellCheck,
  `reuse lint` and PHPStan
- `just scan` — Trivy over the image archive `just archive` writes
- `just actions-pin`, `just actions-update` — move the workflow's action pins
- `just ci` — every gate, locally. Run this before committing

## Where the toolchain comes from

- **`mise.toml` is where tool versions are written.** hadolint, ShellCheck,
  reuse, just, jq, pinact, trivy and zizmor are all listed there. Every justfile
  recipe runs through `mise exec`, so a recipe resolves those binaries and not a
  same-named one on PATH. `gh` is the exception, and only as a local fallback
  for the API token pinact and zizmor need; CI passes its own
- **`just lint` needs a running Docker daemon**, for `docker build --check`.
  `--check` is a buildx flag with no podman equivalent, so this one gate does
  not honour `ENGINE` and does not run without dockerd
- **PHP is a deliberate exception.** `php` and
  `composer` come from the host, not from mise: mise's only PHP backend
  compiles PHP from source, which is minutes added to every CI run in order to
  analyse two files. PHPStan is therefore pinned by `composer.lock`, and
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
  `test/upstream-upgrade-api.sh` fails the build if the members it relies on
  change. The acceptance suite upgrades a volume made by the first published
  image and compares every table with a fresh install's, so a migration that
  silently did not run fails CI rather than shipping

## Code quality

- All linter gates are enforced as errors — fix them, don't suppress them. Any
  suppression, anywhere, needs an explicit, comment-level justification beside
  it to be accepted
- **`baikal.openvex.json` is a reachability claim, not a suppression list.** Each
  statement names one advisory and the exact component version it was argued
  against, so a FrankenPHP bump that moves that component makes the finding
  reappear. Re-argue it then;
  widening a statement to cover the new version without doing so is a lie the
  scanner cannot catch
- REUSE-compliant SPDX headers on every file; licence is **BSD-2-Clause**
- The acceptance suite runs the image under the *exact* confinement the contract
  claims, so a check can never pass under looser settings than we ship. What CI
  proves is what ships
- A test suite that has never failed proves nothing. When adding a check, prove
  it can fail before trusting it
