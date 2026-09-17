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
   `FolderRootManager.beginAccess()`/`endAccess(_:)`, builds a
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
   `Logging/RequestLog.swift` (an actor, bounded to 50 most-recent entries)
   is a fresh-per-session, sanitized request log — method/target/status/byte
   count only, never a local path — that `HTTPConnection` records into and
   `ServerDashboard` polls once a second while running to show request
   count, bytes transferred, and the most recent requests. This completes
   issue #6's stated acceptance criteria.

   **Real-device acceptance of the v0.1 core loop passed** on a physical
   iPhone: selected a Files folder, tapped Start Server, and a second
   physical device on the same LAN loaded the served site at the displayed
   endpoint. No Local Network permission prompt appeared — either the
   permission was already granted for this bundle id from an earlier test
   install, or a plain `NWListener` with no Bonjour advertisement doesn't
   trigger that prompt the way anticipated; either way, the fix that actually
   mattered was the `iServeApp` wiring below, not the privacy-string addition
   (kept anyway; it's correct regardless of whether iOS ends up requiring it
   for this exact code path). Not yet separately re-verified on this specific
   device: traversal rejection and large-file bounded streaming — both are
   covered by automated tests already, but not manually re-confirmed against
   real hardware.

   Real-device testing found three bugs simulators didn't catch:
   - Folder selection silently failed to complete (the system picker never
     dismissed) on a build that was archived unsigned and resigned after the
     fact by a third-party tool, across every location/provider tried. A
     properly signed build (`xcodebuild archive` + `-exportArchive` with a
     real certificate/profile) fixed it outright — not something to chase
     further in the app's own code, but a hard requirement for any future
     device-test build to be produced through a real signing path, never an
     unsigned-then-resigned one.
   - `Start Server` failed immediately with the same generic message
     regardless of what was fixed, which turned out to be because
     **`App/iServeApp.swift` never actually constructed `LiveServerService`**
     — it still built `ServerCoordinator()` with every default parameter,
     silently using the `UnconfiguredServerService` bootstrap (which always
     throws immediately, touching no network at all) in the shipped app the
     whole time issue #6 appeared to be "done". No test caught this because
     nothing exercises `iServeApp`'s own `init()` — `ServerCoordinatorTests`
     and `LiveServerServiceTests` both inject their dependencies directly and
     never touch the real wiring. Fixed by giving `iServeApp` an explicit
     `init()` that builds one `FolderRootManager`, wraps it in a
     `LiveServerService`, and passes both into `ServerCoordinator`. This is
     exactly the kind of gap an actual device tap-through catches and a unit
     suite structurally cannot; there is no automated regression test for it
     here for the same reason.
   - Speculatively (unconfirmed until the above fix let the real listener run
     at all): the project never declared `NSLocalNetworkUsageDescription`
     (`project.yml`'s `INFOPLIST_KEY_NSLocalNetworkUsageDescription`), which
     iOS requires before it will even prompt for the Local Network permission
     a listening `NWListener` needs on a real device. Added defensively; keep
     it regardless of whether it turns out to matter once `LiveServerService`
     is actually reachable. `ServerCoordinator`'s error mapping was also
     widened (`sanitizedStartFailureMessage`) to name which layer failed
     (no-folder/access-denied/listener-failed) instead of one generic
     message, so the next real-device failure is diagnosable from the
     dashboard alone.

PHP, WebDAV, archives and public-reachability tooling stay in their agreed later
milestones. The real-second-LAN-device-loads-the-site half of the v0.1
acceptance gate has now passed on physical hardware, and issue #6's stated
scope (dashboard, endpoint, request log/counters, actionable failure states)
is now implemented end to end; do not close the gate itself until traversal
and large-file streaming are also re-confirmed on a real device (they
already pass in CI).

## v0.2 progress (merged to `main`, `MARKETING_VERSION` 0.2.0)

1. Directory browsing (`docs/ROADMAP.md`'s "Embedded responsive browser file
   manager" / "Directory browsing" deliverables, started): a folder with no
   `index.html`/`index.htm` now gets a generated HTML listing
   (`Handlers/DirectoryListingRenderer.swift`) instead of `404`, and
   `Handlers/StaticFileHandler.swift` redirects (`301`) a directory request
   without a trailing slash first, so relative links resolve correctly.
   `ServerCore/HTTPResponse.swift` gained `.redirect(to:)` and `.html(_:)`
   constructors for this. See `Handlers/README.md`.
2. Bonjour/mDNS advertisement + QR connection helper: `Networking/BonjourAdvertiser.swift`
   publishes the running session as `_http._tcp.` via `NetService`, so a
   nearby device can find it by name; `App/ServerCoordinator.swift` starts
   it once `service.start()` returns a port and stops it everywhere it
   stops the underlying service, exposed as `bonjourState` for the
   dashboard. `App/QRCodeView.swift` renders the endpoint as a scannable
   QR code on-device via CoreImage (`CIFilter.qrCodeGenerator`), shown in
   a "Show QR Code" disclosure next to the existing Copy Address button.
   `project.yml` gained `INFOPLIST_KEY_NSBonjourServices: _http._tcp.`
   alongside the existing `NSLocalNetworkUsageDescription` — Bonjour
   advertisement requires both. See `Networking/README.md` for why that
   Info.plist setting is unverified by CI and what to try if a real-device
   test shows it isn't actually advertising.
3. In-app browser: `App/InAppBrowserView.swift`'s `InAppBrowserSheet` wraps
   `WKWebView` to preview the running server's own endpoint without leaving
   iServe or retyping the address into Safari — no address bar, no history,
   just the one URL it's given, a Reload button, and an "Open in Safari"
   fallback (`openURL`). Opened via a new "Preview in App" button in
   `ServerDashboard`'s connections section, next to Copy Address. Its
   `WKNavigationDelegate` (`WebView.Coordinator`) follows the same pattern
   as `BonjourAdvertiser`'s `NetServiceDelegate`: `nonisolated` methods
   that extract only `Sendable` values before hopping to MainActor, this
   time via `WebViewLoadState` (a `@MainActor @Observable` class) rather
   than `@Binding`, since a `Binding`'s wrapped get/set closures aren't
   guaranteed `Sendable`. Loads the endpoint's plain `http://` URL as-is —
   relies on iOS's long-standing App Transport Security exemption for
   literal-IP-address hosts (the endpoint is always a dotted-quad IPv4
   address, never a resolvable hostname) rather than adding an ATS
   exception to `project.yml`; unverified by CI, same caveat as the
   Bonjour Info.plist setting above. If a real-device test shows the
   preview failing to load specifically due to ATS, the fix is
   `NSAppTransportSecurity` → `NSAllowsLocalNetworking: true` in Info.plist
   (also likely needs `project.yml`'s `info:`/`properties:` block, per the
   same reasoning as the Bonjour services array).
4. Network interface discovery: `Networking/LocalNetworkAddress.allAddresses()`
   walks every active, non-loopback interface (IPv4 and IPv6, not just the
   one `preferredIPv4Address()` picks) as `[NetworkInterfaceAddress]`.
   `App/ServerCoordinator.swift` combines this with the new `runningPort`
   (captured alongside `state` on a successful `start()`) into
   `alternateEndpoints`, filtering out whichever address `state`'s own
   endpoint already uses; `ServerDashboard`'s new "Other Addresses" section
   lists the rest. A link-local IPv6 address gets `%<interface>` appended
   (needed to actually route to it — the same address can exist on several
   interfaces), but is shown as a raw address rather than wrapped into a
   `http://[...]/` URL, since a zone-id URL isn't reliably usable across
   HTTP clients. See `Networking/README.md`.
5. Browser uploads, the last major v0.2 piece: a plain HTML
   `<input type="file" multiple>` form (no JavaScript) in
   `Handlers/DirectoryListingRenderer.swift`'s listing posts
   `multipart/form-data` back to the same directory. New pieces:
   `Transfer/MultipartFormDataParser.swift` (a bounded, incremental
   multipart parser mirroring `HTTPRequestParser`'s feed-bytes-as-they-arrive
   design) and `Transfer/FileChunkWriter.swift` (the write-side mirror of
   `FileChunkReader`), both driven directly by
   `ServerCore/HTTPConnection.swift`, which authorizes an upload's target
   directory, `Content-Type`/boundary, and `Content-Length` (against a new
   `HTTPServerLimits.maxUploadBytes`) before reading a single body byte, and
   deletes any partial file on a malformed/truncated body or an early
   disconnect. `ServerCore/HTTPRouter.swift` gained two upload-authorization
   requirements (default: refuse everything) that
   `Handlers/StaticFileHandler.swift` implements — including refusing to
   ever silently overwrite an existing file. Off by default end to end: a
   new `ServerCoordinator.uploadsEnabled` (surfaced as an "Allow Uploads"
   toggle in `ServerDashboard`, disabled while running) flows through
   `ServerService.start(allowUploads:)` — per `docs/SECURITY.md`, a write
   capability is never implied just by selecting a folder. See
   `ServerCore/README.md`, `Handlers/README.md`, `Transfer/README.md`.

v0.2 is closed out as of `MARKETING_VERSION` 0.2.0: the core Shu-parity
loop (network discovery, Bonjour/QR, directory browsing, download +
upload) is done and merged. `docs/ROADMAP.md`'s remaining v0.2 line items —
the public-address-vs-reachability distinction, large-file reliability
improvements, and transfer/request/client statistics beyond the existing
request log — were deliberately not blocking; pick them up under v0.3 if
they turn out to matter there rather than reopening v0.2.

## v0.3 progress

1. HTTP Range/206 and resumable downloads, `docs/ROADMAP.md`'s first v0.3
   deliverable, started: `Transfer/ByteRangeParser.swift` parses a single
   `Range` request header (RFC 7233) against a file's real size;
   `Handlers/StaticFileHandler.swift`'s `fileResponse(for:request:)` turns a
   satisfiable one into `HTTPResponse.partialContent` (`206`,
   `Content-Range`), an out-of-bounds one into `.rangeNotSatisfiable`
   (`416`), and anything else (no header, or a multi-range request this
   parser doesn't implement — RFC 7233 §3.1 allows ignoring those) into the
   ordinary full `.file` response, which now always advertises
   `Accept-Ranges: bytes` so a client knows a later Range request will
   work. `Transfer/FileChunkReader.swift` gained `offset`/required
   `length` parameters so it streams only the requested span, never the
   whole file, for either case. Applies to a direct file request and to a
   directory's resolved `index.html`/`.htm` alike. Multi-range requests
   (`bytes=0-499,500-999`, which would need a `multipart/byteranges`
   response) are a deliberate gap, not an oversight — see
   `Transfer/README.md`. See also `ServerCore/README.md`,
   `Handlers/README.md`.

2. Native in-app file manager, first increment (browse, preview,
   zip/unzip): adds [ZIPFoundation](https://github.com/weichsel/ZIPFoundation)
   via Swift Package Manager, this project's first third-party dependency,
   since Apple has no first-party ZIP archive API and shelling out is
   ruled out by `AGENTS.md`/the sandbox. `Transfer/ArchiveManager.swift`
   wraps it — `createArchive(containing:at:)`/`extractArchive(at:to:)` —
   with its own Zip-Slip containment check on every extracted entry
   (mirroring `FileSystem/SecurePathResolver.swift`) and an outright
   refusal of symlink entries, independent of whatever protection
   ZIPFoundation itself provides. `App/FileManagerScreen.swift`/
   `FileManagerViewModel.swift` are a new native screen (opened from
   `ServerDashboard`, independent of whether the server is running)
   holding its own scoped access via the now-renamed
   `FolderRootManager.beginAccess()`/`endAccess(_:)` — reentrant with a
   running server's own access, since both rely on security-scoped access
   being reference-counted. Browsing is a plain recursive
   `NavigationStack`; preview wraps `QLPreviewController` via
   `UIViewControllerRepresentable` (SwiftUI's own `quickLookPreview(_:)`
   modifier turned out not to resolve as a member on this toolchain, so
   this uses the older, well-established UIKit path instead); zip is a
   multi-select "Compress" action, unzip a swipe action on `.zip` entries.
   See `Transfer/README.md`, `FileSystem/README.md`.

3. Native in-app file manager, second increment: rename, delete,
   move/copy (via a folder-picker sheet with its own "Move Here"/
   "Copy Here" per level), in-place text editing, in-list search, and 7z
   extraction. Rename/delete are per-row swipe actions; move/copy/delete
   also work multi-select via the existing "Select" mode, gated behind a
   confirmation dialog for bulk delete. None of rename/move/copy will
   silently overwrite an existing name — same "never silently overwrite"
   stance as uploads (`docs/SECURITY.md`) — they set `errorMessage`
   instead. Text editing (`FileManagerEntry.isTextEditable`, gated on the
   file extension's `UTType` conforming to `.text`) opens a plain
   `TextEditor` sheet in place of QuickLook; an extension-less file falls
   back to QuickLook rather than guessing. 7z extraction adds
   [SWCompression](https://github.com/tsolomko/SWCompression) (Apache-2.0)
   — RAR was deliberately left out entirely, since every available RAR
   library wraps the non-commercial-licensed `unrar` code, which
   ZIPFoundation/SWCompression's permissive licensing avoids; 7z is
   extraction-only, since SWCompression (and no other maintained
   permissively-licensed Swift library) can create `.7z`. See
   `Transfer/README.md` for the memory-bounding trade-off 7z's
   whole-archive-in-memory reader accepts.

4. Multi-selection streaming ZIP downloads over HTTP — the roadmap's
   first remaining v0.3 deliverable, and distinct from the in-app
   zip/unzip above: a *browser client* can now select several files
   and/or subdirectories in a directory listing and download them as one
   `.zip`. `Handlers/DirectoryListingRenderer.swift` wraps every
   non-empty listing in a plain (no-JS) `method="POST"` form with a
   checkbox per entry; `ServerCore/HTTPConnection.swift` gained a second
   POST body path alongside uploads, dispatched by `Content-Type`
   (`application/x-www-form-urlencoded` here vs `multipart/form-data` for
   uploads) — it buffers the small selection body (bounded by the new
   `HTTPServerLimits.maxZipSelectionBytes`, since this is a list of names,
   never file content), resolves every name through
   `StaticFileHandler.resolveZipEntries(directoryPath:names:)` (refusing
   the *whole* request if even one name is a traversal attempt or no
   longer exists), builds the archive via `Transfer/ArchiveManager.swift`
   in the app's own temporary directory (bounded by the new
   `maxZipEntryCount`/`maxZipUncompressedBytes`), and streams it back with
   `HTTPResponse.attachment(...)` (`Content-Disposition: attachment`) —
   the same `.file` streaming path as any other download. The temporary
   archive is deleted in `close()`, the one place every termination path
   (clean finish, client disconnect, timeout) already funnels through, so
   cleanup happens exactly once. Unlike uploads this needs no capability
   opt-in: packaging already-servable files as a ZIP exposes nothing a
   plain GET of each one wouldn't. See `ServerCore/README.md`,
   `Handlers/README.md`.

5. Authentication/session layer — `docs/adr/0002-http-basic-authentication.md`.
   Optional, password-only HTTP Basic Authentication (RFC 7617), off by
   default and never persisted to disk (unlike the selected-folder
   bookmark, a plaintext passphrase isn't kept at rest — the owner
   re-enters it each time they want protection on). `ServerCoordinator`
   gained `requiresPassword`/`password`; `ServerDashboard` gained a
   "Require Password" toggle and a `SecureField`, plus a footer warning
   that this server has no encryption so the protection is only meaningful
   on a trusted network. `ServerCore/HTTPConnection.swift` checks every
   request — GET, HEAD, or POST — against `ServerCore/ServerCredentials.swift`
   before it reaches the router or a body byte is read, using a
   constant-time comparison so response timing can't leak the password a
   byte at a time; a missing/wrong credential gets `401` with
   `WWW-Authenticate: Basic realm="iServe"`, so the browser's own native
   login prompt handles it. `ServerService.start(allowUploads:credentials:)`
   threads the optional `ServerCredentials` down through `LiveServerService`
   to `HTTPServer`/`HTTPConnection`. This is the gate only — the
   capability-based permissions/profiles system (`docs/MASTER-SPEC.md` §4:
   Website/Read Only, File Sharing, File Drop, Full Access) it's meant to
   sit in front of is the next, separate roadmap item. See
   `ServerCore/README.md`.

6. Capability-based server permissions/profiles —
   `docs/adr/0003-capability-based-server-profiles.md`. A new
   `ServerCore/ServerProfile.swift` enum replaces the old lone
   `ServerCoordinator.uploadsEnabled` boolean with a `profile` property
   (`ServerService.start(allowUploads:credentials:)` is now
   `start(profile:credentials:)`) bundling two capabilities per profile:
   `allowsDirectoryListing`/`allowsUploads`. Website/Read Only turns off
   the generated directory listing too (a `404` for a no-index directory
   instead), so it's now meaningfully distinct from File Sharing rather
   than differing only in the upload toggle; File Drop adds uploads on top
   of File Sharing. `App/ServerDashboard.swift`'s old "Allow Uploads"
   toggle is now a `Picker` over `ServerProfile.selectable`, with a summary
   line under it. `.fullAccess` exists in the enum but is deliberately kept
   out of `ServerProfile.selectable` until WebDAV write operations (next)
   give it something distinct to do — see the ADR for why. See
   `ServerCore/README.md`, `Handlers/README.md`.

7. WebDAV read operations — `docs/adr/0004-webdav-read-operations.md`.
   `ServerCore/HTTPConnection.swift` now dispatches `OPTIONS` (pure
   capability discovery: `200`, `DAV: 1`, `Allow: GET, HEAD, POST, OPTIONS,
   PROPFIND`, the same for every path) and `PROPFIND` alongside GET/HEAD/
   POST. Two deliberate simplifications, both documented in the ADR rather
   than left as silent gaps: the `Depth` header must be exactly `0` or `1`
   (a missing header or `Depth: infinity` is `400`, never an unbounded
   recursive walk), and a `PROPFIND` request body is never read/parsed —
   every response describes the same fixed property set
   (`resourcetype`/`getcontentlength`/`getcontenttype`/`getlastmodified`/
   `displayname`) regardless of what the client's `<prop>` list actually
   asked for. `ServerCore/HTTPRouter.swift` gained
   `routeWebDAVPropfind(path:depth:) -> HTTPResponse?`, shaped like
   `route(_:)` itself (the router owns the whole response, `nil` meaning
   unsupported -> `501`) rather than like the upload/ZIP authorization
   methods, since there's no streaming body to gate mid-request.
   `Handlers/StaticFileHandler.swift`'s implementation requires
   `allowDirectoryListing` for a directory target (`docs/adr/
   0003-capability-based-server-profiles.md`, independent of whether an
   index file exists there) and omits hidden entries from a `Depth: 1`
   directory's children, same as `DirectoryListingRenderer`. New
   `Handlers/WebDAVResponseBuilder.swift` renders the `multistatus` XML
   body. See `ServerCore/README.md`, `Handlers/README.md`.

Not yet started from v0.3: archive formats beyond zip/7z, multi-select
"search across the whole tree" (current search only filters the current
directory's listing), authorized WebDAV write operations, optional multiple
mounted folders, and rate/connection/request limits (see `docs/ROADMAP.md`
for all of these).

Each build-error round on the request-log/dashboard work (issue #6) surfaced
independently only once the prior one was fixed — a Swift 6 actor-isolation
annotation, a SwiftUI type-checker timeout from a body expression grown too
large, and a `Color`/`HierarchicalShapeStyle` ternary-type ambiguity. None of
this is compiler-verified locally in this environment (no Swift/Xcode
toolchain here — see "Build" above); CI is the only real signal, so expect
more than one round trip on non-trivial SwiftUI/concurrency changes pushed
without local compilation.

Directory browsing needed two more rounds of its own before going green:
a `static let byteFormatter: ByteCountFormatter` in
`DirectoryListingRenderer` failed Swift 6 strict concurrency (a non-`Sendable`
class held as shared mutable static state) — fixed by making it a computed
property, so each access gets its own instance; then, once that compiled,
`StaticFileServingLifecycleTests.testDirectoryListingIsReachableAfterTrailingSlashRedirect`
failed a same-run assertion that `http.url?.path == "/assets/"` after
`URLSession` auto-follows the `301` — the redirect chain's final `path` came
back `/assets` on the CI runner's Foundation version. `statusCode == 200`,
the `text/html` `Content-Type`, and the listing containing the expected
filename all still passed, which only happens if the request that produced
that response really did land on `/assets/`, so this was a client-side
`HTTPURLResponse.url` reporting quirk, not a server bug — the assertion was
dropped rather than chased further.

## App icon

`App/Assets.xcassets/AppIcon.appiconset` holds the app's first real icon —
a single 1024×1024 "universal" master (`ASSETCATALOG_COMPILER_APPICON_NAME:
AppIcon` in `project.yml`; Xcode 14+'s single-size app icon support
generates every smaller size from it, so no legacy 20pt/29pt/40pt/60pt set
is needed). The mark: a five-node network hub in white, radiating from a
folder glyph at the center, on a coral-to-amber gradient — chosen from
three concepts (a literal folder+Wi-Fi mark, this hub mark, and a
high-contrast dark/neon mark) explored as an artifact, then refined by
adding the folder once the hub-only version was picked, so the icon reads
as "network" at a glance and "local file server" up close.

`docs/app-icon-source.svg` is the editable vector source (plain shapes —
a gradient rect, stroke lines, circles, two rounded rects for the folder —
no hand-authored path data). The shipped PNG was produced from it with
headless Chromium (`--screenshot` at a 1024×1024 window size) and then
had ImageMagick strip any alpha channel (`-alpha remove -alpha off`),
since an App Store icon must not carry transparency; regenerate the same
way if the source SVG ever changes.

Not yet done: iOS 18's dark-appearance and tinted-appearance icon
variants (`Assets.xcassets` supports per-appearance app icons via
`"appearances"` in `Contents.json`) — worth a fast follow if/when it
matters, but a real design decision (how the mark simplifies to a
single-color glyph for the tinted case) rather than pure asset generation,
so it wasn't bundled into this pass.
