#!/usr/bin/env bash
# SPDX-License-Identifier: BSD-2-Clause
# SPDX-FileCopyrightText: 2026 Aryan Ameri <github@aryan.ameri.coffee>
set -euo pipefail

# baikal-bootstrap clears version drift by writing configured_version, which is
# only safe because upstream's VersionUpgrade::upgrade() gates every schema
# change on a threshold at or below 0.10.0 - so at or above that it performs no
# DDL and does exactly what we do.
#
# That is a property of upstream's source, not a law. If a release adds a
# threshold above 0.10.0, our shortcut would silently skip a real migration.
# This fails the BUILD in that case, so the assumption is re-checked by a human
# rather than discovered through a corrupted database.

SRC="${1:?path to VersionUpgrade.php}"
EXPECTED="0.10.0 0.2.3 0.3.0 0.4.0 0.4.5 0.5.1 0.9.4"

# || true: with set -e, a non-zero grep (SRC missing, empty, or no matching
# lines - an upstream refactor moving the file is the likely real-world case)
# would propagate through pipefail and kill the script inside this command
# substitution, before the diagnostic below ever runs. An empty FOUND still
# fails the comparison and prints the guidance; only exit-on-grep-failure was
# the bug.
FOUND=$(grep -oE "version_compare\(\\\$sVersionFrom, '[0-9.]+'" "$SRC" \
        | grep -oE "'[0-9.]+'" | tr -d "'" | sort -u | tr '\n' ' ') || true
FOUND="${FOUND% }"

if [[ "$FOUND" != "$EXPECTED" ]]; then
    echo "ERROR: upstream migration thresholds changed." >&2
    echo "  expected: $EXPECTED" >&2
    echo "  found:    $FOUND" >&2
    echo "Re-read VersionUpgrade::upgrade(). If any new threshold is above" >&2
    echo "0.10.0, baikal-bootstrap must stop clearing drift for that range." >&2
    exit 1
fi
echo "upstream migration thresholds unchanged: $FOUND"
