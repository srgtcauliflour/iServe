// A single, narrow hook letting iserve_outbound_interpose.c (Apple-specific,
// cannot touch Zend/PHP engine state safely from inside an interposed libc
// call) report a blocked outbound connection into the current request's
// existing diagnostic log, implemented in iserve_php_bridge.c where that
// log's own capture buffer already lives.
#ifndef ISERVE_OUTBOUND_DIAGNOSTICS_H
#define ISERVE_OUTBOUND_DIAGNOSTICS_H

#ifdef __cplusplus
extern "C" {
#endif

// Appends a short, fixed, non-sensitive message to the current request's
// diagnostic log (surfaced via iserve_php_result_t.diagnostic_log -- the
// same PHPDiagnosticsLog pipeline v0.4 already established). Deliberately
// never includes the actual destination address: ADR-0010's "remote error
// behavior" rule is that a script's own curl_error() must never be able to
// fingerprint what's on the other side of a block, and the diagnostics
// console is for the person running iServe, not something a script can
// read back -- the distinction is about audience, not about naming the
// address here being otherwise harmless. Safe to call from inside the
// interposed connect() itself: only appends to a plain malloc'd buffer, no
// Zend/PHP engine state touched, matching the same safety bar
// iserve_log_message already meets for an ordinary PHP warning.
void iserve_outbound_report_blocked(void);

#ifdef __cplusplus
}
#endif

#endif // ISERVE_OUTBOUND_DIAGNOSTICS_H
