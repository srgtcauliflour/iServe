import Foundation

/// Parses a WebDAV `Destination` header (`MOVE`/`COPY`, RFC 4918 §10.3) —
/// an absolute URL or a bare path — into a request path suitable for
/// `SecurePathResolver.resolve(requestPath:)`. Shared by
/// `Handlers/StaticFileHandler.swift` and `Handlers/MountRouter.swift`
/// (v0.3, `docs/adr/0007-multiple-mounted-folders.md`) rather than
/// duplicated, since both need exactly the same parsing.
enum WebDAVDestinationHeaderParser {
    /// Uses `URLComponents.percentEncodedPath` specifically, never
    /// `URL.path` (which silently percent-*decodes*) — resolving an
    /// already-decoded string here would resolve a subtly different path
    /// than the one the client meant, breaking this server's single-decode
    /// discipline (`docs/SECURITY.md`).
    static func path(from header: String?) -> String? {
        guard let header, !header.isEmpty, let components = URLComponents(string: header) else { return nil }
        let path = components.percentEncodedPath
        return path.isEmpty ? nil : path
    }
}
