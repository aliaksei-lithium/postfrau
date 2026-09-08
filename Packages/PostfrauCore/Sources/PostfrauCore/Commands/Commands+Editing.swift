import Foundation

/// A partial edit to a request. Everything nil is left alone, which is what makes
/// `postfrau set <path> --method POST` mean only that.
public struct RequestEdit: Sendable {
    public var name: String?
    public var url: String?
    public var method: HTTPMethod?
    /// Headers to set, by name. A value of nil removes the header.
    public var headers: [(key: String, value: String?)] = []
    public var params: [(key: String, value: String?)] = []
    public var body: RequestBody?
    public var auth: Auth?
    public var description: String?
    /// Replace rather than merge the header and param tables.
    public var replacesHeaders = false
    public var replacesParams = false

    public init() {}

    public var isEmpty: Bool {
        name == nil && url == nil && method == nil && headers.isEmpty && params.isEmpty
            && body == nil && auth == nil && description == nil
    }
}

extension CommandRunner {
    // MARK: - add

    /// Adds a request under a folder or collection path.
    @discardableResult
    public func addRequest(
        _ request: RequestItem, toFolderAt path: String
    ) async throws -> RequestDetail {
        let target = try await resolve(path)
        var collection = try collection(containing: target)

        let parentID: UUID?
        switch target {
        case .collection: parentID = nil
        case .folder(let folder, _): parentID = folder.id
        case .request:
            throw CommandError.invalid("“\(path)” is a request; requests cannot contain requests.")
        }

        var stored = request
        if stored.name.trimmingCharacters(in: .whitespaces).isEmpty {
            stored.name = Self.defaultName(for: stored)
        }
        guard collection.insert(.request(stored), into: parentID) else {
            throw CommandError.invalid("Could not add “\(stored.name)” to “\(path)”.")
        }
        try await save(collection: collection)
        return try await detail(path: stored.id.uuidString)
    }

    /// Creates a folder under a folder or collection path.
    @discardableResult
    public func addFolder(named name: String, toFolderAt path: String) async throws -> ListedItem {
        let target = try await resolve(path)
        var collection = try collection(containing: target)

        let parentID: UUID?
        switch target {
        case .collection: parentID = nil
        case .folder(let folder, _): parentID = folder.id
        case .request: throw CommandError.invalid("“\(path)” is a request.")
        }

        let folder = Folder(name: name)
        guard collection.insert(.folder(folder), into: parentID) else {
            throw CommandError.invalid("Could not add “\(name)” to “\(path)”.")
        }
        try await save(collection: collection)
        let workspace = try await load()
        return ListedItem(
            path: ItemResolver.path(toItemWithID: folder.id, in: workspace)?.description ?? name,
            name: name, kind: "folder", id: folder.id)
    }

    /// Creates a collection.
    @discardableResult
    public func addCollection(named name: String) async throws -> ListedItem {
        _ = try await load()
        let collection = RequestCollection(name: name)
        try await save(collection: collection)
        return ListedItem(
            path: NamePath(components: [name]).description,
            name: name, kind: "collection", id: collection.id)
    }

    // MARK: - set

    /// Applies a partial edit to a request.
    @discardableResult
    public func update(requestAt path: String, with edit: RequestEdit) async throws -> RequestDetail {
        guard !edit.isEmpty else {
            throw CommandError.invalid("Nothing to change.")
        }
        let resolved = try await resolve(path)
        guard case .request(var request, _, _) = resolved else {
            throw CommandError.invalid("“\(path)” is a \(resolved.kind), not a request.")
        }
        var collection = try collection(containing: resolved)

        if let name = edit.name { request.name = name }
        if let method = edit.method { request.method = method }
        if let description = edit.description { request.description = description }
        if let body = edit.body { request.body = body }
        if let auth = edit.auth { request.auth = auth }

        if edit.replacesHeaders { request.headers = [] }
        for (key, value) in edit.headers {
            Self.apply(key: key, value: value, to: &request.headers)
        }

        if let url = edit.url {
            request.url = url
            // The params table mirrors the URL's query, exactly as the editor does.
            let (_, params) = URLQuery.merge(urlText: url, into: [])
            request.params = params
        }
        if edit.replacesParams { request.params = [] }
        if !edit.params.isEmpty {
            for (key, value) in edit.params {
                Self.apply(key: key, value: value, to: &request.params)
            }
            request.url = URLQuery.compose(
                base: request.url,
                params: KeyValueRows.stripped(request.params),
                encode: request.settings.encodeURL)
        }

        guard collection.replace(.request(request)) else {
            throw CommandError.invalid("Could not save “\(request.name)”.")
        }
        try await save(collection: collection)
        return try await detail(path: request.id.uuidString)
    }

    /// Sets, replaces or removes one row of a key/value table.
    private static func apply(key: String, value: String?, to rows: inout [KeyValue]) {
        let index = rows.firstIndex { $0.key.compare(key, options: .caseInsensitive) == .orderedSame }
        guard let value else {
            if let index { rows.remove(at: index) }
            return
        }
        if let index {
            rows[index].value = value
            rows[index].enabled = true
        } else {
            rows.append(KeyValue(key: key, value: value))
        }
    }

    // MARK: - mv, rm, dup

