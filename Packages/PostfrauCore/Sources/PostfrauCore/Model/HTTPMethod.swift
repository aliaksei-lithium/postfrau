import Foundation

/// An HTTP request method. Unknown verbs survive a round-trip through `custom`.
public enum HTTPMethod: Sendable, Hashable, Codable, CaseIterable, RawRepresentable {
    case get, post, put, patch, delete, head, options
    case custom(String)

    public static let allCases: [HTTPMethod] = [.get, .post, .put, .patch, .delete, .head, .options]

    public init(rawValue: String) {
        switch rawValue.uppercased() {
        case "GET": self = .get
        case "POST": self = .post
        case "PUT": self = .put
        case "PATCH": self = .patch
        case "DELETE": self = .delete
        case "HEAD": self = .head
        case "OPTIONS": self = .options
        case let other: self = .custom(other)
        }
    }

    public var rawValue: String {
        switch self {
        case .get: "GET"
        case .post: "POST"
        case .put: "PUT"
        case .patch: "PATCH"
        case .delete: "DELETE"
        case .head: "HEAD"
        case .options: "OPTIONS"
        case .custom(let verb): verb
        }
    }

    /// Methods that conventionally carry a request body. Postfrau still lets the user send one
    /// on any method; this only drives UI defaults.
    public var usuallyHasBody: Bool {
        switch self {
        case .post, .put, .patch: true
        case .get, .head, .options, .delete: false
        case .custom: true
        }
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        self.init(rawValue: try container.decode(String.self))
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}
