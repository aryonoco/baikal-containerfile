<?php

// SPDX-License-Identifier: BSD-2-Clause
// SPDX-FileCopyrightText: 2026 Aryan Ameri <github@aryan.ameri.coffee>

// A stand-in for Baikal's VersionUpgrade.php, written for
// test/upstreamupgrade: the lines test/upstream-upgrade-api.sh looks for,
// laid out as upstream's own file lays them out, and nothing else of it.

namespace BaikalAdmin\Controller\Install;

class VersionUpgrade extends \Flake\Core\Controller {
    protected $aSuccess = [];

    protected function upgrade($databaseConfig, $sVersionFrom, $sVersionTo) {
        $pdo = $GLOBALS['DB']->getPDO();
    }
}
