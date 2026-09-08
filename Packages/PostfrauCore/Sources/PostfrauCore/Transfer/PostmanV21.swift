import Foundation

/// The shape of a Postman v2.1 collection, as far as Postfrau cares about it.
///
/// Deliberately decoded through `JSONValue` rather than a mirror of Postman's schema: the format
/// is loosely specified, real exports carry fields no schema mentions, and a strict decoder would
/// fail on a file the user can see is fine. Everything unrecognised is kept in `extras` so an
/// export puts it back.
public enum PostmanV21 {
    public static let schemaURL =
        "https://schema.getpostman.com/json/collection/v2.1.0/collection.json"

    /// Keys Postfrau reads itself; everything else at that level is preserved verbatim.
    static let knownCollectionKeys: Set<String> = ["info", "item", "variable", "auth", "event"]
    static let knownItemKeys: Set<String> = ["name", "item", "request", "response", "description"]
    static let knownRequestKeys: Set<String> = [
        "method", "url", "header", "body", "auth", "description",
    ]
}

/// Reads a Postman v2.1 export into a Postfrau collection.
public struct PostmanV21Importer: Sendable {
    public init() {}

    public struct Result: Sendable {
        public var collection: RequestCollection
        /// Things Postfrau could not represent, in the user's words rather than the parser's.
        public var warnings: [String]

        public init(collection: RequestCollection, warnings: [String] = []) {
            self.collection = collection
            self.warnings = warnings
        }
    }

    public enum ImportError: Error, LocalizedError, Equatable {
        case notJSON
        case notACollection

        public var errorDescription: String? {
            switch self {
            case .notJSON: "That file is not JSON."
            case .notACollection:
                "That does not look like a Postman collection — it has no “info” block with a name."
            }
        }
    }

    public func `import`(_ data: Data) throws -> Result {
        guard let root = try? Postfrau.makeDecoder().decode(JSONValue.self, from: data),
              let object = root.objectValue
        else { throw ImportError.notJSON }
        return try `import`(object)
    }

    public func `import`(_ object: [String: JSONValue]) throws -> Result {
        guard let info = object["info"]?.objectValue,
              let name = info["name"]?.stringValue
        else { throw ImportError.notACollection }

        var warnings: [String] = []
        var collection = RequestCollection(name: name)
        collection.description = info["description"].flatMap(Self.descriptionText)
        collection.variables = Self.variables(from: object["variable"])
        collection.auth = Self.auth(from: object["auth"], warnings: &warnings, context: name)
        collection.items = Self.items(from: object["item"], warnings: &warnings)
        collection.extras = Self.extras(of: object, knownKeys: PostmanV21.knownCollectionKeys)

        // Scripts are kept but not run: Postfrau has no script engine, and dropping them would
        // lose work on the round trip.
        if object["event"] != nil {
            warnings.append(
                "Pre-request and test scripts were kept with the collection but are not run.")
        }
        return Result(collection: collection, warnings: warnings)
    }

    // MARK: - Items

    static func items(from value: JSONValue?, warnings: inout [String]) -> [CollectionItem] {
        guard let array = value?.arrayValue else { return [] }
        return array.compactMap { item(from: $0, warnings: &warnings) }
    }

    static func item(from value: JSONValue, warnings: inout [String]) -> CollectionItem? {
        guard let object = value.objectValue else { return nil }
        let name = object["name"]?.stringValue ?? "Untitled"

        // A node with `item` is a folder; one with `request` is a request. Postman allows both
        // keys on the same node, and treats it as a folder.
        if object["item"] != nil {
            var folder = Folder(name: name)
            folder.description = object["description"].flatMap(descriptionText)
            folder.items = items(from: object["item"], warnings: &warnings)
            folder.auth = auth(from: object["auth"], warnings: &warnings, context: name)
            folder.variables = variables(from: object["variable"])
            folder.extras = extras(of: object, knownKeys: PostmanV21.knownItemKeys)
            return .folder(folder)
        }

        guard let requestValue = object["request"] else { return nil }
        var request = self.request(from: requestValue, named: name, warnings: &warnings)
        request.description = object["description"].flatMap(descriptionText) ?? request.description
        // Saved example responses are not something Postfrau models; keeping them means an export
        // still has them.
        var itemExtras = extras(of: object, knownKeys: PostmanV21.knownItemKeys)
        if let responses = object["response"] { itemExtras["response"] = responses }
        request.extras.merge(itemExtras) { _, new in new }
        return .request(request)
    }

