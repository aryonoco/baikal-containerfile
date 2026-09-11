<?php

// SPDX-License-Identifier: BSD-2-Clause
// SPDX-FileCopyrightText: 2026 Aryan Ameri <github@aryan.ameri.coffee>

declare(strict_types=1);

/*
 * The endpoint half of the health definition: everything provable without going
 * through sabre. rootfs/usr/local/bin/baikal-health adds the half that cannot be.
 *
 * The reasons name the check that failed and never a filesystem path.
 */

use Symfony\Component\Yaml\Yaml;

/**
 * @return array{int, string} status and reason
 */
function health(): array
{
    // Unreachable in a serving container: baikal-bootstrap exits 1 rather than
    // pcntl_exec the server when this file is missing, and the root filesystem
    // is read-only, so nothing that answers on :8081 can be without it.
    if (!is_file('/var/www/baikal/vendor/autoload.php')) {
        return [503, 'vendor autoloader missing'];
    }
    require '/var/www/baikal/vendor/autoload.php';

    $configDir = rtrim(getenv('BAIKAL_PATH_CONFIG') ?: '/data/config/', '/') . '/';
    $specificDir = rtrim(getenv('BAIKAL_PATH_SPECIFIC') ?: '/data/Specific/', '/') . '/';
    $configFile = $configDir . 'baikal.yaml';
    $dbFile = $specificDir . 'db/db.sqlite';

    if (!is_readable($configFile)) {
        return [503, 'config unreadable'];
    }

    // Tools::assertBaikalIsOk() checks this on every request, not merely at
    // install, so an unwritable config is a live failure rather than a latent one.
    if (!is_writable($configFile)) {
        return [503, 'config not writable'];
    }

    try {
        $parsed = Yaml::parseFile($configFile);
    } catch (Throwable) {
        return [503, 'config unparseable'];
    }

    if (!is_array($parsed) || !isset($parsed['system']) || !is_array($parsed['system'])) {
        return [503, 'config has no system section'];
    }

    // Non-empty, not equal to BAIKAL_VERSION. Drift redirects every request to
    // /admin/install/, which the 401 assertion in baikal-health already catches.
    $configured = $parsed['system']['configured_version'] ?? null;
    if (!is_string($configured) || $configured === '') {
        return [503, 'config has no configured_version'];
    }

    if (!is_writable($dbFile)) {
        return [503, 'database missing or not writable'];
    }

    try {
        // Read-only, so the probe cannot create the database it is inspecting.
        // An empty db.sqlite left behind here would permanently silence
        // baikal-bootstrap's refusal to boot a config with no database.
        $pdo = new PDO('sqlite:' . $dbFile, null, null, [
            PDO::ATTR_ERRMODE => PDO::ERRMODE_EXCEPTION,
            Pdo\Sqlite::ATTR_OPEN_FLAGS => Pdo\Sqlite::OPEN_READONLY,
        ]);
        // Proves the schema is present, not merely that the file is.
        $pdo->query('SELECT count(*) FROM users');
    } catch (Throwable) {
        return [503, 'database unusable'];
    }

    return [200, 'ok'];
}

[$status, $reason] = health();

http_response_code($status);
header('Content-Type: text/plain; charset=utf-8');
header('Cache-Control: no-store');
echo $reason, "\n";
