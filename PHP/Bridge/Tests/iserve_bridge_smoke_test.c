// Real integration test for PHP/Bridge/iserve_php_bridge.c, run for real in
// CI (.github/workflows/php-embed.yml's native-smoke-test job, the one job
// in that workflow whose binary can actually execute on the runner). Drives
// the bridge exactly the way PHPWorker.swift will once it's wired into the
// app: one bridge_startup(), then multiple execute() calls in the same
// process without re-running startup, proving the persistent-worker request
// loop (not just a single one-shot script run) actually works.
//
// fixtures/smoke.php and ../outside/secret.txt (a TRUE sibling of fixtures/,
// not a subdirectory of it -- see that fixture's own doc comment for a bug
// this once hid) are the request/response mapping and
// open_basedir/disable_functions checks made concrete (requests A/B);
// fixtures/sqlite.php proves pdo_sqlite/sqlite3 actually work (request C);
// fixtures/session.php proves a session persists across requests (requests
// D/E); fixtures/warning.php proves a runtime warning is captured into
// diagnostic_log without leaking into the response body (request F);
// fixtures/security.php is the compatibility/security test suite
// (docs/ROADMAP.md's v0.4 deliverable): disabled functions, blocked
// open_basedir escapes via several different functions, allow_url_fopen/
// allow_url_include off, and the extension allowlist (request G);
// fixtures/upload.php proves a real multipart/form-data body populates
// $_FILES and move_uploaded_file() works within open_basedir (request H).
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
    const char *uploads_dir = "/tmp/iserve_bridge_smoke_test_uploads";
    mkdir(uploads_dir, 0700); // Best-effort: PHP's rfc1867 upload handling never creates upload_tmp_dir itself either.

    if (iserve_php_bridge_startup(5, 64 * 1024 * 1024, sessions_dir, uploads_dir) != 0) {
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

    // Request G: exercises fixtures/security.php -- the ROADMAP's
    // "compatibility/security test suite" deliverable. Every disabled
    // function individually (disable_functions has no glob support, so a
    // typo/omission in any one name is its own independent gap), a real
    // open_basedir escape via several different filesystem functions (not
    // just file_get_contents, already covered by request A), allow_url_fopen/
    // allow_url_include both off, FFI absent, and the smaller allowlisted
    // extensions (json/mbstring/hash/filter) present.
    char security_script_filename[1024];
    snprintf(security_script_filename, sizeof(security_script_filename), "%s/security.php", fixtures_dir);
    iserve_php_request_t request_g = {0};
    request_g.method = "GET";
    request_g.uri = "/security.php";
    request_g.script_filename = security_script_filename;
    request_g.document_root = fixtures_dir;

    iserve_php_result_t result_g;
    iserve_php_execute(&request_g, &result_g);

    check(result_g.startup_diagnostic == NULL, "request G: no startup diagnostic");
    static const char *disabled_functions[] = {
        "exec", "shell_exec", "system", "popen", "proc_open", "proc_close", "dl", "ini_set", "ini_alter", "set_time_limit"
    };
    for (size_t i = 0; i < sizeof(disabled_functions) / sizeof(disabled_functions[0]); i++) {
        char expected[128];
        snprintf(expected, sizeof(expected), "disabled_%s=disabled\n", disabled_functions[i]);
        char description[160];
        snprintf(description, sizeof(description), "request G: %s is disabled", disabled_functions[i]);
        check(body_contains(&result_g, expected), description);
    }
    check(body_contains(&result_g, "allow_url_fopen_blocked=yes\n"), "request G: allow_url_fopen blocks a remote file_get_contents");
    check(body_contains(&result_g, "allow_url_include_blocked=yes\n"), "request G: allow_url_include blocks a remote include");
    check(body_contains(&result_g, "fopen_blocked=yes\n"), "request G: open_basedir blocks fopen() escape");
    check(body_contains(&result_g, "is_readable_blocked=yes\n"), "request G: open_basedir blocks is_readable() escape");
    check(body_contains(&result_g, "opendir_blocked=yes\n"), "request G: open_basedir blocks opendir() escape");
    check(body_contains(&result_g, "scandir_blocked=yes\n"), "request G: open_basedir blocks scandir() escape");
    check(body_contains(&result_g, "ffi_unavailable=unavailable\n"), "request G: FFI is not compiled in");
    check(body_contains(&result_g, "extension_json_available=yes\n"), "request G: json extension available");
    check(body_contains(&result_g, "extension_mbstring_available=yes\n"), "request G: mbstring extension available");
    check(body_contains(&result_g, "extension_hash_available=yes\n"), "request G: hash extension available");
    check(body_contains(&result_g, "extension_filter_available=yes\n"), "request G: filter extension available");

    iserve_php_free_result(&result_g);

    // Request H: exercises fixtures/upload.php -- the ROADMAP's "$_FILES
    // uploads through PHP" v0.4 deliverable. A real, hand-built
    // multipart/form-data body (RFC 1867/2046), so this proves PHP's own
    // multipart parsing actually fires through our custom SAPI's
    // read_post callback (not something the bridge implements itself),
    // that upload_tmp_dir (configured above, outside this request's own
    // open_basedir -- see iserve_php_bridge_startup's own doc comment for
    // why that's fine) is where the temp file lands, and that
    // move_uploaded_file() can move it into fixtures_dir (this request's
    // document_root/open_basedir).
    char upload_script_filename[1024];
    snprintf(upload_script_filename, sizeof(upload_script_filename), "%s/upload.php", fixtures_dir);

    static const char multipart_body[] =
        "--iServeTestBoundary123\r\n"
        "Content-Disposition: form-data; name=\"file\"; filename=\"hello.txt\"\r\n"
        "Content-Type: text/plain\r\n"
        "\r\n"
        "hello from upload\r\n"
        "--iServeTestBoundary123--\r\n";

    iserve_php_request_t request_h = {0};
    request_h.method = "POST";
    request_h.uri = "/upload.php";
    request_h.body = (const unsigned char *)multipart_body;
    request_h.body_length = sizeof(multipart_body) - 1; // exclude the trailing NUL
    request_h.content_type = "multipart/form-data; boundary=iServeTestBoundary123";
    request_h.script_filename = upload_script_filename;
    request_h.document_root = fixtures_dir;

    iserve_php_result_t result_h;
    iserve_php_execute(&request_h, &result_h);

    check(result_h.startup_diagnostic == NULL, "request H: no startup diagnostic");
    check(body_contains(&result_h, "files_isset=yes\n"), "request H: $_FILES populated from a real multipart upload");
    check(body_contains(&result_h, "upload_error=0\n"), "request H: upload_error is UPLOAD_ERR_OK");
    check(body_contains(&result_h, "is_uploaded_file=yes\n"), "request H: is_uploaded_file() recognizes the temp file");
    check(body_contains(&result_h, "move_uploaded_file=yes\n"), "request H: move_uploaded_file() succeeds into this request's own document_root");
    check(body_contains(&result_h, "moved_content=hello from upload\n"), "request H: the moved file's content matches what was uploaded");

    iserve_php_free_result(&result_h);

    iserve_php_bridge_shutdown();

    if (g_failures > 0) {
        fprintf(stderr, "%d check(s) failed\n", g_failures);
        return 1;
    }
    fprintf(stderr, "all checks passed\n");
    return 0;
}
