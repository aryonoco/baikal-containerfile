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

## Verifying what you pulled

GHCR has **no immutable tags and no retention policy** — both are open feature
requests, not oversights on this end. A tag here is a moving pointer, and
nothing at the registry stops it from being repointed. `:0.12.1` records the
version that was published under it; it is not a promise that the bytes behind
it never change. Two things are in your hands instead, and they are the only
integrity controls that actually exist.

**Pin the digest.** Resolve it once, review it like any other dependency, and
let Renovate bump it:

```bash
podman pull ghcr.io/aryonoco/baikal@sha256:...
```

**Verify where it came from.** Every published index carries a build provenance
attestation signed by GitHub's Sigstore identity:

```bash
gh attestation verify oci://ghcr.io/aryonoco/baikal:0.12.1 \
  --repo aryonoco/baikal-containerfile
```

That proves the image came out of this repository's workflow without trusting
the registry, and it fails if a tag has been repointed at anything built
elsewhere.

The index also carries BuildKit's own SLSA provenance and an SPDX SBOM, which
describe the build itself rather than who ran it:

```bash
docker buildx imagetools inspect ghcr.io/aryonoco/baikal:0.12.1 \
  --format '{{ json .SBOM }}'
```

The SBOM is honest but thin, and worth saying so: it sees the distroless Debian
layer and the Go module graph of the FrankenPHP binary, and it cannot see the
twenty PHP extensions compiled into that binary, because nothing in the image
records them.

Each architecture is also published on its own — `:0.12.1-amd64` and
`:0.12.1-arm64`. `:0.12.1` and `:latest` are the multi-arch index over the two.

## Reverse proxy notes

**Do not strip a path prefix** (sabre replies 403 "out of base uri"), and serve
`/.well-known/caldav` and `/.well-known/carddav` as redirects to the DAV root
`/dav.php/` with a **relative** target.
