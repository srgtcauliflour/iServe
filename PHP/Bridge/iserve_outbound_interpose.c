// SSRF / local-network / DNS-rebinding defense for PHP-originated outbound
// connections (docs/adr/0010-php-outbound-networking.md). Interposes the C
// library's connect() via DYLD_INTERPOSE -- a standard, documented Apple
// linker mechanism (<mach-o/dyld-interposing.h>), not a novel technique
// invented for this project.
//
// Deliberately split from the logic it depends on:
//   - iserve_outbound_policy.c decides WHICH addresses are denied (pure,
//     portable, independently unit-tested).
//   - iserve_outbound_guard.c tracks WHEN the check applies (also pure and
//     portable, independently unit-tested).
//   - This file is the one piece that is genuinely platform-specific and
//     can only be proven by actually linking and running it on a real
//     Apple target -- see .github/workflows/php-outbound-networking.yml
//     for that verification, which this sandbox's own Linux toolchain
//     cannot provide (DYLD_INTERPOSE and <mach-o/dyld-interposing.h> do
//     not exist outside Apple's own linker).
//
// ADR-0010's own reasoning for why this -- not a hostname-string denylist,
// not a one-time DNS lookup -- is the only sound enforcement point: any
// check that runs before or independent of the actual TCP connection can be
// bypassed by a hostname that resolves differently between check-time and
// connect-time (DNS rebinding), or trivially sidestepped by a script
// passing a literal IP instead of a hostname at all. Applies uniformly to
// every connection curl makes for a request, including ones curl itself
// opens while following a redirect, since every one of them calls this
// same interposed connect() -- closing the redirect-based SSRF variant
// without needing separate handling.
#ifdef __APPLE__

#include "include/iserve_outbound_diagnostics.h"
#include "include/iserve_outbound_guard.h"
#include "include/iserve_outbound_policy.h"

#include <errno.h>
#include <mach-o/dyld-interposing.h>
#include <sys/socket.h>

static int iserve_interposed_connect(int socket_fd, const struct sockaddr *address, socklen_t address_len)
{
    if (iserve_outbound_guard_is_active() && iserve_outbound_is_denied_sockaddr(address, address_len)) {
        // An ordinary connection-refused-style failure -- curl already
        // knows how to handle this (curl_easy_perform() returns a normal
        // CURLE_COULDNT_CONNECT, no crash, nothing that reveals *why* the
        // connection was refused). The specific reason is surfaced
        // separately, on-device only, through PHPDiagnosticsLog -- never
        // in anything a script's own curl_error() can see.
        iserve_outbound_report_blocked();
        errno = ECONNREFUSED;
        return -1;
    }
    return connect(socket_fd, address, address_len);
}

DYLD_INTERPOSE(iserve_interposed_connect, connect)

#endif // __APPLE__
