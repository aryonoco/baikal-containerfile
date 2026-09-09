<?php

// SPDX-License-Identifier: BSD-2-Clause
// SPDX-FileCopyrightText: 2026 Aryan Ameri <github@aryan.ameri.coffee>

declare(strict_types=1);

/*
 
 * There is no shell in this image. It also has no dependencies. 
 *
 * Output protocol: one tab-separated record per assertion,
 *
 *     ok<TAB>what<TAB>expected<TAB>found
 *     FAIL<TAB>what<TAB>expected<TAB>found
 */

const LOOPBACK_ORIGIN = 'http://127.0.0.1:8080';

/**
 * The ones most likely to be the target of an intrusion.
 */
const FORBIDDEN_SHELLS = ['/bin/sh', '/bin/bash', '/bin/dash'];

const NO_CAPABILITIES = '0000000000000000';
const EGRESS_PROBE_HOST = '9.9.9.9';
const EGRESS_PROBE_PORT = 443;
const EGRESS_PROBE_TIMEOUT = 3;
const DIGEST_TABLE = 'users';
const DIGEST_COLUMN = 'digesta1';

/**
 * Collects assertions and renders them in the record format above.
 */
final class Assertions
{
    private static int $failures = 0;

    public static function equals(string $what, string $expected, string $found): void
    {
        self::record($found === $expected, $what, $expected, $found);
    }

    public static function record(bool $ok, string $what, string $expected, string $found): void
    {
        fwrite(STDOUT, sprintf(
            "%s\t%s\t%s\t%s\n",
            $ok ? 'ok' : 'FAIL',
            self::oneLine($what),
            self::oneLine($expected),
            self::oneLine($found),
        ));

        if (!$ok) {
            ++self::$failures;
        }
    }

    public static function failures(): int
    {
        return self::$failures;
    }

    /** Tabs and newlines are the record separators so they can't be present in any field. */
    private static function oneLine(string $text): string
    {
        return trim(strtr($text, ["\t" => ' ', "\n" => ' ', "\r" => ' ']));
    }
}

// --- filesystem and config helpers ------------------------------------------

/**
 * The image sets BAIKAL_PATH_CONFIG and BAIKAL_PATH_SPECIFIC, and the
 * framework concatenates them directly with a file name.
 */
function pathFromEnvironment(string $name, string $fallback): string
{
    $value = getenv($name);
    if ($value === false || $value === '') {
        $value = $fallback;
    }

    return rtrim($value, '/') . '/';
}

function configFile(): string
{
    return pathFromEnvironment('BAIKAL_PATH_CONFIG', '/data/config/') . 'baikal.yaml';
}

function databaseFile(): string
{
    return pathFromEnvironment('BAIKAL_PATH_SPECIFIC', '/data/Specific/') . 'db/db.sqlite';
}

function readOrThrow(string $path): string
{
    $contents = @file_get_contents($path);
    if ($contents === false) {
        throw new RuntimeException("cannot read $path");
    }

    return $contents;
}

/**
 * Matches one `key: value` line of baikal.yaml
 */
function configLinePattern(string $key): string
{
    return '/^([ \t]*' . preg_quote($key, '/') . ':[ \t]*)(\S[^\r\n]*?)[ \t]*$/m';
}

function readConfigScalar(string $key): string
{
    $file = configFile();
    $contents = readOrThrow($file);
    $pattern = configLinePattern($key);

    $occurrences = preg_match_all($pattern, $contents);
    if ($occurrences === false) {
        throw new RuntimeException("$file: could not be searched for '$key'");
    }
    if ($occurrences !== 1) {
        throw new RuntimeException("$file defines '$key' $occurrences times, expected exactly 1");
    }
    if (preg_match($pattern, $contents, $matches) !== 1) {
        throw new RuntimeException("$file: could not read '$key'");
    }

    return trim($matches[2], "'\"");
}

function writeConfigScalar(string $key, string $value): void
{
    $file = configFile();
    $contents = readOrThrow($file);
    $replacements = 0;

    $rewritten = preg_replace(
        configLinePattern($key),
        '${1}' . $value,
        $contents,
        1,
        $replacements,
    );

    if ($rewritten === null || $replacements !== 1) {
        throw new RuntimeException("$file: rewrote '$key' $replacements times, expected exactly 1");
    }
    if (@file_put_contents($file, $rewritten) === false) {
        throw new RuntimeException("cannot write $file");
    }
}

function authRealm(): string
{
    $realm = readConfigScalar('auth_realm');
    if ($realm === '') {
        throw new RuntimeException('system.auth_realm is empty in ' . configFile());
    }

    return $realm;
}

function openDatabase(): PDO
{
    $file = databaseFile();
    if (!is_readable($file)) {
        throw new RuntimeException("$file is not readable");
    }

    return new PDO('sqlite:' . $file, null, null, [
        PDO::ATTR_ERRMODE => PDO::ERRMODE_EXCEPTION,
    ]);
}

function columnText(mixed $value): string
{
    if ($value === false) {
        return 'no such row';
    }
    if (is_scalar($value)) {
        return (string) $value;
    }

    return get_debug_type($value);
}

