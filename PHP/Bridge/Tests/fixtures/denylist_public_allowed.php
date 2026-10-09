<?php
// Fixture for iserve_bridge_outbound_denylist_test.c's request C -- the
// positive control every other request in this file needs: with outbound
// networking ON, a real, non-denylisted public address must actually
// succeed. Without this, requests A/B/D passing could just mean the
// denylist (or the toggle) is blocking everything indiscriminately, not
// that it's correctly distinguishing denylisted destinations from
// legitimate ones.
$ch = curl_init('https://pypi.org/');
curl_setopt($ch, CURLOPT_RETURNTRANSFER, true);
curl_setopt($ch, CURLOPT_TIMEOUT, 15);
$body = curl_exec($ch);
$code = curl_getinfo($ch, CURLINFO_HTTP_CODE);
$err = curl_error($ch);
curl_close($ch);
echo "public_address_allowed=" . ($code === 200 && strlen((string)$body) > 0 && $err === '' ? 'yes' : 'no') . "\n";