    static func request(
        from value: JSONValue, named name: String, warnings: inout [String]
    ) -> RequestItem {
        // A request can be a bare URL string: `"request": "https://example.com/users"`.
        if let url = value.stringValue {
            return RequestItem(name: name, method: .get, url: url)
        }
        guard let object = value.objectValue else { return RequestItem(name: name) }

        var request = RequestItem(name: name)
        request.method = HTTPMethod(rawValue: (object["method"]?.stringValue ?? "GET").uppercased())
        request.description = object["description"].flatMap(descriptionText)

        let parsed = url(from: object["url"])
        request.url = parsed.url
        request.params = parsed.params
        request.headers = headers(from: object["header"])
        request.auth = auth(from: object["auth"], warnings: &warnings, context: name)
        request.body = body(from: object["body"], warnings: &warnings, context: name)
        request.extras = extras(of: object, knownKeys: PostmanV21.knownRequestKeys)
        return request
    }

    // MARK: - URL

    /// Postman writes a URL either as a string or as an object with the parts split out.
    ///
    /// The object form is authoritative when both are present: `raw` in a real export is often
    /// stale relative to the `query` array the user edited last.
    static func url(from value: JSONValue?) -> (url: String, params: [KeyValue]) {
        guard let value else { return ("", []) }
        if let raw = value.stringValue {
            let (base, params) = URLQuery.merge(urlText: raw, into: [])
            _ = base
            return (raw, params)
        }
        guard let object = value.objectValue else { return ("", []) }

        let params = queryParams(from: object["query"])
        let composed = composedURL(from: object)
        let raw = object["raw"]?.stringValue

        // Prefer what can be rebuilt from the parts; fall back to `raw` when there are no parts.
        let base = composed.isEmpty ? (raw ?? "") : composed
        return (URLQuery.compose(
            base: base, params: KeyValueRows.stripped(params), encode: false), params)
    }

    private static func composedURL(from object: [String: JSONValue]) -> String {
        let host = (object["host"]?.arrayValue?.compactMap(\.stringValue) ?? [])
            .joined(separator: ".")
        guard !host.isEmpty else { return "" }

        var text = ""
        if let scheme = object["protocol"]?.stringValue, !scheme.isEmpty {
            text += "\(scheme)://"
        }
        text += host
        if let port = object["port"]?.stringValue, !port.isEmpty { text += ":\(port)" }

        let path = (object["path"]?.arrayValue ?? []).compactMap { segment -> String? in
            // A path segment can itself be an object for a path variable: `{"value": ":id"}`.
            segment.stringValue ?? segment["value"]?.stringValue
        }
        if !path.isEmpty { text += "/" + path.joined(separator: "/") }
        return text
    }

    private static func queryParams(from value: JSONValue?) -> [KeyValue] {
        (value?.arrayValue ?? []).compactMap { entry in
            guard let object = entry.objectValue,
                  let key = object["key"]?.stringValue
            else { return nil }
            return KeyValue(
                key: key,
                value: object["value"]?.stringValue ?? "",
                enabled: object["disabled"]?.boolValue != true,
                description: object["description"].flatMap(descriptionText))
        }
    }

    // MARK: - Headers, variables, auth

    static func headers(from value: JSONValue?) -> [KeyValue] {
        (value?.arrayValue ?? []).compactMap { entry in
            guard let object = entry.objectValue,
                  let key = object["key"]?.stringValue
            else { return nil }
            return KeyValue(
                key: key,
                value: object["value"]?.stringValue ?? "",
                enabled: object["disabled"]?.boolValue != true,
                description: object["description"].flatMap(descriptionText))
        }
    }

    static func variables(from value: JSONValue?) -> [Variable] {
        (value?.arrayValue ?? []).compactMap { entry in
            guard let object = entry.objectValue,
                  let key = object["key"]?.stringValue
            else { return nil }
            return Variable(
                key: key,
                value: object["value"]?.stringValue ?? "",
                enabled: object["disabled"]?.boolValue != true,
                isSecret: object["type"]?.stringValue == "secret")
        }
    }

    static func auth(
        from value: JSONValue?, warnings: inout [String], context: String
    ) -> Auth {
        guard let object = value?.objectValue,
              let type = object["type"]?.stringValue
        else { return .inherit }

        /// Postman stores each scheme's fields as `[{key, value, type}]` under its own name.
        func field(_ name: String) -> String {
            guard let entries = object[type]?.arrayValue else { return "" }
            for entry in entries {
                guard let pair = entry.objectValue,
                      pair["key"]?.stringValue == name
                else { continue }
                return pair["value"]?.stringValue ?? ""
            }
            return ""
        }

        switch type {
        case "noauth": return Auth.none
        case "bearer": return .bearer(token: field("token"))
        case "basic": return .basic(username: field("username"), password: field("password"))
        case "apikey":
            let location: APIKeyLocation = field("in") == "query" ? .query : .header
            return .apiKey(
                key: field("key").isEmpty ? "X-API-Key" : field("key"),
                value: field("value"),
                location: location)
        default:
            warnings.append(
                "“\(context)” uses \(type) auth, which Postfrau does not support. "
                    + "Its auth is set to none; the original settings are kept for export.")
            return Auth.none
        }
    }