/**
 * HTTP request against the container's listener
 */
function loopbackStatus(string $method, string $path, ?string $credentials = null): string
{
    $headers = "Depth: 0\r\n";
    if ($credentials !== null) {
        $headers .= 'Authorization: Basic ' . base64_encode($credentials) . "\r\n";
    }

    $context = stream_context_create(['http' => [
        'method' => $method,
        'header' => $headers,
        'ignore_errors' => true,
        'timeout' => 5,
    ]]);

    $stream = @fopen(LOOPBACK_ORIGIN . $path, 'r', false, $context);
    if ($stream === false) {
        return 'no response';
    }

    // http wrapper parks the response's header lines here.
    $metadata = stream_get_meta_data($stream);
    fclose($stream);

    $headerLines = $metadata['wrapper_data'] ?? [];
    if (!is_array($headerLines)) {
        return 'no headers';
    }

    foreach ($headerLines as $line) {
        if (!is_string($line)) {
            continue;
        }
        if (preg_match('#^HTTP/\S+\s+(\d{3})#', $line, $matches) === 1) {
            return $matches[1];
        }
    }

    return 'no status line';
}

// --- subcommands ------------------------------------------------------------

function assertPid1(): void
{
    Assertions::equals('PID 1 comm', 'frankenphp', trim(readOrThrow('/proc/1/comm')));
}

/**
 * Extract capability mask from /proc/self/status as a value.
 */
function capabilityMask(string $status, string $field): string
{
    $pattern = '/^' . preg_quote($field, '/') . ':[ \t]*([0-9a-fA-F]+)[ \t]*$/m';

    if (preg_match($pattern, $status, $matches) !== 1) {
        throw new RuntimeException("/proc/self/status has no well-formed $field line");
    }

    return $matches[1];
}

function assertCaps(): void
{
    $status = readOrThrow('/proc/self/status');

    foreach (['CapEff', 'CapPrm'] as $field) {
        $mask = capabilityMask($status, $field);
        Assertions::record(
            hexdec($mask) === 0,
            "$field, every capability bit clear",
            NO_CAPABILITIES,
            $mask,
        );
    }
}

function assertNoShell(): void
{
    foreach (FORBIDDEN_SHELLS as $path) {
        clearstatcache(true, $path);
        $present = file_exists($path) || is_link($path);

        Assertions::record(
            !$present,
            "$path is absent from the image",
            'absent',
            $present ? 'present' : 'absent',
        );
    }
}

/**
 * Measures from inside the container.
 */
function probeEgress(): void
{
    $errno = 0;
    $errstr = '';
    $socket = @fsockopen(
        EGRESS_PROBE_HOST,
        EGRESS_PROBE_PORT,
        $errno,
        $errstr,
        EGRESS_PROBE_TIMEOUT,
    );

    $connected = $socket !== false;
    if ($socket !== false) {
        fclose($socket);
    }

    Assertions::record(
        !$connected,
        'outbound TCP to ' . EGRESS_PROBE_HOST . ':' . EGRESS_PROBE_PORT . ' is refused',
        'no connection',
        $connected ? 'CONNECTED' : sprintf('no connection (errno %d: %s)', $errno, $errstr),
    );
}

function probeLoopback(string $username, string $password): void
{
    Assertions::equals(
        'unauthenticated GET /dav.php from inside the container',
        '401',
        loopbackStatus('GET', '/dav.php'),
    );

    Assertions::equals(
        "authenticated PROPFIND /dav.php/principals/$username/ from inside the container",
        '207',
        loopbackStatus('PROPFIND', "/dav.php/principals/$username/", "$username:$password"),
    );
}

/**
 * Any HTTP status counts as serving here
 */
function waitServing(string $seconds): void
{
    if (preg_match('/^[1-9][0-9]{0,3}$/', $seconds) !== 1) {
        throw new InvalidArgumentException("timeout must be a positive integer, got '$seconds'");
    }

    $deadline = time() + (int) $seconds;
    $status = 'no response';

    while (true) {
        $status = loopbackStatus('GET', '/dav.php');
        if (preg_match('/^[0-9]{3}$/', $status) === 1 || time() >= $deadline) {
            break;
        }
        sleep(1);
    }

    Assertions::record(
        preg_match('/^[0-9]{3}$/', $status) === 1,
        'server answers on ' . LOOPBACK_ORIGIN . "/dav.php within {$seconds}s",
        'an HTTP status',
        $status,
    );
}

/**
 * DAV users authenticate on md5("username:realm:password") stored in
 * users.digesta1 (Core/Frameworks/Baikal/Core/PDOBasicAuth.php:75). The admin
 * account uses sha256("admin:realm:password") in baikal.yaml 
 */
