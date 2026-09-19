// iServe's C bridge onto PHP's embed SAPI (sapi/embed/php_embed.h).
//
// This is a *custom* SAPI module, not the stock `php_embed_module` from
// php_embed.c: the stock one writes straight to the process's real stdout
// and drops every header on the floor (its `send_header` is a no-op), which
// is fine for a one-shot CLI-style embed but useless for something that has
// to hand an HTTP response back to a caller. `iserve_php_bridge.c` defines
// its own `sapi_module_struct` that captures output/headers/status into
// plain-malloc'd buffers instead.
//
// Threading contract: every function here must be called from exactly one
// thread, one call at a time, start-to-finish — this mirrors ADR-0009's
// single PHP-worker-actor design (PHP's interpreter globals are not safe to
// touch from more than one place at once). `iserve_php_bridge_startup()`
// runs PHP's module startup (MINIT) once for the life of the process;
// `iserve_php_execute()` then runs any number of requests in sequence
// without re-running MINIT (re-running full module startup per request —
// reloading pdo_sqlite, session, etc. every time — would be far too slow
// for a server). `iserve_php_bridge_shutdown()` runs module shutdown once,
// at process exit.
#ifndef ISERVE_PHP_BRIDGE_H
#define ISERVE_PHP_BRIDGE_H

#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct {
    char *name;
    char *value;
} iserve_php_header_t;

// Everything here is borrowed by iserve_php_execute() for the duration of
// the call only — the bridge never retains a pointer past that call
// returning, so the caller can free/reuse these buffers immediately after.
typedef struct {
    const char *method;             // "GET", "POST", ... (required)
    const char *uri;                // request-target sent to PHP as REQUEST_URI, e.g. "/index.php?x=1" (required)
    const char *query_string;       // may be NULL/empty
    const unsigned char *body;      // raw request body; may be NULL
    size_t body_length;
    const char *content_type;       // may be NULL
    const char *remote_addr;        // may be NULL
    const char *cookie_header;      // raw Cookie: header value; may be NULL
    const char *script_filename;    // absolute path to the .php file to run (required)
    const char *document_root;      // absolute path; becomes this request's open_basedir (required)
} iserve_php_request_t;

typedef struct {
    int status_code;                // e.g. 200
    iserve_php_header_t *headers;   // owned by this result; see iserve_php_free_result
    size_t header_count;
    unsigned char *body;
    size_t body_length;
    // Set only when PHP itself failed to run the script at all (e.g. the
    // file couldn't be opened) — never populated from script output or
    // PHP errors/warnings, which always stay out of the response per
    // ADR-0009's "remote error behavior" (display_errors is always off).
    // For diagnostics only; never send this string to the HTTP client.
    char *startup_diagnostic;
    // Every message this request passed to the SAPI's log_message hook —
    // PHP warnings/notices/uncaught-exception fatals (log_errors=1 in the
    // bridge's own ini, so php_error_cb routes them here since no
    // error_log path is configured), newline-joined, oldest first, bounded
    // to a fixed size (see ISERVE_DIAGNOSTIC_LOG_CAPACITY in the .c file) so
    // a script that errors in a loop can't grow this unboundedly. NULL when
    // nothing was logged this request. Same rule as startup_diagnostic:
    // ADR-0009's "remote error behavior" — for on-device diagnostics only,
    // never sent to the HTTP client.
    char *diagnostic_log;
} iserve_php_result_t;

// Runs PHP's module startup once for this process, applying ADR-0009's
// resource limits and hardened defaults (disable_functions, display_errors
// off, allow_url_fopen/allow_url_include off, no dynamic extension loading).
// `open_basedir` starts empty and is narrowed to each request's own
// document_root inside iserve_php_execute() — it is never a startup
// parameter, since it varies per request/mount.
//
// - max_execution_time_seconds: PHP's own max_execution_time, enforced by
//   its interrupt-tick timer. `set_time_limit()` is unconditionally
//   disabled (see iserve_php_bridge.c) so a script cannot widen this at
//   runtime; note this is PHP's own cooperative timeout mechanism, not an
//   external watchdog — a script that manages to starve PHP's own tick
//   handler is a known residual gap, not yet closed by this bridge.
// - memory_limit_bytes: PHP's memory_limit, in bytes.
// - session_save_path: absolute path under the app's own container (never
//   under a served folder) for session files; may be NULL to leave
//   sessions using PHP's compiled-in default, which callers should not
//   rely on.
// - upload_tmp_dir: absolute path under the app's own container (never
//   under a served folder, same reasoning as session_save_path) where a
//   $_FILES upload's temporary file is written by PHP's own rfc1867
//   multipart handling. Explicitly setting this (rather than leaving PHP
//   to fall back to its own system-temp-directory guess) is what makes
//   $_FILES uploads work at all in a predictable, sandboxed location --
//   see the .c file's own note on why this path is deliberately exempt
//   from open_basedir (PHP only enforces open_basedir on this directory
//   when it's the *fallback*, never when explicitly configured, matching
//   every other SAPI's own behavior). May be NULL to leave PHP's own
//   fallback in effect, which callers should not rely on -- same caveat
//   as session_save_path.
//
// Returns 0 on success, nonzero on failure. Must be called exactly once,
// before any call to iserve_php_execute().
int iserve_php_bridge_startup(int max_execution_time_seconds, long memory_limit_bytes, const char *session_save_path, const char *upload_tmp_dir);

// Runs PHP's module shutdown once for this process. Must be called exactly
// once, after every call to iserve_php_execute() has returned, and never
// followed by another call to iserve_php_bridge_startup() in the same
// process (PHP's module shutdown is not designed to be re-entered).
void iserve_php_bridge_shutdown(void);

// Runs exactly one request to completion: PHP request startup (RINIT),
// script execution with open_basedir narrowed to `request->document_root`,
// then request shutdown (RSHUTDOWN). `out_result` is zero-initialized by
// this call; the caller must pass iserve_php_free_result(out_result) when
// done with it, exactly once.
void iserve_php_execute(const iserve_php_request_t *request, iserve_php_result_t *out_result);

void iserve_php_free_result(iserve_php_result_t *result);

#ifdef __cplusplus
}
#endif

#endif // ISERVE_PHP_BRIDGE_H
