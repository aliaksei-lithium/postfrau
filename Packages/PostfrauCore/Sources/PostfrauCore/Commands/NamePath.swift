import Foundation

/// Addressing an item by the names a person would type: `Acme API/Users/List users`.
///
/// Distinct from `ItemPath`, which is the id-based location the app uses internally: this is the
/// handle a person or an agent writes down, and it has to survive being typed from memory.
///
/// The CLI and any agent driving it need a handle that survives being written down, and a UUID is
/// not that. Matching is case-insensitive because nobody remembers whether the folder was called
/// "Users" or "users", and a literal `/` in a name is escaped `\/` so a request called
/// "GET /users" is still addressable.
public struct NamePath: Sendable, Hashable, CustomStringConvertible {
    public var components: [String]

    public init(components: [String]) {
        self.components = components
    }

    /// Splits on unescaped `/`.
    public init(_ text: String) {
        var components: [String] = []
        var current = ""
        var escaping = false
        for character in text {
            if escaping {
                // Only `\/` and `\\` mean anything; every other backslash is part of the name.
                if character != "/" && character != "\\" { current.append("\\") }
                current.append(character)
                escaping = false
                continue
            }
            switch character {
            case "\\": escaping = true
            case "/": components.append(current); current = ""
            default: current.append(character)
            }
        }
        if escaping { current.append("\\") }
        components.append(current)
        self.components = components.filter { !$0.isEmpty }
    }

    public var description: String {
        components.map(Self.escape).joined(separator: "/")
    }

    public var isEmpty: Bool { components.isEmpty }

    public func appending(_ name: String) -> NamePath {
        NamePath(components: components + [name])
    }

    public var parent: NamePath { NamePath(components: components.dropLast()) }
    public var last: String? { components.last }

    static func escape(_ component: String) -> String {
        component
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "/", with: "\\/")
    }

    /// True when two names refer to the same thing, as far as a person is concerned.
    static func matches(_ name: String, _ component: String) -> Bool {
        name.compare(component, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
    }
}

/// What a path resolved to.
public enum ResolvedItem: Sendable {
    case collection(RequestCollection)
    case folder(Folder, collectionID: UUID)
    case request(RequestItem, collectionID: UUID, parentID: UUID?)

    public var id: UUID {
        switch self {
        case .collection(let collection): collection.id
        case .folder(let folder, _): folder.id
        case .request(let request, _, _): request.id
        }
    }

    public var name: String {
        switch self {
        case .collection(let collection): collection.name
        case .folder(let folder, _): folder.name
        case .request(let request, _, _): request.name
        }
    }

    public var collectionID: UUID {
        switch self {
        case .collection(let collection): collection.id
        case .folder(_, let id): id
        case .request(_, let id, _): id
        }
    }

    public var kind: String {
        switch self {
        case .collection: "collection"
        case .folder: "folder"
        case .request: "request"
        }
    }
}

/// Finding things in a workspace by path or by id.
public enum ItemResolver {
    public enum ResolveError: Error, LocalizedError, Equatable {
        case notFound(String)
        case ambiguous(String, matches: [String])
        case notAFolder(String)
        case notARequest(String)

        public var errorDescription: String? {
            switch self {
            case .notFound(let path):
                "Nothing at “\(path)”."
            case .ambiguous(let path, let matches):
                "“\(path)” matches \(matches.count) items: \(matches.joined(separator: ", ")). "
                    + "Use the id instead."
            case .notAFolder(let path):
                "“\(path)” is not a folder."
            case .notARequest(let path):
                "“\(path)” is not a request."
            }
        }
    }

    /// Resolves `text` as a UUID if it is one, otherwise as a path.
    public static func resolve(
        _ text: String, in workspace: Workspace
    ) throws -> ResolvedItem {
        if let id = UUID(uuidString: text) {
            guard let found = item(withID: id, in: workspace) else {
                throw ResolveError.notFound(text)
            }
            return found
        }
        return try resolve(path: NamePath(text), in: workspace)
    }

    public static func resolve(
        path: NamePath, in workspace: Workspace
    ) throws -> ResolvedItem {
        guard let first = path.components.first else {
            throw ResolveError.notFound(path.description)
        }

        let collections = workspace.collections.filter { NamePath.matches($0.name, first) }
        guard !collections.isEmpty else { throw ResolveError.notFound(path.description) }
        guard collections.count == 1 else {
            throw ResolveError.ambiguous(
                path.description, matches: collections.map(\.name))
        }
        let collection = collections[0]

        var remaining = Array(path.components.dropFirst())
        if remaining.isEmpty { return .collection(collection) }

        var items = collection.items
        var parentID: UUID?

        while let name = remaining.first {
            remaining.removeFirst()
            let matches = items.filter { NamePath.matches($0.name, name) }
            guard !matches.isEmpty else { throw ResolveError.notFound(path.description) }
            guard matches.count == 1 else {
                throw ResolveError.ambiguous(
                    path.description, matches: matches.map(\.name))
            }

            switch matches[0] {
            case .request(let request):
                guard remaining.isEmpty else { throw ResolveError.notFound(path.description) }
                return .request(request, collectionID: collection.id, parentID: parentID)
            case .folder(let folder):
                if remaining.isEmpty {
                    return .folder(folder, collectionID: collection.id)
                }
                items = folder.items
                parentID = folder.id
            }
        }
        throw ResolveError.notFound(path.description)
    }

    /// The path that would address this item, for output that has to be pasted back in.
    public static func path(toItemWithID id: UUID, in workspace: Workspace) -> NamePath? {
        for collection in workspace.collections {
            if collection.id == id { return NamePath(components: [collection.name]) }
            if let trail = trail(to: id, in: collection.items) {
                return NamePath(components: [collection.name] + trail)
            }
        }
        return nil
    }

    private static func trail(to id: UUID, in items: [CollectionItem]) -> [String]? {
        for item in items {
            if item.id == id { return [item.name] }
            if case .folder(let folder) = item, let deeper = trail(to: id, in: folder.items) {
                return [folder.name] + deeper
            }
        }
        return nil
    }

    /// Looks an item up by id, whichever kind it turns out to be.
    public static func item(withID id: UUID, in workspace: Workspace) -> ResolvedItem? {
        for collection in workspace.collections {
            if collection.id == id { return .collection(collection) }
            if let folder = collection.folder(withID: id) {
                return .folder(folder, collectionID: collection.id)
            }
            if let request = collection.request(withID: id) {
                return .request(
                    request, collectionID: collection.id,
                    parentID: collection.currentParentID(of: id))
            }
        }
        return nil
    }
}
