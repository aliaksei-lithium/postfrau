import Foundation

/// Turns a `curl` command line into a request.
///
/// The point is paste-and-go: every browser's "Copy as cURL" and every API doc's example should
/// land in the URL bar and work. That means tolerating the shell — quotes, `\` continuations,
/// `$'…'` escapes — and ignoring flags that do not change what goes on the wire rather than
/// refusing the whole command over one of them.
public struct CurlParser: Sendable {
    public init() {}

    public struct Result: Sendable {
        public var request: RequestItem
        public var warnings: [String]

        public init(request: RequestItem, warnings: [String] = []) {
            self.request = request
            self.warnings = warnings
        }
    }

    public enum ParseError: Error, LocalizedError, Equatable {
        case notCurl
        case noURL

        public var errorDescription: String? {
            switch self {
            case .notCurl: "That does not start with “curl”."
            case .noURL: "That curl command has no URL."
            }
        }
    }

    /// True when some text looks like a curl command, for the URL bar's paste handling.
    public static func looksLikeCurl(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.hasPrefix("curl ") || trimmed == "curl" || trimmed.hasPrefix("curl\n")
            || trimmed.hasPrefix("curl\t")
    }

    public func parse(_ command: String) throws -> Result {
        var tokens = CurlTokenizer.tokenize(command)
        guard let first = tokens.first, first == "curl" || first.hasSuffix("/curl") else {
            throw ParseError.notCurl
        }
        tokens.removeFirst()

        var request = RequestItem()
        var warnings: [String] = []
        var urls: [String] = []
        var explicitMethod: HTTPMethod?
        var dataParts: [DataPart] = []
        var formFields: [FormField] = []
        var basic: (user: String, password: String)?
        var sendsDataAsQuery = false

        var index = 0
        while index < tokens.count {
            let token = tokens[index]
            index += 1

            /// The value that goes with a flag, whether written `-H x`, `-Hx` or `--header=x`.
            func value(inline: String? = nil) -> String? {
                if let inline { return inline }
                guard index < tokens.count else { return nil }
                defer { index += 1 }
                return tokens[index]
            }

            guard token.hasPrefix("-"), token != "-" else {
                urls.append(token)
                continue
            }

            let (name, inline) = Self.split(flag: token)
            switch name {
            case "-X", "--request":
                if let raw = value(inline: inline) {
                    explicitMethod = HTTPMethod(rawValue: raw.uppercased())
                }

            case "-H", "--header":
                if let raw = value(inline: inline), let pair = Self.header(from: raw) {
                    request.headers.append(pair)
                }

            case "-d", "--data", "--data-raw", "--data-ascii":
                if let raw = value(inline: inline) { dataParts.append(.raw(raw)) }

            case "--data-binary":
                if let raw = value(inline: inline) { dataParts.append(.raw(raw)) }

            case "--data-urlencode":
                if let raw = value(inline: inline) { dataParts.append(.urlEncoded(raw)) }

            case "-F", "--form", "--form-string":
                if let raw = value(inline: inline), let field = Self.formField(from: raw) {
                    formFields.append(field)
                }

            case "-u", "--user":
                if let raw = value(inline: inline) {
                    let parts = raw.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
                    basic = (String(parts.first ?? ""), parts.count > 1 ? String(parts[1]) : "")
                }

            case "-b", "--cookie":
                if let raw = value(inline: inline) {
                    // `-b file.txt` reads a cookie jar; only an inline `k=v` string is a header.
                    if raw.contains("=") {
                        request.headers.append(KeyValue(key: "Cookie", value: raw))
                    } else {
                        warnings.append("Ignored a cookie file (“\(raw)”): Postfrau has no cookie jar.")
                    }
                }

            case "-A", "--user-agent":
                if let raw = value(inline: inline) {
                    request.headers.append(KeyValue(key: "User-Agent", value: raw))
                }

            case "-e", "--referer":
                if let raw = value(inline: inline) {
                    request.headers.append(KeyValue(key: "Referer", value: raw))
                }

            case "--url":
                if let raw = value(inline: inline) { urls.append(raw) }

            case "-L", "--location":
                request.settings.followRedirects = true

            case "-k", "--insecure":
                request.settings.verifyTLS = false

            case "-G", "--get":
                // Applied after parsing: -G is commonly written before the -d flags it moves.
                explicitMethod = .get
                sendsDataAsQuery = true

            case "-I", "--head":
                explicitMethod = .head

            case "-m", "--max-time":
                if let raw = value(inline: inline), let seconds = Double(raw) {
                    request.settings.timeoutSeconds = seconds
                }

            case "--compressed", "-s", "--silent", "-S", "--show-error", "-f", "--fail",
                 "-i", "--include", "-v", "--verbose", "-#", "--progress-bar", "--no-buffer",
                 "-N", "--globoff", "-g", "-4", "-6", "--http1.1", "--http2":
                // Flags about curl's own behaviour, not about the request. Silently fine.
                break

            case "-o", "--output", "-w", "--write-out", "--retry", "--connect-timeout",
                 "-x", "--proxy", "--cert", "--key", "--cacert", "-c", "--cookie-jar":
                // Take a value, but mean nothing here. Consume it so it is not read as the URL.
                _ = value(inline: inline)
                warnings.append("Ignored \(name), which Postfrau does not use.")

            default:
                // Nothing is swallowed after an unknown flag: it is at least as likely to be a
                // boolean as to take a value, and eating the URL is the worse failure. A stray
                // value it did take is filtered out below by not looking like a URL.
                warnings.append("Ignored the unknown option \(name).")
            }
        }

        let candidates = urls.filter(Self.looksLikeURL)
        guard let url = candidates.first else { throw ParseError.noURL }
        if candidates.count > 1 {
            warnings.append(
                "The command has \(candidates.count) URLs; Postfrau imported the first "
                    + "and ignored the rest.")
        }

        request.url = Self.normalize(url: url)
        let (_, params) = URLQuery.merge(urlText: request.url, into: [])
        request.params = params

        if let basic { request.auth = .basic(username: basic.user, password: basic.password) }
        Self.applyAuthorizationHeader(&request)

        if sendsDataAsQuery {
            // `-G` sends what would have been the body as the query string instead.
            request.url = URLQuery.compose(
                base: request.url,
                params: KeyValueRows.stripped(params) + Self.queryPairs(from: dataParts),
                encode: true)
            let (_, merged) = URLQuery.merge(urlText: request.url, into: [])
            request.params = merged
            request.body = .none
        } else {
            request.body = Self.body(
                dataParts: dataParts, formFields: formFields, headers: request.headers)
        }

        request.method = explicitMethod ?? Self.impliedMethod(for: request.body)
        request.name = Self.name(for: request.url)
        return Result(request: request, warnings: warnings)
    }

