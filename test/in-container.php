<?php

// SPDX-License-Identifier: BSD-2-Clause
// SPDX-FileCopyrightText: 2026 Aryan Ameri <github@aryan.ameri.coffee>

declare(strict_types=1);

/*
 * Everything the acceptance suite needs to read or assert from *inside* the
 * container.
 *
 * This exists as a file rather than as `php-cli -r '<code>'` arguments because
 * that form nests PHP inside a single-quoted shell string that itself contains
 * SQL string literals and PHP string literals, and bash checks none of it: a
 * mis-escaped quote yields an empty string rather than an error, and the suite
 * happily asserts against the empty string. Two real defects of exactly that
 * shape were found in the earlier version - a capability check that compared
 * against a line still carrying its own `CapEff` label, and `shell_exec()`
 * calls in an image that deliberately has no shell. A real file gets a parser,
 * strict types, exceptions and a stack trace.
 *
 * There is no shell in this image, so nothing here may use shell_exec(),
 * exec(), system(), passthru(), proc_open() or backticks. Read /proc and the
 * filesystem directly; that is both possible and more direct.
 *
 * It also has no dependencies. symfony/yaml ships in Baikal's vendor tree and
 * would parse baikal.yaml better than the two narrow accessors below do, but
 * requiring that tree would stop this file being analysable on its own, and
 * being checkable is the whole reason it is a file.
 *
 * Output protocol: one tab-separated record per assertion,
 *
 *     ok<TAB>what<TAB>expected<TAB>found
 *     FAIL<TAB>what<TAB>expected<TAB>found
 *
 * which test/acceptance.sh turns into its own pass()/fail(), so host-side and
 * in-container assertions share one counter and one log format. Anything else
 * on stdout or stderr is passed through as a diagnostic. Exit status is 0 only
 * when every assertion in the subcommand passed; 1 when one did not; 2 when
 * the invocation itself was wrong. Silence is never success: a subcommand that
 * emits no records at all is treated by the caller as a failure.
 */

const LOOPBACK_ORIGIN = 'http://127.0.0.1:8080';

/**
 * Distroless ships no shell. These are the three an intrusion would reach for
 * first, and the three a careless base-image change would reintroduce.
 */
const FORBIDDEN_SHELLS = ['/bin/sh', '/bin/bash', '/bin/dash'];

/** A capability mask with every bit clear, as /proc renders it today. */
const NO_CAPABILITIES = '0000000000000000';

/** Public, anycast, and answers on 443 anywhere egress exists. */
const EGRESS_PROBE_HOST = '1.1.1.1';
const EGRESS_PROBE_PORT = 443;
const EGRESS_PROBE_TIMEOUT = 3;

/** Where Baikal's own credential check reads from: PDOBasicAuth.php:75. */
const DIGEST_TABLE = 'users';
const DIGEST_COLUMN = 'digesta1';

/**
 * Collects assertions and renders them in the record format above.
 *
 * Nothing here returns a bare false on failure. A subcommand that cannot even
 * reach the thing it is meant to assert on throws, and the dispatcher turns
 * that into a failed assertion naming the exception. The distinction matters:
 * "CapEff is not zero" and "there is no CapEff line to read" are different
 * defects and must not both surface as a quiet mismatch against ''.
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

    /** Tabs and newlines are the record separators, so no field may carry one. */
    private static function oneLine(string $text): string
    {
        return trim(strtr($text, ["\t" => ' ', "\n" => ' ', "\r" => ' ']));
    }
}

// --- filesystem and config helpers ------------------------------------------

/**
 * The image sets BAIKAL_PATH_CONFIG and BAIKAL_PATH_SPECIFIC, and the framework
 * concatenates them directly with a file name, so the trailing slash is load
 * bearing (Flake/Framework.php:168-182). Reading them here rather than
 * hardcoding /data keeps this file honest if the image's layout ever moves.
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
 * Matches one `key: value` line of baikal.yaml, capturing the indent and key as
 * group 1 and the value as group 2.
 *
 * baikal.yaml is written by baikal-bootstrap through symfony/yaml's dumper, so
 * it is a two-level mapping of plain scalars: no anchors, no flow collections,
 * no block scalars, no repeated keys. Both accessors below insist the key
 * occurs exactly once and fail loudly otherwise, so this narrowness is checked
 * rather than assumed - which is the part a bare preg_replace on the same file
 * was missing.
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

/**
 * auth_realm is an input to every stored password hash, so seeding a user with
 * a guessed realm produces a row that exists and never authenticates - a 401
 * that looks like a broken server rather than a broken test. Take it from the
 * config the server itself is reading.
 */
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

