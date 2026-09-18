// Implementation notes (verified against the real php-8.4.2 source before
// writing this, not from memory — see the commit this file was introduced
// in for the exact files checked):
//
// - sapi_activate() (main/SAPI.c) only calls sapi_module.read_cookies() and
//   only runs POST-body reading when SG(server_context) is non-NULL. We set
//   it to a nonzero placeholder before every php_request_startup() call for
//   exactly this reason — leaving it NULL silently drops $_COOKIE and
//   $_POST on every request, with no error.
// - Anything handed to PHP that must survive past the point our own capture
//   buffers are read back (i.e. anything PHP itself owns/frees, like
//   read_cookies()'s return value) has to come from Zend's own per-request
//   allocator (estrdup/emalloc), which is automatically swept at
//   php_request_shutdown(). Anything WE own and read back after that sweep
//   (the captured response body and headers) must instead be plain
//   malloc'd, never emalloc'd, or it would already be freed by the time
//   iserve_php_execute() returns it to the caller.
// - zend_file_handle needs `primary_script = 1` set by hand after
//   zend_stream_init_filename() — confirmed against sapi/cli/php_cli.c's
//   own usage, since the init helper itself doesn't set it.
#include "include/iserve_php_bridge.h"

#include <sapi/embed/php_embed.h>
#include <Zend/zend_stream.h>
#include <string.h>
#include <stdlib.h>

// Function-pointer SAPI callbacks take no user-data argument, and every
// call into this bridge is serialized (ADR-0009's single PHP-worker-actor
// design — see iserve_php_bridge.h), so plain process-lifetime statics are
// safe: there is never more than one request in flight.
typedef struct {
    unsigned char *bytes;
    size_t length;
    size_t capacity;
} iserve_growable_buffer_t;

typedef struct {
    iserve_php_header_t *items;
    size_t count;
    size_t capacity;
} iserve_growable_headers_t;

static iserve_growable_buffer_t g_capture_body;
static iserve_growable_headers_t g_capture_headers;
static const unsigned char *g_post_body;
static size_t g_post_body_length;
static size_t g_post_body_offset;
static const char *g_cookie_header;
static const char *g_remote_addr;

static char g_ini_entries[2048];

static void iserve_reset_capture(void)
{
    free(g_capture_body.bytes);
    for (size_t i = 0; i < g_capture_headers.count; i++) {
        free(g_capture_headers.items[i].name);
        free(g_capture_headers.items[i].value);
    }
    free(g_capture_headers.items);
    memset(&g_capture_body, 0, sizeof(g_capture_body));
    memset(&g_capture_headers, 0, sizeof(g_capture_headers));
}

static void iserve_append_body(const char *str, size_t str_length)
{
    if (g_capture_body.length + str_length > g_capture_body.capacity) {
        size_t new_capacity = g_capture_body.capacity ? g_capture_body.capacity * 2 : 4096;
        while (new_capacity < g_capture_body.length + str_length) {
            new_capacity *= 2;
        }
        unsigned char *grown = realloc(g_capture_body.bytes, new_capacity);
        if (!grown) {
            return; // Out of memory: drop the overflow rather than crash the worker.
        }
        g_capture_body.bytes = grown;
        g_capture_body.capacity = new_capacity;
    }
    memcpy(g_capture_body.bytes + g_capture_body.length, str, str_length);
    g_capture_body.length += str_length;
}

static size_t iserve_ub_write(const char *str, size_t str_length)
{
    iserve_append_body(str, str_length);
    return str_length;
}

static void iserve_flush(void *server_context)
{
    (void)server_context;
}

static void iserve_send_header(sapi_header_struct *sapi_header, void *server_context)
{
    (void)server_context;
    if (!sapi_header || !sapi_header->header) {
        return;
    }
    // sapi_header->header is a full "Name: value" line, not pre-split.
    const char *colon = memchr(sapi_header->header, ':', sapi_header->header_len);
    if (!colon) {
        return;
    }
    size_t name_len = (size_t)(colon - sapi_header->header);
    const char *value_start = colon + 1;
    size_t value_len = sapi_header->header_len - name_len - 1;
    while (value_len > 0 && *value_start == ' ') {
        value_start++;
        value_len--;
    }

    if (g_capture_headers.count == g_capture_headers.capacity) {
        size_t new_capacity = g_capture_headers.capacity ? g_capture_headers.capacity * 2 : 8;
        iserve_php_header_t *grown = realloc(g_capture_headers.items, new_capacity * sizeof(iserve_php_header_t));
        if (!grown) {
            return;
        }
        g_capture_headers.items = grown;
        g_capture_headers.capacity = new_capacity;
    }

    iserve_php_header_t *entry = &g_capture_headers.items[g_capture_headers.count];
    entry->name = malloc(name_len + 1);
    entry->value = malloc(value_len + 1);
    if (!entry->name || !entry->value) {
        free(entry->name);
        free(entry->value);
        return;
    }
    memcpy(entry->name, sapi_header->header, name_len);
    entry->name[name_len] = '\0';
    memcpy(entry->value, value_start, value_len);
    entry->value[value_len] = '\0';
    g_capture_headers.count++;
}

