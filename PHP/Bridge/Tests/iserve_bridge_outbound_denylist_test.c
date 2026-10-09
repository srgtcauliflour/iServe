// Real integration test for docs/adr/0010-php-outbound-networking.md's IP
// denylist, run through the REAL bridge (iserve_php_bridge_startup() ->
// iserve_outbound_networking_set_enabled() -> the interposed connect()),
// with outbound networking ON -- a separate process from
// iserve_bridge_smoke_test.c, which deliberately keeps it OFF (the real
// off-by-default behavior) for every one of its own requests. PHP's module
// startup/shutdown is non-reentrant, so a single process can only ever
// pick one value for that one bridge-wide setting -- this file exists
// specifically to exercise the OTHER one, the same split
// iserve_outbound_interpose_test.c's own raw-connect() test already uses
// (toggle ON to test the denylist itself, toggle OFF to test the
// off-by-default state), just through curl/PHP instead of a bare socket.
//
// Covers what docs/adr/0010's own "Costs" section names as still needing
// proof "before this ships": not just "a request to a private IP is
// blocked" (request A), but the redirect-based bypass case specifically
// (request D) and the hostname/DNS-rebinding-adjacent case (request B) --
// see each fixture's own doc comment for the full reasoning.
#include "iserve_php_bridge.h"

#include <arpa/inet.h>
#include <netinet/in.h>
#include <stdio.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <unistd.h>

static int g_failures = 0;

static void check(int condition, const char *description)
{
    if (condition) {
        fprintf(stderr, "PASS: %s\n", description);
    } else {
        fprintf(stderr, "FAIL: %s\n", description);
        g_failures++;
    }
}

static int body_contains(const iserve_php_result_t *result, const char *needle)
{
    if (!result->body || result->body_length == 0) {
        return 0;
    }
    size_t needle_len = strlen(needle);
    if (needle_len > result->body_length) {
        return 0;
    }
    for (size_t i = 0; i + needle_len <= result->body_length; i++) {
        if (memcmp(result->body + i, needle, needle_len) == 0) {
            return 1;
        }
    }
    return 0;
}

// Starts a real listening TCP socket on 127.0.0.1 at an OS-assigned
// ephemeral port -- so requests A/B below connect to a target genuinely
// accepting connections, not an arbitrary port nothing happens to be
// bound to (see denylist_loopback.php's own comment for why that
// distinction is the whole point of this test). Never actually accepted
// from PHP's side: the interposed connect() is expected to refuse the
// attempt before a real TCP handshake with this socket ever completes.
static int start_real_listening_server(int *out_port)
{
    int server_fd = socket(AF_INET, SOCK_STREAM, 0);
    if (server_fd < 0) {
        return -1;
    }
    struct sockaddr_in addr;
    memset(&addr, 0, sizeof(addr));
    addr.sin_family = AF_INET;
    addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    addr.sin_port = 0;
    if (bind(server_fd, (struct sockaddr *)&addr, sizeof(addr)) != 0) {
        close(server_fd);
        return -1;
    }
    if (listen(server_fd, 1) != 0) {
        close(server_fd);
        return -1;
    }
    socklen_t addr_len = sizeof(addr);
    if (getsockname(server_fd, (struct sockaddr *)&addr, &addr_len) != 0) {
        close(server_fd);
        return -1;
    }
    *out_port = ntohs(addr.sin_port);
    return server_fd;
}

