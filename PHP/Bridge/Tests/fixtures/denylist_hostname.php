<?php
// Fixture for iserve_bridge_outbound_denylist_test.c's request B -- proves
// the denylist check applies to the RESOLVED address, not the literal
// string a script gives curl. "localhost" is universally pre-configured
// (via the system resolver / /etc/hosts) to resolve to 127.0.0.1 or ::1 --
// a real getaddrinfo() lookup through curl's own DNS resolution, not a
// literal IP a test author chose. If a hostname could reach a denylisted
// address just by never writing out its numeric form, the denylist would
// be a string filter, not the real defense docs/adr/0010 requires: "any
// check that runs before or independent of the actual TCP connection can
// be bypassed by a hostname that resolves differently between check-time
// and connect-time" -- this is the same invariant that defense depends on,
// exercised here with ordinary, real hostname resolution rather than a
// rebinding attack's two-different-answers trick (which would need a
// custom authoritative DNS server this test doesn't have).
//
// The port comes from $_GET['port'] -- same real, demonstrably-listening
// server denylist_loopback.php's own fixture uses and documents, reused
// here so "localhost" resolves to a genuinely live target too.
$port = (int) ($_GET['port'] ?? 0);
$ch = curl_init("http://localhost:{$port}/");
curl_setopt($ch, CURLOPT_RETURNTRANSFER, true);
curl_setopt($ch, CURLOPT_TIMEOUT, 5);
$body = curl_exec($ch);
$errno = curl_errno($ch);
curl_close($ch);
echo "hostname_resolving_to_loopback_blocked=" . (($body === false) && $errno === 7 ? 'yes' : 'no') . "\n";