    // MARK: - Body

    static func body(
        from value: JSONValue?, warnings: inout [String], context: String
    ) -> RequestBody {
        guard let object = value?.objectValue,
              let mode = object["mode"]?.stringValue
        else { return .none }

        switch mode {
        case "raw":
            let text = object["raw"]?.stringValue ?? ""
            let language = object["options"]?["raw"]?["language"]?.stringValue ?? "text"
            return .raw(text: text, language: RawLanguage(postmanName: language))

        case "urlencoded":
            return .urlEncoded(headers(from: object["urlencoded"]))

        case "formdata":
            return .formData(
                formFields(from: object["formdata"], context: context, warnings: &warnings))

        case "file":
            let name = object["file"]?["src"]?.stringValue ?? ""
            warnings.append(
                "“\(context)” sends a file body. The path is remembered as a name only — "
                    + "attach the file again before sending.")
            return .binary(FileReference(displayName: (name as NSString).lastPathComponent))

        case "graphql":
            // Postfrau has no GraphQL mode; the query is perfectly good as a JSON raw body, which
            // is what goes on the wire anyway.
            let query = object["graphql"]?["query"]?.stringValue ?? ""
            let variables = object["graphql"]?["variables"]?.stringValue ?? ""
            var payload = ["query": JSONValue.string(query)]
            if !variables.isEmpty { payload["variables"] = .string(variables) }
            let text = (try? String(
                decoding: Postfrau.makeEncoder().encode(JSONValue.object(payload)), as: UTF8.self))
                ?? query
            warnings.append(
                "“\(context)” is a GraphQL request. It was imported as a JSON body, "
                    + "which is what Postman sends too.")
            return .raw(text: text, language: .json)

        case "none":
            return .none

        default:
            warnings.append("“\(context)” has a \(mode) body, which Postfrau does not understand.")
            return .none
        }
    }

    private static func formFields(
        from value: JSONValue?, context: String, warnings: inout [String]
    ) -> [FormField] {
        (value?.arrayValue ?? []).compactMap { entry in
            guard let object = entry.objectValue,
                  let key = object["key"]?.stringValue
            else { return nil }
            let enabled = object["disabled"]?.boolValue != true
            let contentType = object["contentType"]?.stringValue

            if object["type"]?.stringValue == "file" {
                // Only the name survives: a path from another Mac is not something this one can
                // read, and the sandbox needs the user to pick the file anyway.
                let source = object["src"]?.stringValue
                    ?? object["src"]?.arrayValue?.first?.stringValue ?? ""
                warnings.append(
                    "“\(context)” attaches a file to “\(key)”. "
                        + "Choose the file again before sending.")
                return FormField(
                    key: key,
                    enabled: enabled,
                    value: .file(FileReference(
                        displayName: (source as NSString).lastPathComponent)),
                    contentType: contentType)
            }
            return FormField(
                key: key,
                enabled: enabled,
                value: .text(object["value"]?.stringValue ?? ""),
                contentType: contentType)
        }
    }

    // MARK: - Preserving the rest

    /// Everything at this level Postfrau does not model, so an export can put it back.
    static func extras(
        of object: [String: JSONValue], knownKeys: Set<String>
    ) -> [String: JSONValue] {
        object.filter { !knownKeys.contains($0.key) }
    }

    /// Postman writes a description either as a string or as `{content, type}`.
    static func descriptionText(_ value: JSONValue) -> String? {
        if let text = value.stringValue { return text.isEmpty ? nil : text }
        let content = value["content"]?.stringValue
        return (content?.isEmpty ?? true) ? nil : content
    }
}

extension RawLanguage {
    /// Postman's `options.raw.language` values.
    init(postmanName: String) {
        switch postmanName.lowercased() {
        case "json": self = .json
        case "xml": self = .xml
        case "html": self = .html
        case "javascript": self = .javascript
        case "graphql": self = .json
        default: self = .text
        }
    }

    var postmanName: String {
        switch self {
        case .json: "json"
        case .xml: "xml"
        case .html: "html"
        case .javascript: "javascript"
        case .text: "text"
        }
    }
}
