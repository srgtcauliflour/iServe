// Whether PHP scripts may make ANY outbound network connection this
// session (docs/adr/0010-php-outbound-networking.md's "Consent: a
// separate toggle" -- off by default, layered on top of, and never
// implied by, phpExecutionEnabled, exactly like ServerCoordinator.swift's
// own phpExecutionEnabled is layered on top of profile).
//
// Distinct from iserve_outbound_policy.c's denylist: that decides WHICH
// addresses are reachable once outbound networking is allowed at all.
// This decides whether it's allowed at all -- when disabled (the
// default), iserve_curl_open_socket() (injected directly into php-src's
// own ext/curl/interface.c by PHP/Bridge/patches/curl_setopt_ssrf_guard.py)
// refuses every destination, not just denylisted ones, with the same
// CURLE_COULDNT_CONNECT either way, so a script can never use the failure
// itself to tell "the feature is off" apart from "that specific address
// is denied" (ADR-0010's "remote error behavior" rule).
//
// Set exactly once per session, at iserve_php_bridge_startup() (mirrors
// ServerCoordinator.swift's own "changing this while running has no
// effect on the current session" rule for phpExecutionEnabled), then read
// concurrently by every outbound connection attempt for the life of the
// session -- a plain _Atomic int, since this is genuinely shared,
// write-once/read-many session state.
#ifndef ISERVE_OUTBOUND_TOGGLE_H
#define ISERVE_OUTBOUND_TOGGLE_H

void iserve_outbound_networking_set_enabled(int enabled);
int iserve_outbound_networking_is_enabled(void);

#endif // ISERVE_OUTBOUND_TOGGLE_H
