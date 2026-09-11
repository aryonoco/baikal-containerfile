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
| Healthy | `GET /dav.php` returns **exactly 401** |

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
declares a `HEALTHCHECK`, and Docker and Podman check it correctly with no
configuration.

| | |
|---|---|
| `/usr/local/bin/baikal-health` | The in-container probe `HEALTHCHECK` runs. Asserts `/healthz` is 200 **and** `/dav.php` is exactly 401 |
| `http://127.0.0.1:8081/healthz` | 200 `ok`, or 503 naming the failed check. Verifies the config parses, is writable and carries a `configured_version`, and that the database opens with its schema present |

Port 8081 serves nothing else and is meant to stay unpublished. Kubernetes
`httpGet` probes reach a `containerPort` directly, so they need no publishing —
and they cannot express the 401, which is why the endpoint exists.

There is no shell in this image, so a health command given as a plain string —
which Docker and Podman both run through `/bin/sh -c` — can never pass. An
orchestrator that takes an explicit command needs the JSON array form:

    ["CMD", "/usr/local/bin/frankenphp", "php-cli", "/usr/local/bin/baikal-health"]

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

## Reverse proxy notes

**Do not strip a path prefix** (sabre replies 403 "out of base uri"), and serve
`/.well-known/caldav` and `/.well-known/carddav` as redirects to the DAV root
`/dav.php/` with a **relative** target.

## AI/LLM Disclosure

This project was developed with significant LLM involvement. Each git commit contains an `Assisted-by:` tag detailing the particular model/tool used.

## Licence

Copyright 2026 Aryan Ameri.

[BSD-2-Clause](LICENSES/BSD-2-Clause.txt)

This project is [REUSE](https://reuse.software/) compliant.
