# SPDX-License-Identifier: BSD-2-Clause
# SPDX-FileCopyrightText: 2026 Aryan Ameri <github@aryan.ameri.coffee>
# shellcheck shell=bash

FAILURES=0

pass() { printf '  ok   %s\n' "$1"; }
fail() { printf '  FAIL %s\n' "$1" >&2; FAILURES=$((FAILURES + 1)); }

assert_eq() {
    local expected="$1" actual="$2" what="$3"
    if [[ "$actual" == "$expected" ]]; then
        pass "$what ($actual)"
    else
        fail "$what: expected '$expected', got '$actual'"
    fi
}

# Deliberately no --fail and no 2xx matching. Every Baikal failure mode returns
# 200 with an exception page, so only an exact status code proves anything.
http_status() {
    curl -s -o /dev/null -w '%{http_code}' -X "${2:-GET}" "$1"
}

wait_for_port() {
    local url="$1" tries=60
    while (( tries-- > 0 )); do
        [[ "$(http_status "$url")" != "000" ]] && return 0
        sleep 1
    done
    return 1
}
