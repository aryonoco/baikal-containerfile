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
# is what keeps its exit status alive long enough to be read. It has to be read,
# because it can mean two different things and only one of them is safe to
# ignore.
#
# curl never got a response. It prints 000 and exits non-zero, and 000 is what
# the comparison then fails on, naming the check and the code it wanted. That
# needs no handling here; the sentinel already says it.
#
# curl got a status line and then the request did not finish - the server
# stalled mid-body until --max-time fired, the connection was reset, the peer
# went away. %{http_code} reports the LAST code received, so it is already set
# to something plausible, and comparing it alone reports a check as passing on a
# request that never completed. Measured, not theorised: against a server that
# answers 207 and then sleeps, curl prints 207 and exits 28, and this assertion
# said `ok`. That is the SC2312 failure this suite was just cleaned of - a
# discarded exit status letting a failed command pose as a successful check -
# reappearing one layer up, where ShellCheck cannot see it because the helper
# hands back a string rather than a status. So the status is read, and a request
# that did not complete fails loudly.
assert_status() {
    local expected="${1}" what="${2}"
    shift 2
    local actual rc
    # Long enough that no real DAV request in this suite reaches it, short
    # enough that a server which accepts and then stalls fails the check rather
    # than the whole job.
    actual=$(curl -s -o /dev/null -w '%{http_code}' --connect-timeout 5 --max-time 30 "${@}")
    rc=$?

    if (( rc != 0 )) && [[ "${actual}" != "000" ]]; then
        fail "${what}: curl exited ${rc} after receiving ${actual}, so the request never completed"
        return
    fi

    assert_eq "${expected}" "${actual}" "${what}"
}

# How long wait_for_port waits for anything at all to answer. 60s is what it
# waited before http_status grew a deadline, and wall-clock is the way to keep
# it there: an attempt costs anything from milliseconds (connection refused, the
# ordinary case while the container is still booting) to the 5s http_status now
# allows a stalled one, so a fixed try count buys a budget that swings six-fold
# with the failure mode. Sixty tries had quietly become six minutes.
WAIT_FOR_PORT_SECONDS=60

# Waits for the port to answer, and deliberately claims nothing about the
# answer. A server that sends a status line and then stalls has answered, which
# is the honest reading of "serves"; judging what came back is assert_status's
# job, and calling it is the next thing every caller here does.
wait_for_port() {
    local url="${1}" status deadline=$(( SECONDS + WAIT_FOR_PORT_SECONDS ))
    while (( SECONDS < deadline )); do
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
