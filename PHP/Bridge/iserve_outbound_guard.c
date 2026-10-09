#include "include/iserve_outbound_guard.h"

// _Thread_local, not a plain static -- see the header's own comment for why
// a process-wide flag would be a real, not hypothetical, race with this
// app's own concurrent (non-PHP) networking.
static _Thread_local int g_outbound_guard_active = 0;

void iserve_outbound_guard_begin(void)
{
    g_outbound_guard_active = 1;
}

void iserve_outbound_guard_end(void)
{
    g_outbound_guard_active = 0;
}

int iserve_outbound_guard_is_active(void)
{
    return g_outbound_guard_active;
}
