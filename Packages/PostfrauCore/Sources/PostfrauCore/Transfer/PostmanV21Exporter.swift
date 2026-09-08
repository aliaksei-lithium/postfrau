import Foundation

/// Writes a Postfrau collection back out as a Postman v2.1 export.
///
/// The inverse of `PostmanV21Importer`, and deliberately so: anything the importer could not model
/// was kept in `extras`, and this puts it back at the level it came from. What Postfrau *does*
/// model is written fresh, so an edit made here reaches the exported file.
public struct PostmanV21Exporter: Sendable {
    public init() {}

    public func export(_ collection: RequestCollection) -> JSONValue {
        var root = collection.extras

        var info: [String: JSONValue] = [
            "name": .string(collection.name),
            "schema": .string(PostmanV21.schemaURL),
            // Postman keys a collection by this id; reusing Postfrau's keeps re-imports stable.
            "_postman_id": .string(collection.id.uuidString.lowercased()),
        ]
        if let description = collection.description, !description.isEmpty {
            info["description"] = .string(description)
        }
        root["info"] = .object(info)
        root["item"] = .array(collection.items.map(item(from:)))

        if !collection.variables.isEmpty {
            root["variable"] = .array(collection.variables.map(variable(from:)))
        }
        if let auth = auth(from: collection.auth) { root["auth"] = auth }
        return .object(root)
    }

    public func data(for collection: RequestCollection) throws -> Data {
        try Postfrau.makeEncoder(pretty: true).encode(export(collection))
    }

    // MARK: - Items

    func item(from item: CollectionItem) -> JSONValue {
        switch item {
        case .folder(let folder):
            var object = folder.extras
            object["name"] = .string(folder.name)
            object["item"] = .array(folder.items.map(self.item(from:)))
            if let description = folder.description, !description.isEmpty {
                object["description"] = .string(description)
            }
            if !folder.variables.isEmpty {
                object["variable"] = .array(folder.variables.map(variable(from:)))
            }
            if let auth = auth(from: folder.auth) { object["auth"] = auth }
            return .object(object)

        case .request(let request):
            // `response` was stashed on the request when it was imported; it belongs to the item,
            // not to the request block, so it is lifted back out here.
            var object = request.extras
            let responses = object.removeValue(forKey: "response")
            object["name"] = .string(request.name)
            object["request"] = self.request(from: request, extras: &object)
            if let responses { object["response"] = responses }
            return .object(object)
        }
    }

    private func request(from request: RequestItem, extras: inout [String: JSONValue]) -> JSONValue {
        // Whatever the importer kept from the *request* level is mixed back into the request; the
        // remainder stays on the item. They were merged on the way in, so they are separated here
        // by which keys Postman puts where.
        var object: [String: JSONValue] = [:]
        for key in PostmanV21.requestLevelExtraKeys {
            if let value = extras.removeValue(forKey: key) { object[key] = value }
        }

        object["method"] = .string(request.method.rawValue)
        object["url"] = url(from: request)
        if !request.headers.isEmpty {
            object["header"] = .array(request.headers.compactMap(header(from:)))
        }
        if let description = request.description, !description.isEmpty {
            object["description"] = .string(description)
        }
        if let auth = auth(from: request.auth) { object["auth"] = auth }
        if let body = body(from: request.body) { object["body"] = body }
        return .object(object)
    }

    // MARK: - URL

    /// Both forms, as Postman itself writes: `raw` for humans and the split-out parts for its
    /// own editor. A file with only `raw` imports fine elsewhere but loses the query table.
    func url(from request: RequestItem) -> JSONValue {
        let raw = request.url
        var object: [String: JSONValue] = ["raw": .string(raw)]

        let components = URLComponents(string: raw)
        if let scheme = components?.scheme, !scheme.isEmpty {
            object["protocol"] = .string(scheme)
        }
        if let host = components?.host, !host.isEmpty {
            object["host"] = .array(host.split(separator: ".").map { .string(String($0)) })
        }
        if let port = components?.port { object["port"] = .string("\(port)") }

        let path = (components?.path ?? "")
            .split(separator: "/", omittingEmptySubsequences: true)
            .map { JSONValue.string(String($0)) }
        if !path.isEmpty { object["path"] = .array(path) }

        let params = KeyValueRows.stripped(request.params)
        if !params.isEmpty {
            object["query"] = .array(params.map { param in
                var entry: [String: JSONValue] = [
                    "key": .string(param.key),
                    "value": .string(param.value),
                ]
                if !param.enabled { entry["disabled"] = .bool(true) }
                if let description = param.description, !description.isEmpty {
                    entry["description"] = .string(description)
                }
                return .object(entry)
            })
        }
        return .object(object)
    }

