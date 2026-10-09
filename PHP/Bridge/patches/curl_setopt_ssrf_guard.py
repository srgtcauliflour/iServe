#!/usr/bin/env python3
# A small, tracked patch to php-src's ext/curl/interface.c
# (docs/adr/0010-php-outbound-networking.md) -- applied the same way
# ADR-0009's own ext/standard/config.m4 patch already is: in CI, against a
# fresh upstream checkout, never a maintained fork of the file. Run as
# `python3 curl_setopt_ssrf_guard.py <path-to-interface.c>` from within the
# php-src checkout, before ./buildconf.
#
# SSRF/local-network/DNS-rebinding defense: every handle gets
# CURLOPT_OPENSOCKETFUNCTION set (in _php_curl_set_default_options(), the
# one place both curl_init() and curl_copy_handle() already funnel every
# handle through) to iserve_curl_open_socket(), a small function this patch
# also injects directly into this file. curl calls that function in place
# of its own socket()+connect() for every socket it needs -- including a
# redirect's own follow-up connection -- passing the REAL, already-resolved
# struct sockaddr it's about to use. iserve_curl_open_socket() checks that
# address against iserve_outbound_policy.c's denylist (and whether outbound
# networking is enabled at all, iserve_outbound_toggle.c) and returns
# CURL_SOCKET_BAD to refuse it, or a real socket() to let curl proceed --
# this IS the check at "the moment of the real connection attempt, on the
# resolved address actually being connected to" docs/adr/0010 requires, no
# different in effect from intercepting connect() itself, just through a
# documented libcurl extension point instead of OS-level symbol
# interposition.
#
# That's a correction from this project's own first implementation, not
# the original design: ADR-0010 originally called for DYLD_INTERPOSE'ing
# connect() (iserve_outbound_interpose.c, since removed). A real macOS CI
# run proved that approach fundamentally cannot work the way it was built:
# checked directly against Apple's own open-source dyld
# (apple-oss-distributions/dyld, RuntimeState.cpp's buildInterposingTables()),
# dyld only processes a __DATA,__interpose section from a loaded *dylib* --
# `if (!hdr->isDylib()) continue;` skips the main executable outright. Every
# iServe target (iserve_bridge_smoke_test, and the real iServeWithPHP app)
# links iserve_outbound_interpose.c directly into its own main executable,
# never a separate dylib, so dyld never even looked at its interpose
# section -- confirmed by a real CI run where a request through the actual
# linked bridge+curl build reached a real public address outbound
# networking's off-by-default state should have refused. The
# CURLOPT_OPENSOCKETFUNCTION approach has no such restriction (it's a
# plain function pointer curl calls directly, no dyld involvement at all),
# and is portable enough to verify for real on any platform this project's
# own sandbox can build curl on, closing a verification gap the interposed-
# connect() approach could never close outside real macOS CI.
#
# Also closes the ways a script's own curl_setopt() calls could otherwise
# route around that check or the response-size cap below, the same
# "the bridge decides, the script cannot un-decide" posture as
# disable_functions/open_basedir:
#
# 1. CURLOPT_CONNECTTIMEOUT/CURLOPT_CONNECTTIMEOUT_MS/CURLOPT_TIMEOUT/
#    CURLOPT_TIMEOUT_MS/CURLOPT_MAXREDIRS are clamped, never widened, to a
#    fixed ceiling -- a hung request or an unbounded redirect chain must
#    not be able to hold the single PHP worker open indefinitely.
# 2. CURLOPT_DNS_SERVERS/CURLOPT_INTERFACE are silently ignored: either
#    could let a script route around the open-socket check (pre-seeding
#    its own DNS resolution, or binding to a specific interface).
# 3. CURLOPT_RESOLVE/CURLOPT_CONNECT_TO are silently ignored for the same
#    reason -- both let a script pre-seed its own hostname-to-address
#    mapping, which is exactly the kind of check-time/connect-time
#    mismatch DNS rebinding already exploits.
#
# "Silently ignored" is deliberate, not an oversight: curl_setopt() still
# returns true, same as a real success, so a script can't use the
# function's own return value to detect that this policy exists at all --
# matching ADR-0010's "remote error behavior" rule that a script must never
# be able to fingerprint what's being protected against.
#
# CURLOPT_OPENSOCKETFUNCTION and CURLOPT_SOCKOPTFUNCTION themselves need no
# such patch to stay script-proof: checked directly against the real
# php-8.4.2 source, neither has a case label in _php_curl_setopt()'s switch
# statement in the first place, so a script calling curl_setopt() with
# either already hits the default "not a valid cURL option" branch and
# gets a ValueError -- meaning a script cannot replace the callback this
# patch installs, full stop, not even via a silently-ignored-but-accepted
# call.
#
# Also enforces ADR-0010's resource-bounds section, response-size half:
# every handle gets a running-total byte-ceiling check injected via
# CURLOPT_XFERINFOFUNCTION in _php_curl_set_default_options() (the one
# place both curl_init() and curl_copy_handle() already funnel through),
# since curl's own CURLOPT_MAXFILESIZE only bounds a response with a known
# Content-Length -- a chunked or otherwise unbounded stream has none. A
# script cannot disable this (CURLOPT_PROGRESSFUNCTION/
# CURLOPT_XFERINFOFUNCTION/CURLOPT_NOPROGRESS are silently ignored, same
# "curl_setopt() still returns true" pattern as every other blocked option
# here) or inherit a higher-than-intended CURLOPT_MAXREDIRS from the
# unset default (lowered from php-src's own built-in 20 to this project's
# own clamp ceiling of 10, so an unset default and an explicitly-clamped
# value agree). The companion resource-bounds half -- disabling the 11
# curl_multi_* functions -- needs no patch to this file at all: they're
# ordinary PHP functions blockable by name, so that's done in
# iserve_php_bridge.c's own disable_functions ini string instead.
import sys

