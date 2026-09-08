import Foundation

/// Following `$ref` inside one document.
///
/// Local references only — `#/components/schemas/User`. A remote or file `$ref` would mean
/// fetching something the user did not ask us to fetch, from a URL in a file they may have been
/// handed; that is a decision for them, not for an importer.
struct RefResolver {
    let document: [String: JSONValue]
    /// Guards against `A -> B -> A`, which a schema is perfectly entitled to contain.
    private let depthLimit = 12

    /// The value a `$ref` points at, or the value itself when it is not a reference.
    func resolve(_ value: JSONValue?, depth: Int = 0) -> JSONValue? {
        guard let value else { return nil }
        guard depth < depthLimit else { return nil }
        guard let object = value.objectValue,
              let reference = object["$ref"]?.stringValue
        else { return value }
        guard let target = follow(reference) else { return nil }
        return resolve(target, depth: depth + 1)
    }

    /// True when following this reference would not terminate — a self-referential schema.
    func isCircular(_ value: JSONValue?) -> Bool {
        guard let object = value?.objectValue, object["$ref"] != nil else { return false }
        return resolve(value) == nil
    }

    private func follow(_ reference: String) -> JSONValue? {
        // `#/components/schemas/User` → ["components", "schemas", "User"]
        guard reference.hasPrefix("#/") else { return nil }
        var current = JSONValue.object(document)
        for rawSegment in reference.dropFirst(2).split(separator: "/") {
            // JSON Pointer escapes: ~1 is "/", ~0 is "~".
            let segment = rawSegment
                .replacingOccurrences(of: "~1", with: "/")
                .replacingOccurrences(of: "~0", with: "~")
            guard let next = current[segment] else { return nil }
            current = next
        }
        return current
    }
}

extension OpenAPIImporter {
    // MARK: - Security

    /// The auth a request sends when the document declares it at the top level.
    static func collectionAuth(
        document: [String: JSONValue], resolver: RefResolver, warnings: inout [String]
    ) -> Auth {
        guard let security = document["security"]?.arrayValue, !security.isEmpty else {
            return Auth.none
        }
        guard let auth = auth(for: security, document: document, resolver: resolver) else {
            let names = security.flatMap { ($0.objectValue ?? [:]).keys }.sorted()
            warnings.append(
                "The API uses \(names.joined(separator: ", ")) security, which Postfrau cannot "
                    + "model. Set the collection's auth by hand.")
            return Auth.none
        }
        return auth
    }

    /// Maps the first security requirement Postfrau understands onto an `Auth`.
    ///
    /// The values are placeholders — a spec says a bearer token is needed, never what it is — so
    /// they come across as `{{variables}}` to fill in once, in an environment.
    static func auth(
        for requirements: [JSONValue], document: [String: JSONValue], resolver: RefResolver
    ) -> Auth? {
        let schemes = resolver.resolve(document["components"]?["securitySchemes"])?.objectValue ?? [:]

        for requirement in requirements {
            for name in (requirement.objectValue ?? [:]).keys.sorted() {
                guard let scheme = resolver.resolve(schemes[name])?.objectValue else { continue }
                switch scheme["type"]?.stringValue {
                case "http":
                    switch scheme["scheme"]?.stringValue?.lowercased() {
                    case "bearer": return .bearer(token: "{{token}}")
                    case "basic": return .basic(username: "{{username}}", password: "{{password}}")
                    default: continue
                    }
                case "apiKey":
                    guard let key = scheme["name"]?.stringValue else { continue }
                    let location: APIKeyLocation =
                        scheme["in"]?.stringValue == "query" ? .query : .header
                    return .apiKey(key: key, value: "{{apiKey}}", location: location)
                case "oauth2", "openIdConnect":
                    // The token is what goes on the wire, whatever the flow that obtained it.
                    return .bearer(token: "{{token}}")
                default:
                    continue
                }
            }
        }
        return nil
    }

    // MARK: - Bodies

    /// The request body, and the content type it should be sent with.
    static func body(
        _ requestBody: JSONValue?,
        resolver: RefResolver,
        name: String,
        warnings: inout [String]
    ) -> (RequestBody, String?) {
        guard let body = resolver.resolve(requestBody)?.objectValue,
              let content = body["content"]?.objectValue, !content.isEmpty
        else { return (.none, nil) }

        // JSON first, then anything else JSON-shaped, then whatever is offered.
        let preferred = ["application/json"]
            + content.keys.filter { $0.hasSuffix("+json") }.sorted()
            + ["application/x-www-form-urlencoded", "multipart/form-data", "text/plain"]
        let type = preferred.first { content[$0] != nil } ?? content.keys.sorted().first!
        guard let media = resolver.resolve(content[type])?.objectValue else { return (.none, nil) }

        switch type {
        case "application/x-www-form-urlencoded":
            return (.urlEncoded(fields(from: media, resolver: resolver)), type)

        case "multipart/form-data":
            return (.formData(fields(from: media, resolver: resolver).map {
                FormField(key: $0.key, value: .text($0.value))
            }), type)

        default:
            guard let text = jsonBody(media, resolver: resolver, name: name, warnings: &warnings)
            else { return (.none, type) }
            let language: RawLanguage =
                type.contains("json") ? .json : (type.contains("xml") ? .xml : .text)
            return (.raw(text: text, language: language), type)
        }
    }

