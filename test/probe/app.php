<?php

// SPDX-License-Identifier: BSD-2-Clause
// SPDX-FileCopyrightText: 2026 Aryan Ameri <github@aryan.ameri.coffee>

declare(strict_types=1);

/*
 * Baikal's own subcommands for divbast's in-container probe. The harness
 * installs this beside its core.php, which requires it and adds what it
 * returns to its own subcommands:
 *
 *     frankenphp php-cli core.php <subcommand> [arguments]
 *
 * Each asserts what it did, or what it found, in core.php's records,
 * under the record names the earlier bash suite (in git history) gave
 * them, where it had the check. core.php hands every app subcommand
 * whatever operands it was given, so each checks its own count, and one
 * given the wrong number throws, which core.php records as a failure.
 * Each may use what core.php defines: its Assertions and readOrThrow().
 *
 * The upgrade tests run seed-user and seed-share inside the images
 * published before this suite existed, so this file, and core.php, must
 * load in their PHP too.
 */

final class BaikalProbe
{
    private const string DIGEST_TABLE = 'users';
    private const string DIGEST_COLUMN = 'digesta1';
    private const string NOT_A_DATABASE = "this is not a SQLite database\n";
    private const string DISTRIB_FILE = '/var/www/baikal/Core/Distrib.php';
    private const string SCHEMA_FILE = '/var/www/baikal/Core/Resources/Db/SQLite/db.sql';
    private const string SHARED_CALENDAR = 'test';
    private const string SHARE_URI = 'shared-by-acceptance';
    /**
     * seed-share's shapes: each one's access and share_invitestatus. 3 and
     * 2 are sabre/dav's ACCESS_READWRITE and INVITE_ACCEPTED.
     *
     * @var array<string, array{?int, ?int}>
     */
    private const array SHARE_SHAPES = ['null' => [null, null], 'accepted' => [3, 2]];

    /**
     * Inserts a DAV user and its principal, the rows Baikal's admin UI
     * would write, and reads both back. DAV users authenticate on
     * md5("username:realm:password") in users.digesta1
     * (Core/Frameworks/Baikal/Core/PDOBasicAuth.php); the admin account
     * uses sha256("admin:realm:password") in baikal.yaml instead.
     *
     * @param list<string> $operands
     */
    public static function seedUser(array $operands): void
    {
        [$username, $password] = self::operands('seed-user', $operands, 'username', 'password');
        $realm = self::authRealm();
        $digest = md5("$username:$realm:$password");
        $principal = "principals/$username";
        $database = self::openDatabase();

        $insertUser = $database->prepare(
            'INSERT INTO ' . self::DIGEST_TABLE . ' (username, ' . self::DIGEST_COLUMN . ') VALUES (?, ?)',
        );
        $insertUser->execute([$username, $digest]);

        // email is nullable and unused by the DAV auth path
        $insertPrincipal = $database->prepare(
            'INSERT INTO principals (uri, email, displayname) VALUES (?, ?, ?)',
        );
        $insertPrincipal->execute([$principal, null, ucfirst($username)]);

        $storedDigest = $database->prepare(
            'SELECT ' . self::DIGEST_COLUMN . ' FROM ' . self::DIGEST_TABLE . ' WHERE username = ?',
        );
        $storedDigest->execute([$username]);

        Assertions::equals(
            self::DIGEST_TABLE . '.' . self::DIGEST_COLUMN . " for $username is md5(user:$realm:password)",
            $digest,
            self::columnText($storedDigest->fetchColumn()),
        );

        $storedPrincipal = $database->prepare('SELECT uri FROM principals WHERE uri = ?');
        $storedPrincipal->execute([$principal]);

        Assertions::equals(
            "principals row for $username",
            $principal,
            self::columnText($storedPrincipal->fetchColumn()),
        );
    }

    /**
     * Writes system.configured_version, as a /data an older image left
     * behind would hold it, and reads it back: the drift the bootstrap must
     * upgrade from, never serve.
     *
     * @param list<string> $operands
     */
    public static function setVersion(array $operands): void
    {
        [$version] = self::operands('set-version', $operands, 'version');
        if (preg_match('/^[0-9]+\.[0-9]+\.[0-9]+$/', $version) !== 1) {
            throw new InvalidArgumentException("version must be x.y.z, got '$version'");
        }

        self::writeConfigScalar('configured_version', $version);

        Assertions::equals(
            'system.configured_version in ' . self::configFile(),
            $version,
            self::readConfigScalar('configured_version'),
        );
    }