/**
 * PDOStatement::fetchColumn() is mixed by definition - a column value, or false
 * for no row. Take the mixed in one place, narrow it here, and let everything
 * downstream work in strings.
 */
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
 * One HTTP request against the container's own listener, reduced to its status
 * code. Deliberately no 2xx matching and no failure-on-error: every Baikal
 * failure mode - unwritable config, missing database, unwritable database
 * directory - answers 200 with an exception page, so only an exact code proves
 * anything. ignore_errors keeps the response instead of discarding a 4xx as a
 * stream error, which is the whole point when 401 is the healthy answer.
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

    // The http wrapper parks the response's header lines here. Read through the
    // stream's own metadata rather than the $http_response_header magic local,
    // which is invisible to any static analysis and to the reader.
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

/**
 * The single most load-bearing claim in the design. baikal-bootstrap does its
 * work and then pcntl_exec()s the server, which overlays the process image
 * rather than forking, so FrankenPHP inherits PID 1 and takes SIGTERM
 * directly. `inspect --format '{{.Path}}'` only ever echoes the configured
 * entrypoint back, so asking the container what its own PID 1 is called is the
 * only way to see whether the hand-off actually happened.
 */
function assertPid1(): void
{
    Assertions::equals('PID 1 comm', 'frankenphp', trim(readOrThrow('/proc/1/comm')));
}

/**
 * Extract one capability mask from /proc/self/status as a value.
 *
 * The line is `CapEff:\t0000000000000000`, and the label itself contains both
 * 'a' and 'f'. An earlier version of this check globbed the whole line for
 * [1-9a-f] and so could never pass, in either direction - which is why this
 * captures the hex word and nothing else. The width is not pinned, because the
 * comparison that follows is numeric and a wider all-zero field is still no
 * capabilities.
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

        // Compared as a number, not as text: hexdec() of an all-clear mask is
        // int(0) and of anything else is non-zero, so neither a change of field
        // width nor a formatting accident can make a real capability read as
        // none.
        Assertions::record(
            hexdec($mask) === 0,
            "$field, every capability bit clear",
            NO_CAPABILITIES,
            $mask,
        );
    }
}

/**
 * Absence, not merely non-executability: the base is distroless and that is the
 * point. is_link() is checked too, because a dangling symlink is invisible to
 * file_exists() and would still be a shell path reappearing in the image.
 */
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
 * Reading `docker network inspect --format '{{.Internal}}'` tests the engine,
 * not us. This measures the same claim from the only place it matters: inside
 * the container, where a connect that succeeds means the deployment could fail
 * open to the internet.
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
 * Wait for the listener to answer at all, for a container whose published port
 * the host cannot reach - which is every container on an --internal network.
 * Any HTTP status counts as serving here; what that status must be is a
 * separate assertion, deliberately, because "answered 500" and "never answered"
 * are different failures.
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
 * account uses sha256("admin:realm:password") in baikal.yaml instead - a
 * different scheme entirely, and conflating the two produces a user who exists
 * and can never log in.
 *
 * Written through prepared statements and read straight back. The version this
 * replaced built the INSERT by interpolating into a double-quoted PHP string
 * nested in a single-quoted shell argument, and discarded both the output and
 * the exit status, so a failed insert was indistinguishable from a successful
 * one until a PROPFIND 401'd several checks later.
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

    // email is nullable and unused by the DAV auth path; passing it explicitly
    // records that the column exists rather than leaving it to a default.
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
 * Simulate version drift. When configured_version is older than the image's
 * BAIKAL_VERSION, Baikal 302s every request - dav.php included - to
 * /admin/install/, which is a total CalDAV outage that every client reports as
 * an auth failure. The suite writes the drift here so it can prove the
 * entrypoint clears it rather than serving it.
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
 * Take the database away from beside its config. baikal-bootstrap must refuse
 * to start rather than create an empty one: auth_realm is baked into every
 * stored hash, so a fresh database beside an old config is a server that is up,
 * healthy and empty, and the next backup would write that over the last good
 * copy.
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
        // A subcommand that could not reach the thing it asserts on is a failed
        // assertion, not a crash with no record: the caller counts records, and
        // an exception that produced none would otherwise read as nothing
        // having happened at all.
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
 * $argv exists only when register_argc_argv is on. That is the CLI default, but
 * it is a php.ini setting rather than a guarantee, and $_SERVER carries the same
 * list in a form that can be narrowed instead of assumed.
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

    // Drop the script name; everything after it is the subcommand and operands.
    return array_slice($arguments, 1);
}

exit(main(commandLine()));