    // MARK: - Pieces

    private func header(from pair: KeyValue) -> JSONValue? {
        guard !pair.key.isEmpty else { return nil }
        var object: [String: JSONValue] = [
            "key": .string(pair.key),
            "value": .string(pair.value),
        ]
        if !pair.enabled { object["disabled"] = .bool(true) }
        if let description = pair.description, !description.isEmpty {
            object["description"] = .string(description)
        }
        return .object(object)
    }

    private func variable(from variable: Variable) -> JSONValue {
        var object: [String: JSONValue] = [
            "key": .string(variable.key),
            // A secret's value lives in the Keychain and is blank on disk; exporting it would be
            // the one place Postfrau leaked it into a file the user shares.
            "value": .string(variable.isSecret ? "" : variable.value),
        ]
        if variable.isSecret { object["type"] = .string("secret") }
        if !variable.enabled { object["disabled"] = .bool(true) }
        return .object(object)
    }

    /// Nil for `.inherit`: Postman represents "inherit" by having no `auth` key at all.
    func auth(from auth: Auth) -> JSONValue? {
        func fields(_ pairs: [(String, String)]) -> JSONValue {
            .array(pairs.map { key, value in
                .object([
                    "key": .string(key),
                    "value": .string(value),
                    "type": .string("string"),
                ])
            })
        }

        switch auth {
        case .inherit:
            return nil
        case .none:
            return .object(["type": .string("noauth")])
        case .bearer(let token):
            return .object([
                "type": .string("bearer"),
                "bearer": fields([("token", token)]),
            ])
        case .basic(let username, let password):
            return .object([
                "type": .string("basic"),
                "basic": fields([("username", username), ("password", password)]),
            ])
        case .apiKey(let key, let value, let location):
            return .object([
                "type": .string("apikey"),
                "apikey": fields([
                    ("key", key), ("value", value),
                    ("in", location == .query ? "query" : "header"),
                ]),
            ])
        }
    }

    func body(from body: RequestBody) -> JSONValue? {
        switch body {
        case .none:
            return nil

        case .raw(let text, let language):
            return .object([
                "mode": .string("raw"),
                "raw": .string(text),
                "options": .object([
                    "raw": .object(["language": .string(language.postmanName)]),
                ]),
            ])

        case .urlEncoded(let fields):
            let rows = KeyValueRows.stripped(fields)
            guard !rows.isEmpty else { return nil }
            return .object([
                "mode": .string("urlencoded"),
                "urlencoded": .array(rows.compactMap(header(from:))),
            ])

        case .formData(let fields):
            let rows = fields.filter { !$0.isEmpty }
            guard !rows.isEmpty else { return nil }
            return .object([
                "mode": .string("formdata"),
                "formdata": .array(rows.map(formField(from:))),
            ])

        case .binary(let file):
            return .object([
                "mode": .string("file"),
                "file": .object(["src": .string(file.displayName)]),
            ])
        }
    }

    private func formField(from field: FormField) -> JSONValue {
        var object: [String: JSONValue] = ["key": .string(field.key)]
        switch field.value {
        case .text(let text):
            object["type"] = .string("text")
            object["value"] = .string(text)
        case .file(let reference):
            // Only the name, never a bookmark: a path from this Mac means nothing on another.
            object["type"] = .string("file")
            object["src"] = .string(reference.displayName)
        }
        if let contentType = field.contentType, !contentType.isEmpty {
            object["contentType"] = .string(contentType)
        }
        if !field.enabled { object["disabled"] = .bool(true) }
        return .object(object)
    }
}

extension PostmanV21 {
    /// Keys the importer took from a request block and merged onto the item, so the exporter can
    /// put them back where Postman expects them.
    static let requestLevelExtraKeys: Set<String> = [
        "protocolProfileBehavior", "certificate", "proxy",
    ]
}
