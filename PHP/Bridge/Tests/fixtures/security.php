<?php
// Fixture for PHP/Bridge/Tests/iserve_bridge_smoke_test.c's request G --
// the ROADMAP's "compatibility/security test suite" deliverable
// (docs/adr/0009-php-runtime-feasibility.md's own "Costs" section calls
// for this explicitly: "execute arbitrary code against a selected folder"
// deserves its own dedicated test suite, not just the request/response
// mapping checks fixtures/smoke.php already covers). Not app code; never
// shipped, only ever run by that smoke test.
//
// Every line below is a "must be exactly this" security boundary from
// ADR-0009 -- each echoed as name=value so the C test can assert on it
// independently, the same pattern every other fixture here uses.

// disable_functions: every process/shell-related function ADR-0009 names,
// checked individually (fixtures/smoke.php only ever checked exec/ini_set;
// disable_functions has no glob support, so each literal name is its own
// independent risk of a typo/omission that only checking all of them catches).
foreach (['exec', 'shell_exec', 'system', 'popen', 'proc_open', 'proc_close', 'dl', 'ini_set', 'ini_alter', 'set_time_limit'] as $name) {
    echo "disabled_$name=" . (function_exists($name) ? 'available' : 'disabled') . "\n";
}

// allow_url_fopen/allow_url_include: forced off in the bridge's own ini
// (see iserve_php_bridge.c's implementation-addendum note in the ADR).
// file_get_contents() on a URL fails immediately at stream-open time when
// allow_url_fopen=0, before any DNS/network activity -- safe to run in CI.
$urlFopen = @file_get_contents('http://iserve.invalid/should-not-be-reachable');
echo "allow_url_fopen_blocked=" . ($urlFopen === false ? 'yes' : 'no') . "\n";
// include() on a URL is gated by allow_url_fopen && allow_url_include
// together, checked the same way (before any real connection attempt);
// wrapped in a function so a would-be successful include can't redeclare
// symbols into this fixture's own top-level scope.
function iserve_attempt_url_include(): bool
{
    $result = @include 'http://iserve.invalid/should-not-be-included.php';
    // include() returns false on failure to open; on success (never
    // expected here) it's either an explicit `return` value from the
    // included file or the integer 1 -- either way, not `false`.
    return $result !== false;
}
echo "allow_url_include_blocked=" . (iserve_attempt_url_include() ? 'no' : 'yes') . "\n";

// open_basedir escape attempts via several different functions -- not just
// file_get_contents() (already covered by smoke.php's own check), since
// each of these has its own code path into the filesystem and a gap in
// any one of them would be a real, exploitable escape. ../outside/secret.txt
// is a true sibling of this fixtures/ directory (document_root), genuinely
// outside open_basedir -- see smoke.php's own doc comment for a bug that
// once made an equivalent check here vacuously pass.
$outsidePath = __DIR__ . '/../outside/secret.txt';
echo "fopen_blocked=" . (@fopen($outsidePath, 'r') === false ? 'yes' : 'no') . "\n";
echo "is_readable_blocked=" . (@is_readable($outsidePath) === false ? 'yes' : 'no') . "\n";
echo "opendir_blocked=" . (@opendir(dirname($outsidePath)) === false ? 'yes' : 'no') . "\n";
echo "scandir_blocked=" . (@scandir(dirname($outsidePath)) === false ? 'yes' : 'no') . "\n";

// FFI (arbitrary native code execution -- ADR-0009's extension allowlist
// explicitly excludes it) must simply not be compiled in at all.
echo "ffi_unavailable=" . (class_exists('FFI') ? 'available' : 'unavailable') . "\n";

// The extensions ADR-0009's allowlist DOES name must actually be present
// (pdo_sqlite/sqlite3 are already proven to work, not just compiled in,
// by fixtures/sqlite.php -- this only checks the smaller ones that don't
// warrant their own fixture).
foreach (['json_encode' => 'json', 'mb_strlen' => 'mbstring', 'hash' => 'hash', 'filter_var' => 'filter'] as $function => $label) {
    echo "extension_{$label}_available=" . (function_exists($function) ? 'yes' : 'no') . "\n";
}
