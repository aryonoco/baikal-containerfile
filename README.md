<!-- SPDX-License-Identifier: BSD-2-Clause -->
<!-- SPDX-FileCopyrightText: 2026 Aryan Ameri <github@aryan.ameri.coffee> -->

# baikal-oci-image

A security hardened [Baikal](https://github.com/sabre-io/Baikal) image.

Published as `ghcr.io/divbast/baikal`.

## Base

This image runs [FrankenPHP](https://github.com/php/frankenphp): PHP 8.5 and
Caddy in one binary, on a Debian Trixie-based distroless base. The binary is
the one [divbast/frankenphp](https://github.com/divbast/frankenphp) builds
for this image, `ghcr.io/divbast/frankenphp:baikal`, with Baikal's PHP
extensions, from pinned PHP, Caddy and build tools; the C libraries built
into it are not pinned, as [Dependency updates](#dependency-updates) says.
The Containerfile copies it in by digest, and CI builds nothing until it
has checked that divbast/frankenphp's own build on its `main` attested
that digest. [Verifying the image](#verifying-the-image) shows how to check
the image, and the binary in it, yourself.

## Container Features

| Property | Value |
|---|---|
| Capabilities | none (`--cap-drop ALL`) |
| Root filesystem | read-only |
| User | uid/gid 65532 (`nonroot`) |
| Port | 8080 (DAV), 8081 (health, do not publish) |
| tmpfs required | `/tmp`, sized `512m` |
| Volume required | `/data` |
| Request body | 64 MB at most; a larger one gets 413 |
| Shell in image | none |
| Package manager | none |
| Outbound network | none |
| Healthy | the shipped probe: `/healthz` 200 **and** `GET /dav.php` exactly 401 |

## Running

```bash
podman run -d --name baikal \
  --cap-drop ALL --read-only \
  --user 65532:65532 \
  --tmpfs /tmp:size=512m \
  -v baikal-data:/data \
  -p 8080:8080 \
  -e BAIKAL_ADMIN_PASSWORD=... \
  ghcr.io/divbast/baikal:0.13.0
```

`:0.13.0` names the Baikal version, and `:latest` the newest image. Each
new image of a version moves that version's tag. The `:<version>-<arch>`
and `:<version>-staging` tags are the publish's working tags, not for use.

## Request size and `/tmp`

Caddy refuses a request body over 64 MB with 413. One whose
`Content-Length` says it is too big is refused before PHP reads any of it,
and one sent chunked is cut off at the cap and refused the same way. A
contact with a photo, or an event with attachments, is far below it.

The cap is there for `/tmp`. PHP keeps 16 KiB of a request body in memory
and spools the rest to `/tmp`, where a body takes about twice its size
while it is handled. `size=512m` is eight times the cap: room for four of
the largest uploads at once, beside Caddy's own state. A tmpfs size is a
ceiling, not memory set aside: it takes only what is written to it. A
reverse proxy in front applies its own limit as well.

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
podman run -d --name baikal \
  --cap-drop ALL --read-only \
  --user 65532:65532 \
  --tmpfs /tmp:size=512m \
  -v baikal-data:/data \
  -p 8080:8080 \
  -e BAIKAL_ADMIN_PASSWORD=... \
  --health-cmd '["/usr/local/bin/frankenphp","php-cli","/usr/local/bin/baikal-health"]' \
  ghcr.io/divbast/baikal:0.13.0
```

Under a Quadlet, the equivalents of the tmpfs and the health check are:

```
Tmpfs=/tmp:size=512m
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

Port 8081 serves nothing else and is meant to stay unpublished. It is the
only place `/healthz` answers: on 8080 it is 404, so a health check whose
port is mistyped as 8080 fails rather than reporting a false healthy.

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

One answer that looks like a defect and is not: **a full `/data` passes
every check.** `is_writable()` tests permission, not free space, and the 401
never touches the disk.

There is no shell and no access log on `:8081`, so the name of the failed check
is read back off the engine:

    docker inspect --format '{{json .State.Health}}' <container>

PHP's own errors never reach a response: the image sets `display_errors` off and
sends real errors (fatal, parse, compile) to the container log (stdout, as JSON), and
`/healthz` fails naming `ini` if that setting is not in force. Baikal's own
exception pages, the 200 pages described at the top of this section, are
different: upstream's `handleException()` prints the exception and its stack
trace into the page itself, and no PHP setting can stop it. That is upstream's
behaviour, and this image leaves it alone.

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

Every input the Containerfile names is pinned: the fetch stage's Debian
image and the distroless runtime by digest, the FrankenPHP binary by the
digest of `ghcr.io/divbast/frankenphp:baikal`, and Baikal by version and
checksum. Three packages the fetch stage installs are not: `curl`, `unzip`
and `ca-certificates`, with what they depend on, come from Debian's archive
as it stands on the day of the build. They only fetch Baikal's release and
unpack it; the image takes nothing from that stage but Baikal's own files.

The binary's own inputs, PHP, Caddy, its plugins, xcaddy and
static-php-cli, are pinned in divbast/frankenphp, which also fails its
build unless the binary loads exactly the PHP extensions this image needs.
The C libraries static-php-cli builds into it are not pinned there:
openssl, zlib and several others come from their newest release whenever
the binary is built. So a new `:baikal` digest can carry newer C code with
no pin moved, and that is how fixes to those libraries arrive.

A pin only moves through a pull request, and
[Renovate](https://docs.renovatebot.com/) opens those. It runs every morning,
after every merge to `main`, whenever CI finishes on one of its branches and
when the Dependency Dashboard issue is edited, from
`.github/workflows/renovate.yml`, which calls divbast/ci's shared Renovate
workflow, as the divbast org's `divbast-renovate` GitHub App, and reports on
the Dependency Dashboard issue. Its settings are divbast/renovate-config's
shared presets, and `renovate.json` adds only Baikal's release manager. The
pull requests Renovate opens here are:

- A Baikal release arrives as one pull request that moves the version and
  the checksum together, the checksum already computed from the release's
  own archive.
- A new `:baikal` binary arrives as a pull request that moves the digest,
  and CI verifies the new digest's attestation before it builds.
- A release of divbast/ci arrives as one pull request that moves every
  workflow's pin of it together.

Renovate merges its own pull requests once every check on one has passed,
majors and Baikal releases included, while the repository variable
`BAIKAL_AUTOMERGE` is `enabled`. Two kinds first wait for someone to
approve them on the Dependency Dashboard: a new major version of
divbast/ci, and a raise of `go.mod`'s `go` line. Any other value of the
variable, or none, stops merging from the next run, and Renovate goes on
opening and rebasing pull requests for a person to merge:

    gh variable set BAIKAL_AUTOMERGE --body disabled

After a merge it rebases every open update the merge left behind, so each is
tested again against the new `main` before it merges. It merges with a
squash, which GitHub signs, because `main` accepts only signed commits.

**At most one new image a day.** A merge does not publish. The daily `build`
run publishes `main` if anything merged since the last image, so however many
updates land in a day, users see one new image at most. An urgent fix need not
wait: a manual run of the `build` workflow from `main` (Actions, build, Run
workflow) publishes at once. Neither ever replaces `:latest` with an image of
an older commit.

A publish pushes each architecture, merges them into an index under
`:<version>-staging`, attests it and verifies the attestation, and only then
moves `:<version>` and `:latest`, before checking both as an anonymous client
pulls them. If the attestation or its verification fails, `:<version>` and
`:latest` stay where they were. Re-running the failed job then publishes,
as long as the image artifacts the check built are kept, which is a day;
after that the next daily run or a manual run does.

A daily stall check, `.github/workflows/stall.yml`, which calls divbast/ci's
shared one, fails, and GitHub emails you, when a Renovate pull request has
been open more than 14 days or red or pending for more than a day, when
Renovate has not succeeded in a day, or when two daily runs should have
published and did not.

[divbast/infra](https://github.com/divbast/infra) manages the `renovate`
environment, the App's client ID and private key in it, `BAIKAL_AUTOMERGE`
and this repository's rulesets. It creates `BAIKAL_AUTOMERGE` and then leaves
its value alone, so an apply never turns merging back on. The
`divbast-renovate` App itself, its permissions and its installation are not
managed there: they are set up by hand. A fork needs its own App:

1. Create a GitHub App with its webhook turned off and these repository
   permissions: Checks, Commit statuses, Contents, Issues, Pull requests and
   Workflows read and write; Dependabot alerts and Metadata read. Install it
   on this repository only.
2. Create an environment called `renovate` whose deployment branches are
   limited to `main`. Give it a variable `RENOVATE_APP_CLIENT_ID` holding the
   App's client ID, and a secret `RENOVATE_APP_PRIVATE_KEY` holding a private
   key generated for the App.
3. Run the `renovate` workflow by hand once. The Dependency Dashboard issue
   appears, listing every dependency Renovate found.
4. When you are ready for Renovate to merge on its own, run
   `gh variable set BAIKAL_AUTOMERGE --body enabled`.

## Verifying the image

Every image published from `main` carries an attestation of where it was
built, signed with Sigstore. With [gh](https://cli.github.com/) 2.102.0 or
newer:

    gh attestation verify oci://ghcr.io/divbast/baikal:latest --repo divbast/baikal-oci-image --signer-workflow divbast/ci/.github/workflows/app-publish.yml --source-ref refs/heads/main

`--repo` and `--source-ref` say the image was built from this repository's
`main` branch, and `--signer-workflow` that divbast/ci's publish workflow,
which this repository's `build` workflow calls, signed it. Older versions of
gh compare `--signer-workflow` with only the start of the signer's identity,
and `--source-ref` without regard to case.

If gh reports that its token was denied, for an image anyone may pull, it
is sending a registry login from Docker's configuration, such as a stale one
or what a credential helper hands it, which GHCR refuses. Point
`DOCKER_CONFIG` at an empty directory:

    mkdir -p /tmp/empty-docker-config
    DOCKER_CONFIG=/tmp/empty-docker-config gh attestation verify oci://ghcr.io/divbast/baikal:latest --repo divbast/baikal-oci-image --signer-workflow divbast/ci/.github/workflows/app-publish.yml --source-ref refs/heads/main

Which command verifies an image depends on when it was published. The one
above covers every image published since this repository moved onto
divbast/ci's shared workflows, which sign with divbast/ci's
`app-publish.yml`. It fails for the older ones, which each need their own:

- **Every image this repository published before that move**, `0.13.0`
  among them, was signed by its own `build` workflow. Tags move to newer
  images, and the move itself did that to `:0.13.0` and `:latest`, so a
  tag no longer names the image it did. Verify the digest you run, which
  is the only name an older image keeps. For example, the last
  `:latest` and `:0.13.0` published before the move:

      gh attestation verify oci://ghcr.io/divbast/baikal@sha256:8f2bbc028ddcc1546f8b6a8aabd8fec1e8ddeb4be1350de9995b43aa441f4335 --repo divbast/baikal-oci-image --signer-workflow divbast/baikal-oci-image/.github/workflows/build.yml --source-ref refs/heads/main

- **`0.12.1`** was built before this repository moved to the divbast
  organisation, when it was `aryonoco/baikal-containerfile`, and was
  published here unchanged. Its attestation names that repository, and gh
  finds it only under that account, so `--owner` takes the place of
  `--repo`:

      gh attestation verify oci://ghcr.io/divbast/baikal:0.12.1 --owner aryonoco --signer-workflow aryonoco/baikal-containerfile/.github/workflows/build.yml --source-ref refs/heads/main

`:latest` is whichever image was published last. Each attestation is on
the index that `:<version>` and `:latest` name, so the per-architecture
tags, which are not for use, verify with none of these.

**The FrankenPHP binary.** The image's binary is copied from
`ghcr.io/divbast/frankenphp:baikal`, by the digest the Containerfile's
`COPY --from=` names. Take that digest from the Containerfile at the commit
the image was built from, its `org.opencontainers.image.revision`:

    grep -o 'frankenphp:baikal@sha256:[0-9a-f]*' Containerfile

and, with `<digest>` standing for its `sha256:…` part, check that
divbast/frankenphp's own build on its `main` branch made it:

    gh attestation verify oci://ghcr.io/divbast/frankenphp@<digest> --repo divbast/frankenphp --signer-workflow divbast/frankenphp/.github/workflows/build.yml@refs/heads/main --source-ref refs/heads/main

CI runs the same check before it builds anything, so a binary that fails it
never reaches an image built here.

## Building it yourself

With [mise](https://mise.jdx.dev/), Composer and Docker: `just setup` checks
divbast/ci out into `.ci/` at the commit the workflows pin and installs the
toolchain, and `just ci` runs every gate, the image build included. The
build itself needs no token, and, unlike CI, does not verify the FrankenPHP
binary's attestation: it builds from whatever digest the Containerfile
names. `just scan` reads the published image with
[skopeo](https://github.com/containers/skopeo), which must be on `PATH`.
The lint gates that call GitHub read a token from `GITHUB_TOKEN` and
nowhere else, and refuse anything but a fine-grained personal access token
(`github_pat_`) or the job token CI passes (`ghs_`). One limited to reading
public repositories is enough. Pass it per command rather than exporting
it, as divbast/ci's README says under
[Local GitHub token](https://github.com/divbast/ci#local-github-token).

## AI/LLM Disclosure

This project was developed with significant LLM involvement. Each git commit contains an `Assisted-by:` tag detailing the particular model/tool used.

## Licences in the image

The image's `org.opencontainers.image.licenses` label is
`BSD-2-Clause AND GPL-3.0-only AND BSD-3-Clause AND MIT AND OFL-1.1`:

| Licence | What |
|---|---|
| BSD-2-Clause | This repository: the Containerfile, the bootstrap, the health probe and endpoint, and the Caddy and PHP configuration |
| GPL-3.0-only | Baikal itself, as upstream's `composer.json` declares it. Its files ship unchanged, and its `LICENSE`, the GPL v3 text, ships at `/var/www/baikal/LICENSE` |
| BSD-3-Clause | sabre/dav, sabre/event, sabre/http, sabre/uri, sabre/vobject, sabre/xml and Twig, from the `vendor/` tree Baikal's release ships, each with its `LICENSE` |
| MIT | psr/log, the Symfony packages and Composer's autoloader in that `vendor/` tree, each with its `LICENSE`; Open Iconic's CSS, which sabre/dav ships for its browser plugin in `vendor/sabre/dav/lib/DAV/Browser/assets/openiconic/`, with its `ICON-LICENSE`; jQuery, in `vendor/`; jQuery, Bootstrap and Font Awesome's CSS under `html/res/` and `Core/Resources/Web/`; and the FrankenPHP binary |
| OFL-1.1 | Font Awesome's web fonts under `html/res/` and `Core/Resources/Web/`, and Open Iconic's fonts (`.eot`, `.otf`, `.svg`, `.ttf` and `.woff`) beside its CSS, which upstream licenses under the SIL OFL |

Font Awesome's icons are under CC BY 4.0 only as SVG and JavaScript, and
Baikal's release ships them as neither: the one `.svg` in the image is
Open Iconic's font. PHP, Caddy and the libraries built into the
FrankenPHP binary divbast/frankenphp builds, and the distroless base
image, are other projects' work, and carry their own licences.

## Licence

Copyright 2026 Aryan Ameri.

[BSD-2-Clause](LICENSES/BSD-2-Clause.txt)

This project is [REUSE](https://reuse.software/) compliant.
