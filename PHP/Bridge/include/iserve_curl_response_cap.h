// Declares the response-size-cap threshold check curl_setopt_ssrf_guard.py's
// patch wires in as CURLOPT_XFERINFOFUNCTION on every curl handle
// (docs/adr/0010-php-outbound-networking.md).
//
// The decision logic lives here, as a plain function taking a byte count --
// not curl_off_t, so this header and iserve_curl_response_cap.c have no
// dependency on curl.h at all -- rather than inline inside the injected
// xferinfo callback itself, so it can be unit tested directly
// (Tests/iserve_curl_response_cap_test.c) with synthetic values and no real
// network transfer, matching how iserve_outbound_policy.c/iserve_outbound_toggle.c
// are already tested as pure, deterministic unit tests with no external
// dependency. A real curl_exec() integration test still exists
// (php-outbound-networking.yml's php-curl-native-smoke-test job) to prove
// this is actually wired up and aborts a real in-progress transfer, but the
// threshold decision itself does not need a live network connection to
// verify.
#ifndef ISERVE_CURL_RESPONSE_CAP_H
#define ISERVE_CURL_RESPONSE_CAP_H

#define ISERVE_CURL_MAX_RESPONSE_BYTES (50 * 1024 * 1024)

// Returns non-zero once `bytes_received_so_far` exceeds the cap -- the
// exact question the injected xferinfo callback asks on every progress
// tick to decide whether to abort the transfer (returning 1 from an
// xferinfo callback tells curl to abort with CURLE_ABORTED_BY_CALLBACK).
int iserve_curl_response_cap_exceeded(long long bytes_received_so_far);

#endif // ISERVE_CURL_RESPONSE_CAP_H
