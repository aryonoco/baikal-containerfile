#!/usr/bin/env bash
# SPDX-License-Identifier: BSD-2-Clause
# SPDX-FileCopyrightText: 2026 Aryan Ameri <github@aryan.ameri.coffee>

# Usage: upstream-upgrade-api.sh TREE
#
# Fails unless the Baikal release unpacked at TREE still has every member
# upgradeDatabase() in baikal-bootstrap reaches. That function runs
# Baikal's own upgrade without the web UI, through members upstream never
# meant as an API, so a release that moves or reshapes one must fail the
# build that fetches it, naming what moved, rather than ship a container
# that cannot start. The migrations themselves are upstream's business and
# may change freely.
#
# The Containerfile's fetch stage runs it over the release.
# test/upstreamupgrade runs it over fixtures, and sees every way it can
# fail.
#
# Exit status: 0 when every member is there; 1 when something moved or
# changed, with an ERROR line on stderr for each; 2 when TREE is not one
# directory.

# Every $ in a single-quoted pattern or name below is PHP source text being
# matched or named, so it must not expand; SC2016 warns about exactly that.
# shellcheck disable=SC2016
set -euo pipefail

if (($# != 1)) || [[ ! -d "${1}" ]]; then
	echo "usage: ${0} TREE, where TREE is the directory the Baikal release is unpacked in" >&2
	exit 2
fi
TREE="${1}"
UPGRADE=Core/Frameworks/BaikalAdmin/Controller/Install/VersionUpgrade.php
SQLITE=Core/Frameworks/Flake/Core/Database/Sqlite.php
FAILED=0

fail() {
	echo "ERROR: ${1}" >&2
	FAILED=1
}

for file in "${UPGRADE}" "${SQLITE}"; do
	[[ -f "${TREE}/${file}" ]] || fail "${file} is missing from ${TREE}."
done

# need <file> <pattern> <what>: the file has a line matching the extended
# regular expression. Says nothing of a file already reported missing.
need() {
	local file="${1}" pattern="${2}" what="${3}"
	[[ -f "${TREE}/${file}" ]] || return 0
	grep -Eq -- "${pattern}" "${TREE}/${file}" || fail "${file} no longer has ${what}"
}

need "${UPGRADE}" '^class VersionUpgrade extends \\Flake\\Core\\Controller \{' \
	'class VersionUpgrade extends \Flake\Core\Controller'
need "${UPGRADE}" '^    protected function upgrade\(\$databaseConfig, \$sVersionFrom, \$sVersionTo\) \{' \
	'protected function upgrade($databaseConfig, $sVersionFrom, $sVersionTo)'
need "${UPGRADE}" '^    protected \$aSuccess = \[\];' \
	'protected $aSuccess'
need "${UPGRADE}" "\\\$GLOBALS\['DB'\]->getPDO\(\)" \
	"its connection from \$GLOBALS['DB']->getPDO()"
need "${SQLITE}" '^    function __construct\(\$sDbPath\) \{' \
	'function __construct($sDbPath)'

if ((FAILED)); then
	echo "Re-read VersionUpgrade::upgrade() and Flake's database classes, then" >&2
	echo "bring upgradeDatabase() in baikal-bootstrap back in line with them." >&2
	exit 1
fi
echo "every member the upgrade relies on is in ${TREE}"
