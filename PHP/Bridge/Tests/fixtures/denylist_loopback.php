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
// fixture. iserve_curl_open_socket() refuses a denylisted address before
// curl ever calls socket()/connect() on it at all, so this isn't needed
// to disambiguate "our own check refused this" from "nothing was
// listening there anyway" the way it would for a lower-level connect()
// interception -- it's kept anyway as the stronger proof: the block
// holds even though a real, ready target exists on the other end.
$port = (int) ($_GET['port'] ?? 0);
$ch = curl_init("http://127.0.0.1:{$port}/");
curl_setopt($ch, CURLOPT_RETURNTRANSFER, true);
curl_setopt($ch, CURLOPT_TIMEOUT, 5);
$body = curl_exec($ch);
$errno = curl_errno($ch);
curl_close($ch);
// CURLE_COULDNT_CONNECT == 7 -- what a CURL_SOCKET_BAD return from
// iserve_curl_open_socket() produces.
echo "loopback_blocked=" . (($body === false) && $errno === 7 ? 'yes' : 'no') . "\n";
