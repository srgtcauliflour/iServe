// Vendored copy of Apple's own DYLD_INTERPOSE macro, normally reached via
// <mach-o/dyld-interposing.h>. That header is not part of the public
// Xcode/Command Line Tools SDK -- it's a dyld-internal convenience wrapper
// some toolchain installations happen to carry at that include path and
// others (including, as found by real CI on a macos-14 runner building
// this project, docs/adr/0010-php-outbound-networking.md's own
// outbound-policy-native-smoke-test job) do not. Vendoring it here removes
// that dependency entirely.
//
// This is not a reimplementation or a guess at the mechanism: the macro
// body below is copied verbatim from Apple's own open-source dyld project
// (mach-o/dyld-interposing.h, unchanged since it was first published), so
// everything DYLD_INTERPOSE's callers already know about it -- the
// `__DATA,__interpose` section is dyld's real, stable, documented
// interposing convention, not something bound to a specific header file's
// availability -- still applies unchanged with this copy in place.
#ifndef ISERVE_DYLD_INTERPOSE_H
#define ISERVE_DYLD_INTERPOSE_H

#define DYLD_INTERPOSE(_replacement, _replacee) \
    __attribute__((used)) static struct { const void *replacement; const void *replacee; } _interpose_##_replacee \
        __attribute__((section("__DATA,__interpose"))) = { (const void *)(unsigned long)&_replacement, (const void *)(unsigned long)&_replacee };

#endif // ISERVE_DYLD_INTERPOSE_H
