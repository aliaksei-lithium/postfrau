import Foundation

/// Where an API key is placed on the wire.
public enum APIKeyLocation: String, Sendable, Hashable, Codable, CaseIterable {
    case header
    case query

    public var displayName: String {
        switch self {
        case .header: "Header"
        case .query: "Query Param"
        }
    }
}

/// Authentication helper attached to a request, folder or collection.
///
/// `.inherit` walks up the folder chain to the collection; a collection whose auth is
/// `.inherit` behaves as `.none` (see `AuthResolver`).
public enum Auth: Sendable, Hashable, Codable {
    case inherit
    case none
    case basic(username: String, password: String)
    case bearer(token: String)
    case apiKey(key: String, value: String, location: APIKeyLocation)

    public var kind: Kind {
        switch self {
        case .inherit: .inherit
        case .none: .none
        case .basic: .basic
        case .bearer: .bearer
        case .apiKey: .apiKey
        }
    }

    /// The discriminator, separated out so the UI can offer a picker without associated values.
    public enum Kind: String, Sendable, Hashable, Codable, CaseIterable {
        case inherit, none, basic, bearer, apiKey

        public var displayName: String {
            switch self {
            case .inherit: "Inherit"
            case .none: "No Auth"
            case .basic: "Basic"
            case .bearer: "Bearer Token"
            case .apiKey: "API Key"
            }
        }
    }

    /// An empty value of the given kind, preserving nothing. Used when the user switches type.
    public static func empty(_ kind: Kind) -> Auth {
        switch kind {
        case .inherit: .inherit
        case .none: .none
        case .basic: .basic(username: "", password: "")
        case .bearer: .bearer(token: "")
        case .apiKey: .apiKey(key: "", value: "", location: .header)
        }
    }

    private enum CodingKeys: String, CodingKey {
        case type, username, password, token, key, value, location
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try c.decodeIfPresent(Kind.self, forKey: .type) ?? .none
        switch kind {
        case .inherit:
            self = .inherit
        case .none:
            self = .none
        case .basic:
            self = .basic(
                username: try c.decodeIfPresent(String.self, forKey: .username) ?? "",
                password: try c.decodeIfPresent(String.self, forKey: .password) ?? "")
        case .bearer:
            self = .bearer(token: try c.decodeIfPresent(String.self, forKey: .token) ?? "")
        case .apiKey:
            self = .apiKey(
                key: try c.decodeIfPresent(String.self, forKey: .key) ?? "",
                value: try c.decodeIfPresent(String.self, forKey: .value) ?? "",
                location: try c.decodeIfPresent(APIKeyLocation.self, forKey: .location) ?? .header)
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(kind, forKey: .type)
        switch self {
        case .inherit, .none:
            break
        case .basic(let username, let password):
            try c.encode(username, forKey: .username)
            try c.encode(password, forKey: .password)
        case .bearer(let token):
            try c.encode(token, forKey: .token)
        case .apiKey(let key, let value, let location):
            try c.encode(key, forKey: .key)
            try c.encode(value, forKey: .value)
            try c.encode(location, forKey: .location)
        }
    }
}
