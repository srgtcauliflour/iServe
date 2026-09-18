# PHP

v0.4 module: an embedded PHP runtime, gated behind `docs/adr/0009-php-runtime-feasibility.md`.

- `Bridge/` — the C bridge onto PHP's embed SAPI (`iserve_php_bridge.h`/`.c`), plus its own real CI-executed integration test (`Bridge/Tests/`). Not yet wired into the `iServe` app target — see `docs/ROADMAP.md`'s v0.4 section for what's still needed before it can link into the app.
- `PHPWorker.swift` — the Swift actor wrapping that C API, one request at a time (ADR-0009's single PHP-worker-actor design). Also not yet wired into any target; real source, unbuilt until the bridge is.
