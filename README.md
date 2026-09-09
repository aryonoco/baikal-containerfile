<!-- SPDX-License-Identifier: BSD-2-Clause -->
<!-- SPDX-FileCopyrightText: 2026 Aryan Ameri <github@aryan.ameri.coffee> -->

# baikal-containerfile

A [Baikal](https://github.com/sabre-io/Baikal) CalDAV/CardDAV image that runs
with **no Linux capabilities, a read-only root filesystem, and a non-root user**.

Published as `ghcr.io/aryonoco/baikal`.

## Why this exists

This image runs [FrankenPHP](https://github.com/php/frankenphp): PHP 8.5 and Caddy
in a single mostly-static binary, on a distroless base. One process, so a dead PHP
kills the container. No shell and no package manager in the image at all.

## Container Layout

| Property | Value |
|---|---|
| Capabilities | none (`--cap-drop ALL`) |
| Root filesystem | read-only |
| User | uid/gid 65532 (`nonroot`) |
| Port | 8080 |
| tmpfs required | `/tmp` |
| Volume required | `/data` |
| Shell in image | none |
| Package manager | none |
| Outbound network | none |
| Healthy | `GET /dav.php` returns **exactly 401** |

**Health check must assert 401.** Every Baikal failure mode (unwritable config, missing database, unwritable database directory) returns **200** with an exception page, so `curl --fail` reports a dead server as healthy.

## Running it

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

## Configuration

| Variable | Default | Notes |
|---|---|---|
| `BAIKAL_ADMIN_PASSWORD` | *none* | **Required on first run.** Create-only |
| `BAIKAL_AUTH_REALM` | `BaikalDAV` | **Cannot be changed after first run** — it is an input to every password hash |
| `BAIKAL_DAV_AUTH_TYPE` | `Basic` | Upstream defaults to Digest, which breaks Windows and DAVx5 |
| `BAIKAL_INVITE_FROM` | *empty* | Empty is what keeps outbound network at zero |
| `BAIKAL_TIMEZONE` | `UTC` | |

Settings are written once. Changing a variable after first run has no effect.
Settings changed through the admin UI persists.

## Reverse proxy notes

**Do not strip a path prefix** (sabre replies 403 "out of base uri"), and serve
`/.well-known/caldav` and `/.well-known/carddav` as redirects to the DAV root
`/dav.php/` with a **relative** target.
