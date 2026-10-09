// Standalone unit test for iserve_outbound_toggle.c -- portable, no
// dependency on php-src or DYLD_INTERPOSE (see iserve_outbound_guard_test.c's
// own header comment for why this is kept separate from the Apple-specific
// interposition wiring).
#include "../include/iserve_outbound_toggle.h"

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
    expect("off by default before any set_enabled() call", iserve_outbound_networking_is_enabled(), 0);

    iserve_outbound_networking_set_enabled(1);
    expect("on immediately after set_enabled(1)", iserve_outbound_networking_is_enabled(), 1);

    iserve_outbound_networking_set_enabled(0);
    expect("off immediately after set_enabled(0)", iserve_outbound_networking_is_enabled(), 0);

    // A nonzero value other than 1 must still normalize to "enabled" --
    // callers only ever pass a C-style boolean (e.g. a Swift Bool bridged
    // as Int32), but the API contract is "any nonzero means true", not
    // "only the literal value 1".
    iserve_outbound_networking_set_enabled(42);
    expect("any nonzero value normalizes to enabled", iserve_outbound_networking_is_enabled(), 1);

    iserve_outbound_networking_set_enabled(0);
    expect("off again after a second set_enabled(0)", iserve_outbound_networking_is_enabled(), 0);

    if (g_failures == 0) {
        printf("all checks passed\n");
        return 0;
    }
    printf("%d check(s) failed\n", g_failures);
    return 1;
}