    // MARK: - Pieces

    private enum DataPart: Sendable {
        case raw(String)
        case urlEncoded(String)
        case query(String)

        var text: String {
            switch self {
            case .raw(let text), .urlEncoded(let text), .query(let text): text
            }
        }
    }

    /// `--header=x` → `("--header", "x")`; `-Hx` → `("-H", "x")`; `-H` → `("-H", nil)`.
    static func split(flag token: String) -> (name: String, inline: String?) {
        if token.hasPrefix("--") {
            guard let equals = token.firstIndex(of: "=") else { return (token, nil) }
            return (String(token[token.startIndex..<equals]),
                    String(token[token.index(after: equals)...]))
        }
        // Short flags can carry their value with no space: `-H'Accept: x'`.
        guard token.count > 2 else { return (token, nil) }
        let name = String(token.prefix(2))
        return (name, String(token.dropFirst(2)))
    }

    static func header(from raw: String) -> KeyValue? {
        guard let colon = raw.firstIndex(of: ":") else {
            // `-H "X-Empty;"` is curl's way of sending a header with no value.
            guard raw.hasSuffix(";") else { return nil }
            return KeyValue(key: String(raw.dropLast()), value: "")
        }
        let name = String(raw[raw.startIndex..<colon]).trimmingCharacters(in: .whitespaces)
        let value = String(raw[raw.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return nil }
        return KeyValue(key: name, value: value)
    }

    static func formField(from raw: String) -> FormField? {
        guard let equals = raw.firstIndex(of: "=") else { return nil }
        let key = String(raw[raw.startIndex..<equals])
        var value = String(raw[raw.index(after: equals)...])
        guard !key.isEmpty else { return nil }

        // `field=@path` attaches a file; `field=<path` reads a value from one.
        if value.hasPrefix("@") || value.hasPrefix("<") {
            let path = String(value.dropFirst())
            // `;type=` and `;filename=` suffixes are curl's, not part of the path.
            let clean = path.split(separator: ";", maxSplits: 1).first.map(String.init) ?? path
            return FormField(
                key: key,
                value: .file(FileReference(displayName: (clean as NSString).lastPathComponent)))
        }
        if let semicolon = value.firstIndex(of: ";"), value[semicolon...].hasPrefix(";type=") {
            let contentType = String(value[value.index(semicolon, offsetBy: 6)...])
            value = String(value[value.startIndex..<semicolon])
            return FormField(key: key, value: .text(value), contentType: contentType)
        }
        return FormField(key: key, value: .text(value))
    }

    /// A `-H "Authorization: …"` is better modelled as auth than as a header.
    static func applyAuthorizationHeader(_ request: inout RequestItem) {
        guard let index = request.headers.firstIndex(where: {
            $0.key.lowercased() == "authorization"
        }) else { return }
        let value = request.headers[index].value

        if value.lowercased().hasPrefix("bearer ") {
            request.auth = .bearer(token: String(value.dropFirst("bearer ".count)))
            request.headers.remove(at: index)
        } else if value.lowercased().hasPrefix("basic "),
                  let decoded = Data(base64Encoded: String(value.dropFirst("basic ".count))),
                  let pair = String(data: decoded, encoding: .utf8),
                  let colon = pair.firstIndex(of: ":") {
            request.auth = .basic(
                username: String(pair[pair.startIndex..<colon]),
                password: String(pair[pair.index(after: colon)...]))
            request.headers.remove(at: index)
        }
        // Anything else (Digest, AWS signatures, a bare token) stays a header, which is exactly
        // what it is.
    }

    private static func body(
        dataParts: [DataPart], formFields: [FormField], headers: [KeyValue]
    ) -> RequestBody {
        if !formFields.isEmpty { return .formData(formFields) }
        guard !dataParts.isEmpty else { return .none }

        // curl joins repeated -d with `&`, which is what makes `-d a=1 -d b=2` a form post.
        let joined = dataParts.map(\.text).joined(separator: "&")
        let contentType = headers.first { $0.key.lowercased() == "content-type" }?.value.lowercased()

        // `--data-urlencode` says what it is: form pairs, even when a value has a space in it.
        let isExplicitlyURLEncoded = dataParts.contains {
            if case .urlEncoded = $0 { return true } else { return false }
        }
        if isExplicitlyURLEncoded
            || contentType?.contains("x-www-form-urlencoded") == true
            || (contentType == nil && looksLikeFormPairs(joined))
        {
            return .urlEncoded(formPairs(from: joined))
        }
        return .raw(text: joined, language: language(for: contentType, body: joined))
    }

    private static func queryPairs(from parts: [DataPart]) -> [KeyValue] {
        formPairs(from: parts.map(\.text).joined(separator: "&"))
    }

    private static func formPairs(from joined: String) -> [KeyValue] {
        joined.split(separator: "&").map { pair in
            guard let equals = pair.firstIndex(of: "=") else {
                return KeyValue(key: String(pair), value: "")
            }
            return KeyValue(
                key: String(pair[pair.startIndex..<equals]).removingPercentEncoding
                    ?? String(pair[pair.startIndex..<equals]),
                value: String(pair[pair.index(after: equals)...]).removingPercentEncoding
                    ?? String(pair[pair.index(after: equals)...]))
        }
    }

    /// `a=1&b=2` with nothing JSON-ish about it.
    static func looksLikeFormPairs(_ text: String) -> Bool {
        guard !text.isEmpty, !text.hasPrefix("{"), !text.hasPrefix("["), !text.hasPrefix("<")
        else { return false }
        let pairs = text.split(separator: "&")
        guard !pairs.isEmpty else { return false }
        return pairs.allSatisfy { $0.contains("=") && !$0.contains(" ") }
    }

    private static func language(for contentType: String?, body: String) -> RawLanguage {
        if let contentType {
            if contentType.contains("json") { return .json }
            if contentType.contains("xml") { return .xml }
            if contentType.contains("html") { return .html }
            return .text
        }
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("{") || trimmed.hasPrefix("[") { return .json }
        if trimmed.hasPrefix("<") { return .xml }
        return .text
    }

    private static func impliedMethod(for body: RequestBody) -> HTTPMethod {
        // curl with data and no -X is a POST; without data it is a GET.
        if case .none = body { return .get }
        return .post
    }

    /// `example.com/users` → `https://example.com/users`. curl assumes http; browsers and API docs
    /// mean https, and a request that silently downgrades is worse than one the user retypes.
    static func normalize(url: String) -> String {
        guard !url.contains("://") else { return url }
        return "https://\(url)"
    }

    /// A bare token is the URL only if it looks like one. Everything else curl leaves lying
    /// around — a filename after an option Postfrau ignores, a stray argument — fails this.
    static func looksLikeURL(_ token: String) -> Bool {
        if token.contains("://") { return true }
        if token.hasPrefix("localhost") { return true }
        if token.hasPrefix("{{") { return true }
        guard let host = token.split(separator: "/", maxSplits: 1).first else { return false }
        return host.contains(".") && !host.hasPrefix(".") && !host.hasSuffix(".")
    }

    static func name(for url: String) -> String {
        guard let components = URLComponents(string: url) else { return "Imported request" }
        let path = components.path.split(separator: "/").last.map(String.init)
        return path ?? components.host ?? "Imported request"
    }
}
