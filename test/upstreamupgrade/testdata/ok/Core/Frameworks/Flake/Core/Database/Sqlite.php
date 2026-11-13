<?php

// SPDX-License-Identifier: BSD-2-Clause
// SPDX-FileCopyrightText: 2026 Aryan Ameri <github@aryan.ameri.coffee>

// A stand-in for Flake's Sqlite.php in Baikal, written for
// test/upstreamupgrade: the line test/upstream-upgrade-api.sh looks for,
// laid out as upstream's own file lays it out, and nothing else of it.

namespace Flake\Core\Database;

class Sqlite {
    function __construct($sDbPath) {
    }
}
