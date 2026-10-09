// Standalone unit test for iserve_outbound_guard.c -- portable, no
// dependency on php-src or DYLD_INTERPOSE (see that file's own header
// comment for why this is kept separate from the Apple-specific
// interposition wiring).
#include "../include/iserve_outbound_guard.h"

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
    expect("inactive before any begin() call", iserve_outbound_guard_is_active(), 0);

    iserve_outbound_guard_begin();
    expect("active immediately after begin()", iserve_outbound_guard_is_active(), 1);

    iserve_outbound_guard_end();
    expect("inactive immediately after end()", iserve_outbound_guard_is_active(), 0);

    // A second begin/end cycle -- confirms this isn't a one-shot latch.
    iserve_outbound_guard_begin();
    expect("active again after a second begin()", iserve_outbound_guard_is_active(), 1);
    iserve_outbound_guard_end();
    expect("inactive again after a second end()", iserve_outbound_guard_is_active(), 0);

    if (g_failures == 0) {
        printf("all checks passed\n");
        return 0;
    }
    printf("%d check(s) failed\n", g_failures);
    return 1;
}
