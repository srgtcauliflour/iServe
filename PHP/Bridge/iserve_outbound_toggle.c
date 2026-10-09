#include "include/iserve_outbound_toggle.h"

#include <stdatomic.h>

static _Atomic int g_outbound_networking_enabled = 0;

void iserve_outbound_networking_set_enabled(int enabled)
{
    atomic_store(&g_outbound_networking_enabled, enabled ? 1 : 0);
}

int iserve_outbound_networking_is_enabled(void)
{
    return atomic_load(&g_outbound_networking_enabled);
}
