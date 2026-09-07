import Foundation

/// A named value available to `{{substitution}}`.
///
/// When `isSecret` is true the value lives in the Keychain and `value` is empty on disk;
/// it is populated in memory only while the app is running.
public struct Variable: Sendable, Hashable, Codable, Identifiable {
    public var id: UUID
    public var key: String
    public var value: String
    public var enabled: Bool
    public var isSecret: Bool

    public init(
        id: UUID = UUID(),
        key: String = "",
        value: String = "",
        enabled: Bool = true,
        isSecret: Bool = false
    ) {
        self.id = id
        self.key = key
        self.value = value
        self.enabled = enabled
        self.isSecret = isSecret
    }

    public var isEmpty: Bool { key.isEmpty && value.isEmpty }

    private enum CodingKeys: String, CodingKey {
        case id, key, value, enabled, isSecret
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        key = try c.decodeIfPresent(String.self, forKey: .key) ?? ""
        value = try c.decodeIfPresent(String.self, forKey: .value) ?? ""
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        isSecret = try c.decodeIfPresent(Bool.self, forKey: .isSecret) ?? false
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(key, forKey: .key)
        // A secret's value never reaches the data folder; it lives in the Keychain.
        try c.encode(isSecret ? "" : value, forKey: .value)
        try c.encode(enabled, forKey: .enabled)
        try c.encode(isSecret, forKey: .isSecret)
    }
}
