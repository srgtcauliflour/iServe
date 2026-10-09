# ADR-0011: Remove the native in-app file manager (server-only product scope)

- Status: Accepted.
- Date: 2026-10-09

## Context
Since v0.3, the app has shipped two independent top-level destinations (`App/RootTabView.swift`): a "Files" tab — a native, in-app file manager (`App/FileManagerScreen.swift`/`FileManagerViewModel.swift`) for browsing, previewing, editing, renaming, moving, copying, deleting and zip/unzip-ing the device's own on-device storage — and a "File Sharing" tab (`ServerDashboard`), the actual web/file server this project exists to build. The two were always deliberately independent: the file manager browses the app's own sandboxed Documents directory (or any other location a person separately picks), entirely unrelated to whatever folder is or isn't selected for sharing.

Heading into App Store submission, the product is being narrowed back to a single, focused capability: a foreground web/file **server**. A native file manager duplicates what Files.app, and any third-party file manager already installed, already does well — it was a reasonable v0.3 experiment, but it is not this app's reason to exist, and carrying it adds real review-surface and maintenance cost (its own `ArchiveManager`-backed zip/unzip/7z paths, `QuickLookPreview`, in-place text editing, its own security-scoped bookmark lifecycle) for a feature orthogonal to the actual product.

This is a deliberate, explicit product-scope decision from the project owner, not a bug fix or a response to a spec/implementation conflict — recorded here per `AGENTS.md`'s "significant decisions require an ADR" rule.

## Decision
Remove the native file manager entirely from the shipping app:
- Deleted: `App/FileManagerScreen.swift`, `App/FileManagerViewModel.swift`, `App/RootTabView.swift`, `Tests/iServeTests/FileManagerViewModelTests.swift`.
- `App/iServeApp.swift` now presents `ServerDashboard` directly as the window's root view — no tab bar, since there is only one destination. `ServerDashboard` already wrapped itself in its own `NavigationStack`, so this needed no structural change to that screen.
- `project.yml` drops `INFOPLIST_KEY_UIFileSharingEnabled`/`INFOPLIST_KEY_LSSupportsOpeningDocumentsInPlace` from both the `iServe` and `iServeWithPHP` targets — those two keys existed solely to make the file manager's own Documents-directory browsing reachable from the Files app/Finder; with that screen gone, they serve no remaining purpose.

**What is explicitly kept, because it is shared server infrastructure, not file-manager-specific:**
- `FileSystem/FolderRootManager.swift`/`FolderAccess.swift` (the primary-folder + additional-mounts security-scoped bookmark machinery the server itself depends on) — only their doc comments' references to the now-deleted file manager are corrected.
- `Transfer/ArchiveManager.swift` (ZIPFoundation/SWCompression-backed zip/unzip/7z-extract) — still load-bearing for the server's own streaming-ZIP multi-file download feature (`Handlers/`), unrelated to the file manager's local archive UI that also happened to use it.

**Full current state preserved**: the pre-removal app (file manager + server, as of this decision) is preserved unchanged on the `experimental` branch, branched directly from `main` before any removal commit — nothing here is a data-loss risk, only a product-scope one, and it is fully reversible by returning to that branch if this decision is ever revisited.

## Consequences

### Positive
- A materially smaller, more focused app to review, test, and reason about security for — `AGENTS.md`'s own module boundaries already treated `App/`'s file-manager screens as presentation-layer, so no `ServerCore`/`FileSystem`/`Handlers`/`Transfer`/`Security` boundary needed to move.
- Removes an entire class of local-filesystem-mutation code (rename/move/copy/delete across arbitrary device locations) from the App Store review surface for a v1.0 submission, leaving only the already-reviewed "serve a selected folder" trust boundary.
- Clears room for the planned visual redesign (a professional, Liquid-Glass-based light/dark UI) to focus entirely on the server experience, without also having to carry a second, unrelated screen through that redesign.

### Costs
- The v0.3 file manager work (ZIPFoundation/SWCompression integration, `NSFileCoordinator`-based coordinated reads, `QLPreviewController` wrapping, in-place text editing) is no longer part of the shipping product. None of it is lost — it is intact on `experimental` — but it will bit-rot relative to `main` the longer the two diverge, and reviving it later would mean re-merging rather than a clean cherry-pick.
- `docs/ROADMAP.md`'s v0.3 section documents the file manager as a shipped deliverable; that history is left as an accurate record of what was built and when, with a note added that it was later removed by this ADR, rather than rewritten as if it never existed.

## Revisit triggers
Revisit if App Store feedback or real usage shows a need for even minimal on-device file organization (e.g. renaming a file before sharing it) that the server's own upload/directory-listing UI can't reasonably cover. If so, treat it as a fresh, deliberately-scoped feature built against the current UI, informed by (but not simply restored from) `experimental`'s own implementation — not a revert of this decision.
