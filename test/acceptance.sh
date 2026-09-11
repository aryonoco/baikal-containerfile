#!/usr/bin/env bash
# SPDX-License-Identifier: BSD-2-Clause
# SPDX-FileCopyrightText: 2026 Aryan Ameri <github@aryan.ameri.coffee>
set -uo pipefail
cd "$(dirname "${0}")" || exit 1
# shellcheck source=test/lib.sh
source ./lib.sh

ENGINE="${ENGINE:-docker}"
IMAGE="${IMAGE:-localhost/baikal:dev}"
PORT=18099
INTERNAL_PORT=18089
HEALTH_PORT=18081
HEALTH_BASE="http://127.0.0.1:${HEALTH_PORT}"
BASE="http://127.0.0.1:${PORT}"
PASSWORD='correct horse battery staple'
DAV_USER=alice
DAV_PASS=wonderland
VOL=baikal-acceptance
INTERNAL_VOL=baikal-acceptance-internal
NET=baikal-acceptance-net
INTERNAL_NET=baikal-acceptance-internal-net

CONFINE=(--cap-drop ALL --read-only --user 65532:65532 --tmpfs /tmp)

PHP_BIN=/usr/local/bin/frankenphp
PROBE_SRC=./in-container.php

# Inside the container, the probe lands in the /data volume
PROBE=/data/in-container.php

# Ship the probe into a container.
install_probe() {
    local ctr="${1}"
    "${ENGINE}" cp "${PROBE_SRC}" "${ctr}:${PROBE}" >/dev/null 2>&1 ||
        fail "could not copy ${PROBE_SRC} into ${ctr}:${PROBE}"
}

# Run one probe subcommand and fold record it prints into pass/fail
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

# Watches the engine's own health machinery rather than running the probe
# ourselves. This is what proves a JSON-array HealthCmd executes in an image
# with no shell: a plain-string command would be run through /bin/sh -c and
# could never leave "starting".
wait_for_health() {
    local ctr="${1}" status=timeout deadline=$(( SECONDS + 150 ))
    while (( SECONDS < deadline )); do
        status=$("${ENGINE}" inspect --format '{{.State.Health.Status}}' "${ctr}" 2>/dev/null) ||
            status=absent
        case "${status}" in
            healthy | unhealthy) break ;;
            *) ;;
        esac
        sleep 2
    done
    printf '%s\n' "${status}"
}

cleanup() {
    "${ENGINE}" rm -f baikal-acc baikal-acc-internal >/dev/null 2>&1 || true
    "${ENGINE}" volume rm -f "${VOL}" "${INTERNAL_VOL}" baikal-acc-nopw >/dev/null 2>&1 || true
    "${ENGINE}" network rm -f "${NET}" "${INTERNAL_NET}" >/dev/null 2>&1 || true
}
trap cleanup EXIT
cleanup

"${ENGINE}" network create "${NET}" >/dev/null

start() {
    "${ENGINE}" run -d --name baikal-acc "${CONFINE[@]}" \
        --network "${NET}" -p "${PORT}:8080" -p "${HEALTH_PORT}:8081" \
        -v "${VOL}":/data \
        -e BAIKAL_ADMIN_PASSWORD="${PASSWORD}" \
        "${IMAGE}" >/dev/null
    install_probe baikal-acc
}

echo '== 1. cold start on an empty volume'
start
if wait_for_port "${BASE}/dav.php"; then pass 'container serves'; else fail 'container never served'; "${ENGINE}" logs baikal-acc; fi

echo '== 2. one process: PID 1 is the server, not a supervisor'
# pcntl_exec() overlays the bootstrap process with the server
probe baikal-acc assert-pid1

echo '== 3. health check is exactly 401'
assert_status 401 '/dav.php' "${BASE}/dav.php"

echo '== 4. the health endpoint answers on its own listener'
assert_status 200 '/healthz' "${HEALTH_BASE}/healthz"
assert_contains ok '/healthz says ok' \
    curl -s --connect-timeout 5 --max-time 30 "${HEALTH_BASE}/healthz"
