# ADR-0012: CURLOPT_OPENSOCKETFUNCTION replaces DYLD_INTERPOSE for ADR-0010's outbound-networking defense

- Status: Accepted for v0.5
- Date: 2026-10-09

## Context
`docs/adr/0010-php-outbound-networking.md` specified `DYLD_INTERPOSE`'d `connect()` (`PHP/Bridge/iserve_outbound_interpose.c`) as the enforcement point for the SSRF/local-network/DNS-rebinding denylist: interpose the C library's `connect()`, gated to only apply during PHP script execution, and inspect the real resolved address before letting it through.

A real macOS CI run proved this cannot work the way it was built. Checked directly against Apple's own open-source dyld (`apple-oss-distributions/dyld`, `RuntimeState.cpp`'s own `buildInterposingTables()`):

```cpp
for ( const Loader* ldr : loaded ) {
    const UnsafeHeader* hdr = (const UnsafeHeader*)ldr->analyzer(*this);
    // dylibs in dyld cache cannot have interposing tuples
    if ( ldr->dylibInDyldCache )
        continue;
    if ( !hdr->isDylib() )
        continue;
    ...
```

`if (!hdr->isDylib()) continue;` — dyld only ever processes a `__DATA,__interpose` section from a loaded *dylib*. It never looks at the main executable's own interpose section at all. Every iServe target (`iserve_bridge_smoke_test`, and the real `iServeWithPHP` app) links `iserve_outbound_interpose.c` directly into its own main executable, never a separate dylib — so this interposition was silently inert from the start, on every build that ever ran it.

This went uncaught for as long as it did because the only verification available at each step had its own blind spot:
- This sandbox's own Linux environment has no Mach-O/dyld at all, so `iserve_outbound_interpose_test.c` (a standalone raw-`connect()` test, in `php-outbound-networking.yml`'s `outbound-policy-native-smoke-test` job) could only ever be compile-checked there, never functionally run — already a known, accepted limitation.
- The one real macOS job that *could* have caught it (that same `outbound-policy-native-smoke-test` job) had itself been failing to compile at all up to this point, for an unrelated reason (`<mach-o/dyld-interposing.h>` not reliably present on the runner's SDK — fixed in an earlier commit by vendoring Apple's own macro).
- The first real end-to-end run through the actual linked bridge+curl build (`php-embed.yml`'s `native-smoke-test` job, newly wired in) is what finally exercised the real code path and caught the gap: `request I` in `iserve_bridge_smoke_test.c` showed a real public address was *not* refused while outbound networking was off by default.

## Decision
Replace the interposed `connect()` with `CURLOPT_OPENSOCKETFUNCTION`, a documented libcurl extension point: curl calls the registered function in place of its own `socket()`+`connect()` for every socket it needs for a given handle — including a redirect's own follow-up connection — passing the real, already-resolved `struct sockaddr` it's about to use.

`iserve_curl_open_socket()` is injected directly into php-src's own `ext/curl/interface.c` by `PHP/Bridge/patches/curl_setopt_ssrf_guard.py` (the same file that already patches `curl_setopt()`'s SSRF-bypass options), installed on every handle via `CURLOPT_OPENSOCKETFUNCTION` in `_php_curl_set_default_options()` — the same injection point the response-size-cap `CURLOPT_XFERINFOFUNCTION` callback already uses. It checks the resolved address against the same `iserve_outbound_policy.c` denylist and `iserve_outbound_toggle.c` session toggle as before, returning `CURL_SOCKET_BAD` to refuse it (producing the same `CURLE_COULDNT_CONNECT` an ordinary connection-refused failure would) or a real `socket()` to let curl proceed.

This satisfies ADR-0010's own stated requirement unchanged: "the only sound enforcement point is the moment of the real connection attempt, on the resolved address actually being connected to." `CURLOPT_OPENSOCKETFUNCTION` fires after DNS resolution completes, with the real resolved address, for every connection attempt a handle makes — the DNS-rebinding and redirect-based-bypass cases are covered the same way the interposed `connect()` was meant to cover them, just through a different mechanism reaching the same point in curl's own connection lifecycle.

A script cannot override this: `CURLOPT_OPENSOCKETFUNCTION` has no case label in `_php_curl_setopt()`'s switch statement at all, confirmed directly against the real php-8.4.2 source — a script calling `curl_setopt()` with it already hits the `default:` branch and gets a `ValueError`, meaning it was already unconditionally un-overridable before this ADR, with nothing new to patch for that guarantee.

`iserve_outbound_interpose.c`, `iserve_outbound_guard.c` (the execution-window tracking the interposed `connect()` needed, to distinguish "a PHP script's own curl call" from "the app's own `HTTPServer`/Bonjour networking"), `iserve_dyld_interpose.h` (the vendored `DYLD_INTERPOSE` macro), and their tests are removed entirely. The guard is no longer needed for a structural reason, not just because its one consumer is gone: `CURLOPT_OPENSOCKETFUNCTION` only ever fires from within a curl operation a PHP script itself initiated (`curl_init()`/`curl_exec()` are only ever reachable from PHP script code in this bridge), so the scoping the guard existed to provide is now implicit in the mechanism itself.

## Consequences

### Positive
- Strictly better, not just a workaround: a documented libcurl extension point, not OS-level symbol interposition — no Mach-O/dyld internals to reason about, no "works for a dylib, silently not for a main executable" class of failure mode to rediscover later.
- Portable: unlike `DYLD_INTERPOSE`, which could only ever be exercised on a real Apple target, `CURLOPT_OPENSOCKETFUNCTION` has no platform dependency at all. The full mechanism — denylist, toggle, redirect-based bypass, hostname/DNS-rebinding-adjacent case — was verified for real on this project's own Linux sandbox for the first time, closing a verification gap the interposed-`connect()` approach could never close outside real macOS CI.
- Net reduction in code and moving parts: three files and their tests removed (`iserve_outbound_interpose.c`, `iserve_outbound_guard.c`, `iserve_dyld_interpose.h`), one function injected into an already-patched file.

### Costs
- Every job in both `php-embed.yml` and `php-outbound-networking.yml` that links a test binary (or the real app) directly against a patched `libphp.a` now needs `iserve_outbound_policy.o`/`iserve_outbound_toggle.o`/`iserve_php_bridge.o` on that same link line, since `iserve_curl_open_socket()` references their symbols as externs resolved only at final link time — a new requirement the old design never had (it lived entirely outside `interface.c`, needing no cross-translation-unit symbol resolution within php-src's own build at all). Five previously-self-contained ad hoc test programs in `php-curl-native-smoke-test` needed this added after the fact.
- This is the second time this project has had to correct course on a security mechanism after real CI exposed a gap books and reasoning alone didn't catch (the first being the `<mach-o/dyld-interposing.h>` availability issue, a narrower version of the same "verify on the real target, not just in theory" lesson). Treated as a cost worth naming plainly: a convincing-sounding design based on how a mechanism is *supposed* to work is not the same as having run it.

## Revisit triggers
None anticipated specific to this change. If a future feature needs the app's own (non-PHP) code to also originate outbound requests under a bounded policy — the scenario ADR-0010's own "Positive consequences" section once cited `DYLD_INTERPOSE`'s reusability for — `CURLOPT_OPENSOCKETFUNCTION` has no equivalent generality (it is specific to curl handles), so that would need its own fresh design, not an extension of this one.
