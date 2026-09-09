# SPDX-License-Identifier: BSD-2-Clause
# SPDX-FileCopyrightText: 2026 Aryan Ameri <github@aryan.ameri.coffee>
# shellcheck shell=bash

FAILURES=0

pass() { printf '  ok   %s\n' "${1}"; }
fail() { printf '  FAIL %s\n' "${1}" >&2; FAILURES=$((FAILURES + 1)); }

assert_eq() {
    local expected="${1}" actual="${2}" what="${3}"
    if [[ "${actual}" == "${expected}" ]]; then
        pass "${what} (${actual})"
    else
        fail "${what}: expected '${expected}', got '${actual}'"
    fi
}

# Deliberately no --fail and no 2xx matching. Every Baikal failure mode returns
# 200 with an exception page, so only an exact status code proves anything.
#
# The timeouts are not decoration. Observed on this suite: FrankenPHP accepts
# the connection from the kernel's backlog while it is still starting and then
# never answers it, and a curl with no deadline waits on that for as long as the
# job is allowed to live - a whole CI run hanging on the readiness poll of the
# first check, with no output, which is the worst way for a test to fail. Short
# here because the caller is a poll loop and giving up is how it retries.
http_status() {
    curl -s -o /dev/null -w '%{http_code}' --connect-timeout 2 --max-time 5 \
        -X "${2:-GET}" "${1}"
}

# Assert on the status code of one request; every argument after the label goes
# to curl, so a PROPFIND with a body reads the same way a bare GET does.
#
# The request runs on a line of its own rather than inside the assertion, which
# is what keeps its exit status from being thrown away unseen. That status is
# then still not consulted, and deliberately so: when curl cannot connect it
# prints 000, and 000 is what the comparison fails on, naming the check and the
# code it wanted. Consulting the exit status as well would report a refused
# connection twice while saying nothing at all in the case that actually
# matters here, which is a connection that succeeds and answers wrongly.
assert_status() {
    local expected="${1}" what="${2}"
    shift 2
    local actual
    # Long enough that no real DAV request reaches it, short enough that a
    # server which accepts and then stalls fails the check instead of the job.
    actual=$(curl -s -o /dev/null -w '%{http_code}' --connect-timeout 5 --max-time 30 "${@}")
    assert_eq "${expected}" "${actual}" "${what}"
}

wait_for_port() {
    local url="${1}" tries=60 status
    while (( tries-- > 0 )); do
        # Every attempt before the port opens exits curl non-zero. That is the
        # normal path through this loop rather than a fault, and 000 is how it
        # arrives in the output, so the code is the thing to wait on.
        status=$(http_status "${url}")
        if [[ "${status}" != "000" ]]; then
            return 0
        fi
        sleep 1
    done
    return 1
}
