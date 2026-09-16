import Foundation

/// The single filesystem path-resolution authority for remote-facing requests.
///
/// Every handler that turns an HTTP request target into a filesystem path must go
/// through this resolver instead of constructing a path itself. It implements the
/// pipeline required by `docs/SECURITY.md`: decode the request path exactly once,
/// reject forbidden components, then walk the path one component at a time so every
/// existing intermediate symlink is resolved and checked against the authorized root
/// before the next component is appended.
struct SecurePathResolver: Sendable {
    enum ResolutionError: Error, Equatable {
        /// The request target did not begin with "/".
        case invalidRequestPath
        /// A "%XX" escape was truncated, used non-hex digits, or decoded to invalid UTF-8.
        case malformedEncoding
        /// A decoded component contained a null or control character.
        case invalidCharacter
        /// A decoded component was empty, ".", "..", or contained "/" or "\\".
        case forbiddenComponent
        /// An existing component (via a symlink or otherwise) resolved outside the root.
        case escapesRoot
        /// A non-final component does not exist or is not a directory.
        case notFound
    }

    /// The authorized root, canonicalized once at construction time.
    let root: URL

    /// `root` must already be an existing directory reachable under active
    /// security-scoped access; this resolver does not acquire or manage access itself.
    init(root: URL) {
        self.root = root.resolvingSymlinksInPath().standardizedFileURL
    }

    /// Resolves an HTTP request target (e.g. "/assets/style.css") to an authorized
    /// filesystem URL guaranteed to remain within `root`, or throws a `ResolutionError`
    /// that is safe to surface to a remote client without leaking local paths.
    func resolve(requestPath: String) throws -> URL {
        guard requestPath.hasPrefix("/") else { throw ResolutionError.invalidRequestPath }
        let components = try Self.decodeComponents(of: requestPath)

        var current = root
        for (index, component) in components.enumerated() {
            let isLast = index == components.count - 1
            let candidate = current.appendingPathComponent(component)

            var isDirectory: ObjCBool = false
            let exists = FileManager.default.fileExists(atPath: candidate.path, isDirectory: &isDirectory)

            guard exists else {
                guard isLast else { throw ResolutionError.notFound }
                current = candidate
                break
            }
            guard isLast || isDirectory.boolValue else { throw ResolutionError.notFound }

            // Resolve symlinks per-component so an intermediate symlink cannot smuggle
            // the walk outside root before the final component is even reached.
            let canonical = candidate.resolvingSymlinksInPath()
            guard Self.isContained(canonical, within: root) else { throw ResolutionError.escapesRoot }
            current = canonical
        }

        guard Self.isContained(current, within: root) else { throw ResolutionError.escapesRoot }
        return current
    }

    // MARK: - Component decoding and validation

    private static func decodeComponents(of requestPath: String) throws -> [String] {
        var components: [String] = []
        for raw in requestPath.split(separator: "/", omittingEmptySubsequences: true) {
            let decoded = try percentDecode(raw)
            try validate(decoded)
            components.append(decoded)
        }
        return components
    }

    /// Decodes "%XX" escapes exactly once. A component that itself decodes to text
    /// containing "%XX" again (double encoding) is left as that literal text, which
    /// `validate` treats as an ordinary (almost certainly nonexistent) file name
    /// rather than a second traversal opportunity.
    private static func percentDecode(_ raw: Substring) throws -> String {
        let bytes = Array(raw.utf8)
        var out: [UInt8] = []
        out.reserveCapacity(bytes.count)
        var index = 0
        while index < bytes.count {
            let byte = bytes[index]
            if byte == UInt8(ascii: "%") {
                guard index + 2 < bytes.count,
                      let high = hexDigit(bytes[index + 1]),
                      let low = hexDigit(bytes[index + 2]) else {
                    throw ResolutionError.malformedEncoding
                }
                out.append((high << 4) | low)
                index += 3
            } else {
                out.append(byte)
                index += 1
            }
        }
        guard let decoded = String(bytes: out, encoding: .utf8) else {
            throw ResolutionError.malformedEncoding
        }
        return decoded
    }

    private static func hexDigit(_ byte: UInt8) -> UInt8? {
        switch byte {
        case UInt8(ascii: "0")...UInt8(ascii: "9"): return byte - UInt8(ascii: "0")
        case UInt8(ascii: "a")...UInt8(ascii: "f"): return byte - UInt8(ascii: "a") + 10
        case UInt8(ascii: "A")...UInt8(ascii: "F"): return byte - UInt8(ascii: "A") + 10
        default: return nil
        }
    }

    private static func validate(_ component: String) throws {
        guard !component.isEmpty, component != ".", component != ".." else {
            throw ResolutionError.forbiddenComponent
        }
        guard !component.contains("/"), !component.contains("\\") else {
            throw ResolutionError.forbiddenComponent
        }
        for scalar in component.unicodeScalars where scalar.value < 0x20 || scalar.value == 0x7F {
            throw ResolutionError.invalidCharacter
        }
    }

    private static func isContained(_ target: URL, within root: URL) -> Bool {
        let rootPath = root.path
        let targetPath = target.path
        if targetPath == rootPath { return true }
        let prefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
        return targetPath.hasPrefix(prefix)
    }
}
