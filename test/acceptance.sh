#!/usr/bin/env bash
# SPDX-License-Identifier: BSD-2-Clause
# SPDX-FileCopyrightText: 2026 Aryan Ameri <github@aryan.ameri.coffee>
set -uo pipefail
cd "$(dirname "${0}")" || exit 1
# shellcheck source=test/lib.sh
source ./lib.sh

# Docker locally, podman where it exists. Every flag this suite uses means the
# same thing to both.
ENGINE="${ENGINE:-docker}"
IMAGE="${IMAGE:-localhost/baikal:dev}"
PORT=18099
INTERNAL_PORT=18089
BASE="http://127.0.0.1:${PORT}"
PASSWORD='correct horse battery staple'
DAV_USER=alice
DAV_PASS=wonderland
VOL=baikal-acceptance
INTERNAL_VOL=baikal-acceptance-internal
NET=baikal-acceptance-net
INTERNAL_NET=baikal-acceptance-internal-net

# The confinement contract, in one place. Every run in this file uses it, so a
# check can never accidentally pass under looser settings than we ship.
CONFINE=(--cap-drop ALL --read-only --user 65532:65532 --tmpfs /tmp)

# Everything that has to read or assert on state *inside* the container lives in
# test/in-container.php, run by the image's own binary. This file is orchestration
# only: create networks and volumes, run the image under CONFINE, exec, check
# exit codes and host-side HTTP status codes, clean up. The PHP used to be six
# `php-cli -r '<code>'` blobs, each one PHP nested inside a single-quoted shell
# string that itself held SQL and PHP string literals; bash checks none of that,
# and two real defects of exactly that shape were found in it.
PHP_BIN=/usr/local/bin/frankenphp
PROBE_SRC=./in-container.php

# Inside the container, the probe lands in the /data volume. That is not the
# obvious choice - /tmp is the tmpfs the contract already requires, and is
# writable under --read-only - but `docker cp` into a tmpfs on a --read-only
# container is broken: Docker 29.4.0 refuses `cp` to a read-only rootfs
# outright, and when the tmpfs is declared with --mount instead it reports
# success and copies nothing, leaving the file invisible inside. `cp` into a
# volume works on both engines. What matters either way is that no bind mount
# and no extra flag is involved: the suite must exercise the image under exactly
# the configuration we publish, and a mount added for the tests would mean
# proving a configuration nobody runs.
PROBE=/data/in-container.php

# Ship the probe into a container. Nothing verifies the copy here on purpose:
# every use goes through probe(), which fails loudly when the file is missing,
# because the PHP fatal produces no assertion records and silence is counted as
# a failure rather than read as success.
install_probe() {
    local ctr="${1}"
    "${ENGINE}" cp "${PROBE_SRC}" "${ctr}:${PROBE}" >/dev/null 2>&1 ||
        fail "could not copy ${PROBE_SRC} into ${ctr}:${PROBE}"
}

# Run one probe subcommand and fold each tab-separated record it prints into
# this suite's own pass/fail, so host-side and in-container assertions share one
# counter and one log format. Anything the probe writes that is not a record -
# a PHP warning, a usage error, a stack trace - is passed through as a
# diagnostic so a CI log shows what happened rather than only that something
# did.
probe() {
    local ctr="${1}"
    shift
    local subcommand="${1}"
    local out rc line verdict what expected found saw=0

    out="$("${ENGINE}" exec "${ctr}" "${PHP_BIN}" php-cli "${PROBE}" "${@}" 2>&1)"
    rc=${?}

    while IFS= read -r line; do
        IFS=$'\t' read -r verdict what expected found <<<"${line}"
        case "${verdict}" in
            ok)
                saw=1
                pass "${what} (${found})"
                ;;
            FAIL)
                saw=1
                fail "${what}: expected '${expected}', got '${found}'"
                ;;
            '') ;;
            *) printf '       | %s\n' "${line}" >&2 ;;
        esac
    done <<<"${out}"

    if (( saw == 0 )); then
        fail "${ctr}: probe '${subcommand}' produced no assertions (exit ${rc})"
    fi

    return "${rc}"
}

cleanup() {
    "${ENGINE}" rm -f baikal-acc baikal-acc-internal >/dev/null 2>&1 || true
    "${ENGINE}" volume rm -f "${VOL}" "${INTERNAL_VOL}" baikal-acc-nopw >/dev/null 2>&1 || true
    "${ENGINE}" network rm -f "${NET}" "${INTERNAL_NET}" >/dev/null 2>&1 || true
}
trap cleanup EXIT
cleanup

