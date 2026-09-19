// Real integration test for PHP/Bridge/iserve_php_bridge.c, run for real in
// CI (.github/workflows/php-embed.yml's native-smoke-test job, the one job
// in that workflow whose binary can actually execute on the runner). Drives
// the bridge exactly the way PHPWorker.swift will once it's wired into the
// app: one bridge_startup(), then multiple execute() calls in the same
// process without re-running startup, proving the persistent-worker request
// loop (not just a single one-shot script run) actually works.
//
// fixtures/smoke.php and fixtures/outside/secret.txt are the request/response
// mapping and open_basedir/disable_functions checks made concrete (requests
// A/B); fixtures/sqlite.php proves pdo_sqlite/sqlite3 actually work (request
// C); fixtures/session.php proves a session persists across requests
// (requests D/E); fixtures/warning.php proves a runtime warning is captured
// into diagnostic_log without leaking into the response body (request F).
// See each fixture for what its assertions below are reading back.
#include "iserve_php_bridge.h"

#include <stdio.h>
#include <string.h>
#include <strings.h>
#include <stdlib.h>
#include <sys/stat.h>

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

// Extracts just the "name=value" pair a Set-Cookie header's value starts
// with, dropping any trailing "; path=..."/"; HttpOnly" attributes -- a
// real client's Cookie header on its next request carries only that pair,
// never the attributes. Returns a caller-owned, malloc'd string (or NULL);
// the caller must free() it.
static char *extract_cookie_pair(const char *set_cookie_value)
{
    if (!set_cookie_value) {
        return NULL;
    }
    const char *end = strchr(set_cookie_value, ';');
    size_t length = end ? (size_t)(end - set_cookie_value) : strlen(set_cookie_value);
    char *pair = malloc(length + 1);
    if (!pair) {
        return NULL;
    }
    memcpy(pair, set_cookie_value, length);
    pair[length] = '\0';
    return pair;
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

    const char *sessions_dir = "/tmp/iserve_bridge_smoke_test_sessions";
    mkdir(sessions_dir, 0700); // Best-effort: PHP's session extension never creates save_path itself.

    if (iserve_php_bridge_startup(5, 64 * 1024 * 1024, sessions_dir) != 0) {
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
    check(result_a.diagnostic_log == NULL, "request A: no diagnostic_log entries for a clean request");

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

    // Request C: exercises fixtures/sqlite.php — proves pdo_sqlite/sqlite3
    // (ADR-0009's extension allowlist) actually work under the embed SAPI,
    // reusing the same started bridge again. This is v0.4's own exit gate
    // ("self-contained PHP+SQLite applications execute reliably"), not
    // exercised by requests A/B at all.
    char sqlite_script_filename[1024];
    snprintf(sqlite_script_filename, sizeof(sqlite_script_filename), "%s/sqlite.php", fixtures_dir);
    iserve_php_request_t request_c = {0};
    request_c.method = "GET";
    request_c.uri = "/sqlite.php";
    request_c.script_filename = sqlite_script_filename;
    request_c.document_root = fixtures_dir;

    iserve_php_result_t result_c;
    iserve_php_execute(&request_c, &result_c);

    check(result_c.startup_diagnostic == NULL, "request C: no startup diagnostic");
    check(body_contains(&result_c, "sqlite3_roundtrip=hello from sqlite3"), "request C: sqlite3 extension writes and reads back");
    check(body_contains(&result_c, "pdo_sqlite_roundtrip=hello from pdo_sqlite"), "request C: pdo_sqlite extension writes and reads back");

    iserve_php_free_result(&result_c);

    // Requests D/E: exercise fixtures/session.php — proves a PHP session
    // actually persists across separate iserve_php_execute() calls (not
    // just that session_start() runs without error), by feeding request
    // E the exact session cookie request D's own Set-Cookie header names,
    // the same way a real client's second request would.
    char session_script_filename[1024];
    snprintf(session_script_filename, sizeof(session_script_filename), "%s/session.php", fixtures_dir);
    iserve_php_request_t request_d = {0};
    request_d.method = "GET";
    request_d.uri = "/session.php";
    request_d.script_filename = session_script_filename;
    request_d.document_root = fixtures_dir;

    iserve_php_result_t result_d;
    iserve_php_execute(&request_d, &result_d);

    check(result_d.startup_diagnostic == NULL, "request D: no startup diagnostic");
    check(body_contains(&result_d, "visits=1"), "request D: fresh session starts at visits=1");
    char *session_cookie = extract_cookie_pair(find_header(&result_d, "Set-Cookie"));
    check(session_cookie != NULL, "request D: session_start() sent a Set-Cookie header");

    iserve_php_free_result(&result_d);

    iserve_php_request_t request_e = {0};
    request_e.method = "GET";
    request_e.uri = "/session.php";
    request_e.cookie_header = session_cookie;
    request_e.script_filename = session_script_filename;
    request_e.document_root = fixtures_dir;

    iserve_php_result_t result_e;
    iserve_php_execute(&request_e, &result_e);

    check(result_e.startup_diagnostic == NULL, "request E: no startup diagnostic");
    check(body_contains(&result_e, "visits=2"), "request E: same session's $_SESSION persisted across requests");

    iserve_php_free_result(&result_e);
    free(session_cookie);

    // Request F: exercises fixtures/warning.php -- proves a PHP runtime
    // warning (display_errors=0, so it never reaches the actual response
    // body) is still captured into out_result->diagnostic_log via
    // iserve_log_message, the data source for the ROADMAP's "PHP
    // diagnostics console" deliverable (on-device only, never sent to a
    // remote client -- see that field's own doc comment).
    char warning_script_filename[1024];
    snprintf(warning_script_filename, sizeof(warning_script_filename), "%s/warning.php", fixtures_dir);
    iserve_php_request_t request_f = {0};
    request_f.method = "GET";
    request_f.uri = "/warning.php";
    request_f.script_filename = warning_script_filename;
    request_f.document_root = fixtures_dir;

    iserve_php_result_t result_f;
    iserve_php_execute(&request_f, &result_f);

    check(result_f.startup_diagnostic == NULL, "request F: no startup diagnostic");
    check(body_contains(&result_f, "before") && body_contains(&result_f, "after"), "request F: script output still runs around the warning");
    check(result_f.diagnostic_log != NULL, "request F: a triggered warning is captured into diagnostic_log");
    check(result_f.diagnostic_log != NULL && strstr(result_f.diagnostic_log, "iserve diagnostic marker") != NULL,
        "request F: diagnostic_log contains the warning message");
    check(!body_contains(&result_f, "iserve diagnostic marker"), "request F: warning text never leaks into the response body (display_errors=0)");

    iserve_php_free_result(&result_f);

    iserve_php_bridge_shutdown();

    if (g_failures > 0) {
        fprintf(stderr, "%d check(s) failed\n", g_failures);
        return 1;
    }
    fprintf(stderr, "all checks passed\n");
    return 0;
}