path = sys.argv[1]
with open(path) as f:
    content = f.read()

# Each (anchor, replacement) pair's anchor is real source text copied
# directly from php-8.4.2's own ext/curl/interface.c, not reconstructed
# from memory -- verified to appear in the file exactly once before this
# patch ever runs, and rechecked below after applying all three, so a
# future php-src version shifting this code produces a loud, specific CI
# failure here rather than a silent no-op patch.
replacements = [
    (
        "			lval = zval_get_long(zvalue);\n"
        "			if ((option == CURLOPT_PROTOCOLS || option == CURLOPT_REDIR_PROTOCOLS) &&",
        "			lval = zval_get_long(zvalue);\n"
        "			/* iServe (docs/adr/0010-php-outbound-networking.md): clamp, never widen,\n"
        "			 * a script's own timeout/redirect-limit options -- a hung request or an\n"
        "			 * unbounded redirect chain must not be able to hold the single PHP worker\n"
        "			 * open indefinitely. */\n"
        "			switch (option) {\n"
        "				case CURLOPT_CONNECTTIMEOUT:\n"
        "				case CURLOPT_TIMEOUT:\n"
        "					if (lval > 30) { lval = 30; }\n"
        "					break;\n"
        "				case CURLOPT_CONNECTTIMEOUT_MS:\n"
        "				case CURLOPT_TIMEOUT_MS:\n"
        "					if (lval > 30000) { lval = 30000; }\n"
        "					break;\n"
        "				case CURLOPT_MAXREDIRS:\n"
        "					if (lval > 10) { lval = 10; }\n"
        "					break;\n"
        "			}\n"
        "			if ((option == CURLOPT_PROTOCOLS || option == CURLOPT_REDIR_PROTOCOLS) &&"
    ),
    (
        "		case CURLOPT_PROTOCOLS_STR:\n"
        "		case CURLOPT_REDIR_PROTOCOLS_STR:\n"
        "#endif\n"
        "		{\n"
        "			zend_string *tmp_str;\n"
        "			zend_string *str = zval_get_tmp_string(zvalue, &tmp_str);",
        "		case CURLOPT_PROTOCOLS_STR:\n"
        "		case CURLOPT_REDIR_PROTOCOLS_STR:\n"
        "#endif\n"
        "		{\n"
        "			/* iServe (docs/adr/0010-php-outbound-networking.md): CURLOPT_DNS_SERVERS\n"
        "			 * and CURLOPT_INTERFACE could let a script route around the open-socket\n"
        "			 * check (binding to a specific interface, or pre-seeding its own\n"
        "			 * resolution) -- silently ignored, not an error, so a script can't\n"
        "			 * use the failure itself to detect this policy exists. */\n"
        "			if (option == CURLOPT_DNS_SERVERS || option == CURLOPT_INTERFACE) {\n"
        "				return SUCCESS;\n"
        "			}\n"
        "			zend_string *tmp_str;\n"
        "			zend_string *str = zval_get_tmp_string(zvalue, &tmp_str);"
    ),
    (
        "			struct curl_slist *slist = NULL;",
        "			struct curl_slist *slist = NULL;\n"
        "			/* iServe (docs/adr/0010-php-outbound-networking.md): CURLOPT_RESOLVE and\n"
        "			 * CURLOPT_CONNECT_TO could let a script pre-seed its own DNS resolution,\n"
        "			 * bypassing the open-socket check entirely -- silently ignored,\n"
        "			 * same reasoning as CURLOPT_DNS_SERVERS/CURLOPT_INTERFACE above. */\n"
        "			if (option == CURLOPT_RESOLVE || option == CURLOPT_CONNECT_TO) {\n"
        "				return SUCCESS;\n"
        "			}"
    ),
    (
        # Insert the SSRF-defense open-socket callback and the
        # response-size-cap xferinfo callback just above
        # _php_curl_set_default_options() -- the one function both
        # curl_init() and curl_copy_handle() already funnel every handle
        # through, so installing either callback there, rather than at
        # each call site, can't be missed for a handle created either way.
        "/* {{{ _php_curl_set_default_options()\n"
        "   Set default options for a handle */\n"
        "static void _php_curl_set_default_options(php_curl *ch)\n",
        "/* iServe (docs/adr/0010-php-outbound-networking.md): SSRF/local-\n"
        " * network/DNS-rebinding defense. curl calls this in place of its\n"
        " * own socket()+connect() for every socket it needs -- including a\n"
        " * redirect's own follow-up connection -- with the REAL, already-\n"
        " * resolved address it's about to use, which is the one sound\n"
        " * enforcement point: a hostname that resolves differently between\n"
        " * an earlier check and this moment (DNS rebinding) or a script\n"
        " * passing a literal IP instead of a hostname are both covered,\n"
        " * since neither changes what this callback actually sees.\n"
        " * iserve_outbound_is_denied_sockaddr()/iserve_outbound_networking_is_enabled()/\n"
        " * iserve_outbound_report_blocked() are declared here directly (not\n"
        " * via #include) rather than adding an -I flag to php-src's own\n"
        " * build for three single-purpose headers -- resolved at the final\n"
        " * link, same as php-src's own embed SAPI hooks already are, by\n"
        " * whichever iServe bridge object files that final link already\n"
        " * includes (PHP/Bridge/iserve_outbound_policy.c/iserve_outbound_toggle.c/\n"
        " * iserve_php_bridge.c). */\n"
        "#include <sys/socket.h>\n"
        "\n"
        "extern int iserve_outbound_is_denied_sockaddr(const struct sockaddr *addr, socklen_t addr_len);\n"
        "extern int iserve_outbound_networking_is_enabled(void);\n"
        "extern void iserve_outbound_report_blocked(void);\n"
        "\n"
        "static curl_socket_t iserve_curl_open_socket(void *clientp, curlsocktype purpose, struct curl_sockaddr *address)\n"
        "{\n"
        "\t(void) clientp;\n"
        "\t(void) purpose;\n"
        "\tif (!iserve_outbound_networking_is_enabled() ||\n"
        "\t    iserve_outbound_is_denied_sockaddr(&address->addr, (socklen_t) address->addrlen)) {\n"
        "\t\t/* A script must not be able to tell \"outbound networking is off\"\n"
        "\t\t * apart from \"that specific address is denied\" -- CURL_SOCKET_BAD\n"
        "\t\t * here produces the exact same CURLE_COULDNT_CONNECT a real,\n"
        "\t\t * ordinary connection-refused failure would (ADR-0010's \"remote\n"
        "\t\t * error behavior\" rule), the same outcome whichever reason applies. */\n"
        "\t\tiserve_outbound_report_blocked();\n"
        "\t\treturn CURL_SOCKET_BAD;\n"
        "\t}\n"
        "\treturn socket(address->family, address->socktype, address->protocol);\n"
        "}\n"
        "\n"
        "/* iServe (docs/adr/0010-php-outbound-networking.md): resource-bounds\n"
        " * section -- a running-total byte ceiling on every handle's response\n"
        " * body, enforced independently of Content-Length (a chunked or\n"
        " * otherwise unbounded stream may never send one). Returning nonzero\n"
        " * from curl's own xferinfo callback is libcurl's own documented way\n"
        " * to abort an in-progress transfer (CURLE_ABORTED_BY_CALLBACK),\n"
        " * rather than this project inventing its own early-abort protocol. */\n"
        "#define ISERVE_CURL_MAX_RESPONSE_BYTES (50 * 1024 * 1024)\n"
        "\n"
        "static int iserve_curl_xferinfo(void *clientp, curl_off_t dltotal, curl_off_t dlnow, curl_off_t ultotal, curl_off_t ulnow)\n"
        "{\n"
        "\t(void) clientp;\n"
        "\t(void) dltotal;\n"
        "\t(void) ultotal;\n"
        "\t(void) ulnow;\n"
        "\tif (dlnow > ISERVE_CURL_MAX_RESPONSE_BYTES) {\n"
        "\t\treturn 1;\n"
        "\t}\n"
        "\treturn 0;\n"
        "}\n"
        "\n"
        "/* {{{ _php_curl_set_default_options()\n"
        "   Set default options for a handle */\n"
        "static void _php_curl_set_default_options(php_curl *ch)\n"
    ),
    (
        # CURLOPT_NOPROGRESS must be 0 (not the stock default of 1) for
        # libcurl to invoke CURLOPT_XFERINFOFUNCTION at all -- so turning
        # the cap on and wiring up its callback are the same change.
        # CURLOPT_OPENSOCKETFUNCTION goes in alongside it: both are
        # per-handle defaults every curl_init()/curl_copy_handle() must
        # get, and this is the one injection point that reaches both.
        "	curl_easy_setopt(ch->cp, CURLOPT_NOPROGRESS,        1);\n",
        "	curl_easy_setopt(ch->cp, CURLOPT_OPENSOCKETFUNCTION, iserve_curl_open_socket);\n"
        "	curl_easy_setopt(ch->cp, CURLOPT_OPENSOCKETDATA,    (void *) ch);\n"
        "	curl_easy_setopt(ch->cp, CURLOPT_NOPROGRESS,        0);\n"
        "	curl_easy_setopt(ch->cp, CURLOPT_XFERINFOFUNCTION,  iserve_curl_xferinfo);\n"
        "	curl_easy_setopt(ch->cp, CURLOPT_XFERINFODATA,      (void *) ch);\n"
    ),
    (
        # Lowered from php-src's own built-in default of 20 to this
        # project's own clamp ceiling of 10 (patched into curl_setopt()
        # above), so a handle that never touches CURLOPT_MAXREDIRS at all
        # gets the same limit as one that explicitly tries to raise it.
        "	curl_easy_setopt(ch->cp, CURLOPT_MAXREDIRS, 20); /* prevent infinite redirects */\n",
        "	curl_easy_setopt(ch->cp, CURLOPT_MAXREDIRS, 10); /* prevent infinite redirects (iServe ADR-0010 ceiling) */\n"
    ),
    (
        # A script must not be able to remove or starve the response-size
        # cap this patch just installed: CURLOPT_PROGRESSFUNCTION and
        # CURLOPT_XFERINFOFUNCTION would let it replace iserve_curl_xferinfo
        # outright, and CURLOPT_NOPROGRESS would let it turn progress
        # reporting back off so the callback never fires. All three are
        # silently ignored before the switch below ever sees them -- same
        # fingerprint-resistant pattern as every other blocked option here.
        "	CURLcode error = CURLE_OK;\n"
        "	zend_long lval;\n"
        "\n"
        "	switch (option) {\n",
        "	CURLcode error = CURLE_OK;\n"
        "	zend_long lval;\n"
        "\n"
        "	/* iServe (docs/adr/0010-php-outbound-networking.md): see\n"
        "	 * iserve_curl_xferinfo() above -- a script cannot remove or starve\n"
        "	 * the response-size cap it installs on every handle. */\n"
        "	if (option == CURLOPT_PROGRESSFUNCTION || option == CURLOPT_XFERINFOFUNCTION || option == CURLOPT_NOPROGRESS) {\n"
        "		return SUCCESS;\n"
        "	}\n"
        "\n"
        "	switch (option) {\n"
    ),
]

for index, (old, new) in enumerate(replacements):
    count = content.count(old)
    if count != 1:
        print(f"ERROR: patch {index + 1}/{len(replacements)} expected exactly 1 occurrence of its anchor, found {count}. "
              f"php-src's ext/curl/interface.c may have changed shape since this patch was written -- "
              f"anchor starts: {old[:60]!r}", file=sys.stderr)
        sys.exit(1)
    content = content.replace(old, new, 1)

with open(path, "w") as f:
    f.write(content)

print(f"curl_setopt_ssrf_guard.py: applied {len(replacements)}/{len(replacements)} patches to {path}")
