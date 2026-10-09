#!/usr/bin/env python3
# Converts a downloaded CA bundle (curl's own official
# https://curl.se/ca/cacert.pem, extracted from Mozilla's trusted root
# program -- see https://curl.se/docs/caextract.html) into a compiled C
# source file defining iserve_curl_ca_bundle_pem (declared in
# include/iserve_curl_ca_bundle.h), the bundle
# PHP/Bridge/patches/curl_setopt_ssrf_guard.py's own patch installs on
# every curl handle via CURLOPT_CAINFO_BLOB.
#
# Run as `python3 generate_curl_ca_bundle.py <path-to-cacert.pem>
# <path-to-output.c>` -- the output .c file is never committed to the
# repo, generated fresh in CI each run from a freshly downloaded bundle,
# the same "reproducible from source" treatment every other from-source
# dependency here already gets. The output path should land directly in
# PHP/Bridge/ itself (sibling to iserve_php_bridge.c etc.), matching the
# "include/..." (not "../include/...") style every other file there
# already uses, since this generated file's own #include is written to
# match that same convention.
import sys

if len(sys.argv) != 3:
    print(f"usage: {sys.argv[0]} <path-to-cacert.pem> <path-to-output.c>", file=sys.stderr)
    sys.exit(1)

pem_path, output_path = sys.argv[1], sys.argv[2]

# Read as UTF-8: curl.se's own cacert.pem includes human-readable "##"
# comment lines naming each certificate's issuer (often with non-ASCII
# characters, e.g. accented company names) ahead of every actual
# "-----BEGIN CERTIFICATE-----" block. Only the certificate blocks
# themselves matter to curl's own PEM parser -- extracted below, as pure
# base64/ASCII content, specifically so this never has to carry arbitrary
# non-ASCII bytes through C string-literal generation at all.
with open(pem_path, "r", encoding="utf-8") as f:
    full_text = f.read()

cert_lines = []
in_certificate = False
for line in full_text.split("\n"):
    if line.startswith("-----BEGIN CERTIFICATE-----"):
        in_certificate = True
    if in_certificate:
        cert_lines.append(line)
    if line.startswith("-----END CERTIFICATE-----"):
        in_certificate = False
pem_text = "\n".join(cert_lines)

if not pem_text.strip():
    print(f"ERROR: {pem_path} does not look like a PEM certificate bundle "
          f"(no '-----BEGIN CERTIFICATE-----' block found) -- refusing to "
          f"generate a C file from it", file=sys.stderr)
    sys.exit(1)

if not pem_text.isascii():
    print(f"ERROR: extracted certificate data from {pem_path} contains "
          f"non-ASCII bytes -- a certificate block should be pure base64, "
          f"something is wrong with this file or the extraction above",
          file=sys.stderr)
    sys.exit(1)

# One adjacent C string literal per line (the compiler concatenates them),
# rather than a single huge literal -- a CA bundle is hundreds of KB of
# text, and splitting it this way keeps each individual literal a
# reasonable size and the generated file readable/diffable if ever
# inspected by hand. json.dumps() handles C-compatible escaping correctly
# (backslashes/quotes, though a real PEM bundle's own alphabet -- base64 +
# headers + newlines -- never actually contains either).
import json

lines = pem_text.split("\n")
literal_lines = []
for line in lines:
    # json.dumps() on a plain line produces a double-quoted, C-compatible
    # escaped string (JSON string escaping is a strict subset of C string
    # escaping for this printable-ASCII content) -- re-adding the newline
    # curl's own PEM parser expects between entries.
    literal_lines.append(json.dumps(line + "\n"))

with open(output_path, "w") as f:
    f.write('#include "include/iserve_curl_ca_bundle.h"\n\n')
    f.write("const char iserve_curl_ca_bundle_pem[] =\n")
    for literal in literal_lines:
        f.write(f"    {literal}\n")
    f.write("    ;\n")

print(f"generate_curl_ca_bundle.py: wrote {output_path} from {pem_path} ({len(pem_text)} bytes of PEM text)")
