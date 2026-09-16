import Foundation

/// Maps a file extension to a MIME type for the v0.1 static handler. Anything
/// unrecognized gets a safe generic binary fallback rather than a guess.
enum MIMEType {
    static let binaryFallback = "application/octet-stream"

    private static let byExtension: [String: String] = [
        // Web
        "html": "text/html; charset=utf-8",
        "htm": "text/html; charset=utf-8",
        "css": "text/css; charset=utf-8",
        "js": "text/javascript; charset=utf-8",
        "mjs": "text/javascript; charset=utf-8",
        "json": "application/json",
        "xml": "application/xml",
        "txt": "text/plain; charset=utf-8",
        "csv": "text/csv; charset=utf-8",
        "svg": "image/svg+xml",
        // Images
        "png": "image/png",
        "jpg": "image/jpeg",
        "jpeg": "image/jpeg",
        "gif": "image/gif",
        "webp": "image/webp",
        "ico": "image/x-icon",
        "bmp": "image/bmp",
        // Audio
        "mp3": "audio/mpeg",
        "wav": "audio/wav",
        "m4a": "audio/mp4",
        "aac": "audio/aac",
        "flac": "audio/flac",
        // Video
        "mp4": "video/mp4",
        "mov": "video/quicktime",
        "webm": "video/webm",
        "m4v": "video/x-m4v",
        // Documents
        "pdf": "application/pdf",
        "doc": "application/msword",
        "docx": "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
        "xls": "application/vnd.ms-excel",
        "xlsx": "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
        "ppt": "application/vnd.ms-powerpoint",
        "pptx": "application/vnd.openxmlformats-officedocument.presentationml.presentation",
        // Archives
        "zip": "application/zip",
        "gz": "application/gzip",
        "tar": "application/x-tar",
        // Fonts
        "woff": "font/woff",
        "woff2": "font/woff2",
        "ttf": "font/ttf",
        "otf": "font/otf",
    ]

    static func forPathExtension(_ pathExtension: String) -> String {
        byExtension[pathExtension.lowercased()] ?? binaryFallback
    }
}
