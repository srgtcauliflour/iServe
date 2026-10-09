// Proves the actual DYLD_INTERPOSE mechanism works -- iserve_outbound_policy_test.c
// and iserve_outbound_guard_test.c already prove the pure logic each piece
// uses, but neither can prove the interposition itself actually intercepts
// a real connect() call; that can only be verified on a real Apple target,
// which is exactly what this test (compiled and run on native macOS CI,
// never cross-compiled) exists to do.
//
// Deliberately starts a REAL listening server on 127.0.0.1 first, rather
// than just attempting a connect() to an address nothing is listening on:
// a bare "connect() failed" by itself can't distinguish "our interposition
// blocked it" from "nothing was there to refuse the connection naturally"
// -- both look identical from the caller's side. Connecting to a socket
// that demonstrably *is* accepting connections, and showing it only fails
// while the guard is active, is the only way to actually prove this
// mechanism is the thing doing the blocking.
#include "../include/iserve_outbound_guard.h"
#include "../include/iserve_outbound_toggle.h"

#include <arpa/inet.h>
#include <errno.h>
#include <netinet/in.h>
#include <stdio.h>
#include <string.h>
#include <sys/socket.h>
#include <unistd.h>

static int g_failures = 0;

static void expect(const char *label, int actual, int expected)
{
    if (actual != expected) {
        printf("FAIL: %s -- expected %d, got %d\n", label, expected, actual);
        g_failures++;
    } else {
        printf("ok: %s\n", label);
    }
}

int main(void)
{
    int server_fd = socket(AF_INET, SOCK_STREAM, 0);
    if (server_fd < 0) {
        printf("FAIL: could not create the listening socket\n");
        return 1;
    }

    struct sockaddr_in server_addr;
    memset(&server_addr, 0, sizeof(server_addr));
    server_addr.sin_family = AF_INET;
    server_addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    server_addr.sin_port = 0; // Let the OS pick an ephemeral port.

    if (bind(server_fd, (struct sockaddr *)&server_addr, sizeof(server_addr)) != 0) {
        printf("FAIL: could not bind the listening socket\n");
        return 1;
    }
    if (listen(server_fd, 1) != 0) {
        printf("FAIL: could not listen on the bound socket\n");
        return 1;
    }

    socklen_t addr_len = sizeof(server_addr);
    if (getsockname(server_fd, (struct sockaddr *)&server_addr, &addr_len) != 0) {
        printf("FAIL: could not read back the ephemeral port\n");
        return 1;
    }

    // Guard inactive: an ordinary, unaffected connect() to our own real
    // listening loopback socket must succeed -- establishes the baseline
    // this whole test depends on (if this fails, the test setup itself is
    // broken, not the interposition).
    int client_before = socket(AF_INET, SOCK_STREAM, 0);
    int rc_before = connect(client_before, (struct sockaddr *)&server_addr, addr_len);
    expect("connect() to a real listening loopback socket succeeds when the guard is inactive", rc_before, 0);
    close(client_before);

    // The denylist/public-address assertions below are about
    // iserve_outbound_policy.c's own classification logic, so they need
    // the session-level toggle explicitly ON first -- otherwise every
    // destination would be blocked regardless of the denylist, and the
    // "public address is allowed" assertion below would pass for the
    // wrong reason. The off-by-default behavior itself is proved
    // separately, at the end of this test, with the toggle OFF again.
    iserve_outbound_networking_set_enabled(1);

    // Guard active: the exact same real, listening loopback socket must
    // now be refused -- the socket is still demonstrably accepting
    // connections (just proved above), so this can only be our own
    // interposed connect() actively blocking it, not a coincidental
    // "nothing was there" failure.
    iserve_outbound_guard_begin();
    int client_during = socket(AF_INET, SOCK_STREAM, 0);
    int rc_during = connect(client_during, (struct sockaddr *)&server_addr, addr_len);
    int errno_during = errno;
    expect("connect() to the same loopback socket is refused while the guard is active", rc_during, -1);
    expect("the refusal is ECONNREFUSED (an ordinary curl-handleable failure)", errno_during, ECONNREFUSED);
    close(client_during);

    // Guard still active: a real, non-denylisted public address must still
    // be allowed through -- proves this isn't a blanket "deny everything
    // while active" shortcut, it's genuinely consulting the denylist.
    struct sockaddr_in public_addr;
    memset(&public_addr, 0, sizeof(public_addr));
    public_addr.sin_family = AF_INET;
    public_addr.sin_port = htons(443);
    inet_pton(AF_INET, "1.1.1.1", &public_addr.sin_addr); // Cloudflare's public resolver.
    int client_public = socket(AF_INET, SOCK_STREAM, 0);
    int rc_public = connect(client_public, (struct sockaddr *)&public_addr, sizeof(public_addr));
    int errno_public = errno;
    // ECONNREFUSED is specifically the signature our own interposition
    // produces when it blocks something -- that's the one outcome this
    // check actually cares about distinguishing. Any other failure (a
    // timeout, no route, a firewalled CI network) is a real-world network
    // condition this test has no business diagnosing, not evidence the
    // denylist did anything wrong.
    if (rc_public == 0 || errno_public != ECONNREFUSED) {
        printf("ok: connecting to a real public address while the guard is active was not blocked by the denylist (rc=%d errno=%d)\n", rc_public, errno_public);
    } else {
        printf("FAIL: connecting to a real public address while the guard is active was refused (ECONNREFUSED) -- the denylist incorrectly blocked it\n");
        g_failures++;
    }
    close(client_public);

    // Toggle OFF (the default, docs/adr/0010-php-outbound-networking.md's
    // "Consent: a separate toggle"): the exact same real, non-denylisted
    // public address just proved reachable above must now be refused too
    // -- proving the off-by-default state blocks everything, not just the
    // denylisted ranges iserve_outbound_policy.c names.
    iserve_outbound_networking_set_enabled(0);
    int client_public_disabled = socket(AF_INET, SOCK_STREAM, 0);
    int rc_public_disabled = connect(client_public_disabled, (struct sockaddr *)&public_addr, sizeof(public_addr));
    int errno_public_disabled = errno;
    expect("a real public address is refused while outbound networking is off by default", rc_public_disabled, -1);
    expect("the refusal is ECONNREFUSED, same as a denylisted address", errno_public_disabled, ECONNREFUSED);
    close(client_public_disabled);

    iserve_outbound_guard_end();
    close(server_fd);

    if (g_failures == 0) {
        printf("all checks passed\n");
        return 0;
    }
    printf("%d check(s) failed\n", g_failures);
    return 1;
}
