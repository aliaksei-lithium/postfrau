import Foundation

/// A loss-tolerant representation of arbitrary JSON.
///
/// Used to preserve fields Postfrau does not model (Postman `event[]` scripts,
/// `protocolProfileBehavior`, vendor extensions) so that import → export round-trips
/// keep them intact. Numbers are held as their literal text; they are re-encoded as an
/// integer when they fit `Int64` and as a `Decimal` otherwise, which preserves far more
/// precision than a `Double` round-trip would.
public enum JSONValue: Sendable, Hashable {
    case null
    case bool(Bool)
    case number(String)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])
}

extension JSONValue: Codable {
    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let bool = try? container.decode(Bool.self) {
            self = .bool(bool)
        } else if let int = try? container.decode(Int64.self) {
            self = .number(String(int))
        } else if let decimal = try? container.decode(Decimal.self) {
            self = .number(decimal.description)
        } else if let string = try? container.decode(String.self) {
            self = .string(string)
        } else if let array = try? container.decode([JSONValue].self) {
            self = .array(array)
        } else if let object = try? container.decode([String: JSONValue].self) {
            self = .object(object)
        } else {
            throw DecodingError.dataCorruptedError(
                in: container, debugDescription: "Unsupported JSON value")
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null:
            try container.encodeNil()
        case .bool(let value):
            try container.encode(value)
        case .number(let text):
            if let int = Int64(text) {
                try container.encode(int)
            } else if let decimal = Decimal(string: text) {
                try container.encode(decimal)
            } else {
                try container.encode(text)
            }
        case .string(let value):
            try container.encode(value)
        case .array(let values):
            try container.encode(values)
        case .object(let values):
            try container.encode(values)
        }
    }
}

extension JSONValue {
    /// The value as a string, for the common case of reading a scalar out of `extras`.
    public var stringValue: String? {
        switch self {
        case .string(let value): value
        case .number(let text): text
        case .bool(let value): String(value)
        default: nil
        }
    }

    public var boolValue: Bool? {
        switch self {
        case .bool(let value): value
        case .string(let text): Bool(text)
        default: nil
        }
    }

    public var arrayValue: [JSONValue]? {
        if case .array(let values) = self { return values }
        return nil
    }

    public var objectValue: [String: JSONValue]? {
        if case .object(let values) = self { return values }
        return nil
    }

    public subscript(key: String) -> JSONValue? {
        objectValue?[key]
    }
}
