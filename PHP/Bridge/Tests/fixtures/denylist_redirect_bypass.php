<?php
// Fixture for iserve_bridge_outbound_denylist_test.c's request D -- proves
// the redirect-based SSRF bypass docs/adr/0010-php-outbound-networking.md
// names explicitly ("a remote server redirecting a script's own request to
// an internal address is caught the same way a directly-requested internal
// address is") is actually closed, not just asserted in the ADR's prose.
//
// httpbin.org/redirect-to is a real, independently-operated public test
// service (not infrastructure this project controls) that does exactly
// one thing: answers with an HTTP redirect to whatever URL the caller
// asks for. That's the only way to construct this scenario at all inside
// a CI sandbox: this project has no public server of its own a "redirect
// to an internal address" response could come from, and every address
// this sandbox could stand its own test server on (loopback, a CI
// runner's own private LAN address) is itself inside the denylist -- the
// very thing being tested -- so it can't play the role of the legitimate
// first hop a real attacker's server would be.
//
// The redirect target's port comes from $_GET['port'] -- same real,
// demonstrably-listening server denylist_loopback.php's own fixture uses
// and documents (reused here via the C driver), so a failure here can
// only mean the redirect's own second connect() was refused, not that
// nothing was listening on an arbitrarily chosen port.
$port = (int) ($_GET['port'] ?? 0);
$ch = curl_init('https://httpbin.org/redirect-to?url=' . urlencode("http://127.0.0.1:{$port}/") . '&status_code=302');
curl_setopt($ch, CURLOPT_RETURNTRANSFER, true);
curl_setopt($ch, CURLOPT_FOLLOWLOCATION, true);
curl_setopt($ch, CURLOPT_TIMEOUT, 15);
$body = curl_exec($ch);
$errno = curl_errno($ch);
$redirect_count = curl_getinfo($ch, CURLINFO_REDIRECT_COUNT);
curl_close($ch);
// redirect_count >= 1 confirms the first hop (the real, legitimate
// httpbin.org request) actually succeeded and a redirect was genuinely
// followed -- so a failure below can only mean the SECOND connect(), to
// the redirect's own internal target, was what got blocked, not that
// httpbin.org itself was unreachable for an unrelated reason.
echo "redirect_followed=" . ($redirect_count >= 1 ? 'yes' : 'no') . "\n";
echo "redirect_to_denylisted_address_blocked=" . (($body === false) && $errno === 7 ? 'yes' : 'no') . "\n";
