import Foundation

/// One row of `postfrau ls`.
public struct ListedItem: Sendable, Hashable, Codable {
    public var path: String
    public var name: String
    public var kind: String
    public var id: UUID
    public var method: String?
    public var url: String?
    /// How deep under the listed root, for the `--tree` rendering.
    public var depth: Int

    public init(
        path: String, name: String, kind: String, id: UUID,
        method: String? = nil, url: String? = nil, depth: Int = 0
    ) {
        self.path = path
        self.name = name
        self.kind = kind
        self.id = id
        self.method = method
        self.url = url
        self.depth = depth
    }
}

/// A request as the CLI reports it: what is stored, plus what it would resolve to.
public struct RequestDetail: Sendable, Codable {
    public var path: String
    public var id: UUID
    public var name: String
    public var method: String
    public var url: String
    public var resolvedURL: String
    public var headers: [HeaderField]
    public var params: [KeyValue]
    public var auth: String
    public var body: BodySummary
    public var description: String?
    /// Variables the request uses that nothing in scope defines.
    public var unresolvedVariables: [String]

    public struct BodySummary: Sendable, Codable {
        public var kind: String
        public var contentType: String?
        public var text: String?
        public var fields: [String]?
        public var byteCount: Int?
    }
}

extension CommandRunner {
    // MARK: - ls

    /// Lists what is at a path, or every collection when the path is empty.
    ///
    /// - Parameter recursive: walk the whole subtree rather than one level.
    public func list(path: String?, recursive: Bool) async throws -> [ListedItem] {
        let workspace = try await load()

        guard let path, !path.isEmpty else {
            return workspace.collections.map { collection in
                ListedItem(
                    path: NamePath(components: [collection.name]).description,
                    name: collection.name,
                    kind: "collection",
                    id: collection.id)
            }
        }

        let resolved = try await resolve(path)
        switch resolved {
        case .request(let request, _, _):
            // Listing a request lists itself: there is nothing under it.
            let base = ItemResolver.path(toItemWithID: request.id, in: workspace)
            return [ListedItem(
                path: base?.description ?? request.name,
                name: request.name, kind: "request", id: request.id,
                method: request.method.rawValue, url: request.url)]

        case .collection(let collection):
            return rows(
                for: collection.items,
                under: NamePath(components: [collection.name]),
                recursive: recursive, depth: 0)

        case .folder(let folder, _):
            let base = ItemResolver.path(toItemWithID: folder.id, in: workspace)
                ?? NamePath(components: [folder.name])
            return rows(for: folder.items, under: base, recursive: recursive, depth: 0)
        }
    }

    private func rows(
        for items: [CollectionItem], under base: NamePath, recursive: Bool, depth: Int
    ) -> [ListedItem] {
        var out: [ListedItem] = []
        for item in items {
            let path = base.appending(item.name)
            switch item {
            case .request(let request):
                out.append(ListedItem(
                    path: path.description, name: request.name, kind: "request", id: request.id,
                    method: request.method.rawValue, url: request.url, depth: depth))
            case .folder(let folder):
                out.append(ListedItem(
                    path: path.description, name: folder.name, kind: "folder", id: folder.id,
                    depth: depth))
                if recursive {
                    out.append(contentsOf: rows(
                        for: folder.items, under: path, recursive: true, depth: depth + 1))
                }
            }
        }
        return out
    }

    // MARK: - get

    /// Everything about one request, including what its variables resolve to right now.
    public func detail(path: String, overrides: [String: String] = [:]) async throws -> RequestDetail {
        let workspace = try await load()
        let resolved = try await resolve(path)
        guard case .request(let request, _, _) = resolved else {
            throw CommandError.invalid("“\(path)” is a \(resolved.kind), not a request.")
        }

        let scope = scope(forRequestWithID: request.id, overrides: overrides)
        let resolver = VariableResolver(scope: scope)
        let auth = effectiveAuth(forRequestWithID: request.id)

        let composed = URLQuery.compose(
            base: request.url,
            params: KeyValueRows.stripped(request.params),
            encode: request.settings.encodeURL)

        return RequestDetail(
            path: ItemResolver.path(toItemWithID: request.id, in: workspace)?.description ?? path,
            id: request.id,
            name: request.name,
            method: request.method.rawValue,
            url: request.url,
            resolvedURL: resolver.resolved(composed),
            headers: KeyValueRows.stripped(request.headers)
                .map { HeaderField(name: $0.key, value: $0.value) },
            params: KeyValueRows.stripped(request.params),
            auth: Self.describe(auth),
            body: Self.summarize(request.body),
            description: request.description,
            unresolvedVariables: resolver.resolve(Self.searchable(request)).unresolved)
    }

    /// The auth in one word, without ever printing the credential.
    static func describe(_ auth: Auth) -> String {
        switch auth {
        case .none: "none"
        case .inherit: "inherit"
        case .bearer: "bearer"
        case .basic(let username, _): "basic:\(username)"
        case .apiKey(let key, _, let location): "apikey:\(key):\(location == .query ? "query" : "header")"
        }
    }

    static func summarize(_ body: RequestBody) -> RequestDetail.BodySummary {
        switch body {
        case .none:
            return .init(kind: "none")
        case .raw(let text, let language):
            return .init(
                kind: "raw", contentType: language.defaultContentType, text: text,
                byteCount: text.utf8.count)
        case .urlEncoded(let fields):
            return .init(
                kind: "urlencoded", contentType: "application/x-www-form-urlencoded",
                fields: KeyValueRows.stripped(fields).map { "\($0.key)=\($0.value)" })
        case .formData(let fields):
            return .init(
                kind: "formdata", contentType: "multipart/form-data",
                fields: fields.filter { !$0.isEmpty }.map { field in
                    switch field.value {
                    case .text(let value): "\(field.key)=\(value)"
                    case .file(let reference): "\(field.key)=@\(reference.displayName)"
                    }
                })
        case .binary(let reference):
            return .init(kind: "file", fields: [reference.displayName])
        }
    }

    /// Every piece of a request that might mention a variable, for the unresolved check.
    private static func searchable(_ request: RequestItem) -> String {
        var parts = [request.url]
        parts += request.headers.flatMap { [$0.key, $0.value] }
        parts += request.params.flatMap { [$0.key, $0.value] }
        if case .raw(let text, _) = request.body { parts.append(text) }
        return parts.joined(separator: " ")
    }

    // MARK: - Environments

    public func listEnvironments() async throws -> [(name: String, isActive: Bool, count: Int)] {
        let workspace = try await load()
        return workspace.environments.map {
            ($0.name, $0.id == workspace.activeEnvironmentID, $0.variables.count)
        }
    }

    public func environment(named name: String) async throws -> RequestEnvironment {
        let workspace = try await load()
        guard let found = workspace.environments.first(where: {
            NamePath.matches($0.name, name)
        }) else {
            throw CommandError.notFound("No environment called “\(name)”.")
        }
        return found
    }
}
