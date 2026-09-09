#!/usr/bin/env bash
# SPDX-License-Identifier: BSD-2-Clause
# SPDX-FileCopyrightText: 2026 Aryan Ameri <github@aryan.ameri.coffee>
set -uo pipefail
cd "$(dirname "$0")" || exit 1
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

# --- PHP payloads -----------------------------------------------------------
#
# There is no shell in the image, so every one of these runs via the binary's
# own CLI (`frankenphp php-cli -r`), never `shell_exec()` (that execs
# /bin/sh, which check 4 below proves is absent). Each is read into a
# variable from a quoted heredoc, rather than embedded as a single-quoted
# command argument, so its literal `$identifiers` are never mistaken by
# tooling for unexpanded bash variables: a quoted heredoc is unambiguous
# about not expanding, a single-quoted argument string is not. Anything that
# varies per call travels through the exec'd process's own environment
# (`docker/podman exec -e`), not through string interpolation into PHP
# source.

read -r -d '' PHP_PID1 <<'PHP' || true
echo trim(file_get_contents("/proc/1/comm"));
PHP

read -r -d '' PHP_CAPS <<'PHP' || true
preg_match_all("/^Cap(Eff|Prm):\s*(\S+)/m", file_get_contents("/proc/self/status"), $m, PREG_SET_ORDER);
foreach ($m as $x) { echo $x[1], "=", $x[2], PHP_EOL; }
PHP

read -r -d '' PHP_SEED_USER <<'PHP' || true
$realm = "BaikalDAV"; $u = "alice"; $p = "wonderland";
$pdo = new PDO("sqlite:/data/Specific/db/db.sqlite");
$pdo->exec("INSERT INTO users (username,digesta1) VALUES (\"$u\",\"" . md5("$u:$realm:$p") . "\")");
$pdo->exec("INSERT INTO principals (uri,displayname) VALUES (\"principals/$u\",\"Alice\")");
PHP

read -r -d '' PHP_FSOCKOPEN <<'PHP' || true
var_dump(@fsockopen("1.1.1.1", 443, $errno, $errstr, 3));
PHP

# Parameterised via ACC_METHOD / ACC_PATH / ACC_AUTH in the exec environment,
# not string interpolation, so this payload is static text like every other
# one here.
read -r -d '' PHP_HTTP_STATUS <<'PHP' || true
$method = getenv("ACC_METHOD") ?: "GET";
$path   = getenv("ACC_PATH");
$auth   = getenv("ACC_AUTH");
$header = "";
if ($auth !== false && $auth !== "") {
    $header = "Authorization: Basic " . base64_encode($auth) . "\r\nDepth: 0\r\n";
}
$ctx = stream_context_create(["http" => [
    "method"        => $method,
    "header"        => $header,
    "ignore_errors" => true,
    "timeout"       => 5,
]]);
@file_get_contents("http://127.0.0.1:8080" . $path, false, $ctx);
foreach ($http_response_header ?? [] as $h) {
    if (preg_match("#^HTTP/\S+\s+(\d+)#", $h, $m)) { echo $m[1]; break; }
}
PHP

read -r -d '' PHP_VERSION_DRIFT <<'PHP' || true
$f = "/data/config/baikal.yaml";
file_put_contents($f, preg_replace("/configured_version:.*/", "configured_version: 0.10.1", file_get_contents($f)));
PHP

read -r -d '' PHP_UNLINK_DB <<'PHP' || true
unlink("/data/Specific/db/db.sqlite");
PHP

# -----------------------------------------------------------------------------

