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
    /// Query parameters for this send. Every saved row with one of these names — enabled or
    /// disabled — is replaced by the rows given here, in order, so repeating a name sends it
    /// repeatedly: `--param id=a --param id=b` is `?id=a&id=b`. A row with an empty value only
    /// removes: `--param page=` sends no `page` at all.
    public var params: [QueryParam]
    /// Replaces the request's own auth for this send. `.inherit` uses the folder's or the
    /// collection's even when the request has auth of its own.
    public var auth: Auth?

    public struct QueryParam: Sendable, Hashable, Codable {
        public var name: String
        public var value: String

        public init(name: String, value: String) {
            self.name = name
            self.value = value
        }
    }

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

    public init(
        body: String? = nil, fields: [Field] = [], headers: [HeaderField] = [],
        params: [QueryParam] = [], auth: Auth? = nil
    ) {
        self.body = body
        self.fields = fields
        self.headers = headers
        self.params = params
        self.auth = auth
    }

    /// Every field this build reads, for `LocalAPI.decodeStrictly`.
    public static let fields: Set<String> = ["body", "fields", "headers", "params", "auth"]

    public var isEmpty: Bool {
        body == nil && fields.isEmpty && headers.isEmpty && params.isEmpty && auth == nil
    }

    /// Whether this patch uses anything beyond the v3.5 contract (`body`, `fields`, `headers`),
    /// which an older app would decode and then silently drop.
    public var needsParamsCapability: Bool { !params.isEmpty || auth != nil }

    /// What `--param` did, for a dry run to say: `--param deposit_id ×3, --param page`.
    public var paramsOrigin: String? {
        guard !params.isEmpty else { return nil }
        var order: [String] = []
        var counts: [String: Int] = [:]
        for param in params {
            if counts[param.name] == nil { order.append(param.name) }
            counts[param.name, default: 0] += 1
        }
        return order.map { name in
            let count = counts[name] ?? 1
            return "--param \(name)" + (count > 1 ? " ×\(count)" : "")
        }.joined(separator: ", ")
    }

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
        params = try container.decodeIfPresent([QueryParam].self, forKey: .params) ?? []
        auth = try container.decodeIfPresent(Auth.self, forKey: .auth)
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

        if !params.isEmpty { request = Self.applying(params, to: request) }
        if let auth { request.auth = auth }
        return request
    }

    /// The request with `params` in its table, and the table owning the whole query.
    ///
    /// The builder sends the URL text's own query when the table has no enabled rows, so a
    /// request saved as `…?page=1` with an empty table would keep `page` after `--param page=`
    /// removed it. Moving that query into the table first, then dropping it from the text, leaves
    /// one place the query comes from.
    public static func applying(_ params: [QueryParam], to request: RequestItem) -> RequestItem {
        var request = request
        if request.params.active.isEmpty {
            request.params += URLQuery.parse(request.url).params
        }
        request.url = URLQuery.stripQuery(from: request.url)
        let names = Set(params.map(\.name))
        request.params.removeAll { names.contains($0.key) }
        request.params += params.filter { !$0.value.isEmpty }
            .map { KeyValue(key: $0.name, value: $0.value) }
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
