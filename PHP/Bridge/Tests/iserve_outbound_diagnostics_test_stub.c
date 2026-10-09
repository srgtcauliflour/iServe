// Test-only stand-in for iserve_outbound_report_blocked() (declared in
// include/iserve_outbound_diagnostics.h, really defined in
// iserve_php_bridge.c alongside PHPDiagnosticsLog). iserve_outbound_interpose.c
// calls it directly, but the real definition needs the full Zend/PHP
// embed headers to compile -- unavailable, and deliberately not built, in
// outbound-policy-native-smoke-test (see that job's own comment in
// .github/workflows/php-outbound-networking.yml for why it stays free of
// the PHPKit/curlkit/mbedtlskit build entirely). This stub exists only so
// iserve_outbound_interpose_test.c can link and prove the interposition
// itself works; it is never linked into the real app.
#include "../include/iserve_outbound_diagnostics.h"

#include <stdio.h>

void iserve_outbound_report_blocked(void)
{
    printf("(test stub) iserve_outbound_report_blocked() called\n");
}
