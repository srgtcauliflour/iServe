// Standalone unit test for iserve_outbound_policy.c -- deliberately has no
// dependency on php-src or the embed SAPI at all, so it can run on any
// host (including this project's own CI runner for Linux-based tooling,
// not just macOS).
#include "../include/iserve_outbound_policy.h"

#include <arpa/inet.h>
#include <stdio.h>
#include <string.h>

static int g_failures = 0;

static void check_ipv4(const char *ip, int expect_denied)
{
    struct sockaddr_in sin;
    memset(&sin, 0, sizeof(sin));
    sin.sin_family = AF_INET;
    if (inet_pton(AF_INET, ip, &sin.sin_addr) != 1) {
        printf("FAIL: inet_pton could not parse %s\n", ip);
        g_failures++;
        return;
    }
    int denied = iserve_outbound_is_denied_sockaddr((struct sockaddr *)&sin, sizeof(sin));
    if ((denied != 0) != (expect_denied != 0)) {
        printf("FAIL: %s expected denied=%d, got %d\n", ip, expect_denied, denied);
        g_failures++;
    } else {
        printf("ok: %s denied=%d\n", ip, denied);
    }
}

static void check_ipv6(const char *ip, int expect_denied)
{
    struct sockaddr_in6 sin6;
    memset(&sin6, 0, sizeof(sin6));
    sin6.sin6_family = AF_INET6;
    if (inet_pton(AF_INET6, ip, &sin6.sin6_addr) != 1) {
        printf("FAIL: inet_pton could not parse %s\n", ip);
        g_failures++;
        return;
    }
    int denied = iserve_outbound_is_denied_sockaddr((struct sockaddr *)&sin6, sizeof(sin6));
    if ((denied != 0) != (expect_denied != 0)) {
        printf("FAIL: %s expected denied=%d, got %d\n", ip, expect_denied, denied);
        g_failures++;
    } else {
        printf("ok: %s denied=%d\n", ip, denied);
    }
}

int main(void)
{
    // IPv4: RFC 1918 private ranges -- denied.
    check_ipv4("10.0.0.1", 1);
    check_ipv4("10.255.255.255", 1);
    check_ipv4("172.16.0.1", 1);
    check_ipv4("172.31.255.255", 1);
    check_ipv4("192.168.1.1", 1);
    check_ipv4("192.168.255.255", 1);

    // IPv4: just outside the RFC 1918 ranges -- allowed.
    check_ipv4("9.255.255.255", 0);
    check_ipv4("11.0.0.0", 0);
    check_ipv4("172.15.255.255", 0);
    check_ipv4("172.32.0.0", 0);
    check_ipv4("192.167.255.255", 0);
    check_ipv4("192.169.0.0", 0);

    // IPv4: loopback -- denied.
    check_ipv4("127.0.0.1", 1);
    check_ipv4("127.255.255.255", 1);

    // IPv4: link-local, including the cloud-metadata address -- denied.
    check_ipv4("169.254.0.1", 1);
    check_ipv4("169.254.169.254", 1);

    // IPv4: CGNAT -- denied.
    check_ipv4("100.64.0.1", 1);
    check_ipv4("100.127.255.255", 1);
    check_ipv4("100.63.255.255", 0);
    check_ipv4("100.128.0.0", 0);

    // IPv4: multicast/broadcast/unspecified -- denied.
    check_ipv4("224.0.0.1", 1);
    check_ipv4("239.255.255.255", 1);
    check_ipv4("255.255.255.255", 1);
    check_ipv4("0.0.0.0", 1);

    // IPv4: a real, ordinary public address -- allowed.
    check_ipv4("8.8.8.8", 0);
    check_ipv4("1.1.1.1", 0);

    // IPv6: loopback/unspecified -- denied.
    check_ipv6("::1", 1);
    check_ipv6("::", 1);

    // IPv6: link-local -- denied.
    check_ipv6("fe80::1", 1);
    check_ipv6("fe80::ffff:ffff:ffff:ffff", 1);

    // IPv6: unique-local -- denied.
    check_ipv6("fc00::1", 1);
    check_ipv6("fd00::1", 1);

    // IPv6: multicast -- denied.
    check_ipv6("ff02::1", 1);

    // IPv6: a real, ordinary public address -- allowed.
    check_ipv6("2606:4700:4700::1111", 0); // Cloudflare's public resolver.

    // IPv4-mapped IPv6: classified by the embedded IPv4 address -- the
    // specific bypass this mapping exists to close.
    check_ipv6("::ffff:127.0.0.1", 1);
    check_ipv6("::ffff:10.0.0.1", 1);
    check_ipv6("::ffff:169.254.169.254", 1);
    check_ipv6("::ffff:8.8.8.8", 0);

    if (g_failures == 0) {
        printf("all checks passed\n");
        return 0;
    }
    printf("%d check(s) failed\n", g_failures);
    return 1;
}
