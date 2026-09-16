import Foundation

/// An ordered, case-insensitive-lookup header list. Preserves insertion order and
/// duplicate fields (e.g. repeated `Set-Cookie`-style headers) exactly as received.
struct HTTPHeaderField: Equatable, Sendable {
    let name: String
    let value: String
}

struct HTTPHeaders: Sendable, Equatable {
    private(set) var fields: [HTTPHeaderField] = []

    init() {}

    mutating func add(name: String, value: String) {
        fields.append(HTTPHeaderField(name: name, value: value))
    }

    /// The value of the first field whose name matches case-insensitively, if any.
    subscript(name: String) -> String? {
        fields.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }?.value
    }

    var count: Int { fields.count }
}
