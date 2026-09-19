<?php
// Fixture for PHP/Bridge/Tests/iserve_bridge_smoke_test.c — proves a PHP
// runtime warning (display_errors=0, so it never reaches the HTTP response)
// is still captured into iserve_php_result_t.diagnostic_log, the
// ROADMAP "PHP diagnostics console" deliverable's data source. Not app
// code; never shipped, only ever run by that smoke test.
echo "before\n";
trigger_error("iserve diagnostic marker", E_USER_WARNING);
echo "after\n";
