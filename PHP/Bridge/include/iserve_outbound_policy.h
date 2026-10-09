// Pure, platform-independent classification of a destination address as
// denylisted for PHP-originated outbound connections (docs/adr/0010-php-
// outbound-networking.md). Deliberately has nothing to do with *how* this
// gets enforced (the DYLD_INTERPOSE'd connect() in iserve_php_bridge.c is a
// separate, Apple-specific concern) -- this file is plain, portable C so it
// can be unit-tested on any host, independent of whether the interposition
// mechanism itself can even be exercised there.
#ifndef ISERVE_OUTBOUND_POLICY_H
#define ISERVE_OUTBOUND_POLICY_H

#include <sys/socket.h>

#ifdef __cplusplus
extern "C" {
#endif

// Returns nonzero if `addr` falls within a range ADR-0010 denies outbound
// PHP connections to, zero if the address is allowed. Only AF_INET and
// AF_INET6 are understood; any other address family is treated as denied
// (fail closed -- an address this policy doesn't recognize is never treated
// as safe by default).
//
// Checks (ADR-0010's own list):
//   IPv4: RFC 1918 private (10/8, 172.16/12, 192.168/16), loopback (127/8),
//   link-local (169.254/16 -- this is what covers the 169.254.169.254
//   cloud-metadata-style address class of target), CGNAT (100.64/10),
//   multicast (224/4), broadcast (255.255.255.255), unspecified (0.0.0.0).
//   IPv6: loopback (::1), link-local (fe80::/10), unique-local (fc00::/7),
//   multicast (ff00::/8), unspecified (::).
//
// An IPv4-mapped IPv6 address (::ffff:a.b.c.d) is unwrapped and classified
// by its embedded IPv4 address -- not an ADR-0010 line item verbatim, but a
// direct consequence of its own stated reasoning ("the only sound
// enforcement point is the moment of the real connection attempt, on the
// resolved address actually being connected to"): the address actually
// being connected to here *is* an IPv4 destination, just spelled in IPv6
// form, and a script passing a literal ::ffff:127.0.0.1 is exactly the kind
// of "pass a literal IP instead of a hostname" bypass that ADR already
// calls out as something this check has to hold against.
int iserve_outbound_is_denied_sockaddr(const struct sockaddr *addr, socklen_t addr_len);

#ifdef __cplusplus
}
#endif

#endif // ISERVE_OUTBOUND_POLICY_H
