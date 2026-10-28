<!-- SPDX-License-Identifier: BSD-2-Clause -->
<!-- SPDX-FileCopyrightText: 2026 Aryan Ameri <github@aryan.ameri.coffee> -->

# baikal-containerfile

A security hardened [Baikal](https://github.com/sabre-io/Baikal) image.

Published as `ghcr.io/aryonoco/baikal`.

## Base

This image runs [FrankenPHP](https://github.com/php/frankenphp): PHP 8.5 and Caddy
in a single mostly-static binary on a Debian Trixie-based distroless base.

## Container Features

| Property | Value |
|---|---|
| Capabilities | none (`--cap-drop ALL`) |
| Root filesystem | read-only |
| User | uid/gid 65532 (`nonroot`) |
| Port | 8080 (DAV), 8081 (health, do not publish) |
| tmpfs required | `/tmp` |
| Volume required | `/data` |
| Shell in image | none |
| Package manager | none |
| Outbound network | none |
| Healthy | the shipped probe: `/healthz` 200 **and** `GET /dav.php` exactly 401 |

## Running

```bash
podman run -d --name baikal \
  --cap-drop ALL --read-only \
  --user 65532:65532 \
  --tmpfs /tmp \
  -v baikal-data:/data \
  -p 8080:8080 \
  -e BAIKAL_ADMIN_PASSWORD=... \
  ghcr.io/aryonoco/baikal:0.12.1
```

## Health

Every Baikal failure mode — unwritable config, missing database, unwritable
database directory — returns **200** with an exception page, so `curl --fail`
reports a dead server as healthy. The image therefore ships its own probe and
declares a `HEALTHCHECK`. Docker runs it with no configuration.

Podman does not. Podman's `libimage` reads a healthcheck only out of a
Docker-media-type manifest, and this image is published as an OCI index, so
Podman's inspection path never looks at the config's healthcheck field —
[podman/podman#25454](https://github.com/containers/podman/issues/25454) and
[#18904](https://github.com/containers/podman/issues/18904) track it. The
healthcheck is in the image config; a Podman user has to pass it explicitly:

```bash
podman run -d --health-cmd '["/usr/local/bin/frankenphp","php-cli","/usr/local/bin/baikal-health"]' ghcr.io/aryonoco/baikal:0.12.1
```

Under a Quadlet, the equivalent is:

```
HealthCmd=["/usr/local/bin/frankenphp","php-cli","/usr/local/bin/baikal-health"]
```

The array above has no leading `"CMD"` on purpose: Podman before 5.8.0
re-splits an array that starts with `"CMD"` into one useless token, so
omitting it is what makes the check work across versions.

Kubernetes ignores an image `HEALTHCHECK` entirely, on either engine, and
wants the probe declared in the pod spec instead.

| | |
|---|---|
| `/usr/local/bin/baikal-health` | The in-container probe `HEALTHCHECK` runs. Asserts `/healthz` is 200 **and** `/dav.php` is exactly 401 |
| `http://127.0.0.1:8081/healthz` | 200 `ok`, or 503 naming the failed check. Verifies the config parses, is writable and carries a `configured_version`, and that the database opens with its schema present |

Port 8081 serves nothing else and is meant to stay unpublished.

There is no shell in this image, so a health command given as a plain string —
which Docker and Podman both run through `/bin/sh -c` — can never pass. An
explicit command needs the JSON array form, and the form is not the same
everywhere. Compose's `healthcheck.test` wants a leading `CMD`:

    test: ["CMD", "/usr/local/bin/frankenphp", "php-cli", "/usr/local/bin/baikal-health"]

Podman's `--health-cmd` and a Quadlet's `HealthCmd=` do not — see above.

Kubernetes does not either. An `exec` probe takes the argv and nothing else; a leading
`"CMD"` fails with `"CMD": executable file not found`:

    exec:
      command: ["/usr/local/bin/frankenphp", "php-cli", "/usr/local/bin/baikal-health"]

Prefer that to an `httpGet` probe against `/healthz`. `httpGet` reaches a
`containerPort` directly and so needs no publishing, but it cannot express the
exact 401, and `/healthz` on its own is only half of what healthy means here.

Two answers that look like defects and are not:

- **A full `/data` passes every check.** `is_writable()` tests permission, not
  free space, and the 401 never touches the disk
- **`http://host:8080/healthz` returns 200 — from Baikal's own front
  controller**, not from the health endpoint, so a one-digit typo in the port
  reports a false healthy. The health endpoint is only ever on 8081

There is no shell and no access log on `:8081`, so the name of the failed check
is read back off the engine:

    docker inspect --format '{{json .State.Health}}' <container>

## Env Vars

| Variable | Default | Notes |
|---|---|---|
| `BAIKAL_ADMIN_PASSWORD` | *none* | **Required on first run.** Create-only |
| `BAIKAL_AUTH_REALM` | `BaikalDAV` | **Cannot be changed after first run** — it is an input to every password hash |
| `BAIKAL_DAV_AUTH_TYPE` | `Basic` | Upstream defaults to Digest, which breaks Windows and DAVx5 |
| `BAIKAL_INVITE_FROM` | *empty* | Keeps outbound network at zero |
| `BAIKAL_TIMEZONE` | `UTC` | |

Settings are written once. Changing a variable after first run has no effect.
Settings changed through the admin UI persists.

## Upgrading Baikal

Start an image with a newer Baikal on an existing `/data`, and it runs
Baikal's own upgrade before it serves anything: the same code as Baikal's
admin upgrade page, migrations included. **Back up `/data` first.** Baikal
cannot downgrade, the image refuses to start on a `/data` newer than itself,
and `config/baikal.yaml` and `Specific/db/db.sqlite` are one restore unit. If
the upgrade fails, the container refuses to start and logs why; restore the
backup.

A new Baikal release reaches `:latest` on its own: Renovate merges it once
every check passes, and the next daily image carries it. To choose when your
`/data` migrates, pin a version tag such as `:0.13.0` rather than `:latest`,
and back up before you move the tag.

## Reverse proxy notes

**Do not strip a path prefix** (sabre replies 403 "out of base uri"), and serve
`/.well-known/caldav` and `/.well-known/carddav` as redirects to the DAV root
`/dav.php/` with a **relative** target.

## Dependency updates

Every input to the image is pinned: the builder and runtime images by digest,
Baikal by version and checksum. A pin only moves through a pull request, and
[Renovate](https://docs.renovatebot.com/) opens those. It runs every morning,
after every merge to `main` and whenever CI finishes on one of its branches,
from `.github/workflows/renovate.yml` in this repository, as a GitHub App
installed here and nowhere else, and reports on the Dependency Dashboard
issue. A new Baikal release arrives with its checksum already computed.

Renovate merges its own pull requests once every check on one has passed,
majors and Baikal releases included, while the repository variable
`BAIKAL_AUTOMERGE` is `enabled`. Any other value, or none, stops it from the
next run, and Renovate goes on opening and rebasing pull requests for a person
to merge:

    gh variable set BAIKAL_AUTOMERGE --body disabled

After a merge it rebases every open update the merge left behind, so each is
tested again against the new `main` before it merges. Its merged commits land
on `main` unsigned, because GitHub cannot sign a commit it rebases.

**At most one new image a day.** A merge does not publish. The daily `build`
run publishes `main` if anything merged since the last image, so however many
updates land in a day, users see one new image at most. An urgent fix need not
wait: a manual run of the `build` workflow from `main` (Actions, build, Run
workflow) publishes at once.

A daily stall check, `.github/workflows/stall.yml`, fails, and GitHub emails
you, when a Renovate pull request has been open more than 14 days or red or
pending for more than a day, when Renovate has not succeeded in a day, or when
two daily runs should have published and did not.

A fork needs its own App:

1. Create a GitHub App with its webhook turned off and these repository
   permissions: Checks, Commit statuses, Contents, Issues, Pull requests and
   Workflows read and write; Metadata read. Install it on this repository
   only.
2. Create an environment called `renovate` whose deployment branches are
   limited to `main`. Give it a variable `RENOVATE_APP_CLIENT_ID` holding the
   App's client ID, and a secret `RENOVATE_APP_PRIVATE_KEY` holding a private
   key generated for the App.
3. Run the `renovate` workflow by hand once. The Dependency Dashboard issue
   appears, listing every dependency Renovate found.
4. When you are ready for Renovate to merge on its own, run
   `gh variable set BAIKAL_AUTOMERGE --body enabled`.

## AI/LLM Disclosure

This project was developed with significant LLM involvement. Each git commit contains an `Assisted-by:` tag detailing the particular model/tool used.

## Licence

Copyright 2026 Aryan Ameri.

[BSD-2-Clause](LICENSES/BSD-2-Clause.txt)

This project is [REUSE](https://reuse.software/) compliant.
