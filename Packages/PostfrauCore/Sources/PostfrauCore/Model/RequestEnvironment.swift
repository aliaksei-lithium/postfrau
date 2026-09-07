import Foundation

/// A named set of variables the user switches between.
///
/// Named `RequestEnvironment` so it does not collide with SwiftUI's `Environment` in the app layer.
public struct RequestEnvironment: Sendable, Hashable, Codable, Identifiable {
    public var id: UUID
    public var name: String
    public var variables: [Variable]
    public var updatedAt: Date
    public var revision: Int

    public init(
        id: UUID = UUID(),
        name: String = "New Environment",
        variables: [Variable] = [],
        updatedAt: Date = Date(),
        revision: Int = 1
    ) {
        self.id = id
        self.name = name
        self.variables = variables
        self.updatedAt = updatedAt
        self.revision = revision
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, id, name, variables, updatedAt, revision
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? "New Environment"
        variables = try c.decodeIfPresent([Variable].self, forKey: .variables) ?? []
        updatedAt = try c.decodeIfPresent(Date.self, forKey: .updatedAt) ?? Date()
        revision = try c.decodeIfPresent(Int.self, forKey: .revision) ?? 1
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(Postfrau.schemaVersion, forKey: .schemaVersion)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encode(variables, forKey: .variables)
        try c.encode(updatedAt, forKey: .updatedAt)
        try c.encode(revision, forKey: .revision)
    }

    public func duplicated(named newName: String? = nil) -> RequestEnvironment {
        RequestEnvironment(
            name: newName ?? "\(name) copy",
            variables: variables.map { var v = $0; v.id = UUID(); return v })
    }
}

/// The globals document: variables visible to every request regardless of environment.
public struct Globals: Sendable, Hashable, Codable {
    public var variables: [Variable]
    public var updatedAt: Date
    public var revision: Int

    public init(variables: [Variable] = [], updatedAt: Date = Date(), revision: Int = 1) {
        self.variables = variables
        self.updatedAt = updatedAt
        self.revision = revision
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, variables, updatedAt, revision
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        variables = try c.decodeIfPresent([Variable].self, forKey: .variables) ?? []
        updatedAt = try c.decodeIfPresent(Date.self, forKey: .updatedAt) ?? Date()
        revision = try c.decodeIfPresent(Int.self, forKey: .revision) ?? 1
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(Postfrau.schemaVersion, forKey: .schemaVersion)
        try c.encode(variables, forKey: .variables)
        try c.encode(updatedAt, forKey: .updatedAt)
        try c.encode(revision, forKey: .revision)
    }
}

/// Everything loaded from the data folder.
public struct Workspace: Sendable, Hashable {
    public var collections: [RequestCollection]
    public var environments: [RequestEnvironment]
    public var globals: Globals
    public var activeEnvironmentID: UUID?

    public init(
        collections: [RequestCollection] = [],
        environments: [RequestEnvironment] = [],
        globals: Globals = Globals(),
        activeEnvironmentID: UUID? = nil
    ) {
        self.collections = collections
        self.environments = environments
        self.globals = globals
        self.activeEnvironmentID = activeEnvironmentID
    }

    public var activeEnvironment: RequestEnvironment? {
        guard let activeEnvironmentID else { return nil }
        return environments.first { $0.id == activeEnvironmentID }
    }

    public var totalRequestCount: Int {
        collections.reduce(0) { $0 + $1.requestCount }
    }

    public func collection(withID id: UUID) -> RequestCollection? {
        collections.first { $0.id == id }
    }

    /// The collection that contains `itemID`, if any.
    public func collectionContaining(itemID: UUID) -> RequestCollection? {
        collections.first { $0.id == itemID || $0.item(withID: itemID) != nil }
    }
}

/// The marker file that identifies a folder as a Postfrau data folder.
public struct WorkspaceMarker: Sendable, Hashable, Codable {
    public var schemaVersion: Int
    public var workspaceID: UUID
    public var createdAt: Date
    public var createdBy: String
    public var appVersion: String

    public init(
        schemaVersion: Int = Postfrau.schemaVersion,
        workspaceID: UUID = UUID(),
        createdAt: Date = Date(),
        createdBy: String = ProcessInfo.processInfo.hostName,
        appVersion: String = Postfrau.appVersion
    ) {
        self.schemaVersion = schemaVersion
        self.workspaceID = workspaceID
        self.createdAt = createdAt
        self.createdBy = createdBy
        self.appVersion = appVersion
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, workspaceID, createdAt, createdBy, appVersion
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try c.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? Postfrau.schemaVersion
        workspaceID = try c.decodeIfPresent(UUID.self, forKey: .workspaceID) ?? UUID()
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        createdBy = try c.decodeIfPresent(String.self, forKey: .createdBy) ?? ""
        appVersion = try c.decodeIfPresent(String.self, forKey: .appVersion) ?? ""
    }
}
