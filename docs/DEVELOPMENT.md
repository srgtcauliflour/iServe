# Development guide

## Bootstrap status

The initial repository contained only planning documents and six v0.1 issues. This
change starts issue #1 with a SwiftUI iPhone/iPad dashboard, an injectable
`ServerCoordinator`/`ServerService` lifecycle boundary, unit tests, and CI.

**This is not a working server yet.** Choose Folder and Start Server are disabled
and labelled as future work. No filesystem access, listener, fabricated endpoint,
PHP runtime, WebDAV dependency or background mode is included.

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
- Other top-level module directories explain ownership for subsequent issues.
- `Tests/iServeTests/`: coordinator shutdown and initial-state tests.

On an inactive or background scene transition, the app calls the service's
idempotent stop operation. Returning active does not start anything. The future
listener must cancel connections before releasing scoped folder access and must
report asynchronous readiness before publishing a running state or endpoint.
The bootstrap intentionally does not invent a synchronous network-start contract.

## Manual acceptance (macOS/iOS required)

1. Generate the project and launch on both iPhone and iPad simulators.
2. Confirm dashboard, empty folder state, stopped status and preview explanation.
3. Confirm Choose Folder and Start Server are disabled; no endpoint is advertised.
4. Rotate each simulator and enable the largest accessibility text size. All
   explanatory text and controls must remain reachable by scrolling.
5. With VoiceOver enabled, verify headings and disabled controls are understandable.
6. Leave the app and return. Status remains stopped; no automatic start occurs.

A clean simulator build and these manual checks remain part of issue #1's gate.
Coordinator tests do not prove device lifecycle or filesystem/network correctness.
The development environment used to author this change is Linux without Swift or
Xcode; iOS compilation and XCTest require the accompanying macOS CI or a Mac.

## Next tasks

1. Issue #2: Files picker, bookmark restoration and balanced scoped-access lifetimes
   with recoverable errors and tests. Replace the disabled folder action.
2. Issue #3: secure path resolver and hostile-path/symlink corpus, before file access.
3. Issue #4: bounded HTTP parser and Network.framework listener, including readiness,
   cancellation, timeouts and connection limits. Replace the disabled start action.
4. Issue #5: static routing, MIME, GET/HEAD and bounded streaming/backpressure.
5. Issue #6: real local endpoints, sanitized bounded logs and dashboard integration.

PHP, WebDAV, archives and public-reachability tooling stay in their agreed later
milestones. Do not close the v0.1 acceptance gate until a real second LAN device
loads the selected site and traversal/large-file checks pass.
