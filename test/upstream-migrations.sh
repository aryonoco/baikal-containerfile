#!/usr/bin/env bash
# SPDX-License-Identifier: BSD-2-Clause
# SPDX-FileCopyrightText: 2026 Aryan Ameri <github@aryan.ameri.coffee>
set -euo pipefail

SRC="${1:?path to VersionUpgrade.php}"
EXPECTED="0.10.0 0.2.3 0.3.0 0.4.0 0.4.5 0.5.1 0.9.4"

# Try to detect an upstream change
FOUND=$(grep -oE "version_compare\(\\\$sVersionFrom, '[0-9.]+'" "${SRC}" \
        | grep -oE "'[0-9.]+'" | tr -d "'" | sort -u | tr '\n' ' ') || true
FOUND="${FOUND% }"

if [[ "${FOUND}" != "${EXPECTED}" ]]; then
    echo "ERROR: upstream migration thresholds changed." >&2
    echo "  expected: ${EXPECTED}" >&2
    echo "  found:    ${FOUND}" >&2
    echo "Re-read VersionUpgrade::upgrade(). If any new threshold is above" >&2
    echo "0.10.0, baikal-bootstrap must stop clearing drift for that range." >&2
    exit 1
fi
echo "upstream migration thresholds unchanged: ${FOUND}"
