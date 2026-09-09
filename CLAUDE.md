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

## The confinement contract

These are the guarantees the image makes. A change that breaks any of them is a
breaking change.

| Property | Value |
|---|---|
| Capabilities | **none** (`--cap-drop ALL`) |
| Root filesystem | **read-only** |
| User | uid/gid **65532**, never root |
| Listen port | **8080** — never 80 |
| tmpfs required | exactly one: `/tmp` |
| Volume required | exactly one: `/data` |
| Outbound network | **none** |
| Healthy | `GET /dav.php` returns **exactly 401** |

- **Never assert `2xx` or use `curl --fail` for health.** Unwritable config, a
  missing database and an unwritable database directory *all* return **200** with
  an exception page. Only an exact `401` proves PHP ran, config parsed and is writable,
  the version matches, and sabre/dav booted.
- **`BAIKAL_PATH_CONFIG` and `BAIKAL_PATH_SPECIFIC` need trailing slashes.** The
  framework concatenates them directly with `baikal.yaml` and `db/db.sqlite`
  (`Core/Frameworks/Flake/Framework.php:168-182`). A missing slash yields
  `/data/configbaikal.yaml` and a container that boots into the install wizard
- **One process tree, always.** FrankenPHP is a single binary containing PHP and
  Caddy, and the entrypoint `pcntl_exec`s it so it inherits PID 1. A dead PHP kills
  the container. Do not add a supervisor, s6, or a second long-running process
- **Nothing may add a shell or a package manager to the final image.** The base is
  distroless; that is the point, and it is what removes apt patching from the
  weekly rebuild entirely
- **The binary must never carry a file capability.** The official FrankenPHP build
  carries `cap_net_bind_service=ep`, and a binary with a file capability cannot be
  exec'd at all under `--cap-drop ALL` — it dies with `Operation not permitted`
  and exit 126 before PHP starts
- **Never serve the `302 → /admin/install/` state.** On version drift the
  container clears it or refuses to start. Serving it is a total CalDAV outage
  that every client reports as an auth or sync failure
- **Never generate a random admin password**, and **never create an empty
  database beside an existing config**.
- The application tree stays root-owned and unwritten. Everything mutable lives
  in `/data`

## Key commands

- `just build` — build the image locally
- `just test` — build, then run the acceptance suite against it
- `just lint` — hadolint, ShellCheck, `reuse lint`
- `just ci` — everything CI runs. Run this before committing

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
- `VersionUpgrade::upgrade()` gates every migration on a threshold in exactly
  `{0.2.3, 0.3.0, 0.4.0, 0.4.5, 0.5.1, 0.9.4, 0.10.0}`. At or above 0.10.0 it
  performs **no DDL** — it writes one key and returns. That is why the entrypoint
  may clear drift itself, and why `test/upstream-migrations.sh` fails the build
  if those thresholds ever move

## Code quality

- All linter gates are enforced as errors — fix them, don't suppress them. Any
  suppression, anywhere, needs an explicit, comment-level justification beside
  it to be accepted
- REUSE-compliant SPDX headers on every file; licence is **BSD-2-Clause**
- The acceptance suite runs the image under the *exact* confinement the contract
  claims, so a check can never pass under looser settings than we ship. What CI
  proves is what ships
- A test suite that has never failed proves nothing. When adding a check, prove
  it can fail before trusting it