    /**
     * Leaves the database where it is, and makes it stop being a database.
     * This is the one fault only /healthz can see: the file is present and
     * writable, so sabre still answers 401 to a request with no credentials
     * without ever reaching the backend.
     *
     * @param list<string> $operands
     */
    public static function damageDb(array $operands): void
    {
        self::operands('damage-db', $operands);
        $file = self::databaseFile();

        if (!file_exists($file)) {
            throw new RuntimeException("$file does not exist, so there is nothing to damage");
        }
        if (@file_put_contents($file, self::NOT_A_DATABASE) === false) {
            throw new RuntimeException("cannot overwrite $file");
        }

        clearstatcache(true, $file);

        $damaged = @file_get_contents($file) === self::NOT_A_DATABASE;
        $writable = is_writable($file);

        Assertions::record(
            $damaged && $writable,
            "$file holds bytes that are not a SQLite database, and is still writable",
            'damaged and writable',
            ($damaged ? 'damaged' : 'unchanged') . ($writable ? ' and writable' : ' and not writable'),
        );
    }

    /**
     * Takes the database away, leaving the config: the half-restored /data
     * the bootstrap must refuse to start on.
     *
     * @param list<string> $operands
     */
    public static function removeDb(array $operands): void
    {
        self::operands('remove-db', $operands);
        $file = self::databaseFile();

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

    /**
     * Shares the owner's calendar with the sharee, in one of two shapes.
     * null leaves access and share_invitestatus NULL, as schemas before
     * Baikal 0.13.0 allowed: 0.13.0's migration rebuilds calendarinstances
     * and fills both in, so this row is old data that an upgrade has to
     * carry across. 0.13.0's schema refuses it. accepted is a share as
     * sabre/dav records one its sharee accepted, read-write, which every
     * schema takes.
     *
     * @param list<string> $operands
     */
    public static function seedShare(array $operands): void
    {
        [$owner, $sharee, $shape] = self::operands('seed-share', $operands, 'owner', 'sharee', 'shape');
        if (!array_key_exists($shape, self::SHARE_SHAPES)) {
            throw new InvalidArgumentException(
                'shape must be one of ' . implode(', ', array_keys(self::SHARE_SHAPES)) . ", got '$shape'",
            );
        }
        [$access, $inviteStatus] = self::SHARE_SHAPES[$shape];
        $database = self::openDatabase();

        $calendar = $database->prepare(
            'SELECT calendarid FROM calendarinstances WHERE principaluri = ? AND uri = ?',
        );
        $calendar->execute(["principals/$owner", self::SHARED_CALENDAR]);
        $calendarId = $calendar->fetchColumn();
        if (!is_int($calendarId) && !is_string($calendarId)) {
            throw new RuntimeException("principals/$owner has no calendar '" . self::SHARED_CALENDAR . "' to share");
        }

        $insert = $database->prepare(
            'INSERT INTO calendarinstances '
            . '(calendarid, principaluri, access, displayname, uri, share_href, share_invitestatus) '
            . 'VALUES (?, ?, ?, ?, ?, ?, ?)',
        );
        $insert->execute([
            $calendarId,
            "principals/$sharee",
            $access,
            'Shared by ' . ucfirst($owner),
            self::SHARE_URI,
            "principals/$sharee",
            $inviteStatus,
        ]);

        Assertions::equals("$owner's calendar is shared with $sharee", '1', self::shareCount($database, $owner, $sharee));
    }

    /**
     * @param list<string> $operands
     */
    public static function assertShare(array $operands): void
    {
        [$owner, $sharee] = self::operands('assert-share', $operands, 'owner', 'sharee');

        Assertions::equals(
            "$owner's share with $sharee survived the upgrade",
            '1',
            self::shareCount(self::openDatabase(), $owner, $sharee),
        );
    }

    /**
     * @param list<string> $operands
     */
    public static function assertCurrentVersion(array $operands): void
    {
        self::operands('assert-current-version', $operands);
        if (!is_file(self::DISTRIB_FILE)) {
            throw new RuntimeException(self::DISTRIB_FILE . ' is missing, so there is no version to compare with');
        }
        require_once self::DISTRIB_FILE;   // defines BAIKAL_VERSION

        Assertions::equals(
            'system.configured_version in ' . self::configFile() . " is this image's Baikal",
            BAIKAL_VERSION,
            self::readConfigScalar('configured_version'),
        );
    }

    /**
     * Compares every table of the live database with a fresh install's,
     * built in memory from the schema this image ships. An upgrade is only
     * finished when the upgraded database is indistinguishable from a new
     * one: the same columns in the same order with the same types, NOT
     * NULLs, defaults and primary keys, and the same sets of indexed
     * columns. Index names are left out, because SQLite's names for UNIQUE
     * constraints follow a table through a rename.
     *
     * @param list<string> $operands
     */
    public static function assertSchema(array $operands): void
    {
        self::operands('assert-schema', $operands);
        $fresh = new PDO('sqlite::memory:', null, null, [
            PDO::ATTR_ERRMODE => PDO::ERRMODE_EXCEPTION,
        ]);
        $fresh->exec(readOrThrow(self::SCHEMA_FILE));

        $expected = self::schemaOf($fresh);
        $found = self::schemaOf(self::openDatabase());

        Assertions::equals(
            'tables in ' . self::databaseFile() . ' are a fresh install\'s',
            implode(' ', array_keys($expected)),
            implode(' ', array_keys($found)),
        );

        foreach ($expected as $table => $shape) {
            Assertions::equals("table $table has a fresh install's shape", $shape, $found[$table] ?? 'absent');
        }
    }

    /**
     * Asserts PHP here opens no URL stream: allow_url_fopen is off, so
     * fopen() and file_get_contents() refuse an http:// or ftp:// URL.
     * php-cli reads the same /etc/frankenphp/php.d as the server, so the
     * setting found here is the one the server runs with.
     *
     * @param list<string> $operands
     */
    public static function assertIni(array $operands): void
    {
        self::operands('assert-ini', $operands);

        Assertions::equals('allow_url_fopen is off', 'off', self::onOff('allow_url_fopen'));
    }

    /**
     * The operands a subcommand was given, when they are exactly as many
     * as the arguments it names; anything else throws.
     *
     * @param list<string> $operands
     * @return list<string>
     */
    private static function operands(string $subcommand, array $operands, string ...$names): array
    {
        if (count($operands) !== count($names)) {
            throw new InvalidArgumentException(sprintf(
                '%s takes %s, got %d',
                $subcommand,
                $names === [] ? 'no arguments' : implode(' ', array_map(static fn (string $name): string => "<$name>", $names)),
                count($operands),
            ));
        }

        return $operands;
    }

    /**
     * A boolean ini directive as on or off, as PHP itself reads one: On,
     * Yes, True and any non-zero number are on.
     */
    private static function onOff(string $directive): string
    {
        $value = ini_get($directive);
        if ($value === false) {
            throw new RuntimeException("PHP has no $directive setting");
        }
        $value = strtolower(trim($value));

        $on = in_array($value, ['on', 'yes', 'true'], true) || (int) $value !== 0;

        return $on ? 'on' : 'off';
    }

    /**
     * The image sets BAIKAL_PATH_CONFIG and BAIKAL_PATH_SPECIFIC, and the
     * framework concatenates them directly with a file name.
     */
    private static function pathFromEnvironment(string $name, string $fallback): string
    {
        $value = getenv($name);
        if ($value === false || $value === '') {
            $value = $fallback;
        }

        return rtrim($value, '/') . '/';
    }

    private static function configFile(): string
    {
        return self::pathFromEnvironment('BAIKAL_PATH_CONFIG', '/data/config/') . 'baikal.yaml';
    }

    private static function databaseFile(): string
    {
        return self::pathFromEnvironment('BAIKAL_PATH_SPECIFIC', '/data/Specific/') . 'db/db.sqlite';
    }

    /**
     * Matches one `key: value` line of baikal.yaml.
     */
    private static function configLinePattern(string $key): string
    {
        return '/^([ \t]*' . preg_quote($key, '/') . ':[ \t]*)(\S[^\r\n]*?)[ \t]*$/m';
    }

    private static function readConfigScalar(string $key): string
    {
        $file = self::configFile();
        $contents = readOrThrow($file);
        $pattern = self::configLinePattern($key);

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

    private static function writeConfigScalar(string $key, string $value): void
    {
        $file = self::configFile();
        $contents = readOrThrow($file);
        $replacements = 0;

        $rewritten = preg_replace(
            self::configLinePattern($key),
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

    private static function authRealm(): string
    {
        $realm = self::readConfigScalar('auth_realm');
        if ($realm === '') {
            throw new RuntimeException('system.auth_realm is empty in ' . self::configFile());
        }

        return $realm;
    }

    private static function openDatabase(): PDO
    {
        $file = self::databaseFile();
        if (!is_readable($file)) {
            throw new RuntimeException("$file is not readable");
        }

        return new PDO('sqlite:' . $file, null, null, [
            PDO::ATTR_ERRMODE => PDO::ERRMODE_EXCEPTION,
        ]);
    }

    private static function columnText(mixed $value): string
    {
        if ($value === false) {
            return 'no such row';
        }
        if (is_scalar($value)) {
            return (string) $value;
        }

        return get_debug_type($value);
    }

    private static function shareCount(PDO $database, string $owner, string $sharee): string
    {
        $query = $database->prepare(
            'SELECT COUNT(*) FROM calendarinstances AS share '
            . 'JOIN calendarinstances AS own ON own.calendarid = share.calendarid '
            . 'WHERE own.principaluri = ? AND own.uri = ? '
            . 'AND share.principaluri = ? AND share.uri = ? AND share.share_href = ?',
        );
        $query->execute([
            "principals/$owner",
            self::SHARED_CALENDAR,
            "principals/$sharee",
            self::SHARE_URI,
            "principals/$sharee",
        ]);

        return self::columnText($query->fetchColumn());
    }

    /**
     * @return array<string, string> each table's shape on one line, by table name
     */
    private static function schemaOf(PDO $database): array
    {
        $shapes = [];
        $tables = self::rows(
            $database,
            "SELECT name FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%' ORDER BY name",
        );

        foreach ($tables as $table) {
            $name = self::columnText($table['name'] ?? null);

            $columns = [];
            foreach (self::rows($database, 'PRAGMA table_info(' . self::quoted($database, $name) . ')') as $column) {
                $columns[] = sprintf(
                    '%s %s notnull=%s default=%s pk=%s',
                    self::columnText($column['name'] ?? null),
                    self::columnText($column['type'] ?? null),
                    self::columnText($column['notnull'] ?? null),
                    ($column['dflt_value'] ?? null) === null ? 'none' : self::columnText($column['dflt_value']),
                    self::columnText($column['pk'] ?? null),
                );
            }

            $indexes = [];
            foreach (self::rows($database, 'PRAGMA index_list(' . self::quoted($database, $name) . ')') as $index) {
                $indexColumns = [];
                $indexName = self::columnText($index['name'] ?? null);
                foreach (self::rows($database, 'PRAGMA index_info(' . self::quoted($database, $indexName) . ')') as $member) {
                    $indexColumns[] = self::columnText($member['name'] ?? null);
                }
                $indexes[] = (self::columnText($index['unique'] ?? null) === '1' ? 'unique' : 'index')
                    . '(' . implode(',', $indexColumns) . ')';
            }
            sort($indexes);

            $shapes[$name] = 'columns: ' . implode(', ', $columns) . '; indexes: ' . implode(' ', $indexes);
        }

        return $shapes;
    }

    /**
     * @return list<array<string, mixed>>
     */
    private static function rows(PDO $database, string $sql): array
    {
        $statement = $database->query($sql);
        if ($statement === false) {
            throw new RuntimeException("query failed: $sql");
        }

        $rows = [];
        foreach ($statement->fetchAll(PDO::FETCH_ASSOC) as $row) {
            if (!is_array($row)) {
                continue;
            }
            $named = [];
            foreach ($row as $column => $value) {
                if (is_string($column)) {
                    $named[$column] = $value;
                }
            }
            $rows[] = $named;
        }

        return $rows;
    }

    private static function quoted(PDO $database, string $identifier): string
    {
        $quoted = $database->quote($identifier);
        if ($quoted === false) {
            throw new RuntimeException("cannot quote '$identifier'");
        }

        return $quoted;
    }
}

return [
    'seed-user' => BaikalProbe::seedUser(...),
    'set-version' => BaikalProbe::setVersion(...),
    'damage-db' => BaikalProbe::damageDb(...),
    'remove-db' => BaikalProbe::removeDb(...),
    'seed-share' => BaikalProbe::seedShare(...),
    'assert-share' => BaikalProbe::assertShare(...),
    'assert-current-version' => BaikalProbe::assertCurrentVersion(...),
    'assert-schema' => BaikalProbe::assertSchema(...),
    'assert-ini' => BaikalProbe::assertIni(...),
];