function seedUser(string $username, string $password): void
{
    $realm = authRealm();
    $digest = md5("$username:$realm:$password");
    $principal = "principals/$username";
    $database = openDatabase();

    $insertUser = $database->prepare(
        'INSERT INTO ' . DIGEST_TABLE . ' (username, ' . DIGEST_COLUMN . ') VALUES (?, ?)',
    );
    $insertUser->execute([$username, $digest]);

    // email is nullable and unused by the DAV auth path
    $insertPrincipal = $database->prepare(
        'INSERT INTO principals (uri, email, displayname) VALUES (?, ?, ?)',
    );
    $insertPrincipal->execute([$principal, null, ucfirst($username)]);

    $storedDigest = $database->prepare(
        'SELECT ' . DIGEST_COLUMN . ' FROM ' . DIGEST_TABLE . ' WHERE username = ?',
    );
    $storedDigest->execute([$username]);

    Assertions::equals(
        DIGEST_TABLE . '.' . DIGEST_COLUMN . " for $username is md5(user:$realm:password)",
        $digest,
        columnText($storedDigest->fetchColumn()),
    );

    $storedPrincipal = $database->prepare('SELECT uri FROM principals WHERE uri = ?');
    $storedPrincipal->execute([$principal]);

    Assertions::equals(
        "principals row for $username",
        $principal,
        columnText($storedPrincipal->fetchColumn()),
    );
}

/**
 * Simulate version drift
 */
function setVersion(string $version): void
{
    if (preg_match('/^[0-9]+\.[0-9]+\.[0-9]+$/', $version) !== 1) {
        throw new InvalidArgumentException("version must be x.y.z, got '$version'");
    }

    writeConfigScalar('configured_version', $version);

    Assertions::equals(
        'system.configured_version in ' . configFile(),
        $version,
        readConfigScalar('configured_version'),
    );
}

/**
 * Take the database away 
 */
function removeDatabase(): void
{
    $file = databaseFile();

    if (!file_exists($file)) {
        throw new RuntimeException("$file does not exist, so there is nothing to remove");
    }
    if (!@unlink($file)) {
        throw new RuntimeException("cannot unlink $file");
    }

    clearstatcache(true, $file);

    Assertions::record(
        !file_exists($file),
        "$file removed",
        'absent',
        file_exists($file) ? 'present' : 'absent',
    );
}

// --- dispatch ---------------------------------------------------------------

/**
 * @return array<string, array{arguments: list<string>, handler: Closure}>
 */
function commands(): array
{
    return [
        'assert-pid1' => ['arguments' => [], 'handler' => assertPid1(...)],
        'assert-caps' => ['arguments' => [], 'handler' => assertCaps(...)],
        'assert-no-shell' => ['arguments' => [], 'handler' => assertNoShell(...)],
        'probe-egress' => ['arguments' => [], 'handler' => probeEgress(...)],
        'probe-loopback' => ['arguments' => ['username', 'password'], 'handler' => probeLoopback(...)],
        'wait-serving' => ['arguments' => ['seconds'], 'handler' => waitServing(...)],
        'seed-user' => ['arguments' => ['username', 'password'], 'handler' => seedUser(...)],
        'set-version' => ['arguments' => ['version'], 'handler' => setVersion(...)],
        'remove-db' => ['arguments' => [], 'handler' => removeDatabase(...)],
    ];
}

/**
 * @param array<string, array{arguments: list<string>, handler: Closure}> $commands
 */
function usage(array $commands): string
{
    $lines = ['usage: php-cli in-container.php <subcommand> [arguments]', '', 'subcommands:'];

    foreach ($commands as $name => $command) {
        $placeholders = array_map(
            static fn (string $argument): string => '<' . $argument . '>',
            $command['arguments'],
        );
        $lines[] = '  ' . rtrim($name . ' ' . implode(' ', $placeholders));
    }

    return implode("\n", $lines) . "\n";
}

/**
 * @param list<string> $arguments
 */
function main(array $arguments): int
{
    $commands = commands();
    $name = $arguments[0] ?? '';

    if (!isset($commands[$name])) {
        fwrite(STDERR, $name === '' ? "no subcommand given\n" : "unknown subcommand '$name'\n");
        fwrite(STDERR, usage($commands));

        return 2;
    }

    $command = $commands[$name];
    $operands = array_slice($arguments, 1);
    $expected = count($command['arguments']);

    if (count($operands) !== $expected) {
        fwrite(STDERR, sprintf(
            "%s takes %d argument(s) (%s), got %d\n",
            $name,
            $expected,
            $expected === 0 ? 'none' : implode(', ', $command['arguments']),
            count($operands),
        ));

        return 2;
    }

    try {
        ($command['handler'])(...$operands);
    } catch (Throwable $problem) {
        Assertions::record(
            false,
            "$name completed",
            'no exception',
            $problem::class . ': ' . $problem->getMessage(),
        );
    }

    return Assertions::failures() === 0 ? 0 : 1;
}

/**
 * $argv exists only when register_argc_argv is on. 
 *
 * @return list<string>
 */
function commandLine(): array
{
    $raw = $_SERVER['argv'] ?? null;
    if (!is_array($raw)) {
        return [];
    }

    $arguments = [];
    foreach ($raw as $value) {
        if (is_string($value)) {
            $arguments[] = $value;
        }
    }

    // Drop the script name. Everything after it is the subcommand and
    // operands.
    return array_slice($arguments, 1);
}

exit(main(commandLine()));
