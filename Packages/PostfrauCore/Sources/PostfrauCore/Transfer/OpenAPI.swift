import Foundation

/// Reads an OpenAPI 3.x document into a Postfrau collection.
///
/// The aim is a collection you can *send from*, not a faithful rendering of the specification.
/// A spec describes what an endpoint accepts; a request has to carry something concrete. So path
/// templates become `{{variables}}` you can fill in, and a request body is built from the
/// example the spec gives — or synthesised from its schema when it gives none, because an empty
/// body is far less use than a shaped one you can edit.
///
/// JSON only. OpenAPI is as often YAML, but a YAML parser is a third-party dependency (`PLAN.md`
/// §0) and the subset needed here is not small enough to hand-roll honestly. A YAML document is
/// detected and says what to do about it rather than failing obscurely.
public struct OpenAPIImporter: Sendable {
    public init() {}

    public struct Result: Sendable {
        public var collection: RequestCollection
        public var warnings: [String]

        public init(collection: RequestCollection, warnings: [String] = []) {
            self.collection = collection
            self.warnings = warnings
        }
    }

    public enum ImportError: Error, LocalizedError, Equatable {
        case notJSON
        case looksLikeYAML
        case notOpenAPI
        case swagger2

        public var errorDescription: String? {
            switch self {
            case .notJSON:
                "That file is not JSON."
            case .looksLikeYAML:
                "That looks like a YAML OpenAPI document. Postfrau reads the JSON form — convert "
                    + "it first, for example with `yq -o=json spec.yaml > spec.json`."
            case .notOpenAPI:
                "That does not look like an OpenAPI document — it has no “openapi” version and "
                    + "no “paths”."
            case .swagger2:
                "That is a Swagger 2.0 document. Postfrau reads OpenAPI 3.0 and 3.1; convert it "
                    + "first, for example at converter.swagger.io."
            }
        }
    }

    // MARK: - Entry points

    public func `import`(_ data: Data) throws -> Result {
        guard let root = try? Postfrau.makeDecoder().decode(JSONValue.self, from: data),
              let object = root.objectValue
        else {
            throw Self.looksLikeYAML(data) ? ImportError.looksLikeYAML : ImportError.notJSON
        }
        return try `import`(object)
    }

    public func `import`(_ document: [String: JSONValue]) throws -> Result {
        if document["swagger"]?.stringValue?.hasPrefix("2") == true { throw ImportError.swagger2 }
        guard Self.looksLikeOpenAPI(document) else { throw ImportError.notOpenAPI }

        var warnings: [String] = []
        let resolver = RefResolver(document: document)

        let info = document["info"]?.objectValue ?? [:]
        var collection = RequestCollection(
            name: info["title"]?.stringValue ?? "Imported API")
        collection.description = Self.describe(info, version: document["openapi"]?.stringValue)

        // `servers[0]` becomes {{baseUrl}}, so every request in the collection can be pointed
        // somewhere else by editing one variable.
        let (baseURL, serverWarnings) = Self.baseURL(from: document["servers"])
        warnings.append(contentsOf: serverWarnings)
        collection.variables = [Variable(key: "baseUrl", value: baseURL)]

        collection.auth = Self.collectionAuth(
            document: document, resolver: resolver, warnings: &warnings)

        let operations = Self.operations(
            in: document, resolver: resolver, warnings: &warnings)
        guard !operations.isEmpty else {
            warnings.append("The document has no operations under “paths”.")
            return Result(collection: collection, warnings: warnings)
        }
        collection.items = Self.group(operations, declaredTags: Self.declaredTags(document))

        // Path templates come across as variables the user has to fill in; say so once rather
        // than leaving them to wonder why a request will not send.
        let templated = operations.filter { $0.request.url.dropFirst("{{baseUrl}}".count).contains("{{") }
            .count
        if templated > 0 {
            warnings.append(
                "\(templated) request(s) have path variables such as {{id}}. Give them values in "
                    + "an environment, or edit the URL before sending.")
        }
        // Everything unmodelled is kept so an export puts it back.
        collection.extras = document.filter {
            !["openapi", "info", "servers", "paths", "components", "security"].contains($0.key)
        }
        return Result(collection: collection, warnings: warnings)
    }

    // MARK: - Detection

    /// True when a JSON object is an OpenAPI document rather than a Postman one.
    public static func looksLikeOpenAPI(_ object: [String: JSONValue]) -> Bool {
        if object["openapi"]?.stringValue?.hasPrefix("3") == true { return true }
        if object["swagger"] != nil { return true }
        // A document with paths and an info block, but no Postman `item` array.
        return object["paths"]?.objectValue != nil && object["item"] == nil
    }