static size_t iserve_read_post(char *buffer, size_t count_bytes)
{
    size_t remaining = g_post_body_length - g_post_body_offset;
    size_t to_copy = count_bytes < remaining ? count_bytes : remaining;
    if (to_copy > 0) {
        memcpy(buffer, g_post_body + g_post_body_offset, to_copy);
        g_post_body_offset += to_copy;
    }
    return to_copy;
}

static char *iserve_read_cookies(void)
{
    // Must be Zend-arena allocated (estrdup, not strdup/malloc): PHP treats
    // this as memory it owns for the life of the request and never frees it
    // itself, relying on the request-end arena sweep instead (see the
    // file-level note above).
    if (!g_cookie_header) {
        return NULL;
    }
    return estrdup(g_cookie_header);
}

static void iserve_register_server_variables(zval *track_vars_array)
{
    php_import_environment_variables(track_vars_array);
    if (SG(request_info).request_method) {
        php_register_variable("REQUEST_METHOD", SG(request_info).request_method, track_vars_array);
    }
    if (SG(request_info).query_string) {
        php_register_variable("QUERY_STRING", SG(request_info).query_string, track_vars_array);
    }
    if (SG(request_info).request_uri) {
        php_register_variable("REQUEST_URI", SG(request_info).request_uri, track_vars_array);
    }
    if (SG(request_info).path_translated) {
        php_register_variable("SCRIPT_FILENAME", SG(request_info).path_translated, track_vars_array);
        php_register_variable("PATH_TRANSLATED", SG(request_info).path_translated, track_vars_array);
    }
    if (SG(request_info).content_type) {
        php_register_variable("CONTENT_TYPE", SG(request_info).content_type, track_vars_array);
    }
    char content_length[32];
    snprintf(content_length, sizeof(content_length), "%ld", (long)SG(request_info).content_length);
    php_register_variable("CONTENT_LENGTH", content_length, track_vars_array);
    php_register_variable("SERVER_PROTOCOL", "HTTP/1.1", track_vars_array);
    php_register_variable("SERVER_SOFTWARE", "iServe", track_vars_array);
    php_register_variable("GATEWAY_INTERFACE", "CGI/1.1", track_vars_array);
    if (g_remote_addr) {
        php_register_variable("REMOTE_ADDR", g_remote_addr, track_vars_array);
    }
}

static void iserve_log_message(const char *message, int syslog_type_int)
{
    (void)syslog_type_int;
    fprintf(stderr, "[iServe PHP] %s\n", message);
}

static int iserve_startup(sapi_module_struct *sapi_module)
{
    return php_module_startup(sapi_module, NULL);
}

static int iserve_deactivate(void)
{
    return SUCCESS;
}

static sapi_module_struct iserve_sapi_module = {
    "iserve",                          /* name */
    "iServe Embedded PHP",             /* pretty name */

    iserve_startup,                    /* startup */
    php_module_shutdown_wrapper,       /* shutdown */

    NULL,                              /* activate */
    iserve_deactivate,                 /* deactivate */

    iserve_ub_write,                   /* unbuffered write */
    iserve_flush,                      /* flush */
    NULL,                              /* get uid */
    NULL,                              /* getenv */

    php_error,                         /* error handler */

    NULL,                              /* header handler */
    NULL,                              /* send headers handler */
    iserve_send_header,                /* send header handler */

    iserve_read_post,                  /* read POST data */
    iserve_read_cookies,               /* read Cookies */

    iserve_register_server_variables,  /* register server variables */
    iserve_log_message,                /* Log message */
    NULL,                              /* Get request time */
    NULL,                              /* Child terminate */

    STANDARD_SAPI_MODULE_PROPERTIES
};

