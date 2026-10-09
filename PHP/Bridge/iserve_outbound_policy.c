#include "include/iserve_outbound_policy.h"

#include <netinet/in.h>
#include <stdint.h>
#include <string.h>

static int iserve_outbound_is_denied_ipv4(uint32_t host_order_addr)
{
    uint32_t a = host_order_addr;

    // RFC 1918 private ranges.
    if ((a & 0xFF000000u) == 0x0A000000u) return 1;             // 10.0.0.0/8
    if ((a & 0xFFF00000u) == 0xAC100000u) return 1;             // 172.16.0.0/12
    if ((a & 0xFFFF0000u) == 0xC0A80000u) return 1;             // 192.168.0.0/16

    // Loopback.
    if ((a & 0xFF000000u) == 0x7F000000u) return 1;             // 127.0.0.0/8

    // Link-local -- covers 169.254.169.254-style cloud metadata targets.
    if ((a & 0xFFFF0000u) == 0xA9FE0000u) return 1;             // 169.254.0.0/16

    // CGNAT (RFC 6598).
    if ((a & 0xFFC00000u) == 0x64400000u) return 1;             // 100.64.0.0/10

    // Multicast, broadcast, unspecified.
    if ((a & 0xF0000000u) == 0xE0000000u) return 1;             // 224.0.0.0/4
    if (a == 0xFFFFFFFFu) return 1;                              // 255.255.255.255
    if (a == 0x00000000u) return 1;                              // 0.0.0.0

    return 0;
}

static int iserve_outbound_is_denied_ipv6(const struct in6_addr *addr)
{
    const unsigned char *b = addr->s6_addr;

    // IPv4-mapped (::ffff:a.b.c.d): classify by the embedded IPv4 address --
    // see the header's own comment for why this isn't optional.
    static const unsigned char ipv4_mapped_prefix[12] = {
        0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0xFF, 0xFF
    };
    if (memcmp(b, ipv4_mapped_prefix, sizeof(ipv4_mapped_prefix)) == 0) {
        uint32_t embedded = ((uint32_t)b[12] << 24) | ((uint32_t)b[13] << 16) |
                            ((uint32_t)b[14] << 8) | (uint32_t)b[15];
        return iserve_outbound_is_denied_ipv4(embedded);
    }

    // Unspecified (::).
    static const unsigned char zero[16] = {0};
    if (memcmp(b, zero, sizeof(zero)) == 0) return 1;

    // Loopback (::1).
    static const unsigned char loopback[16] = {
        0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1
    };
    if (memcmp(b, loopback, sizeof(loopback)) == 0) return 1;

    // Link-local (fe80::/10): top 10 bits are 1111111010.
    if ((b[0] == 0xFE) && ((b[1] & 0xC0) == 0x80)) return 1;

    // Unique-local (fc00::/7): top 7 bits are 1111110.
    if ((b[0] & 0xFE) == 0xFC) return 1;

    // Multicast (ff00::/8).
    if (b[0] == 0xFF) return 1;

    return 0;
}

int iserve_outbound_is_denied_sockaddr(const struct sockaddr *addr, socklen_t addr_len)
{
    if (!addr) return 1; // Fail closed.

    if (addr->sa_family == AF_INET) {
        if (addr_len < (socklen_t)sizeof(struct sockaddr_in)) return 1;
        const struct sockaddr_in *sin = (const struct sockaddr_in *)addr;
        return iserve_outbound_is_denied_ipv4(ntohl(sin->sin_addr.s_addr));
    }

    if (addr->sa_family == AF_INET6) {
        if (addr_len < (socklen_t)sizeof(struct sockaddr_in6)) return 1;
        const struct sockaddr_in6 *sin6 = (const struct sockaddr_in6 *)addr;
        return iserve_outbound_is_denied_ipv6(&sin6->sin6_addr);
    }

    // Any other address family (AF_UNIX, AF_UNSPEC, ...) is denied outright
    // -- curl has no legitimate reason to connect() via anything but IPv4/
    // IPv6 for an http/https request, and an address family this policy
    // doesn't recognize is never treated as safe by default.
    return 1;
}
