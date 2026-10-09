// Standalone unit test for iserve_curl_response_cap.c -- portable, no
// dependency on php-src or curl (the threshold decision takes a plain byte
// count, not curl_off_t, specifically so it can be tested this way). The
// real integration (does curl's own xferinfo callback actually call this
// and abort a real in-progress transfer) is covered separately by
// php-outbound-networking.yml's php-curl-native-smoke-test job.
#include "../include/iserve_curl_response_cap.h"

#include <stdio.h>

static int g_failures = 0;

static void expect(const char *label, int actual, int expected)
{
    if ((actual != 0) != (expected != 0)) {
        printf("FAIL: %s expected %d, got %d\n", label, expected, actual);
        g_failures++;
    } else {
        printf("ok: %s\n", label);
    }
}

int main(void)
{
    expect("zero bytes received is not over the cap", iserve_curl_response_cap_exceeded(0), 0);
    expect("well under the cap is not over the cap", iserve_curl_response_cap_exceeded(1024 * 1024), 0);
    expect("exactly at the cap is not over the cap", iserve_curl_response_cap_exceeded(ISERVE_CURL_MAX_RESPONSE_BYTES), 0);
    expect("one byte over the cap is over the cap", iserve_curl_response_cap_exceeded(ISERVE_CURL_MAX_RESPONSE_BYTES + 1), 1);
    expect("well over the cap is over the cap", iserve_curl_response_cap_exceeded(100 * 1024 * 1024), 1);

    if (g_failures == 0) {
        printf("all checks passed\n");
        return 0;
    }
    printf("%d check(s) failed\n", g_failures);
    return 1;
}
