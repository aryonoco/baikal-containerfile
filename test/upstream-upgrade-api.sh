#!/usr/bin/env bash
# SPDX-License-Identifier: BSD-2-Clause
# SPDX-FileCopyrightText: 2026 Aryan Ameri <github@aryan.ameri.coffee>
# Every $ in a single-quoted pattern or name below is PHP source text being
# matched or named, so it must not expand; SC2016 warns about exactly that.
# shellcheck disable=SC2016
set -euo pipefail

ROOT="${1:?path to the unpacked Baikal tree}"
UPGRADE="${ROOT}/Core/Frameworks/BaikalAdmin/Controller/Install/VersionUpgrade.php"
SQLITE="${ROOT}/Core/Frameworks/Flake/Core/Database/Sqlite.php"

# baikal-bootstrap runs Baikal's own upgrade without the web UI, through
# members upstream never meant as an API. Fail here, naming what moved,
# rather than later as a container that cannot start. Migrations themselves
# are upstream's business and may change freely.
MISSING=0
need() {
    local file="${1}" pattern="${2}" what="${3}"
    if ! grep -Eq -- "${pattern}" "${file}"; then
        echo "ERROR: ${file#"${ROOT}/"} no longer has ${what}" >&2
        MISSING=1
    fi
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

if (( MISSING )); then
    echo "Re-read VersionUpgrade::upgrade() and Flake's database classes, then" >&2
    echo "bring upgradeDatabase() in baikal-bootstrap back in line with them." >&2
    exit 1
fi
echo "upstream upgrade API unchanged"