# A published port on a Docker/Podman --internal network is unreachable from
# the host (verified: curl against it returns 000 while the same container
# answers on its container IP), so a network that carries every HTTP check in
# this file cannot itself be --internal. Checks 1-8 and 10-12 therefore run on
# an ordinary user-defined bridge network; only check 9 below exercises a
# genuinely internal one, and it proves egress-lessness from inside the
# container rather than by publishing a port through it.
"${ENGINE}" network create "${NET}" >/dev/null

start() {
    "${ENGINE}" run -d --name baikal-acc "${CONFINE[@]}" \
        --network "${NET}" -p "${PORT}:8080" \
        -v "${VOL}":/data \
        -e BAIKAL_ADMIN_PASSWORD="${PASSWORD}" \
        "${IMAGE}" >/dev/null
    install_probe baikal-acc
}

echo '== 1. cold start on an empty volume'
start
if wait_for_port "${BASE}/dav.php"; then pass 'container serves'; else fail 'container never served'; "${ENGINE}" logs baikal-acc; fi

echo '== 2. one process: PID 1 is the server, not a supervisor'
# pcntl_exec() overlays the bootstrap process with the server; it does not
# fork. `docker inspect --format '{{.Path}}'` only ever echoes the configured
# entrypoint back, so the only way to prove the exec actually happened is to
# ask the container what its own PID 1 is.
probe baikal-acc assert-pid1

echo '== 3. health check is exactly 401'
assert_status 401 '/dav.php' "${BASE}/dav.php"

echo '== 4. no shell in the image'
# Absence rather than non-executability, and three paths rather than one: the
# base is distroless and a shell reappearing in it is a change of kind, not of
# degree.
probe baikal-acc assert-no-shell

echo '== 5. process capability sets are all zero'
# The raw /proc/self/status line still carries the labels CapEff/CapPrm, and
# CapEff contains both 'a' and 'f' - so a substring match against the whole
# line can never distinguish an all-zero mask from a real one. The probe parses
# out the hex word and compares it as a number.
probe baikal-acc assert-caps

echo '== 6. DAV actually works'
probe baikal-acc seed-user "${DAV_USER}" "${DAV_PASS}"

# The DAV verbs stay here, in curl, on purpose: driven through the published
# port they prove the port mapping and the whole request path from outside the
# container, which a loopback call from inside cannot.
assert_status 207 'authenticated PROPFIND' -u "${DAV_USER}:${DAV_PASS}" \
    -X PROPFIND -H 'Depth: 0' "${BASE}/dav.php/principals/${DAV_USER}/"
assert_status 201 'MKCALENDAR' -u "${DAV_USER}:${DAV_PASS}" \
    -X MKCALENDAR "${BASE}/dav.php/calendars/${DAV_USER}/test/"

EVENT=$'BEGIN:VCALENDAR\r\nVERSION:2.0\r\nPRODID:-//acceptance//EN\r\nBEGIN:VEVENT\r\nUID:accept-1\r\nDTSTAMP:20260101T000000Z\r\nDTSTART:20260101T120000Z\r\nDTEND:20260101T130000Z\r\nSUMMARY:acceptance\r\nEND:VEVENT\r\nEND:VCALENDAR\r\n'
assert_status 201 'PUT event' -u "${DAV_USER}:${DAV_PASS}" \
    -X PUT -H 'Content-Type: text/calendar' --data-binary "${EVENT}" \
    "${BASE}/dav.php/calendars/${DAV_USER}/test/accept-1.ics"

assert_contains 'SUMMARY:acceptance' 'GET event round-trips' \
    curl -s --connect-timeout 5 --max-time 30 -u "${DAV_USER}:${DAV_PASS}" \
    "${BASE}/dav.php/calendars/${DAV_USER}/test/accept-1.ics"

assert_status 207 'REPORT sync-collection' -u "${DAV_USER}:${DAV_PASS}" \
    -X REPORT -H 'Depth: 1' -H 'Content-Type: application/xml' \
    --data '<?xml version="1.0"?><d:sync-collection xmlns:d="DAV:"><d:sync-token/><d:prop><d:getetag/></d:prop></d:sync-collection>' \
    "${BASE}/dav.php/calendars/${DAV_USER}/test/"

echo '== 7. CardDAV works'
assert_status 201 'MKCOL addressbook' -u "${DAV_USER}:${DAV_PASS}" \
    -X MKCOL -H 'Content-Type: application/xml' \
    --data '<?xml version="1.0"?><d:mkcol xmlns:d="DAV:" xmlns:c="urn:ietf:params:xml:ns:carddav"><d:set><d:prop><d:resourcetype><d:collection/><c:addressbook/></d:resourcetype></d:prop></d:set></d:mkcol>' \
    "${BASE}/dav.php/addressbooks/${DAV_USER}/contacts/"