    /// A cheap check for the YAML form, so the error can say what to do about it.
    public static func looksLikeYAML(_ data: Data) -> Bool {
        let head = String(decoding: data.prefix(2048), as: UTF8.self)
        guard !head.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("{") else {
            return false
        }
        return head.contains("openapi:") || head.contains("swagger:") || head.contains("paths:")
    }

    static func describe(_ info: [String: JSONValue], version: String?) -> String? {
        var parts: [String] = []
        if let description = info["description"]?.stringValue, !description.isEmpty {
            parts.append(description)
        }
        var line: [String] = []
        if let apiVersion = info["version"]?.stringValue { line.append("API version \(apiVersion)") }
        if let version { line.append("OpenAPI \(version)") }
        if !line.isEmpty { parts.append(line.joined(separator: " · ")) }
        return parts.isEmpty ? nil : parts.joined(separator: "\n\n")
    }

    // MARK: - Servers

    /// The first server URL, with its template variables filled from their defaults.
    static func baseURL(from servers: JSONValue?) -> (String, [String]) {
        guard let first = servers?.arrayValue?.first?.objectValue,
              var url = first["url"]?.stringValue, !url.isEmpty
        else {
            return ("https://example.com", [
                "The document names no server, so {{baseUrl}} is a placeholder — set it before sending.",
            ])
        }

        // `https://{region}.api.example.com/{version}` — substitute each default so the URL works
        // as given, rather than leaving a template that resolves to nothing.
        var warnings: [String] = []
        for (name, value) in first["variables"]?.objectValue ?? [:] {
            guard let fallback = value["default"]?.stringValue else { continue }
            url = url.replacingOccurrences(of: "{\(name)}", with: fallback)
        }
        if url.contains("{") {
            warnings.append(
                "The server URL still has placeholders in it: \(url). Edit {{baseUrl}} before sending.")
        }
        if url.hasSuffix("/") { url.removeLast() }
        return (url, warnings)
    }

    // MARK: - Operations

    struct Operation {
        var request: RequestItem
        /// The first tag the operation declares, if any.
        var group: String?
        /// The first path segment, used only when the whole document is untagged.
        var pathGroup: String?
    }

    static let methods = ["get", "put", "post", "delete", "options", "head", "patch", "trace"]

    static func operations(
        in document: [String: JSONValue], resolver: RefResolver, warnings: inout [String]
    ) -> [Operation] {
        guard let paths = document["paths"]?.objectValue else { return [] }

        var out: [Operation] = []
        for path in paths.keys.sorted() {
            guard let item = resolver.resolve(paths[path])?.objectValue else { continue }
            // Parameters declared on the path item apply to every operation under it.
            let shared = (item["parameters"]?.arrayValue ?? []).compactMap { resolver.resolve($0) }

            for method in methods {
                guard let operation = item[method]?.objectValue else { continue }
                out.append(Self.operation(
                    method: method, path: path, operation: operation,
                    sharedParameters: shared, resolver: resolver, warnings: &warnings))
            }
        }
        return out
    }

