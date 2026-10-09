# PHP

v0.4 module: an embedded PHP runtime, gated behind `docs/adr/0009-php-runtime-feasibility.md`.

- `Bridge/` — the C bridge onto PHP's embed SAPI (`iserve_php_bridge.h`/`.c`), plus its own real CI-executed integration test (`Bridge/Tests/`).
- `PHPWorker.swift` — the Swift actor wrapping that C API, one request at a time (ADR-0009's single PHP-worker-actor design).

Both compile and link as part of a real app target, `iServeWithPHP`
(`project.yml`) — but that target is deliberately separate from `iServe`,
the one `ios.yml` builds and ships. `iServeWithPHP` is built only by
`.github/workflows/php-embed.yml` (`build-app-with-php-device`/
`-simulator`), against a `libphp.a` + headers package that same workflow's
own cross-compile jobs produce and upload within the same run — `Vendor/`
here is never committed (ADR-0009: reproducible from source, not a vendored
binary blob) and `ios.yml` never fetches it. This keeps PHP's fragile
cross-compiled dependency from ever being able to break the real app's
build/release pipeline, while still proving `PHP/Bridge`/`PHPWorker.swift`
compile and link against the rest of the real app (SwiftUI, ServerCore,
Handlers — not just a standalone clang invocation).

`ServerCoordinator.phpExecutionEnabled` — a "Run PHP Scripts" toggle in
`ServerDashboard`, off by default — constructs and starts a `PHPWorker`,
under `#if canImport(PHPBridge)` so the ordinary `iServe` target never
references it, and hands it down through `ServerService`/`LiveServerService`
to `StaticFileHandler`, which dispatches a `.php` GET/HEAD/POST request to
it (`ServerCore/PHPScriptExecutor.swift` declares the executor protocol
itself with no dependency on this directory, so that dispatch code lives
in the ordinary `iServe` target too, and is covered by a real test —
`Tests/iServeTests/PHPScriptExecutionLifecycleTests.swift` — using a fake
executor, no PHP runtime involved).

v0.4 is feature-complete: request/response mapping, `index.php` directory-index
routing, sessions, PDO/SQLite, `$_FILES` uploads, the PHP execution toggle,
and an on-device diagnostics console for the runtime warnings/errors
`display_errors=0` otherwise hides (`Logging/PHPDiagnosticsLog.swift`).
See `docs/ROADMAP.md`'s v0.4 section for the full list and
`docs/adr/0009-php-runtime-feasibility.md` for the security design each
piece follows. Still open: extending the compatibility/security test
suite (`PHP/Bridge/Tests/fixtures/security.php`) to resource-limit
exhaustion (`max_execution_time`/`memory_limit` actually terminating a
runaway script) — deferred deliberately, see the ROADMAP for why.

v0.5 adds outbound networking (`docs/adr/0010-php-outbound-networking.md`):
real `curl`, built from source against mbedTLS (also built from source),
now compiled into the same `libphp.a` every job above already builds, and
linked into `iServeWithPHP` alongside it (`project.yml`'s `OTHER_LDFLAGS`).
Off by default, gated behind its own separate `ServerCoordinator.outboundNetworkingEnabled`
toggle (never implied by `phpExecutionEnabled`) — `ServerDashboard` only
shows it while "Run PHP Scripts" is on. The SSRF/local-network/DNS-rebinding
defense lives in `Bridge/iserve_outbound_policy.c` (which addresses are
denied) and `Bridge/iserve_outbound_toggle.c` (whether outbound networking
is allowed at all this session); the actual enforcement —
`iserve_curl_open_socket()`, checked against every connection's real
resolved address via `CURLOPT_OPENSOCKETFUNCTION` — is injected directly
into php-src's own `ext/curl/interface.c` by
`Bridge/patches/curl_setopt_ssrf_guard.py`, the same patch that closes the
`curl_setopt()`-level ways a script could otherwise route around that
check, clamps timeout/redirect-limit options, caps response size via a
response-size-cap `CURLOPT_XFERINFOFUNCTION` (the threshold decision itself,
`iserve_curl_response_cap_exceeded()`, lives in its own
`Bridge/iserve_curl_response_cap.c` so it has a deterministic, no-network
unit test alongside the policy/toggle ones), and installs a CA root
bundle via `CURLOPT_CAINFO_BLOB` (generated fresh each build by
`Bridge/patches/generate_curl_ca_bundle.py` — curl's own CA-bundle
auto-detection is skipped when cross-compiling). `curl_multi_*` is
disabled outright (one worker, one request at a time, matching ADR-0009's
already-accepted concurrency model). See `docs/adr/0012-curl-opensocket-replaces-dyld-interpose.md`
for why this replaced an originally-specified, Apple-only `DYLD_INTERPOSE`'d
`connect()`. See `docs/ROADMAP.md`'s v0.5 section
for the full deliverable list and verification status, and
`docs/adr/0010-php-outbound-networking.md` for the design reasoning.

For on-device testing (not App Store distribution — `iServeWithPHP` is
never referenced by `ios.yml` or the real `iServe` bundle id, per
ADR-0009's isolation guarantee above), `php-embed.yml` can build a signed
`.ipa` on demand: run it via `workflow_dispatch` with `build_ipa: true`,
then download `iServeWithPHP-signed-ipa` from that run's own artifacts.
