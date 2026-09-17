import Foundation

/// Renders a minimal, mobile-friendly HTML directory listing for a folder
/// that has no `index.html`/`index.htm`. Only ever given a directory URL
/// `SecurePathResolver` has already authorized; it reads that directory's
/// immediate contents and nothing else.
///
/// Hidden entries (names starting with ".") are omitted, matching
/// `docs/SECURITY.md`'s "do not expose hidden/special metadata by default"
/// posture — an exact request for one still resolves normally; it's only
/// left out of the listing itself.
enum DirectoryListingRenderer {
    // Computed, not stored: ByteCountFormatter is a non-Sendable class, so a
    // `static let` would be shared mutable state under Swift 6 strict
    // concurrency. A fresh instance per access has no such state to share.
    private static var byteFormatter: ByteCountFormatter {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter
    }

    struct Entry {
        let name: String
        let isDirectory: Bool
        let size: Int?
    }

    /// `requestPath` is the remote-facing directory path this listing is for
    /// (e.g. "/assets/"), always ending in "/" — used only to render a title
    /// and decide whether an "up" link makes sense, never to construct a
    /// filesystem path. Entry links are relative to it, so the caller must
    /// only serve this for a request path the client's browser actually has
    /// as its current URL (i.e. after any trailing-slash redirect).
    ///
    /// `allowUploads` (v0.2) adds a plain HTML upload form — no JavaScript,
    /// works with `StaticFileHandler`'s multipart handling alone — when the
    /// caller has already decided this session/directory accepts uploads.
    /// The renderer itself makes no such decision; see
    /// `Handlers/StaticFileHandler.swift`'s `authorizeUpload(directoryPath:)`.
    ///
    /// Non-empty listings (v0.3) are always wrapped in a second, plain
    /// `method="POST"` form (default `enctype`, so the browser sends
    /// `application/x-www-form-urlencoded`) with one checkbox per entry
    /// (`name="select"`) and a "Download Selected (.zip)" button —
    /// unconditional, unlike uploads, since packaging already-servable
    /// files as a ZIP exposes nothing a plain GET of each one wouldn't.
    /// See `ServerCore/HTTPConnection.swift`'s `beginZipDownload(for:leftoverBodyBytes:)`.
    static func render(directoryURL: URL, requestPath: String, allowUploads: Bool = false) -> Data {
        let entries = listEntries(in: directoryURL)
        var html = """
        <!DOCTYPE html>
        <html>
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <title>Index of \(escapeText(requestPath))</title>
        <style>
        body { font-family: -apple-system, sans-serif; margin: 2em auto; max-width: 40em; color: #1c1c1e; }
        h1 { font-size: 1.1em; word-break: break-all; }
        ul { list-style: none; padding: 0; }
        li { padding: 0.6em 0; border-bottom: 1px solid #e5e5ea; display: flex; justify-content: space-between; align-items: baseline; }
        .entry { display: flex; align-items: baseline; gap: 0.5em; min-width: 0; }
        a { color: #007aff; text-decoration: none; word-break: break-all; }
        .size { color: #8e8e93; font-size: 0.85em; white-space: nowrap; padding-left: 1em; }
        .zipbar { margin: 1em 0; text-align: right; }
        form.upload { margin: 1.5em 0; padding: 1em; border: 1px dashed #c7c7cc; border-radius: 8px; }
        form.upload button { margin-left: 0.5em; }
        </style>
        </head>
        <body>
        <h1>Index of \(escapeText(requestPath))</h1>

        """

        html += entries.isEmpty ? "<ul>\n" : "<form method=\"POST\">\n<ul>\n"

        if requestPath != "/" {
            html += "<li><a href=\"../\">.. (up)</a></li>\n"
        }

        for entry in entries {
            let href = escapeAttribute(entry.name) + (entry.isDirectory ? "/" : "")
            let label = escapeText(entry.name) + (entry.isDirectory ? "/" : "")
            let checkbox = "<input type=\"checkbox\" name=\"select\" value=\"\(escapeText(entry.name))\">"
            if let size = entry.size {
                let sizeText = byteFormatter.string(fromByteCount: Int64(size))
                html += "<li><span class=\"entry\">\(checkbox)<a href=\"\(href)\">\(label)</a></span>"
                html += "<span class=\"size\">\(escapeText(sizeText))</span></li>\n"
            } else {
                html += "<li><span class=\"entry\">\(checkbox)<a href=\"\(href)\">\(label)</a></span></li>\n"
            }
        }

        if entries.isEmpty {
            html += "<li>Empty folder</li>\n</ul>\n"
        } else {
            html += """
            </ul>
            <div class="zipbar"><button type="submit">Download Selected (.zip)</button></div>
            </form>

            """
        }

        if allowUploads {
            // No `action`: submits back to this same directory URL,
            // whatever path it was actually reached at.
            html += """
            <form class="upload" method="POST" enctype="multipart/form-data">
            <input type="file" name="file" multiple>
            <button type="submit">Upload</button>
            </form>

            """
        }

        html += """
        </body>
        </html>
        """
        return Data(html.utf8)
    }

    private static func listEntries(in directoryURL: URL) -> [Entry] {
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        )) ?? []

        let entries: [Entry] = contents.compactMap { url in
            let name = url.lastPathComponent
            guard !name.hasPrefix(".") else { return nil }
            let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey])
            let isDirectory = values?.isDirectory ?? false
            let size = isDirectory ? nil : values?.fileSize
            return Entry(name: name, isDirectory: isDirectory, size: size)
        }

        return entries.sorted { lhs, rhs in
            if lhs.isDirectory != rhs.isDirectory { return lhs.isDirectory }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
    }

    private static func escapeText(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    /// Percent-encodes a single filesystem entry name for use as an `href`
    /// value, then HTML-escapes the result for embedding in the attribute.
    private static func escapeAttribute(_ text: String) -> String {
        let encoded = text.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? text
        return escapeText(encoded)
    }
}
