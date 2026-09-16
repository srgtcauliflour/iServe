# Development guide

## Bootstrap status

The initial repository contained only planning documents and six v0.1 issues. This
change starts issue #1 with a SwiftUI iPhone/iPad dashboard, an injectable
`ServerCoordinator`/`ServerService` lifecycle boundary, unit tests, and CI.

**This is not a working server yet.** Issue #2 implementation adds Files folder
selection, local bookmark persistence, stale-bookmark refresh, Retry and Forget.
Root metadata is validated under temporary scoped access. Start Server remains
disabled; no listener, fabricated endpoint, PHP or WebDAV runtime is included.

## Build

Use a Mac with Xcode 16 or newer (Swift 6), its command-line tools selected, and
an iOS simulator runtime installed. The provisional deployment floor is iOS 17:
this is an implementation baseline for Observation, not a newly agreed product
requirement. The iServe specification did not set a minimum OS; other projects'
iOS requirements do not apply automatically.

```sh
brew install xcodegen
xcodegen generate
open iServe.xcodeproj
```

`project.yml` is the source of truth for the generated Xcode project, including
shared scheme and test target. Generated projects and local signing state are
ignored. Select the iServe scheme and an iPhone or iPad simulator. Physical device
builds require your own signing team and, if necessary, a unique bundle identifier.
No developer identity or provisioning profile is committed.

Run the same checks as CI:

```sh
bash scripts/ci.sh
```

The script generates the project and runs the unit tests on an available iPhone
and iPad from the newest installed compatible runtime that contains both.
Results are written to `build/`. CI uploads the result bundles even after failure.
App icons and distribution metadata are not included in this development bootstrap.

## Boundaries and lifecycle

- `App/`: dashboard, observable coordinator, active-scene lifecycle forwarding.
- `ServerCore/`: injectable transport ownership boundary; no transport yet.
- `FileSystem/`: scoped root validation, saved bookmarks and provider error recovery.
- Other top-level module directories explain ownership for subsequent issues.
- `Tests/iServeTests/`: coordinator shutdown and initial-state tests.

On an inactive or background scene transition, the app calls the service's
idempotent stop operation. Returning active does not start anything. The future
listener must cancel connections before releasing scoped folder access and must
report asynchronous readiness before publishing a running state or endpoint.
The bootstrap intentionally does not invent a synchronous network-start contract.

## Manual acceptance (macOS/iOS required)

1. Generate the project and launch on both iPhone and iPad simulators.
2. Confirm dashboard and stopped status. Choose a folder under On My iPhone/iPad;
   confirm its name appears and no absolute path is shown.
3. Repeat with iCloud Drive and an installed third-party Files provider. Cancel the
   picker and confirm the previous folder remains unchanged. Start Server remains
   disabled; no endpoint is advertised.
4. Rotate each simulator and enable the largest accessibility text size. All
   explanatory text and controls must remain reachable by scrolling.
5. With VoiceOver enabled, verify headings and disabled controls are understandable.
6. Leave the app and return. Status remains stopped; no automatic start occurs.
7. Terminate and relaunch. Confirm the folder restores from its bookmark. Remove or
   revoke the folder/provider and relaunch; expect a recoverable message. Reconnect
   the provider and use Retry, or reselect the folder.
8. Use Forget Folder, relaunch, and confirm no selection is restored. The folder and
   its contents must remain intact. Verify stale bookmark renewal on a real device
   when the provider exposes a stale bookmark; unit tests cover this deterministically.

A clean simulator build and these manual checks remain part of issue #1's gate.
Coordinator/provider-double tests do not prove actual Files-provider or network correctness.
The development environment used to author this change is Linux without Swift or
Xcode; iOS compilation and XCTest require the accompanying macOS CI or a Mac.

## Next tasks

1. Issue #2: implementation and deterministic tests added; run the real Files-provider
   acceptance checklist above before closing the issue.
2. Issue #3: `SecurePathResolver` and its hostile-path/symlink test corpus are added
   (`FileSystem/SecurePathResolver.swift`, `Tests/iServeTests/SecurePathResolverTests.swift`).
   It is not yet wired to anything remote-facing because no HTTP layer exists yet;
   issue #5's static handler must be the first caller.
3. Issue #4: `ServerCore/HTTPServer.swift` + `HTTPConnection.swift` (Network.framework
   listener/connection lifecycle) and `HTTPRequestParser.swift` (bounded, transport-
   independent parser) are added, with `NotFoundRouter` as a placeholder router. See
   `ServerCore/README.md`. Not yet wired to `ServerCoordinator`/the dashboard — issue
   #6 replaces `UnconfiguredServerService` with a real implementation. No keep-alive/
   pipelining yet (documented v0.1 simplification); a specific requested port that
   never becomes available can leave `start()` pending indefinitely since only `.any`
   is exercised by the test suite.
4. Issue #5: static routing, MIME, GET/HEAD and bounded streaming/backpressure, routed
   exclusively through `SecurePathResolver.resolve(requestPath:)`. Replaces
   `NotFoundRouter` with a real `HTTPRouter` and gives `HTTPResponse`/`HTTPConnection`
   a chunked body path instead of a single in-memory `Data` body.
5. Issue #6: real local endpoints, sanitized bounded logs and dashboard integration —
   replace `UnconfiguredServerService` with an `HTTPServer`-backed `ServerService` and
   surface `HTTPServer.state`/the bound port in `ServerDashboard`. Replace the disabled
   start action.

PHP, WebDAV, archives and public-reachability tooling stay in their agreed later
milestones. Do not close the v0.1 acceptance gate until a real second LAN device
loads the selected site and traversal/large-file checks pass.
