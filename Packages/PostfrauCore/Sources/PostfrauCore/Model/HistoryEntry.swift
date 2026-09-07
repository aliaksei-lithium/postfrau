import Foundation

/// One recorded send. Stored one-per-line in `history.jsonl`, local to the machine.
public struct HistoryEntry: Sendable, Hashable, Codable, Identifiable {
    public var id: UUID
    public var sentAt: Date
    public var method: HTTPMethod
    public var resolvedURL: String
    public var statusCode: Int?
    public var durationMs: Double
    public var responseBytes: Int
    public var requestSnapshot: RequestItem
    public var error: String?
    /// The collection the request was saved in when it was sent, if any.
    public var collectionName: String?

    public init(
        id: UUID = UUID(),
        sentAt: Date = Date(),
        method: HTTPMethod = .get,
        resolvedURL: String = "",
        statusCode: Int? = nil,
        durationMs: Double = 0,
        responseBytes: Int = 0,
        requestSnapshot: RequestItem = RequestItem(),
        error: String? = nil,
        collectionName: String? = nil
    ) {
        self.id = id
        self.sentAt = sentAt
        self.method = method
        self.resolvedURL = resolvedURL
        self.statusCode = statusCode
        self.durationMs = durationMs
        self.responseBytes = responseBytes
        self.requestSnapshot = requestSnapshot
        self.error = error
        self.collectionName = collectionName
    }

    /// The path (and query) of the resolved URL, for the compact sidebar row.
    public var displayPath: String {
        guard let components = URLComponents(string: resolvedURL) else { return resolvedURL }
        let path = components.path.isEmpty ? "/" : components.path
        if let query = components.query, !query.isEmpty { return "\(path)?\(query)" }
        return path
    }

    public var host: String {
        URLComponents(string: resolvedURL)?.host ?? ""
    }

    private enum CodingKeys: String, CodingKey {
        case id, sentAt, method, resolvedURL, statusCode, durationMs
        case responseBytes, requestSnapshot, error, collectionName
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        sentAt = try c.decodeIfPresent(Date.self, forKey: .sentAt) ?? Date()
        method = try c.decodeIfPresent(HTTPMethod.self, forKey: .method) ?? .get
        resolvedURL = try c.decodeIfPresent(String.self, forKey: .resolvedURL) ?? ""
        statusCode = try c.decodeIfPresent(Int.self, forKey: .statusCode)
        durationMs = try c.decodeIfPresent(Double.self, forKey: .durationMs) ?? 0
        responseBytes = try c.decodeIfPresent(Int.self, forKey: .responseBytes) ?? 0
        requestSnapshot = try c.decodeIfPresent(RequestItem.self, forKey: .requestSnapshot) ?? RequestItem()
        error = try c.decodeIfPresent(String.self, forKey: .error)
        collectionName = try c.decodeIfPresent(String.self, forKey: .collectionName)
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(sentAt, forKey: .sentAt)
        try c.encode(method, forKey: .method)
        try c.encode(resolvedURL, forKey: .resolvedURL)
        try c.encodeIfPresent(statusCode, forKey: .statusCode)
        try c.encode(durationMs, forKey: .durationMs)
        try c.encode(responseBytes, forKey: .responseBytes)
        try c.encode(requestSnapshot, forKey: .requestSnapshot)
        try c.encodeIfPresent(error, forKey: .error)
        try c.encodeIfPresent(collectionName, forKey: .collectionName)
    }
}
