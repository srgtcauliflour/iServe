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

Nothing in the app yet constructs a `PHPWorker` or calls it from the HTTP
request path — see `docs/ROADMAP.md`'s v0.4 section for what's still open.
