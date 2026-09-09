<?php

// SPDX-License-Identifier: BSD-2-Clause
// SPDX-FileCopyrightText: 2026 Aryan Ameri <github@aryan.ameri.coffee>

declare(strict_types=1);

/*
 * Everything rootfs/usr/local/bin/baikal-bootstrap borrows from the image
 */

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
