#!/usr/bin/env python3
# A small, tracked patch to php-src's ext/curl/interface.c
# (docs/adr/0010-php-outbound-networking.md) -- applied the same way
# ADR-0009's own ext/standard/config.m4 patch already is: in CI, against a
# fresh upstream checkout, never a maintained fork of the file. Run as
# `python3 curl_setopt_ssrf_guard.py <path-to-interface.c>` from within the
# php-src checkout, before ./buildconf.
#
# Closes the three ways a script's own curl_setopt() calls could otherwise
# route around the interposed connect() check (iserve_outbound_interpose.c)
# the SAME threat model as that file's own "the bridge decides, the script
# cannot un-decide" posture, just at the curl_setopt() layer instead of the
# connect() layer:
#
# 1. CURLOPT_CONNECTTIMEOUT/CURLOPT_CONNECTTIMEOUT_MS/CURLOPT_TIMEOUT/
#    CURLOPT_TIMEOUT_MS/CURLOPT_MAXREDIRS are clamped, never widened, to a
#    fixed ceiling -- a hung request or an unbounded redirect chain must
#    not be able to hold the single PHP worker open indefinitely.
# 2. CURLOPT_DNS_SERVERS/CURLOPT_INTERFACE are silently ignored: either
#    could let a script route around the interposed connect() check
#    (pre-seeding its own DNS resolution, or binding to a specific
#    interface).
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
# CURLOPT_OPENSOCKETFUNCTION and CURLOPT_SOCKOPTFUNCTION -- also named in
# ADR-0010 as options that could bypass the connect-time check -- need no
# patch at all: checked directly against the real php-8.4.2 source, neither
# has a case label in _php_curl_setopt()'s switch statement in the first
# place, so a script calling curl_setopt() with either already hits the
# default "not a valid cURL option" branch and gets a ValueError, with
# nothing here to add.
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
        "			 * and CURLOPT_INTERFACE could let a script route around the interposed\n"
        "			 * connect() check (binding to a specific interface, or pre-seeding its\n"
        "			 * own resolution) -- silently ignored, not an error, so a script can't\n"
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
        "			 * bypassing the interposed connect() check entirely -- silently ignored,\n"
        "			 * same reasoning as CURLOPT_DNS_SERVERS/CURLOPT_INTERFACE above. */\n"
        "			if (option == CURLOPT_RESOLVE || option == CURLOPT_CONNECT_TO) {\n"
        "				return SUCCESS;\n"
        "			}"
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