    /// The example the spec gives, or one synthesised from its schema.
    private static func jsonBody(
        _ media: [String: JSONValue],
        resolver: RefResolver,
        name: String,
        warnings: inout [String]
    ) -> String? {
        // An explicit example is always better than anything we can invent.
        if let example = media["example"] {
            return encode(example)
        }
        if let first = media["examples"]?.objectValue?
            .sorted(by: { $0.key < $1.key }).first?.value,
           let value = resolver.resolve(first)?["value"] {
            return encode(value)
        }
        guard let schema = resolver.resolve(media["schema"]) else { return nil }
        guard let sample = example(for: schema, resolver: resolver) else {
            warnings.append("“\(name)” has a body Postfrau could not build an example for.")
            return nil
        }
        return encode(sample)
    }

    private static func fields(
        from media: [String: JSONValue], resolver: RefResolver
    ) -> [KeyValue] {
        guard let schema = resolver.resolve(media["schema"])?.objectValue,
              let properties = resolver.resolve(schema["properties"])?.objectValue
        else { return [] }
        let required = Set(
            (schema["required"]?.arrayValue ?? []).compactMap(\.stringValue))
        return properties.keys.sorted().map { key in
            let value = example(for: resolver.resolve(properties[key]) ?? .null, resolver: resolver)
            return KeyValue(
                key: key,
                value: value.flatMap { $0.stringValue ?? encode($0) } ?? "",
                enabled: required.isEmpty || required.contains(key))
        }
    }

    static func encode(_ value: JSONValue) -> String {
        guard let data = try? Postfrau.makeEncoder(pretty: true).encode(value) else { return "" }
        return String(decoding: data, as: UTF8.self)
    }

    // MARK: - Example synthesis

    /// A concrete value matching a schema, so an imported request has a body worth editing.
    ///
    /// Depth-limited: a schema may refer to itself, and "a user has friends who are users" would
    /// otherwise expand forever.
    static func example(
        for schema: JSONValue, resolver: RefResolver, depth: Int = 0,
        visiting: Set<String> = []
    ) -> JSONValue? {
        // A schema that refers to something already being expanded is recursive — `Pet.friend`
        // is a `Pet`. Stopping at the second sighting gives one readable level; carrying on to
        // the depth limit gives six nested copies nobody wants to edit.
        var visiting = visiting
        if let reference = schema.objectValue?["$ref"]?.stringValue {
            guard !visiting.contains(reference) else { return nil }
            visiting.insert(reference)
        }
        guard depth < 6, let object = resolver.resolve(schema)?.objectValue else { return nil }

        // Anything the spec states outright beats anything inferred.
        if let example = object["example"] { return example }
        if let first = object["enum"]?.arrayValue?.first { return first }
        if let fallback = object["default"] { return fallback }

        // A composed schema: take the first branch that yields something.
        for keyword in ["allOf", "oneOf", "anyOf"] {
            guard let branches = object[keyword]?.arrayValue else { continue }
            if keyword == "allOf" {
                // Merge every branch, which is what allOf means.
                var merged: [String: JSONValue] = [:]
                for branch in branches {
                    if case .object(let fields)? = example(for: branch, resolver: resolver, depth: depth + 1, visiting: visiting) {
                        merged.merge(fields) { existing, _ in existing }
                    }
                }
                return merged.isEmpty ? nil : .object(merged)
            }
            for branch in branches {
                if let value = example(for: branch, resolver: resolver, depth: depth + 1, visiting: visiting) {
                    return value
                }
            }
        }

        switch Self.type(of: object) {
        case "object":
            let properties = resolver.resolve(object["properties"])?.objectValue ?? [:]
            guard !properties.isEmpty else { return .object([:]) }
            var out: [String: JSONValue] = [:]
            for key in properties.keys.sorted() {
                guard let value = example(
                    for: properties[key] ?? .null, resolver: resolver, depth: depth + 1,
                    visiting: visiting)
                else { continue }
                out[key] = value
            }
            return .object(out)

        case "array":
            guard let items = object["items"],
                  let element = example(
                    for: items, resolver: resolver, depth: depth + 1, visiting: visiting)
            else { return .array([]) }
            return .array([element])

        case "string":
            return .string(placeholder(for: object))
        case "integer":
            return .number("0")
        case "number":
            return .number("0")
        case "boolean":
            return .bool(false)
        case "null":
            return .null
        default:
            return nil
        }
    }

    /// OpenAPI 3.1 allows `type` to be an array (`["string", "null"]`); 3.0 does not.
    static func type(of schema: [String: JSONValue]) -> String? {
        if let single = schema["type"]?.stringValue { return single }
        if let many = schema["type"]?.arrayValue {
            return many.compactMap(\.stringValue).first { $0 != "null" }
        }
        // No type, but properties: it is an object, whatever it says.
        return schema["properties"] != nil ? "object" : nil
    }

    /// A string that hints at what belongs there, rather than a bare "string".
    static func placeholder(for schema: [String: JSONValue]) -> String {
        switch schema["format"]?.stringValue {
        case "date-time": "1970-01-01T00:00:00Z"
        case "date": "1970-01-01"
        case "email": "name@example.com"
        case "uuid": "00000000-0000-0000-0000-000000000000"
        case "uri", "url": "https://example.com"
        case "byte": "" 
        case "password": ""
        default: ""
        }
    }

    /// The example value for a parameter, from its own example or its schema.
    static func exampleValue(
        for parameter: [String: JSONValue], resolver: RefResolver
    ) -> String {
        if let example = parameter["example"] {
            return example.stringValue ?? encode(example)
        }
        guard let schema = parameter["schema"],
              let value = example(for: schema, resolver: resolver)
        else { return "" }
        return value.stringValue ?? encode(value)
    }
}

extension OpenAPIImporter.Result {
    /// The same shape the Postman importer returns, so callers that accept either can be written
    /// once rather than branching on the format everywhere.
    public var asPostmanResult: PostmanV21Importer.Result {
        PostmanV21Importer.Result(collection: collection, warnings: warnings)
    }
}
