<!-- SPDX-License-Identifier: BSD-2-Clause -->
<!-- SPDX-FileCopyrightText: 2026 Aryan Ameri <github@aryan.ameri.coffee> -->

# baikal-containerfile

A [Baikal](https://github.com/sabre-io/Baikal) CalDAV/CardDAV image that runs
with **no Linux capabilities, a read-only root filesystem, and a non-root user**.

Published as `ghcr.io/aryonoco/baikal`.

## Why this exists

Neither community image is usable at this confinement level.
[`ckulka/baikal`](https://github.com/ckulka/baikal-docker) is abandoned and every
tag ships Baikal 0.10.1, inside the vulnerable range of
[GHSA-j44x-cj7p-vx2w](https://github.com/sabre-io/Baikal/security/advisories/GHSA-j44x-cj7p-vx2w)
— a stored XSS that takes over the admin panel, with no CVE and no package
mapping, so no scanner reports it.
[`ghcr.io/aalmenar/baikal`](https://github.com/aalmenar/baikal-docker) is current
but runs nginx with an unsupervised, daemonized php-fpm: when php-fpm dies the
container stays `running` and serves 502 to every client indefinitely.

This image uses Apache with mod_php, so there is exactly one process tree. If PHP
fails, the container exits.

## The contract

| Property | Value |
|---|---|
| Capabilities | none (`--cap-drop ALL`) |
| Root filesystem | read-only |
| User | uid/gid 33 |
| Port | 8080 |
| tmpfs required | `/run`, `/tmp` |
| Volume required | `/data` |
| Outbound network | none |
| Healthy | `GET /dav.php` returns **exactly 401** |

**The health check must assert 401 exactly.** Every Baikal failure mode —
unwritable config, missing database, unwritable database directory — returns
**200** with an exception page, so `curl --fail` reports a dead server as healthy.

## Running it

```bash
podman run -d --name baikal \
  --cap-drop ALL --read-only \
  --user 33:33 \
  --tmpfs /run --tmpfs /tmp \
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

Settings are written **once**. Changing a variable after first run has no effect,
and a setting changed through the admin UI persists. If you need the security
posture enforced rather than merely initialised, deny the container egress at
your firewall — that is a control, not an optimisation.

## Reverse proxy

Out of scope for this image, but two things break DAV if you get them wrong:
**never strip a path prefix** (sabre replies 403 "out of base uri"), and serve
`/.well-known/caldav` and `/.well-known/carddav` as redirects to the DAV root
`/dav.php/` with a **relative** target.
