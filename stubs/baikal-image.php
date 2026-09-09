<?php

// SPDX-License-Identifier: BSD-2-Clause
// SPDX-FileCopyrightText: 2026 Aryan Ameri <github@aryan.ameri.coffee>

declare(strict_types=1);

/*
 * Everything rootfs/usr/local/bin/baikal-bootstrap borrows from the image and
 * this repository does not contain. Both symbols arrive with the Baikal release
 * archive, which is fetched and unpacked at build time, so there is no vendor
 * tree here and never will be - the archive ships its own and no Composer runs.
 *
 * PHPStan scans this file for definitions and does not analyse it, so the
 * bodies are deliberately empty. Its real value is the other direction: this is
 * the checked, reviewable list of what the entrypoint depends on from outside
 * itself. A Baikal upgrade that changes either signature fails the lint gate
 * here rather than at container start, which is the only other place it would
 * ever have been noticed.
 *
 * The alternative - ignoreErrors, or a lower level - would have silenced these
 * two along with every genuine error in our own code, and our own code is the
 * only code this gate exists to check.
 */

namespace Symfony\Component\Yaml {
    /**
     * symfony/yaml, as it ships in the Baikal 0.12.1 vendor tree. Only the two
     * entry points baikal-bootstrap actually calls are declared; the optional
     * nesting and alias limits it never passes are left off on purpose, so that
     * starting to pass one is a change here too.
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
     * Core/Distrib.php, which the entrypoint requires directly. Upstream writes
     * it with define() rather than const, and the value moves with the
     * BAIKAL_VERSION build argument - phpstan.neon lists it under
     * dynamicConstantNames so the literal below is read as a shape, not as a
     * fact about the running image.
     */
    define('BAIKAL_VERSION', '0.12.1');
}
