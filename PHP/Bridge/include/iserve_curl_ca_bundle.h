// Declares the CA root bundle iserve_curl_ssrf_guard.py's patch installs on
// every curl handle via CURLOPT_CAINFO_BLOB (docs/adr/0010-php-outbound-networking.md).
//
// Why this exists at all: curl's own autoconf CA-bundle auto-detection
// (CURL_CHECK_CA_BUNDLE, acinclude.m4) only runs `test "$cross_compiling"
// != "yes"` -- it's unconditionally skipped for every cross-compiled
// target this project builds curl for (iOS device/Simulator), leaving
// mbedTLS with zero trusted root certificates and every real HTTPS
// request failing certificate verification ("The certificate is not
// correctly signed by the trusted CA") -- a real failure caught on actual
// macOS CI (php-embed.yml's own simulator-smoke-test job), not a
// hypothetical. The native build happens to auto-detect macOS's own
// /etc/ssl/cert.pem and works without this -- but setting the SAME
// explicit, known-good bundle unconditionally on every platform (rather
// than only cross-compiled ones) removes any dependency on what the BUILD
// machine's own filesystem happens to contain, native builds included.
//
// The actual bundle text (iserve_curl_ca_bundle_pem's definition, in a
// separately generated .c file, see
// patches/generate_curl_ca_bundle.py) is never committed to the repo:
// generated fresh each CI run from curl's own official, regularly-updated
// distribution (https://curl.se/docs/caextract.html, itself extracted
// from Mozilla's own trusted root program on a schedule) -- the same
// "reproducible from source, not a vendored binary blob" rule ADR-0009
// already applies to every other from-source dependency here, just for a
// list of trusted root certificates instead of a compiled library.
//
// CURLOPT_CAINFO_BLOB (an in-memory alternative to CURLOPT_CAINFO's file
// path, added to curl well before the 8.22.0 this project pins) is used
// specifically so no separate file needs to exist at a predictable
// runtime path inside the app's own bundle at all -- the bundle's own
// bytes are compiled directly into the binary, with CURL_BLOB_NOCOPY
// since this data is a process-lifetime constant that outlives every
// curl handle.
#ifndef ISERVE_CURL_CA_BUNDLE_H
#define ISERVE_CURL_CA_BUNDLE_H

extern const char iserve_curl_ca_bundle_pem[];

#endif // ISERVE_CURL_CA_BUNDLE_H