cleanup() {
    "$ENGINE" rm -f baikal-acc baikal-acc-internal >/dev/null 2>&1 || true
    "$ENGINE" volume rm -f "$VOL" "$INTERNAL_VOL" baikal-acc-nopw >/dev/null 2>&1 || true
    "$ENGINE" network rm -f "$NET" "$INTERNAL_NET" >/dev/null 2>&1 || true
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
"$ENGINE" network create "$NET" >/dev/null

start() {
    "$ENGINE" run -d --name baikal-acc "${CONFINE[@]}" \
        --network "$NET" -p "${PORT}:8080" \
        -v "$VOL":/data \
        -e BAIKAL_ADMIN_PASSWORD="$PASSWORD" \
        "$IMAGE" >/dev/null
}

# Runs PHP inside the container. There is no shell in the image; the binary's
# own CLI is how anything gets executed in there.
in_ctr() { "$ENGINE" exec baikal-acc /usr/local/bin/frankenphp php-cli -r "$1"; }

echo '== 1. cold start on an empty volume'
start
if wait_for_port "$BASE/dav.php"; then pass 'container serves'; else fail 'container never served'; "$ENGINE" logs baikal-acc; fi

echo '== 2. one process: PID 1 is the server, not a supervisor'
# pcntl_exec() overlays the bootstrap process with the server; it does not
# fork. `docker inspect --format '{{.Path}}'` only ever echoes the configured
# entrypoint back, so the only way to prove the exec actually happened is to
# ask the container what its own PID 1 is.
COMM="$(in_ctr "$PHP_PID1" 2>/dev/null)"
assert_eq frankenphp "$COMM" 'PID 1 comm'

echo '== 3. health check is exactly 401'
assert_eq 401 "$(http_status "$BASE/dav.php")" '/dav.php'

echo '== 4. no shell in the image'
if "$ENGINE" exec baikal-acc /bin/sh -c 'echo x' >/dev/null 2>&1; then
    fail 'a shell is present in the image'
else
    pass 'no /bin/sh'
fi

echo '== 5. process capability sets are all zero'
# The raw /proc/self/status line still carries the labels CapEff/CapPrm, and
# CapEff contains both 'a' and 'f' - so a substring match against the whole
# line can never distinguish an all-zero mask from a real one. Compare the
# hex values alone.
CAPRAW="$(in_ctr "$PHP_CAPS" 2>/dev/null)"
CAP_EFF="$(grep -m1 '^Eff=' <<<"$CAPRAW" | cut -d= -f2)"
CAP_PRM="$(grep -m1 '^Prm=' <<<"$CAPRAW" | cut -d= -f2)"
assert_eq 0000000000000000 "${CAP_EFF:-<missing>}" 'CapEff all zero'
assert_eq 0000000000000000 "${CAP_PRM:-<missing>}" 'CapPrm all zero'

echo '== 6. DAV actually works'
in_ctr "$PHP_SEED_USER" >/dev/null

assert_eq 207 "$(curl -s -o /dev/null -w '%{http_code}' -u "$DAV_USER:$DAV_PASS" \
    -X PROPFIND -H 'Depth: 0' "$BASE/dav.php/principals/$DAV_USER/")" 'authenticated PROPFIND'
assert_eq 201 "$(curl -s -o /dev/null -w '%{http_code}' -u "$DAV_USER:$DAV_PASS" \
    -X MKCALENDAR "$BASE/dav.php/calendars/$DAV_USER/test/")" 'MKCALENDAR'

EVENT=$'BEGIN:VCALENDAR\r\nVERSION:2.0\r\nPRODID:-//acceptance//EN\r\nBEGIN:VEVENT\r\nUID:accept-1\r\nDTSTAMP:20260101T000000Z\r\nDTSTART:20260101T120000Z\r\nDTEND:20260101T130000Z\r\nSUMMARY:acceptance\r\nEND:VEVENT\r\nEND:VCALENDAR\r\n'
assert_eq 201 "$(curl -s -o /dev/null -w '%{http_code}' -u "$DAV_USER:$DAV_PASS" \
    -X PUT -H 'Content-Type: text/calendar' --data-binary "$EVENT" \
    "$BASE/dav.php/calendars/$DAV_USER/test/accept-1.ics")" 'PUT event'

if curl -s -u "$DAV_USER:$DAV_PASS" "$BASE/dav.php/calendars/$DAV_USER/test/accept-1.ics" \
     | grep -q 'SUMMARY:acceptance'; then
    pass 'GET event round-trips'
else
    fail 'GET event did not return what was PUT'
fi

assert_eq 207 "$(curl -s -o /dev/null -w '%{http_code}' -u "$DAV_USER:$DAV_PASS" \
    -X REPORT -H 'Depth: 1' -H 'Content-Type: application/xml' \
    --data '<?xml version="1.0"?><d:sync-collection xmlns:d="DAV:"><d:sync-token/><d:prop><d:getetag/></d:prop></d:sync-collection>' \
    "$BASE/dav.php/calendars/$DAV_USER/test/")" 'REPORT sync-collection'

echo '== 7. CardDAV works'
assert_eq 201 "$(curl -s -o /dev/null -w '%{http_code}' -u "$DAV_USER:$DAV_PASS" \
    -X MKCOL -H 'Content-Type: application/xml' \
    --data '<?xml version="1.0"?><d:mkcol xmlns:d="DAV:" xmlns:c="urn:ietf:params:xml:ns:carddav"><d:set><d:prop><d:resourcetype><d:collection/><c:addressbook/></d:resourcetype></d:prop></d:set></d:mkcol>' \
    "$BASE/dav.php/addressbooks/$DAV_USER/contacts/")" 'MKCOL addressbook'

echo '== 8. RFC 6764 .well-known discovery'
assert_eq 301 "$(http_status "$BASE/.well-known/caldav")" '/.well-known/caldav'
assert_eq 301 "$(http_status "$BASE/.well-known/carddav")" '/.well-known/carddav'

echo '== 9. no egress required, measured from a genuinely --internal network'
# A flag read (docker network inspect --format '{{.Internal}}') tests Docker,
# not us. This starts a second instance of the image, under the same CONFINE
# settings, on a network with no route out, and proves from inside the
# container - there is no shell and no curl in the image - that DAV still
# works with no egress available to fail open through.
"$ENGINE" network create --internal "$INTERNAL_NET" >/dev/null
"$ENGINE" run -d --name baikal-acc-internal "${CONFINE[@]}" \
    --network "$INTERNAL_NET" -p "${INTERNAL_PORT}:8080" \
    -v "$INTERNAL_VOL":/data \
    -e BAIKAL_ADMIN_PASSWORD="$PASSWORD" \
    "$IMAGE" >/dev/null

in_ctr_internal() { "$ENGINE" exec baikal-acc-internal /usr/local/bin/frankenphp php-cli -r "$1"; }

internal_status() {
    # $1: HTTP method, $2: path, $3: optional "user:pass" for Basic auth.
    "$ENGINE" exec \
        -e ACC_METHOD="$1" -e ACC_PATH="$2" -e ACC_AUTH="${3:-}" \
        baikal-acc-internal /usr/local/bin/frankenphp php-cli -r "$PHP_HTTP_STATUS"
}

wait_for_internal() {
    local tries=60
    while (( tries-- > 0 )); do
        [[ -n "$(internal_status GET /dav.php)" ]] && return 0
        sleep 1
    done
    return 1
}

if wait_for_internal; then
    pass 'internal-network container serves'
else
    fail 'internal-network container never served'
    "$ENGINE" logs baikal-acc-internal
fi

assert_eq true "$("$ENGINE" network inspect "$INTERNAL_NET" --format '{{.Internal}}')" \
    'test network really is internal'

OUTBOUND="$(in_ctr_internal "$PHP_FSOCKOPEN" 2>/dev/null)"
assert_eq 'bool(false)' "$OUTBOUND" 'outbound TCP connect fails with no egress'

assert_eq 401 "$(internal_status GET /dav.php)" 'unauthenticated GET from inside is 401'

in_ctr_internal "$PHP_SEED_USER" >/dev/null

assert_eq 207 "$(internal_status PROPFIND "/dav.php/principals/$DAV_USER/" "$DAV_USER:$DAV_PASS")" \
    'authenticated PROPFIND from inside, no egress available'

"$ENGINE" rm -f baikal-acc-internal >/dev/null 2>&1
"$ENGINE" volume rm -f "$INTERNAL_VOL" >/dev/null 2>&1
"$ENGINE" network rm -f "$INTERNAL_NET" >/dev/null 2>&1

echo '== 10. warm restart preserves data'
"$ENGINE" restart baikal-acc >/dev/null
wait_for_port "$BASE/dav.php" || fail 'did not come back'
assert_eq 401 "$(http_status "$BASE/dav.php")" '/dav.php after restart'
if curl -s -u "$DAV_USER:$DAV_PASS" "$BASE/dav.php/calendars/$DAV_USER/test/accept-1.ics" \
     | grep -q 'SUMMARY:acceptance'; then
    pass 'event survived restart'
else
    fail 'event lost across restart'
fi

echo '== 11. version drift is cleared, never served as a 302'
"$ENGINE" rm -f baikal-acc >/dev/null
"$ENGINE" run --rm "${CONFINE[@]}" -v "$VOL":/data \
    --entrypoint /usr/local/bin/frankenphp "$IMAGE" php-cli -r "$PHP_VERSION_DRIFT"
start
wait_for_port "$BASE/dav.php" || fail 'did not start after drift'
assert_eq 401 "$(http_status "$BASE/dav.php")" '/dav.php after version drift'
if "$ENGINE" logs baikal-acc 2>&1 | grep -q 'cleared version drift: 0.10.1'; then
    pass 'drift was cleared'
else
    fail 'no drift-cleared log line'
fi

echo '== 12. failure rules refuse rather than serve'
"$ENGINE" rm -f baikal-acc >/dev/null
"$ENGINE" run --rm "${CONFINE[@]}" --network "$NET" -v baikal-acc-nopw:/data "$IMAGE" >/dev/null 2>&1
assert_eq 1 "$?" 'cold start with no admin password exits 1'

"$ENGINE" run --rm "${CONFINE[@]}" -v "$VOL":/data \
    --entrypoint /usr/local/bin/frankenphp "$IMAGE" php-cli -r "$PHP_UNLINK_DB"
"$ENGINE" run --rm "${CONFINE[@]}" --network "$NET" -v "$VOL":/data \
    -e BAIKAL_ADMIN_PASSWORD="$PASSWORD" "$IMAGE" >/dev/null 2>&1
assert_eq 1 "$?" 'config without database exits 1'

echo
if (( FAILURES == 0 )); then
    echo "acceptance: all checks passed"
    exit 0
fi
echo "acceptance: $FAILURES check(s) failed" >&2
exit 1
