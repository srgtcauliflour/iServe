import Foundation

/// Renders a WebDAV `PROPFIND` response body (v0.3 read-only WebDAV, RFC
/// 4918 §9.1) as a `DAV:` `multistatus` XML document. Given only
/// already-resolved entries `Handlers/StaticFileHandler.swift` computed; it
/// opens nothing itself, the same "renderer never touches the filesystem"
/// split as `DirectoryListingRenderer`.
///
/// Every entry gets the same fixed property set regardless of what the
/// client's request body actually asked for — this server never parses
/// that body at all. See `docs/adr/0004-webdav-read-operations.md` for why.
enum WebDAVResponseBuilder {
    struct Entry {
        /// The resource's request path, already trailing-slash-terminated
        /// for a collection.
        let href: String
        let isCollection: Bool
        /// `nil` for a collection.
        let length: Int?
        let lastModified: Date?
        /// `nil` for a collection.
        let contentType: String?
        let displayName: String
    }

    // Computed, not stored, for the same reason `DirectoryListingRenderer`'s
    // `byteFormatter` is: `DateFormatter` is a non-Sendable class, so a
    // `static let` would be shared mutable state under Swift 6 strict
    // concurrency.
    private static var rfc1123Formatter: DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss 'GMT'"
        return formatter
    }

    static func multiStatus(entries: [Entry]) -> Data {
        var xml = "<?xml version=\"1.0\" encoding=\"utf-8\"?>\n<D:multistatus xmlns:D=\"DAV:\">\n"
        for entry in entries {
            xml += render(entry)
        }
        xml += "</D:multistatus>\n"
        return Data(xml.utf8)
    }

    private static func render(_ entry: Entry) -> String {
        var properties = entry.isCollection
            ? "<D:resourcetype><D:collection/></D:resourcetype>\n"
            : "<D:resourcetype/>\n"
        if let length = entry.length {
            properties += "<D:getcontentlength>\(length)</D:getcontentlength>\n"
        }
        if let contentType = entry.contentType {
            properties += "<D:getcontenttype>\(escape(contentType))</D:getcontenttype>\n"
        }
        if let lastModified = entry.lastModified {
            properties += "<D:getlastmodified>\(rfc1123Formatter.string(from: lastModified))</D:getlastmodified>\n"
        }
        properties += "<D:displayname>\(escape(entry.displayName))</D:displayname>\n"

        return """
        <D:response>
        <D:href>\(escape(entry.href))</D:href>
        <D:propstat>
        <D:prop>
        \(properties)</D:prop>
        <D:status>HTTP/1.1 200 OK</D:status>
        </D:propstat>
        </D:response>

        """
    }

    private static func escape(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }
}
