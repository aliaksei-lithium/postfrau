import Foundation

/// Changes to a saved request for one send, without touching what is saved.
///
/// `run --body @payload.json` used to parse and then do nothing: the saved body went out and the
/// dry run showed it, which is how a caller ends up sending yesterday's payload to production.
/// Everything that reshapes a saved request on the command line goes through here, so the local
/// path and the Local API path apply it the same way.
public struct RequestPatch: Sendable, Hashable, Codable {
    /// Replaces the saved body outright. `{{variables}}` in it resolve as they would in a saved one.
    public var body: String?
    /// JSON fields to set in the body — the saved one, or `body` if given — applied in order.
    public var fields: [Field]
    /// Headers to add, or to replace when one with the same name (any case) is already there.
    public var headers: [HeaderField]

    public struct Field: Sendable, Hashable, Codable {
        /// `partner_bank_id`, `data.items[0].id` — the `--capture` path syntax, `$` optional.
        public var path: String
        /// Read as a JSON literal when it is one (`42`, `true`, `null`, `{"a":1}`, `"42"`), and as
        /// a string otherwise. `{{variables}}` resolve first, so `--field id={{bank}}` sends a
        /// number when `bank` holds one.
        public var value: String

        public init(path: String, value: String) {
            self.path = path
            self.value = value
        }
    }

    public init(body: String? = nil, fields: [Field] = [], headers: [HeaderField] = []) {
        self.body = body
        self.fields = fields
        self.headers = headers
    }

    public var isEmpty: Bool { body == nil && fields.isEmpty && headers.isEmpty }

    /// Whether the body that goes out differs from the saved one.
    public var changesBody: Bool { body != nil || !fields.isEmpty }

    /// What changed the body, for a dry run to say: `--body`, `--body, --field a, --field b`.
    /// Nil when the saved body went out unchanged.
    public var bodyOrigin: String? {
        guard changesBody else { return nil }
        var parts: [String] = []
        if body != nil { parts.append("--body") }
        parts += fields.map { "--field \($0.path)" }
        return parts.joined(separator: ", ")
    }

    // Decoded by hand so an older tool that sends only some keys still decodes.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        body = try container.decodeIfPresent(String.self, forKey: .body)
        fields = try container.decodeIfPresent([Field].self, forKey: .fields) ?? []
        headers = try container.decodeIfPresent([HeaderField].self, forKey: .headers) ?? []
    }

    // MARK: - Applying

    /// The request as it should be sent.
    ///
    /// Field values and — when fields are set — the body itself are resolved with `resolver`
    /// here rather than by the builder, because a saved body like `{"id": {{id}}}` is only JSON
    /// once its variables are filled in.
    public func applied(
        to request: RequestItem, resolver: VariableResolver
    ) throws -> RequestItem {
        var request = request
        if let body { request.body = .raw(guessingLanguageOf: body) }

        if !fields.isEmpty {
            guard case .raw(let text, _) = request.body else {
                throw CommandRunner.CommandError.invalid(
                    "--field sets a value in a JSON body, and this request has "
                        + (request.body.kind == .none ? "no body" : "a \(request.body.kind.displayName.lowercased()) body")
                        + ". Pass the whole body with --body instead.")
            }
            let resolvedText = resolver.resolved(text)
            let source = resolvedText.trimmingCharacters(in: .whitespacesAndNewlines)
            var root: JSONValue
            if source.isEmpty {
                root = .object([:])
            } else if let parsed = try? Postfrau.makeDecoder()
                .decode(JSONValue.self, from: Data(source.utf8)) {
                root = parsed
            } else {
                throw CommandRunner.CommandError.invalid(
                    "--field needs a JSON body, and this one is not JSON once its variables are "
                        + "filled in. Pass the whole body with --body instead.")
            }
            for field in fields {
                let value = Self.literal(resolver.resolved(field.value))
                guard let updated = JSONPath.setting(value, at: field.path, in: root) else {
                    throw CommandRunner.CommandError.invalid(
                        "--field \(field.path): no such place in the body. A missing key is "
                            + "created, but an array index has to exist already.")
                }
                root = updated
            }
            let data = try Postfrau.makeEncoder(pretty: false).encode(root)
            request.body = .raw(text: String(decoding: data, as: UTF8.self), language: .json)
        }

        for header in headers {
            request.headers.removeAll { $0.key.caseInsensitiveCompare(header.name) == .orderedSame }
            request.headers.append(KeyValue(key: header.name, value: header.value))
        }
        return request
    }

    /// `42` → a number, `"42"` → the string 42, `abc` → the string abc.
    static func literal(_ text: String) -> JSONValue {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty,
           let value = try? Postfrau.makeDecoder().decode(JSONValue.self, from: Data(trimmed.utf8))
        {
            return value
        }
        return .string(text)
    }
}

extension RequestBody {
    /// A raw body whose language is guessed from its first character: JSON, XML or text.
    public static func raw(guessingLanguageOf text: String) -> RequestBody {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let language: RawLanguage =
            trimmed.hasPrefix("{") || trimmed.hasPrefix("[") ? .json
            : (trimmed.hasPrefix("<") ? .xml : .text)
        return .raw(text: text, language: language)
    }
}
