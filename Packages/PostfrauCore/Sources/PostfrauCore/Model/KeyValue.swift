import Foundation

/// One row of a key/value table: query params, headers, urlencoded body fields, variables.
public struct KeyValue: Sendable, Hashable, Codable, Identifiable {
    public var id: UUID
    public var key: String
    public var value: String
    public var enabled: Bool
    public var description: String?

    public init(
        id: UUID = UUID(),
        key: String = "",
        value: String = "",
        enabled: Bool = true,
        description: String? = nil
    ) {
        self.id = id
        self.key = key
        self.value = value
        self.enabled = enabled
        self.description = description
    }

    /// True when the row carries nothing the user typed — the trailing placeholder row.
    public var isEmpty: Bool {
        key.isEmpty && value.isEmpty && (description ?? "").isEmpty
    }

    private enum CodingKeys: String, CodingKey {
        case id, key, value, enabled, description
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        key = try c.decodeIfPresent(String.self, forKey: .key) ?? ""
        value = try c.decodeIfPresent(String.self, forKey: .value) ?? ""
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        description = try c.decodeIfPresent(String.self, forKey: .description)
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(key, forKey: .key)
        try c.encode(value, forKey: .value)
        try c.encode(enabled, forKey: .enabled)
        try c.encodeIfPresent(description, forKey: .description)
    }
}

extension [KeyValue] {
    /// The rows a request will actually send: enabled and with a non-empty key.
    public var active: [KeyValue] {
        filter { $0.enabled && !$0.key.isEmpty }
    }
}
