<?php
// Fixture for PHP/Bridge/Tests/iserve_bridge_smoke_test.c — exercises the
// request/response mapping the bridge's request struct is supposed to
// provide, plus the ADR-0009 restrictions the bridge is supposed to
// enforce. Not app code; never shipped, only ever run by that smoke test.
header('X-iServe-Test: 1');
http_response_code(201);

echo "method=" . ($_SERVER['REQUEST_METHOD'] ?? '') . "\n";
echo "query=" . ($_GET['q'] ?? '') . "\n";
echo "post=" . ($_POST['p'] ?? '') . "\n";
echo "cookie=" . ($_COOKIE['c'] ?? '') . "\n";
echo "disable_functions_exec=" . (function_exists('exec') ? 'available' : 'disabled') . "\n";
echo "ini_set_blocked=" . (function_exists('ini_set') ? 'available' : 'disabled') . "\n";

// ../outside/secret.txt must be a TRUE sibling of this fixtures/ directory
// (PHP/Bridge/Tests/outside/secret.txt), never a subdirectory of it — it
// was once placed at fixtures/outside/secret.txt by mistake, which made
// this check vacuously pass regardless of whether open_basedir actually
// enforced anything: __DIR__/../outside/secret.txt then resolved to a
// path that simply didn't exist (a sibling of fixtures/, one level too
// high), so file_get_contents() failed with ENOENT before open_basedir
// was ever consulted, not because of it. Moved the real file so this
// traversal attempt actually reaches an existing file outside
// open_basedir and is genuinely blocked.
$outside = @file_get_contents(__DIR__ . '/../outside/secret.txt');
echo "open_basedir_enforced=" . ($outside === false ? 'yes' : 'no') . "\n";
