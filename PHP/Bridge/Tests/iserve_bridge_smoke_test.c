// Real integration test for PHP/Bridge/iserve_php_bridge.c, run for real in
// CI (.github/workflows/php-embed.yml's native-smoke-test job, the one job
// in that workflow whose binary can actually execute on the runner). Drives
// the bridge exactly the way PHPWorker.swift will once it's wired into the
// app: one bridge_startup(), then multiple execute() calls in the same
// process without re-running startup, proving the persistent-worker request
// loop (not just a single one-shot script run) actually works.
//
// fixtures/smoke.php and fixtures/outside/secret.txt are the request/response
// mapping and open_basedir/disable_functions checks made concrete; see
// fixtures/smoke.php for what each assertion below is reading back.
#include "iserve_php_bridge.h"

#include <stdio.h>
#include <string.h>
#include <strings.h>
#include <stdlib.h>

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
    // result->body is not NUL-terminated; bound the search to body_length.
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

static const char *find_header(const iserve_php_result_t *result, const char *name)
{
    for (size_t i = 0; i < result->header_count; i++) {
        if (strcasecmp(result->headers[i].name, name) == 0) {
            return result->headers[i].value;
        }
    }
    return NULL;
}

int main(int argc, char **argv)
{
    if (argc < 2) {
        fprintf(stderr, "usage: %s <fixtures-dir>\n", argv[0]);
        return 1;
    }
    const char *fixtures_dir = argv[1];
    char script_filename[1024];
    snprintf(script_filename, sizeof(script_filename), "%s/smoke.php", fixtures_dir);

    if (iserve_php_bridge_startup(5, 64 * 1024 * 1024, "/tmp/iserve_bridge_smoke_test_sessions") != 0) {
        fprintf(stderr, "FAIL: iserve_php_bridge_startup\n");
        return 1;
    }

    // Request A: GET with a query string and a cookie.
    iserve_php_request_t request_a = {0};
    request_a.method = "GET";
    request_a.uri = "/smoke.php?q=hello";
    request_a.query_string = "q=hello";
    request_a.cookie_header = "c=cookieval";
    request_a.script_filename = script_filename;
    request_a.document_root = fixtures_dir;

    iserve_php_result_t result_a;
    iserve_php_execute(&request_a, &result_a);

    check(result_a.startup_diagnostic == NULL, "request A: no startup diagnostic");
    check(result_a.status_code == 201, "request A: http_response_code(201) captured");
    const char *custom_header = find_header(&result_a, "X-iServe-Test");
    check(custom_header != NULL && strcmp(custom_header, "1") == 0, "request A: header() call captured");
    check(body_contains(&result_a, "method=GET"), "request A: REQUEST_METHOD mapped");
    check(body_contains(&result_a, "query=hello"), "request A: query string mapped to $_GET");
    check(body_contains(&result_a, "cookie=cookieval"), "request A: cookie header mapped to $_COOKIE");
    check(body_contains(&result_a, "disable_functions_exec=disabled"), "request A: exec() disabled");
    check(body_contains(&result_a, "ini_set_blocked=disabled"), "request A: ini_set() disabled");
    check(body_contains(&result_a, "open_basedir_enforced=yes"), "request A: open_basedir blocks escape to sibling dir");

    iserve_php_free_result(&result_a);

    // Request B: POST, reusing the same started bridge — proves the
    // request loop doesn't require re-running module startup, and that
    // request A's $_GET/$_COOKIE state doesn't leak into request B.
    const char *post_body = "p=world";
    iserve_php_request_t request_b = {0};
    request_b.method = "POST";
    request_b.uri = "/smoke.php";
    request_b.body = (const unsigned char *)post_body;
    request_b.body_length = strlen(post_body);
    request_b.content_type = "application/x-www-form-urlencoded";
    request_b.script_filename = script_filename;
    request_b.document_root = fixtures_dir;

    iserve_php_result_t result_b;
    iserve_php_execute(&request_b, &result_b);

    check(result_b.startup_diagnostic == NULL, "request B: no startup diagnostic");
    check(body_contains(&result_b, "method=POST"), "request B: REQUEST_METHOD mapped");
    check(body_contains(&result_b, "post=world"), "request B: POST body mapped to $_POST");
    check(!body_contains(&result_b, "query=hello"), "request B: no state leaked from request A's $_GET");
    check(!body_contains(&result_b, "cookie=cookieval"), "request B: no state leaked from request A's $_COOKIE");

    iserve_php_free_result(&result_b);

    iserve_php_bridge_shutdown();

    if (g_failures > 0) {
        fprintf(stderr, "%d check(s) failed\n", g_failures);
        return 1;
    }
    fprintf(stderr, "all checks passed\n");
    return 0;
}