echo '== 8. RFC 6764 .well-known discovery'
assert_status 301 '/.well-known/caldav' "${BASE}/.well-known/caldav"
assert_status 301 '/.well-known/carddav' "${BASE}/.well-known/carddav"

echo '== 9. no egress required, measured from a genuinely --internal network'
# A flag read (docker network inspect --format '{{.Internal}}') tests Docker,
# not us. This starts a second instance of the image, under the same CONFINE
# settings, on a network with no route out, and proves from inside the
# container - there is no shell and no curl in the image - that DAV still
# works with no egress available to fail open through.
"${ENGINE}" network create --internal "${INTERNAL_NET}" >/dev/null
"${ENGINE}" run -d --name baikal-acc-internal "${CONFINE[@]}" \
    --network "${INTERNAL_NET}" -p "${INTERNAL_PORT}:8080" \
    -v "${INTERNAL_VOL}":/data \
    -e BAIKAL_ADMIN_PASSWORD="${PASSWORD}" \
    "${IMAGE}" >/dev/null
install_probe baikal-acc-internal

# The host cannot reach this container's published port, so readiness has to be
# established from inside it too.
# Mirrors check 1: a container that never serves has to be diagnosable from
# the CI log alone, and the probe has nothing to report about a server that
# never came up, so the container's own output is the only evidence there is.
probe baikal-acc-internal wait-serving 60 || "${ENGINE}" logs baikal-acc-internal

# `network inspect` failing and the network not being internal are different
# defects. Folded into one comparison they both surfaced as "expected true, got
# ''", which names only the second.
if internal=$("${ENGINE}" network inspect "${INTERNAL_NET}" --format '{{.Internal}}'); then
    assert_eq true "${internal}" 'test network really is internal'
else
    fail "test network really is internal: ${ENGINE} network inspect ${INTERNAL_NET} failed"
fi

probe baikal-acc-internal probe-egress
probe baikal-acc-internal seed-user "${DAV_USER}" "${DAV_PASS}"
probe baikal-acc-internal probe-loopback "${DAV_USER}" "${DAV_PASS}"

"${ENGINE}" rm -f baikal-acc-internal >/dev/null 2>&1
"${ENGINE}" volume rm -f "${INTERNAL_VOL}" >/dev/null 2>&1
"${ENGINE}" network rm -f "${INTERNAL_NET}" >/dev/null 2>&1

echo '== 10. warm restart preserves data'
"${ENGINE}" restart baikal-acc >/dev/null
wait_for_port "${BASE}/dav.php" || fail 'did not come back'
assert_status 401 '/dav.php after restart' "${BASE}/dav.php"
assert_contains 'SUMMARY:acceptance' 'event survived restart' \
    curl -s --connect-timeout 5 --max-time 30 -u "${DAV_USER}:${DAV_PASS}" \
    "${BASE}/dav.php/calendars/${DAV_USER}/test/accept-1.ics"

echo '== 11. version drift is cleared, never served as a 302'
# Age the config in the volume while the container that owns it is still up -
# the probe only ever reaches the image through `exec`, so the mutation happens
# before the container is taken away rather than in a throwaway one afterwards.
# Nothing is requested in between, so the aged config is never served.
probe baikal-acc set-version 0.10.1
"${ENGINE}" rm -f baikal-acc >/dev/null
start
wait_for_port "${BASE}/dav.php" || fail 'did not start after drift'
assert_status 401 '/dav.php after version drift' "${BASE}/dav.php"
assert_contains 'cleared version drift: 0.10.1' 'drift was cleared' \
    "${ENGINE}" logs baikal-acc

echo '== 12. failure rules refuse rather than serve'
probe baikal-acc remove-db
"${ENGINE}" rm -f baikal-acc >/dev/null

"${ENGINE}" run --rm "${CONFINE[@]}" --network "${NET}" -v baikal-acc-nopw:/data "${IMAGE}" >/dev/null 2>&1
assert_eq 1 "${?}" 'cold start with no admin password exits 1'

"${ENGINE}" run --rm "${CONFINE[@]}" --network "${NET}" -v "${VOL}":/data \
    -e BAIKAL_ADMIN_PASSWORD="${PASSWORD}" "${IMAGE}" >/dev/null 2>&1
assert_eq 1 "${?}" 'config without database exits 1'

echo
if (( FAILURES == 0 )); then
    echo "acceptance: all checks passed"
    exit 0
fi
echo "acceptance: ${FAILURES} check(s) failed" >&2
exit 1
