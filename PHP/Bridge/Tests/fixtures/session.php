<?php
// Fixture for PHP/Bridge/Tests/iserve_bridge_smoke_test.c — proves a PHP
// session actually persists across separate iserve_php_execute() calls
// through the embed SAPI bridge (session.save_path is already configured
// in iserve_php_bridge_startup's hardcoded ini). Not app code; never
// shipped, only ever run by that smoke test.
session_start();
$_SESSION['visits'] = ($_SESSION['visits'] ?? 0) + 1;
echo "session_id=" . session_id() . "\n";
echo "visits=" . $_SESSION['visits'] . "\n";