int iserve_php_bridge_startup(int max_execution_time_seconds, long memory_limit_bytes, const char *session_save_path)
{
    // pcntl_*/posix_* are not covered here because they are simply not
    // compiled in at all (excluded from ADR-0009's extension allowlist) —
    // disable_functions only accepts exact, literal function names, it has
    // no glob/prefix support, so it cannot list a whole extension's
    // functions by pattern the way the ADR's prose shorthand implies.
    // ini_set/ini_alter/set_time_limit are disabled because open_basedir,
    // display_errors and max_execution_time are all PHP_INI_ALL — without
    // blocking the setter functions themselves, a script could widen or
    // remove every one of those restrictions at runtime via ini_set().
    snprintf(g_ini_entries, sizeof(g_ini_entries),
        "html_errors=0\n"
        "display_errors=0\n"
        "log_errors=1\n"
        "implicit_flush=0\n"
        "output_buffering=0\n"
        "register_argc_argv=0\n"
        "expose_php=0\n"
        "enable_dl=0\n"
        "allow_url_fopen=0\n"
        "allow_url_include=0\n"
        "open_basedir=\n"
        "max_execution_time=%d\n"
        "max_input_time=%d\n"
        "memory_limit=%ld\n"
        "session.save_path=%s\n"
        "disable_functions=exec,shell_exec,system,popen,proc_open,proc_close,dl,ini_set,ini_alter,set_time_limit\n",
        max_execution_time_seconds,
        max_execution_time_seconds,
        memory_limit_bytes,
        session_save_path ? session_save_path : "");

    sapi_startup(&iserve_sapi_module);
    iserve_sapi_module.ini_entries = g_ini_entries;

    if (iserve_sapi_module.startup(&iserve_sapi_module) == FAILURE) {
        return 1;
    }
    SG(options) |= SAPI_OPTION_NO_CHDIR;
    return 0;
}

void iserve_php_bridge_shutdown(void)
{
    php_module_shutdown();
    sapi_shutdown();
}

void iserve_php_execute(const iserve_php_request_t *request, iserve_php_result_t *out_result)
{
    memset(out_result, 0, sizeof(*out_result));
    iserve_reset_capture();

    g_post_body = request->body;
    g_post_body_length = request->body_length;
    g_post_body_offset = 0;
    g_cookie_header = request->cookie_header;
    g_remote_addr = request->remote_addr;

    // These three are borrowed straight from `request` rather than
    // estrdup'd: neither SAPI.c nor main.c ever efree()s
    // request_info.{query_string,request_uri,path_translated}, and
    // Zend's per-request allocator arena (what estrdup/emalloc use) isn't
    // activated until zend_activate() runs *inside* php_request_startup()
    // below — calling estrdup this early would allocate into whatever
    // arena happened to be active from the previous request, not this
    // one. `request` is guaranteed valid for this whole call per this
    // bridge's borrowing contract, so a direct (const-cast) pointer is
    // both simpler and correct here; only read_cookies() below needs a
    // real copy, and it runs at the right time to make one safely.
    SG(server_context) = (void *)1; // Must be nonzero: see the file-level note on sapi_activate().
    SG(request_info).request_method = request->method;
    SG(request_info).query_string = (char *)request->query_string;
    SG(request_info).request_uri = (char *)request->uri;
    SG(request_info).path_translated = (char *)request->script_filename;
    SG(request_info).content_type = request->content_type;
    SG(request_info).content_length = (zend_long)request->body_length;
    SG(request_info).proto_num = 1001;

    if (php_request_startup() == FAILURE) {
        out_result->startup_diagnostic = strdup("php_request_startup failed");
        return;
    }

    zend_string *open_basedir_name = zend_string_init("open_basedir", sizeof("open_basedir") - 1, 0);
    zend_alter_ini_entry_chars(open_basedir_name, request->document_root, strlen(request->document_root),
        PHP_INI_SYSTEM, PHP_INI_STAGE_ACTIVATE);
    zend_string_release(open_basedir_name);

    zend_file_handle file_handle;
    zend_stream_init_filename(&file_handle, request->script_filename);
    file_handle.primary_script = 1;

    php_execute_script(&file_handle);

    zend_destroy_file_handle(&file_handle);

    int status_code = SG(sapi_headers).http_response_code;
    php_request_shutdown(NULL);

    out_result->status_code = status_code > 0 ? status_code : 200;

    // Transfer ownership of the capture buffers to out_result; the caller
    // frees them via iserve_php_free_result(). g_capture_body/g_capture_headers
    // are left pointing at freed-by-transfer memory until the next
    // iserve_reset_capture() call zeroes them out again.
    out_result->body = g_capture_body.bytes;
    out_result->body_length = g_capture_body.length;
    out_result->headers = g_capture_headers.items;
    out_result->header_count = g_capture_headers.count;
    memset(&g_capture_body, 0, sizeof(g_capture_body));
    memset(&g_capture_headers, 0, sizeof(g_capture_headers));
}

void iserve_php_free_result(iserve_php_result_t *result)
{
    free(result->body);
    for (size_t i = 0; i < result->header_count; i++) {
        free(result->headers[i].name);
        free(result->headers[i].value);
    }
    free(result->headers);
    free(result->startup_diagnostic);
    memset(result, 0, sizeof(*result));
}