# The health listener is not the DAV listener. Publishing it must not publish DAV.
assert_status 404 '/dav.php on the health listener' "${HEALTH_BASE}/dav.php"
assert_status 404 '/ on the health listener' "${HEALTH_BASE}/"
rc=0
"${ENGINE}" exec baikal-acc "${PHP_BIN}" php-cli /usr/local/bin/baikal-health || rc=$?
assert_eq 0 "${rc}" 'baikal-health exits 0 on a healthy container'
health_status="$(wait_for_health baikal-acc)"
assert_eq healthy "${health_status}" 'engine reports the container healthy'

echo '== 5. no shell in the image'
probe baikal-acc assert-no-shell

echo '== 6. process capability sets are all zero'
# The raw /proc/self/status line carries the labels CapEff/CapPrm
probe baikal-acc assert-caps

echo '== 7. DAV actually works'
probe baikal-acc seed-user "${DAV_USER}" "${DAV_PASS}"

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

echo '== 8. CardDAV works'
assert_status 201 'MKCOL addressbook' -u "${DAV_USER}:${DAV_PASS}" \
    -X MKCOL -H 'Content-Type: application/xml' \
    --data '<?xml version="1.0"?><d:mkcol xmlns:d="DAV:" xmlns:c="urn:ietf:params:xml:ns:carddav"><d:set><d:prop><d:resourcetype><d:collection/><c:addressbook/></d:resourcetype></d:prop></d:set></d:mkcol>' \
    "${BASE}/dav.php/addressbooks/${DAV_USER}/contacts/"

echo '== 9. RFC 6764 .well-known discovery'
assert_status 301 '/.well-known/caldav' "${BASE}/.well-known/caldav"
assert_status 301 '/.well-known/carddav' "${BASE}/.well-known/carddav"

echo '== 10. no egress required, measured from a genuinely --internal network'
"${ENGINE}" network create --internal "${INTERNAL_NET}" >/dev/null
"${ENGINE}" run -d --name baikal-acc-internal "${CONFINE[@]}" \
    --network "${INTERNAL_NET}" -p "${INTERNAL_PORT}:8080" \
    -v "${INTERNAL_VOL}":/data \
    -e BAIKAL_ADMIN_PASSWORD="${PASSWORD}" \
    "${IMAGE}" >/dev/null
install_probe baikal-acc-internal

probe baikal-acc-internal wait-serving 60 || "${ENGINE}" logs baikal-acc-internal

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

echo '== 11. warm restart preserves data'
"${ENGINE}" restart baikal-acc >/dev/null
wait_for_port "${BASE}/dav.php" || fail 'did not come back'
assert_status 401 '/dav.php after restart' "${BASE}/dav.php"
assert_contains 'SUMMARY:acceptance' 'event survived restart' \
    curl -s --connect-timeout 5 --max-time 30 -u "${DAV_USER}:${DAV_PASS}" \
    "${BASE}/dav.php/calendars/${DAV_USER}/test/accept-1.ics"

echo '== 12. version drift is cleared, never served as a 302'

probe baikal-acc set-version 0.10.1
"${ENGINE}" rm -f baikal-acc >/dev/null
start
wait_for_port "${BASE}/dav.php" || fail 'did not start after drift'
assert_status 401 '/dav.php after version drift' "${BASE}/dav.php"
assert_contains 'cleared version drift: 0.10.1' 'drift was cleared' \
    "${ENGINE}" logs baikal-acc

echo '== 13. failure rules refuse rather than serve'
probe baikal-acc remove-db
assert_status 503 '/healthz with the database removed' "${HEALTH_BASE}/healthz"
rc=0
"${ENGINE}" exec baikal-acc "${PHP_BIN}" php-cli /usr/local/bin/baikal-health || rc=$?
assert_eq 1 "${rc}" 'baikal-health exits 1 with the database removed'
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