    static func operation(
        method: String,
        path: String,
        operation: [String: JSONValue],
        sharedParameters: [JSONValue],
        resolver: RefResolver,
        warnings: inout [String]
    ) -> Operation {
        var request = RequestItem(
            name: Self.name(for: operation, method: method, path: path),
            method: HTTPMethod(rawValue: method.uppercased()),
            // `{id}` becomes `{{id}}`: a Postfrau variable the user can fill in, rather than a
            // literal brace that would be sent as part of the path.
            url: "{{baseUrl}}" + Self.templated(path))
        request.description = Self.operationDescription(operation)

        let parameters = (sharedParameters + (operation["parameters"]?.arrayValue ?? []))
            .compactMap { resolver.resolve($0)?.objectValue }
        for parameter in parameters {
            guard let name = parameter["name"]?.stringValue else { continue }
            let value = Self.exampleValue(for: parameter, resolver: resolver)
            switch parameter["in"]?.stringValue {
            case "query":
                request.params.append(KeyValue(
                    key: name, value: value,
                    // A parameter the spec does not require starts switched off, so the first
                    // send is the minimal one that should work.
                    enabled: parameter["required"]?.boolValue == true,
                    description: parameter["description"]?.stringValue))
            case "header":
                request.headers.append(KeyValue(
                    key: name, value: value,
                    enabled: parameter["required"]?.boolValue == true,
                    description: parameter["description"]?.stringValue))
            case "cookie":
                warnings.append("“\(request.name)” takes a cookie parameter “\(name)”, which was skipped.")
            default:
                break  // `path` parameters are already in the URL as {{name}}
            }
        }
        if !request.params.isEmpty {
            request.url = URLQuery.compose(
                base: request.url,
                params: KeyValueRows.stripped(request.params),
                encode: false)
        }

        let (body, contentType) = Self.body(
            operation["requestBody"], resolver: resolver, name: request.name, warnings: &warnings)
        request.body = body
        if let contentType, !request.headers.contains(where: {
            $0.key.lowercased() == "content-type"
        }) {
            request.headers.append(KeyValue(key: "Content-Type", value: contentType))
        }

        // Security declared on the operation overrides the collection's.
        if let security = operation["security"]?.arrayValue {
            request.auth = Self.auth(for: security, document: resolver.document, resolver: resolver)
                ?? Auth.none
        }

        var extras = operation.filter {
            !["summary", "description", "operationId", "parameters", "requestBody",
              "responses", "tags", "security"].contains($0.key)
        }
        if let responses = operation["responses"] { extras["responses"] = responses }
        request.extras = extras

        return Operation(
            request: request,
            group: operation["tags"]?.arrayValue?.first?.stringValue,
            pathGroup: Self.firstSegment(of: path))
    }

    static func name(for operation: [String: JSONValue], method: String, path: String) -> String {
        if let summary = operation["summary"]?.stringValue, !summary.isEmpty { return summary }
        if let id = operation["operationId"]?.stringValue, !id.isEmpty { return id }
        return "\(method.uppercased()) \(path)"
    }

    static func operationDescription(_ operation: [String: JSONValue]) -> String? {
        let description = operation["description"]?.stringValue
        let summary = operation["summary"]?.stringValue
        // The summary is already the name, so only add the description when it says more.
        guard let description, !description.isEmpty, description != summary else { return nil }
        return description
    }

    /// `/users/{id}/posts` → `/users/{{id}}/posts`
    static func templated(_ path: String) -> String {
        var out = ""
        var index = path.startIndex
        while index < path.endIndex {
            guard path[index] == "{",
                  let close = path[index...].firstIndex(of: "}")
            else {
                out.append(path[index])
                index = path.index(after: index)
                continue
            }
            let name = path[path.index(after: index)..<close]
            out += "{{\(name)}}"
            index = path.index(after: close)
        }
        return out
    }

    static func firstSegment(of path: String) -> String? {
        path.split(separator: "/").first.map { segment in
            // A path that starts with a template has no useful name in it.
            segment.hasPrefix("{") ? "Endpoints" : String(segment)
        }
    }

    // MARK: - Grouping

    /// The `tags` the document declares, in the order it declares them.
    ///
    /// Used for folder order, because that is the order the API's own authors chose and the order
    /// every other OpenAPI tool shows — not the alphabetical order the paths happen to iterate in.
    static func declaredTags(_ document: [String: JSONValue]) -> [String] {
        (document["tags"]?.arrayValue ?? []).compactMap { $0["name"]?.stringValue }
    }

    /// Tags become folders; an untagged operation sits at the root.
    ///
    /// A document that uses no tags at all falls back to grouping by the first path segment,
    /// since a flat list of forty requests is no use to anyone. Mixing the two would be worse
    /// than either: a mostly-tagged document would grow one odd folder named after a path.
    static func group(_ operations: [Operation], declaredTags: [String]) -> [CollectionItem] {
        let isTagged = operations.contains { $0.group != nil }

        var order: [String] = isTagged ? declaredTags : []
        var buckets: [String: [RequestItem]] = [:]
        var loose: [RequestItem] = []

        for operation in operations {
            guard let group = isTagged ? operation.group : operation.pathGroup else {
                loose.append(operation.request)
                continue
            }
            if buckets[group] == nil, !order.contains(group) { order.append(group) }
            buckets[group, default: []].append(operation.request)
        }

        // A declared tag nothing uses gets no folder.
        var items: [CollectionItem] = order.compactMap { name in
            guard let requests = buckets[name] else { return nil }
            return .folder(Folder(name: name, items: requests.map { .request($0) }))
        }
        items.append(contentsOf: loose.map { .request($0) })
        return items
    }
}
