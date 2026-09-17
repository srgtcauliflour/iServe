import Foundation

/// One of the server profiles `docs/MASTER-SPEC.md` section 4 defines. Each
/// case bundles the capabilities a session grants together, rather than
/// letting directory browsing and uploads vary independently — the same
/// "explicit capability, never implied" posture `docs/SECURITY.md` already
/// applies to uploads on their own now applies to the whole bundle. Threaded
/// from `ServerCoordinator` down through `ServerService.start(profile:credentials:)`
/// to `Handlers/StaticFileHandler.swift`'s `allowDirectoryListing`/`allowUploads`.
enum ServerProfile: String, CaseIterable, Sendable, Identifiable, Hashable {
    case websiteReadOnly
    case fileSharing
    case fileDrop
    case fullAccess

    var id: String { rawValue }

    /// Cases meaningful to offer as a choice today. `.fullAccess` is defined
    /// now so a later authorized-write capability (WebDAV) doesn't need
    /// another `ServerService.start` signature change, but it stays out of
    /// the picker until something actually distinguishes it from
    /// `.fileDrop` — offering two profiles that behave identically would be
    /// actively misleading rather than a harmless placeholder.
    static let selectable: [ServerProfile] = [.websiteReadOnly, .fileSharing, .fileDrop]

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
        case .fullAccess: "Reserved for authorized write operations (e.g. WebDAV) once they ship."
        }
    }
}
