<?php
// Fixture for PHP/Bridge/Tests/iserve_bridge_smoke_test.c — proves the
// pdo_sqlite/sqlite3 extensions ADR-0009's allowlist compiles in actually
// work under the embed SAPI: create a database file within open_basedir,
// write to it, and read it back, through both extensions the allowlist
// names. This is v0.4's own exit gate ("self-contained PHP+SQLite
// applications execute reliably"), not yet exercised anywhere else.
// open_basedir enforcement itself is already proven by smoke.php's own
// file_get_contents check; this fixture only proves SQLite/PDO work at
// all. Not app code; never shipped, only ever run by that smoke test.
// The database file is deleted first so repeated runs are idempotent,
// and again at the end so this fixture directory never accumulates one.
$dbPath = __DIR__ . '/smoke.sqlite';
@unlink($dbPath);

$db = new SQLite3($dbPath);
$db->exec('CREATE TABLE greetings (id INTEGER PRIMARY KEY, message TEXT)');
$db->exec("INSERT INTO greetings (message) VALUES ('hello from sqlite3')");
$row = $db->query('SELECT message FROM greetings WHERE id = 1')->fetchArray(SQLITE3_ASSOC);
echo "sqlite3_roundtrip=" . ($row['message'] ?? 'MISSING') . "\n";
$db->close();

$pdo = new PDO('sqlite:' . $dbPath);
$pdo->exec("INSERT INTO greetings (message) VALUES ('hello from pdo_sqlite')");
$pdoRow = $pdo->query('SELECT message FROM greetings WHERE id = 2')->fetch(PDO::FETCH_ASSOC);
echo "pdo_sqlite_roundtrip=" . ($pdoRow['message'] ?? 'MISSING') . "\n";
$pdo = null;

@unlink($dbPath);
