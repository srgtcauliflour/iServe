// A single, process-lifetime flag marking "a PHP script is currently
// executing" -- the gate the interposed connect() (iserve_outbound_interpose.c,
// Apple-specific) checks before ever consulting the denylist
// (iserve_outbound_policy.h, portable). Kept in its own portable file,
// separate from both of those: this flag's own begin/end/is-active logic has
// nothing platform-specific about it and is fully unit-testable on any host,
// independent of whether DYLD_INTERPOSE itself can be exercised there.
#ifndef ISERVE_OUTBOUND_GUARD_H
#define ISERVE_OUTBOUND_GUARD_H

#ifdef __cplusplus
extern "C" {
#endif

// Call immediately before running PHP script code that might originate
// outbound connections, and iserve_outbound_guard_end() immediately after --
// see iserve_php_bridge.c's iserve_php_execute(), which scopes this tightly
// around its own php_execute_script() call specifically (RINIT/RSHUTDOWN
// never make network calls, so including them in the window would only
// widen it without reason).
//
// Thread-local, deliberately: PHPWorker (the Swift caller) is an actor, and
// Swift's cooperative thread pool does not pin a given actor's synchronous
// C call to the same OS thread across separate invocations, nor does it
// promise that thread is otherwise idle -- iserve_php_bridge.h's own
// "exactly one thread, one call at a time, start-to-finish" contract is
// about PHP's own interpreter state, not a claim that nothing else in this
// process ever runs concurrently with it. This app's own HTTPServer gives
// every connection its own concurrently-running actor (ADR-0009), and
// Bonjour/Network.framework can originate its own connect() calls on its
// own threads at any time. A single process-wide (non-thread-local) flag
// here would let an unrelated connect() on a *different* thread get
// wrongly checked against the denylist for as long as the one PHP worker
// thread's own call happens to be running concurrently elsewhere -- thread-
// local storage means only the OS thread actually inside this specific,
// synchronous iserve_php_execute() call ever sees the flag as active, and
// every other thread's own connect() calls are completely unaffected
// regardless of what's running concurrently. Safe without its own
// synchronization: nothing but the thread that sets it ever reads it.
void iserve_outbound_guard_begin(void);
void iserve_outbound_guard_end(void);

// Returns nonzero if a guarded window (begin called, end not yet called) is
// currently active. Outside such a window -- this app's own HTTPServer,
// Bonjour, or any other non-PHP-originated connection -- the interposed
// connect() passes straight through to the real implementation, completely
// unaffected by anything in this file.
int iserve_outbound_guard_is_active(void);

#ifdef __cplusplus
}
#endif

#endif // ISERVE_OUTBOUND_GUARD_H
