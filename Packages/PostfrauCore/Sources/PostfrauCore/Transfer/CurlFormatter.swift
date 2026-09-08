import Foundation

/// Writes a request back out as a `curl` command.
///
/// For pasting into a terminal, a ticket or a colleague's chat, so it is formatted to be read:
/// one flag per line, continuations aligned. Quoting is single-quote-first because that is the
/// form that survives a body full of double quotes and backslashes unchanged.
public struct CurlFormatter: Sendable {
    /// Whether `{{variables}}` are written out resolved or left as they are.
    public enum VariableHandling: Sendable, Hashable, CaseIterable {
        /// Substitute the values in scope — a command that runs as-is.
        case resolved
        /// Leave `{{baseUrl}}` in place — a command that is safe to share.
        case raw

        public var displayName: String {
            switch self {
            case .resolved: "With values filled in"
            case .raw: "Keeping {{variables}}"
            }
        }
    }

    public init() {}

    /// - Parameters:
    ///   - resolver: used when `handling` is `.resolved`.
    ///   - effectiveAuth: the auth after the inherit chain has been walked, so the command carries
    ///     the header the request would actually send.
    public func format(
        _ request: RequestItem,
        resolver: VariableResolver? = nil,
        effectiveAuth: Auth? = nil,
        handling: VariableHandling = .raw
    ) -> String {
        func text(_ value: String) -> String {
            guard handling == .resolved, let resolver else { return value }
            return resolver.resolved(value)
        }

        var lines: [String] = []
        let url = text(URLQuery.compose(
            base: request.url,
            params: KeyValueRows.stripped(request.params),
            encode: request.settings.encodeURL))
        lines.append("curl \(Self.quote(url))")

        if request.method != .get {
            lines.append("--request \(request.method.rawValue)")
        }

        let auth = effectiveAuth ?? request.auth
        for header in Self.authHeaders(for: auth, text: text) {
            lines.append("--header \(Self.quote("\(header.name): \(header.value)"))")
        }

        for header in KeyValueRows.stripped(request.headers) {
            lines.append("--header \(Self.quote("\(text(header.key)): \(text(header.value))"))")
        }

        lines.append(contentsOf: bodyLines(request.body, text: text))

        if !request.settings.verifyTLS { lines.append("--insecure") }
        if request.settings.followRedirects { lines.append("--location") }

        // A leading four spaces on the continuations, which is what everyone's terminal shows.
        return lines.enumerated()
            .map { index, line in index == 0 ? line : "    \(line)" }
            .joined(separator: " \\\n")
    }

    // MARK: - Body

    private func bodyLines(_ body: RequestBody, text: (String) -> String) -> [String] {
        switch body {
        case .none:
            return []

        case .raw(let raw, _):
            guard !raw.isEmpty else { return [] }
            return ["--data-raw \(Self.quote(text(raw)))"]

        case .urlEncoded(let fields):
            return KeyValueRows.stripped(fields).map { pair in
                "--data-urlencode \(Self.quote("\(text(pair.key))=\(text(pair.value))"))"
            }

        case .formData(let fields):
            return fields.filter { !$0.isEmpty }.map { field in
                switch field.value {
                case .text(let value):
                    return "--form \(Self.quote("\(text(field.key))=\(text(value))"))"
                case .file(let reference):
                    // `@name` is curl's attach syntax; the name is all Postfrau kept, so the
                    // command needs the path filled in before it runs. Saying so beats a
                    // silently wrong path.
                    let name = reference.displayName.isEmpty ? "FILE" : reference.displayName
                    return "--form \(Self.quote("\(text(field.key))=@\(name)"))"
                }
            }

        case .binary(let reference):
            let name = reference.displayName.isEmpty ? "FILE" : reference.displayName
            return ["--data-binary \(Self.quote("@\(name)"))"]
        }
    }

    /// The headers auth turns into, so the command sends what Postfrau would.
    static func authHeaders(for auth: Auth, text: (String) -> String) -> [HeaderField] {
        switch auth {
        case .none, .inherit:
            return []
        case .bearer(let token):
            let value = text(token)
            return value.isEmpty ? [] : [HeaderField(name: "Authorization", value: "Bearer \(value)")]
        case .basic(let username, let password):
            let pair = "\(text(username)):\(text(password))"
            let encoded = Data(pair.utf8).base64EncodedString()
            return [HeaderField(name: "Authorization", value: "Basic \(encoded)")]
        case .apiKey(let key, let value, let location):
            // A query-string key is part of the URL, and the URL was already composed above.
            guard location == .header else { return [] }
            return [HeaderField(name: text(key), value: text(value))]
        }
    }

    // MARK: - Quoting

    /// Single quotes unless the value contains one, in which case double quotes with the few
    /// characters the shell still reads inside them escaped.
    static func quote(_ value: String) -> String {
        guard !value.isEmpty else { return "''" }
        if !value.contains("'") {
            // Nothing inside single quotes is special to the shell, so this is always safe.
            return "'\(value)'"
        }
        var escaped = ""
        for character in value {
            if character == "\"" || character == "\\" || character == "$" || character == "`" {
                escaped.append("\\")
            }
            escaped.append(character)
        }
        return "\"\(escaped)\""
    }
}