    public func move(itemAt path: String, toFolderAt destination: String) async throws -> ListedItem {
        let source = try await resolve(path)
        let target = try await resolve(destination)
        guard source.collectionID == target.collectionID else {
            throw CommandError.invalid(
                "Moving between collections is not supported from the command line yet.")
        }
        var collection = try collection(containing: source)

        let parentID: UUID?
        switch target {
        case .collection: parentID = nil
        case .folder(let folder, _):
            guard folder.id != source.id else {
                throw CommandError.invalid("A folder cannot be moved into itself.")
            }
            guard !collection.folder(folder.id, isInsideOrEqualTo: source.id) else {
                throw CommandError.invalid("A folder cannot be moved into its own subtree.")
            }
            parentID = folder.id
        case .request: throw CommandError.invalid("“\(destination)” is a request.")
        }

        guard let item = collection.remove(itemWithID: source.id),
              collection.insert(item, into: parentID)
        else {
            throw CommandError.invalid("Could not move “\(source.name)”.")
        }
        try await save(collection: collection)

        let workspace = try await load()
        return ListedItem(
            path: ItemResolver.path(toItemWithID: source.id, in: workspace)?.description ?? source.name,
            name: source.name, kind: source.kind, id: source.id)
    }

    public func remove(itemAt path: String) async throws -> ListedItem {
        let resolved = try await resolve(path)
        let removed = ListedItem(
            path: path, name: resolved.name, kind: resolved.kind, id: resolved.id)

        if case .collection(let collection) = resolved {
            try await store.delete(collectionID: collection.id)
            try await withWorkspace { $0.collections.removeAll { $0.id == collection.id } }
            return removed
        }

        var collection = try collection(containing: resolved)
        guard collection.remove(itemWithID: resolved.id) != nil else {
            throw CommandError.invalid("Could not remove “\(resolved.name)”.")
        }
        try await save(collection: collection)
        return removed
    }

    public func duplicate(itemAt path: String) async throws -> ListedItem {
        let resolved = try await resolve(path)

        if case .collection(let collection) = resolved {
            let copy = collection.duplicated()
            try await save(collection: copy)
            return ListedItem(
                path: NamePath(components: [copy.name]).description,
                name: copy.name, kind: "collection", id: copy.id)
        }

        var collection = try collection(containing: resolved)
        guard let item = collection.item(withID: resolved.id) else {
            throw CommandError.notFound("Nothing at “\(path)”.")
        }
        let copy: CollectionItem
        switch item {
        case .request(let request): copy = .request(request.duplicated())
        case .folder(var folder):
            folder.name = "\(folder.name) copy"
            copy = RequestCollection.reidentify([.folder(folder)])[0]
        }
        let parentID = collection.currentParentID(of: resolved.id)
        let index = collection.currentIndex(of: resolved.id).map { $0 + 1 }
        guard collection.insert(copy, into: parentID, at: index) else {
            throw CommandError.invalid("Could not duplicate “\(resolved.name)”.")
        }
        try await save(collection: collection)

        let workspace = try await load()
        return ListedItem(
            path: ItemResolver.path(toItemWithID: copy.id, in: workspace)?.description ?? copy.name,
            name: copy.name, kind: resolved.kind, id: copy.id)
    }

    // MARK: - Environments

    @discardableResult
    public func setVariable(
        _ key: String, to value: String, inEnvironmentNamed name: String, isSecret: Bool
    ) async throws -> RequestEnvironment {
        var environment = try await environment(named: name)
        let previous = environment.variables

        if let index = environment.variables.firstIndex(where: {
            $0.key.compare(key, options: .caseInsensitive) == .orderedSame
        }) {
            environment.variables[index].value = value
            environment.variables[index].isSecret = isSecret
            environment.variables[index].enabled = true
        } else {
            environment.variables.append(
                Variable(key: key, value: value, isSecret: isSecret))
        }
        try await save(environment: environment, previous: previous)
        return environment
    }

    @discardableResult
    public func unsetVariable(
        _ key: String, inEnvironmentNamed name: String
    ) async throws -> RequestEnvironment {
        var environment = try await environment(named: name)
        let previous = environment.variables
        environment.variables.removeAll {
            $0.key.compare(key, options: .caseInsensitive) == .orderedSame
        }
        guard environment.variables.count != previous.count else {
            throw CommandError.notFound("“\(name)” has no variable called “\(key)”.")
        }
        try await save(environment: environment, previous: previous)
        return environment
    }

    /// Switches the active environment.
    ///
    /// The choice lives in `ui-state.json` alongside the open tabs, because it is a property of
    /// this Mac rather than of the shared workspace. The CLI therefore reads that file, changes
    /// the one field, and writes it back — leaving the app's tabs and window state alone.
    public func useEnvironment(named name: String?) async throws -> String {
        _ = try await load()
        let id: UUID?
        let label: String
        if let name, name.lowercased() != "none" {
            let environment = try await environment(named: name)
            id = environment.id
            label = environment.name
        } else {
            id = nil
            label = "none"
        }

        try await withWorkspace { $0.activeEnvironmentID = id }
        var uiState = await store.loadUIState()
        uiState.activeEnvironmentID = id
        try await store.save(uiState: uiState)
        return label
    }

    @discardableResult
    public func addEnvironment(named name: String) async throws -> RequestEnvironment {
        _ = try await load()
        let environment = RequestEnvironment(name: name)
        try await save(environment: environment, previous: [])
        return environment
    }

    /// A name for a request that was created without one.
    static func defaultName(for request: RequestItem) -> String {
        guard let components = URLComponents(string: request.url),
              let last = components.path.split(separator: "/").last
        else { return request.url.isEmpty ? "New Request" : request.url }
        return String(last)
    }
}

extension CommandRunner {
    /// Adds a whole collection, as `postfrau import` does.
    public func importCollection(_ collection: RequestCollection) async throws {
        _ = try await load()
        try await save(collection: collection)
    }
}
