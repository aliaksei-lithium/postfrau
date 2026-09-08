import Foundation

/// An ordered child of a collection or folder.
///
/// Named `CollectionItem` rather than `Item` because the bare name is far too generic to
/// live in the app layer's namespace.
public enum CollectionItem: Sendable, Hashable, Codable, Identifiable {
    case folder(Folder)
    case request(RequestItem)

    public var id: UUID {
        switch self {
        case .folder(let folder): folder.id
        case .request(let request): request.id
        }
    }

    public var name: String {
        switch self {
        case .folder(let folder): folder.name
        case .request(let request): request.name
        }
    }

    public var asFolder: Folder? {
        if case .folder(let folder) = self { return folder }
        return nil
    }

    public var asRequest: RequestItem? {
        if case .request(let request) = self { return request }
        return nil
    }

    private enum CodingKeys: String, CodingKey { case type, folder, request }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let type = try c.decodeIfPresent(String.self, forKey: .type) ?? "request"
        switch type {
        case "folder":
            self = .folder(try c.decode(Folder.self, forKey: .folder))
        case "request":
            self = .request(try c.decode(RequestItem.self, forKey: .request))
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .type, in: c, debugDescription: "Unknown collection item type \"\(type)\"")
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .folder(let folder):
            try c.encode("folder", forKey: .type)
            try c.encode(folder, forKey: .folder)
        case .request(let request):
            try c.encode("request", forKey: .type)
            try c.encode(request, forKey: .request)
        }
    }
}

/// A group of requests and nested folders.
public struct Folder: Sendable, Hashable, Codable, Identifiable {
    public var id: UUID
    public var name: String
    public var description: String?
    public var auth: Auth
    public var variables: [Variable]
    public var items: [CollectionItem]
    public var extras: [String: JSONValue]

    public init(
        id: UUID = UUID(),
        name: String = "New Folder",
        description: String? = nil,
        auth: Auth = .inherit,
        variables: [Variable] = [],
        items: [CollectionItem] = [],
        extras: [String: JSONValue] = [:]
    ) {
        self.id = id
        self.name = name
        self.description = description
        self.auth = auth
        self.variables = variables
        self.items = items
        self.extras = extras
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, description, auth, variables, items, extras
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? "New Folder"
        description = try c.decodeIfPresent(String.self, forKey: .description)
        auth = try c.decodeIfPresent(Auth.self, forKey: .auth) ?? .inherit
        variables = try c.decodeIfPresent([Variable].self, forKey: .variables) ?? []
        items = try c.decodeIfPresent([CollectionItem].self, forKey: .items) ?? []
        extras = try c.decodeIfPresent([String: JSONValue].self, forKey: .extras) ?? [:]
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encodeIfPresent(description, forKey: .description)
        try c.encode(auth, forKey: .auth)
        try c.encode(variables, forKey: .variables)
        try c.encode(items, forKey: .items)
        if !extras.isEmpty { try c.encode(extras, forKey: .extras) }
    }
}

/// A saved collection: the root of one tree, and one file in the data folder.
///
/// Named `RequestCollection` so it does not shadow the standard library's `Collection`
/// protocol inside this module.
public struct RequestCollection: Sendable, Hashable, Codable, Identifiable {
    public var id: UUID
    public var name: String
    public var description: String?
    /// `.inherit` at the root is meaningless and is normalized to `.none` on decode.
    public var auth: Auth
    public var variables: [Variable]
    public var items: [CollectionItem]
    public var createdAt: Date
    public var updatedAt: Date
    /// Bumped by `WorkspaceStore` on every write; used to order concurrent edits from two Macs.
    public var revision: Int
    /// Overrides the app-wide history recording level for everything in this collection.
    /// Nil means "use the app setting" — the common case.
    public var historyRecording: HistoryRecordLevel?
    public var extras: [String: JSONValue]

    public init(
        id: UUID = UUID(),
        name: String = "New Collection",
        description: String? = nil,
        auth: Auth = .none,
        variables: [Variable] = [],
        items: [CollectionItem] = [],
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        revision: Int = 1,
        historyRecording: HistoryRecordLevel? = nil,
        extras: [String: JSONValue] = [:]
    ) {
        self.id = id
        self.name = name
        self.description = description
        self.auth = auth == .inherit ? .none : auth
        self.variables = variables
        self.items = items
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.revision = revision
        self.historyRecording = historyRecording
        self.extras = extras
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, id, name, description, auth, variables, items
        case createdAt, updatedAt, revision, historyRecording, extras
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? "New Collection"
        description = try c.decodeIfPresent(String.self, forKey: .description)
        let decodedAuth = try c.decodeIfPresent(Auth.self, forKey: .auth) ?? .none
        auth = decodedAuth == .inherit ? .none : decodedAuth
        variables = try c.decodeIfPresent([Variable].self, forKey: .variables) ?? []
        items = try c.decodeIfPresent([CollectionItem].self, forKey: .items) ?? []
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        updatedAt = try c.decodeIfPresent(Date.self, forKey: .updatedAt) ?? createdAt
        revision = try c.decodeIfPresent(Int.self, forKey: .revision) ?? 1
        historyRecording = try c.decodeIfPresent(HistoryRecordLevel.self, forKey: .historyRecording)
        extras = try c.decodeIfPresent([String: JSONValue].self, forKey: .extras) ?? [:]
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(Postfrau.schemaVersion, forKey: .schemaVersion)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encodeIfPresent(description, forKey: .description)
        try c.encode(auth, forKey: .auth)
        try c.encode(variables, forKey: .variables)
        try c.encode(items, forKey: .items)
        try c.encode(createdAt, forKey: .createdAt)
        try c.encode(updatedAt, forKey: .updatedAt)
        try c.encode(revision, forKey: .revision)
        try c.encodeIfPresent(historyRecording, forKey: .historyRecording)
        if !extras.isEmpty { try c.encode(extras, forKey: .extras) }
    }
}
