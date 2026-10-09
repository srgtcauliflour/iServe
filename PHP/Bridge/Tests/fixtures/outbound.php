<?php
// Fixture for PHP/Bridge/Tests/iserve_bridge_smoke_test.c's request I --
// proves docs/adr/0010-php-outbound-networking.md's outbound-networking
// toggle end to end, through the REAL bridge (iserve_php_bridge_startup()
// -> iserve_outbound_networking_set_enabled() -> iserve_curl_open_socket(),
// injected directly into php-src's own ext/curl/interface.c), not just
// the standalone C unit tests iserve_outbound_toggle_test.c already
// covers. That smoke test's own iserve_php_bridge_startup() call passes
// outbound_networking_enabled=0 (the off-by-default state, see main()) --
// so every outbound connection attempt below must be refused, even to a
// real, non-denylisted public address.

// A real, known-reachable public HTTPS endpoint (the same host
// php-curl-native-smoke-test's own embed-SAPI test already uses
// successfully on this exact CI runner type) -- picked specifically so a
// failure here can only mean the toggle actually blocked it, not "nothing
// was reachable to begin with".
$ch = curl_init('https://pypi.org/');
curl_setopt($ch, CURLOPT_RETURNTRANSFER, true);
curl_setopt($ch, CURLOPT_TIMEOUT, 5);
$body = curl_exec($ch);
$errno = curl_errno($ch);
curl_close($ch);
// CURLE_COULDNT_CONNECT (7) is the ordinary failure code curl reports for
// connect() returning ECONNREFUSED -- the exact, deliberately generic
// signature ADR-0010's "remote error behavior" rule promises a script
// will see, indistinguishable from an address the denylist itself blocks.
echo "outbound_blocked_by_default=" . (($body === false) && $errno === 7 ? 'yes' : 'no') . "\n";

// CURLOPT_RESOLVE/CURLOPT_CONNECT_TO/CURLOPT_DNS_SERVERS/CURLOPT_INTERFACE
// must still be silently accepted (curl_setopt() returns true) even
// though they're functionally inert -- a script can't use curl_setopt()'s
// own return value to detect this policy exists.
$ch2 = curl_init();
$resolve_ok = curl_setopt($ch2, CURLOPT_RESOLVE, ['example.com:443:1.2.3.4']);
$connect_to_ok = curl_setopt($ch2, CURLOPT_CONNECT_TO, ['example.com:443:1.2.3.4:443']);
$dns_servers_ok = curl_setopt($ch2, CURLOPT_DNS_SERVERS, '8.8.8.8');
$interface_ok = curl_setopt($ch2, CURLOPT_INTERFACE, 'en0');
curl_close($ch2);
echo "ssrf_bypass_options_silently_accepted=" . ($resolve_ok && $connect_to_ok && $dns_servers_ok && $interface_ok ? 'yes' : 'no') . "\n";

// The 11 curl_multi_* functions (ADR-0010's resource-bounds/Concurrency
// section) -- checked here too (fixtures/security.php's own general
// disable_functions list covers the shell/process ones; this is the
// fixture specifically about outbound networking's own resource bounds).
foreach ([
    'curl_multi_init', 'curl_multi_add_handle', 'curl_multi_remove_handle',
    'curl_multi_select', 'curl_multi_exec', 'curl_multi_getcontent',
    'curl_multi_info_read', 'curl_multi_close', 'curl_multi_errno',
    'curl_multi_strerror', 'curl_multi_setopt',
] as $name) {
    echo "disabled_$name=" . (function_exists($name) ? 'available' : 'disabled') . "\n";
}