int main(int argc, char **argv)
{
    if (argc < 2) {
        fprintf(stderr, "usage: %s <fixtures-dir>\n", argv[0]);
        return 1;
    }
    const char *fixtures_dir = argv[1];

    const char *sessions_dir = "/tmp/iserve_bridge_outbound_denylist_test_sessions";
    mkdir(sessions_dir, 0700);
    const char *uploads_dir = "/tmp/iserve_bridge_outbound_denylist_test_uploads";
    mkdir(uploads_dir, 0700);

    // outbound_networking_enabled=1 -- the one thing this test file exists
    // to exercise that iserve_bridge_smoke_test.c deliberately never does.
    if (iserve_php_bridge_startup(15, 64 * 1024 * 1024, sessions_dir, uploads_dir, 1) != 0) {
        fprintf(stderr, "FAIL: iserve_php_bridge_startup\n");
        return 1;
    }

    // A real, demonstrably-live loopback server -- requests A and B below
    // connect to it (never actually accepted from PHP's side; see
    // start_real_listening_server()'s own comment for why this matters).
    int listening_port = 0;
    int listening_fd = start_real_listening_server(&listening_port);
    if (listening_fd < 0) {
        fprintf(stderr, "FAIL: could not start the real listening server requests A/B depend on\n");
        return 1;
    }
    char port_query[32];
    snprintf(port_query, sizeof(port_query), "port=%d", listening_port);

    struct {
        const char *fixture;
        const char *query_string; // NULL for a request that takes no query string
        const char *expected_body_line;
        const char *description;
    } requests[] = {
        { "denylist_loopback.php", port_query, "loopback_blocked=yes\n", "request A: a literal denylisted loopback address is refused even with outbound networking on" },
        { "denylist_hostname.php", port_query, "hostname_resolving_to_loopback_blocked=yes\n", "request B: a hostname that resolves to loopback is refused, not just a literal IP" },
        { "denylist_public_allowed.php", NULL, "public_address_allowed=yes\n", "request C: a real, non-denylisted public address is still reachable (positive control)" },
    };

    for (size_t i = 0; i < sizeof(requests) / sizeof(requests[0]); i++) {
        char script_filename[1024];
        snprintf(script_filename, sizeof(script_filename), "%s/%s", fixtures_dir, requests[i].fixture);

        iserve_php_request_t request = {0};
        request.method = "GET";
        request.script_filename = script_filename;
        request.document_root = fixtures_dir;
        request.query_string = requests[i].query_string;
        char uri[256];
        if (requests[i].query_string) {
            snprintf(uri, sizeof(uri), "/%s?%s", requests[i].fixture, requests[i].query_string);
        } else {
            snprintf(uri, sizeof(uri), "/%s", requests[i].fixture);
        }
        request.uri = uri;

        iserve_php_result_t result;
        iserve_php_execute(&request, &result);

        char description[256];
        snprintf(description, sizeof(description), "%s: no startup diagnostic", requests[i].description);
        check(result.startup_diagnostic == NULL, description);
        check(body_contains(&result, requests[i].expected_body_line), requests[i].description);

        iserve_php_free_result(&result);
    }

    // Request D: the redirect-based bypass -- kept separate from the loop
    // above since it asserts on two distinct output lines (and depends on
    // a third-party test service, httpbin.org, unlike A/B/C which are
    // fully local and deterministic -- see the fixture's own comment).
    // Still uses the same real listening server as A/B: the redirect's
    // own target is that same loopback port, for the same "demonstrably
    // live, not just unoccupied" reason.
    char redirect_script_filename[1024];
    snprintf(redirect_script_filename, sizeof(redirect_script_filename), "%s/denylist_redirect_bypass.php", fixtures_dir);

    iserve_php_request_t request_d = {0};
    request_d.method = "GET";
    char redirect_uri[256];
    snprintf(redirect_uri, sizeof(redirect_uri), "/denylist_redirect_bypass.php?%s", port_query);
    request_d.uri = redirect_uri;
    request_d.query_string = port_query;
    request_d.script_filename = redirect_script_filename;
    request_d.document_root = fixtures_dir;

    iserve_php_result_t result_d;
    iserve_php_execute(&request_d, &result_d);

    check(result_d.startup_diagnostic == NULL, "request D: no startup diagnostic");
    check(body_contains(&result_d, "redirect_followed=yes\n"), "request D: the legitimate first hop (httpbin.org) succeeded and a redirect was followed");
    check(body_contains(&result_d, "redirect_to_denylisted_address_blocked=yes\n"), "request D: a remote redirect to a denylisted address is blocked, same as a direct request");

    iserve_php_free_result(&result_d);

    close(listening_fd);

    iserve_php_bridge_shutdown();

    if (g_failures > 0) {
        fprintf(stderr, "%d check(s) failed\n", g_failures);
        return 1;
    }
    fprintf(stderr, "all checks passed\n");
    return 0;
}
