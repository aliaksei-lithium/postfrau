import Foundation

/// Per-request transport options.
public struct RequestSettings: Sendable, Hashable, Codable {
    public var followRedirects: Bool
    public var maxRedirects: Int
    public var timeoutSeconds: Double
    public var verifyTLS: Bool
    public var sendCookies: Bool
    public var encodeURL: Bool

    public init(
        followRedirects: Bool = true,
        maxRedirects: Int = 10,
        timeoutSeconds: Double = 30,
        verifyTLS: Bool = true,
        sendCookies: Bool = true,
        encodeURL: Bool = true
    ) {
        self.followRedirects = followRedirects
        self.maxRedirects = maxRedirects
        self.timeoutSeconds = timeoutSeconds
        self.verifyTLS = verifyTLS
        self.sendCookies = sendCookies
        self.encodeURL = encodeURL
    }

    private enum CodingKeys: String, CodingKey {
        case followRedirects, maxRedirects, timeoutSeconds, verifyTLS, sendCookies, encodeURL
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let fallback = RequestSettings()
        followRedirects = try c.decodeIfPresent(Bool.self, forKey: .followRedirects) ?? fallback.followRedirects
        maxRedirects = try c.decodeIfPresent(Int.self, forKey: .maxRedirects) ?? fallback.maxRedirects
        timeoutSeconds = try c.decodeIfPresent(Double.self, forKey: .timeoutSeconds) ?? fallback.timeoutSeconds
        verifyTLS = try c.decodeIfPresent(Bool.self, forKey: .verifyTLS) ?? fallback.verifyTLS
        sendCookies = try c.decodeIfPresent(Bool.self, forKey: .sendCookies) ?? fallback.sendCookies
        encodeURL = try c.decodeIfPresent(Bool.self, forKey: .encodeURL) ?? fallback.encodeURL
    }
}

/// A single saved request. `url` is the raw text the user typed and may contain `{{variables}}`.
public struct RequestItem: Sendable, Hashable, Codable, Identifiable {
    public var id: UUID
    public var name: String
    public var method: HTTPMethod
    public var url: String
    public var params: [KeyValue]
    public var headers: [KeyValue]
    public var auth: Auth
    public var body: RequestBody
    public var settings: RequestSettings
    public var description: String?
    /// Fields from an imported document that Postfrau does not model, kept so export round-trips.
    public var extras: [String: JSONValue]

    public init(
        id: UUID = UUID(),
        name: String = "New Request",
        method: HTTPMethod = .get,
        url: String = "",
        params: [KeyValue] = [],
        headers: [KeyValue] = [],
        auth: Auth = .inherit,
        body: RequestBody = .none,
        settings: RequestSettings = RequestSettings(),
        description: String? = nil,
        extras: [String: JSONValue] = [:]
    ) {
        self.id = id
        self.name = name
        self.method = method
        self.url = url
        self.params = params
        self.headers = headers
        self.auth = auth
        self.body = body
        self.settings = settings
        self.description = description
        self.extras = extras
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, method, url, params, headers, auth, body, settings, description, extras
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? "New Request"
        method = try c.decodeIfPresent(HTTPMethod.self, forKey: .method) ?? .get
        url = try c.decodeIfPresent(String.self, forKey: .url) ?? ""
        params = try c.decodeIfPresent([KeyValue].self, forKey: .params) ?? []
        headers = try c.decodeIfPresent([KeyValue].self, forKey: .headers) ?? []
        auth = try c.decodeIfPresent(Auth.self, forKey: .auth) ?? .inherit
        body = try c.decodeIfPresent(RequestBody.self, forKey: .body) ?? .none
        settings = try c.decodeIfPresent(RequestSettings.self, forKey: .settings) ?? RequestSettings()
        description = try c.decodeIfPresent(String.self, forKey: .description)
        extras = try c.decodeIfPresent([String: JSONValue].self, forKey: .extras) ?? [:]
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encode(method, forKey: .method)
        try c.encode(url, forKey: .url)
        try c.encode(params, forKey: .params)
        try c.encode(headers, forKey: .headers)
        try c.encode(auth, forKey: .auth)
        try c.encode(body, forKey: .body)
        try c.encode(settings, forKey: .settings)
        try c.encodeIfPresent(description, forKey: .description)
        if !extras.isEmpty { try c.encode(extras, forKey: .extras) }
    }
}

extension RequestItem {
    /// A copy with fresh identifiers, for duplicate / paste.
    public func duplicated(named newName: String? = nil) -> RequestItem {
        var copy = self
        copy.id = UUID()
        copy.name = newName ?? "\(name) copy"
        copy.params = params.map { var r = $0; r.id = UUID(); return r }
        copy.headers = headers.map { var r = $0; r.id = UUID(); return r }
        if case .formData(let fields) = copy.body {
            copy.body = .formData(fields.map { var f = $0; f.id = UUID(); return f })
        }
        if case .urlEncoded(let rows) = copy.body {
            copy.body = .urlEncoded(rows.map { var r = $0; r.id = UUID(); return r })
        }
        return copy
    }
}
