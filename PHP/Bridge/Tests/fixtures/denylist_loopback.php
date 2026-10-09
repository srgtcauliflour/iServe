<?php
// Fixture for iserve_bridge_outbound_denylist_test.c's request A -- with
// outbound networking ON (unlike iserve_bridge_smoke_test.c's own
// requests, this test binary's own iserve_php_bridge_startup() call
// passes outbound_networking_enabled=1, see main()), a literal denylisted
// loopback address must still be refused by iserve_outbound_policy.c's
// own classification, independent of the toggle.
//
// The port comes from $_GET['port'] -- the C driver starts a REAL
// listening socket on 127.0.0.1 at that port before this request, and
// confirms it's actually accepting connections, before running this
// fixture. A bare "connect to an arbitrary port" can't tell "our own
// denylist refused this" apart from "nothing was listening there anyway"
// -- both look identical from curl's side (CURLE_COULDNT_CONNECT either
// way) -- so proving the target is demonstrably live first is the only
// way this test means anything (same discipline
// iserve_outbound_interpose_test.c's own raw-socket test already uses).
$port = (int) ($_GET['port'] ?? 0);
$ch = curl_init("http://127.0.0.1:{$port}/");
curl_setopt($ch, CURLOPT_RETURNTRANSFER, true);
curl_setopt($ch, CURLOPT_TIMEOUT, 5);
$body = curl_exec($ch);
$errno = curl_errno($ch);
curl_close($ch);
// CURLE_COULDNT_CONNECT == 7 -- the interposed connect()'s ECONNREFUSED.
echo "loopback_blocked=" . (($body === false) && $errno === 7 ? 'yes' : 'no') . "\n";
