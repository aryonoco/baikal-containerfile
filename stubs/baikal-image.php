<?php

// SPDX-License-Identifier: BSD-2-Clause
// SPDX-FileCopyrightText: 2026 Aryan Ameri <github@aryan.ameri.coffee>

declare(strict_types=1);

/*
 * What the image's own PHP borrows from the Baikal tree. Three files need it:
 * rootfs/usr/local/bin/baikal-bootstrap uses both Yaml methods,
 * BAIKAL_VERSION, Flake's Sqlite database and VersionUpgrade;
 * rootfs/usr/local/share/baikal-health/index.php uses Yaml::parseFile; and
 * test/in-container.php uses BAIKAL_VERSION. Trimming this to what one of
 * them needs breaks the others.
 */

namespace Flake\Core\Database {
    /**
     * Opens the SQLite file with PDO in exception mode, as Baikal 0.12.1 and
     * 0.13.0 ship it.
     */
    class Sqlite
    {
        /**
         * @param string $sDbPath
         */
        public function __construct($sDbPath)
        {
        }
    }
}

namespace BaikalAdmin\Controller\Install {
    /**
     * Only the members baikal-bootstrap reaches. test/upstream-upgrade-api.sh
     * fails the build if upstream changes any of them.
     */
    class VersionUpgrade
    {
        /** @var array<mixed> */
        protected $aSuccess = [];

        /**
         * Throws on failure; writes system.configured_version on success.
         *
         * @param array<mixed> $databaseConfig
         * @param string $sVersionFrom
         * @param string $sVersionTo
         * @return bool
         */
        protected function upgrade($databaseConfig, $sVersionFrom, $sVersionTo)
        {
        }
    }
}

namespace Symfony\Component\Yaml {
    /**
     * symfony/yaml, as it ships in the Baikal 0.12.1 vendor tree.
     */
    class Yaml
    {
        public static function parseFile(string $filename, int $flags = 0): mixed
        {
        }

        public static function dump(mixed $input, int $inline = 2, int $indent = 4, int $flags = 0): string
        {
        }
    }
}

namespace {
    /*
     * Core/DUpstream writes it with define()
     */
    define('BAIKAL_VERSION', '0.12.1');
}
