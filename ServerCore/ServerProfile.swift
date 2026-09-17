import Foundation

/// One of the server profiles `docs/MASTER-SPEC.md` section 4 defines. Each
/// case bundles the capabilities a session grants together, rather than
/// letting directory browsing, uploads and WebDAV writes vary independently
/// — the same "explicit capability, never implied" posture `docs/SECURITY.md`
/// already applies to uploads on their own now applies to the whole bundle.
/// Threaded from `ServerCoordinator` down through
/// `ServerService.start(profile:credentials:)` to
/// `Handlers/StaticFileHandler.swift`'s `allowDirectoryListing`/
/// `allowUploads`/`allowWebDAVWrites`.
enum ServerProfile: String, CaseIterable, Sendable, Identifiable, Hashable {
    case websiteReadOnly
    case fileSharing
    case fileDrop
    case fullAccess

    var id: String { rawValue }

    /// Every case is meaningful to offer as a choice: `.fullAccess`
    /// (`docs/adr/0005-webdav-write-operations.md`) now authorizes
    /// `MKCOL`/`PUT`/`DELETE`/`MOVE`/`COPY`, finally distinguishing it from
    /// `.fileDrop` rather than being an inert placeholder.
    static let selectable: [ServerProfile] = [.websiteReadOnly, .fileSharing, .fileDrop, .fullAccess]

    /// Whether a directory with no index file gets a generated
    /// `DirectoryListingRenderer` listing, or a plain `404`. Website mode is
    /// for serving a site's own pages, not for browsing whatever else is in
    /// the selected folder.
    var allowsDirectoryListing: Bool {
        switch self {
        case .websiteReadOnly: false
        case .fileSharing, .fileDrop, .fullAccess: true
        }
    }

    /// Whether a POST multipart upload is authorized at all
    /// (`StaticFileHandler.authorizeUpload`/`authorizeUploadedFile`).
    var allowsUploads: Bool {
        switch self {
        case .websiteReadOnly, .fileSharing: false
        case .fileDrop, .fullAccess: true
        }
    }

    /// Whether WebDAV `MKCOL`/`PUT`/`DELETE`/`MOVE`/`COPY` are authorized at
    /// all (`docs/adr/0005-webdav-write-operations.md`). Unlike a browser
    /// upload, WebDAV `PUT` is allowed to overwrite an existing file —
    /// enabling this is the explicit, one-time opt-in into that.
    var allowsWebDAVWrites: Bool {
        switch self {
        case .websiteReadOnly, .fileSharing, .fileDrop: false
        case .fullAccess: true
        }
    }

    var displayName: String {
        switch self {
        case .websiteReadOnly: "Website / Read Only"
        case .fileSharing: "File Sharing"
        case .fileDrop: "File Drop"
        case .fullAccess: "Full Access"
        }
    }

    var summary: String {
        switch self {
        case .websiteReadOnly: "Serves index pages only. No directory browsing, no uploads."
        case .fileSharing: "Browse and download files. No uploads."
        case .fileDrop: "Browse, download, and upload files. No destructive operations."
        case .fullAccess: "Full WebDAV access: create, overwrite, move, copy, and delete files and folders."
        }
    }
}
