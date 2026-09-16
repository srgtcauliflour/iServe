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

## Physical device builds

The project owner has a physical iPhone 17 Pro Max on the latest iOS and can sign
and install an `.ipa` themselves at any time — they do not need their own Mac to
get a build onto the device. Whenever a physical-device build is useful (closing
an issue's real-device acceptance criteria, or any point progress is worth
seeing on-device), an agent working in an environment without a local Swift/Xcode
toolchain must not treat that as a blocker: produce a compiled `.ipa` via GitHub
Actions (or another available CI/build service) rather than only offering
simulator/CI validation. `CODE_SIGN_STYLE` is `Automatic` with a blank
`DEVELOPMENT_TEAM` in `project.yml`, and no developer identity or provisioning
profile is committed, so a CI-produced archive/IPA is expected to be unsigned (or
signed with a throwaway identity) — the owner re-signs it with their own
certificate/team before installing. Building this (e.g. `xcodebuild archive` plus
`-exportArchive`, or exporting an unsigned `.xcarchive` payload as an `.ipa`
directly) is not yet wired into `.github/workflows/ios.yml`, which currently only
runs simulator tests; add a build/export job or workflow when a device build is
actually requested rather than speculatively now.

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
4. Issue #5: `Handlers/StaticFileHandler.swift` (routes through
   `SecurePathResolver.resolve(requestPath:)`, including re-resolving
   `index.html`/`index.htm` rather than opening them directly) and
   `Handlers/MIMEType.swift` are added, replacing `NotFoundRouter`.
   `HTTPResponse.body` is now `HTTPResponseBody` (`.empty` / `.data` / `.file`);
   `HTTPConnection` streams a `.file` body through the new
   `Transfer/FileChunkReader.swift` one bounded chunk at a time, gated on each
   chunk's network-send completion. Oversized request lines/headers now get
   `414`/`431` instead of a generic `400`. See `Handlers/README.md`,
   `Transfer/README.md`, `ServerCore/README.md`. Still not wired to
   `ServerCoordinator`/the dashboard, and still no real filesystem-provider
   security-scoped session — issue #6 owns both.
5. Issue #6 (partial): `ServerCore/LiveServerService.swift` replaces
   `UnconfiguredServerService` — it acquires scoped access to the selected
   folder for the whole server session via
   `FolderRootManager.beginServingAccess()`/`endServingAccess(_:)`, builds a
   real `HTTPServer(router: StaticFileHandler(...))` over that root, and
   releases scope only after the listener/connections have cancelled.
   `ServerCore/ServerService.swift`'s protocol now includes `start()`.
   `App/ServerCoordinator.swift`'s `State` gained `.noFolder`/`.ready`/
   `.starting`/`.running(endpoint:)`/`.error` (`.unavailable` keeps its prior
   meaning: scene-inactive or an explicit stop); `start()` resolves the
   endpoint via the new `Networking/LocalNetworkAddress.swift`
   (`getifaddrs`-based LAN IPv4 discovery, injectable for tests). Start/Stop
   in `ServerDashboard` are wired to real state, with a Copy button for the
   endpoint.
   Remaining for issue #6: a real request log and request/byte counters
   (`Logging/` is still just a placeholder), and the real-device acceptance
   pass itself — this has not been validated against an actual Files provider
   root or a second physical LAN device, only CI simulators.

PHP, WebDAV, archives and public-reachability tooling stay in their agreed later
milestones. Do not close the v0.1 acceptance gate until a real second LAN device
loads the selected site and traversal/large-file checks pass.
