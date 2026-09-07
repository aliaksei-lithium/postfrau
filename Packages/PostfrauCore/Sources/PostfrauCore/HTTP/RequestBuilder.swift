import Foundation

/// The bytes a request will send.
public enum BodyPayload: Sendable {
    case none
    case data(Data)
    /// A file URL streamed by `URLSession` — used for binary bodies and multipart with file parts,
    /// so uploading a large file does not mean holding it in memory.
    case file(URL)
    /// Set when the payload is a temporary file the executor should delete once the send finishes.
    public var temporaryFileToClean: URL? {
        if case .file(let url) = self, url.path.contains("/postfrau-upload-") { return url }
        return nil
    }

    public var byteCount: Int? {
        switch self {
        case .none: 0
        case .data(let data): data.count
        case .file(let url):
            (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? nil
        }
    }
}

/// A request turned into something `URLSession` can send.
public struct BuiltRequest: Sendable {
    public var urlRequest: URLRequest
    public var payload: BodyPayload
    /// The URL after variable substitution and query composition — what history records.
    public var resolvedURL: String
    /// Headers Postfrau added on the user's behalf, shown greyed-out in the Headers tab.
    public var automaticHeaders: [HeaderField]
    public var warnings: [String]
    /// Security-scoped resources that must stay open until the send completes.
    public var accessedURLs: [URL]

    /// Every header actually on the wire, in send order.
    public var allHeaders: [HeaderField] {
        (urlRequest.allHTTPHeaderFields ?? [:])
            .map { HeaderField(name: $0.key, value: $0.value) }
            .sorted { $0.name.lowercased() < $1.name.lowercased() }
    }
}

/// Turns a `RequestItem` plus resolved variables into a `URLRequest`.
public struct RequestBuilder: Sendable {
    public enum BuildError: Error, LocalizedError, Equatable {
        case emptyURL
        case invalidURL(String)
        case unreadableFile(String)

        public var errorDescription: String? {
            switch self {
            case .emptyURL:
                "Enter a URL before sending."
            case .invalidURL(let text):
                "“\(text)” is not a valid URL."
            case .unreadableFile(let name):
                "Postfrau can no longer read “\(name)”. Pick the file again."
            }
        }
    }

    public init() {}

    /// - Parameters:
    ///   - request: the request as edited, still containing `{{variables}}`.
    ///   - resolver: resolves those variables.
    ///   - effectiveAuth: the auth after walking the inherit chain (see `AuthResolver`).
    public func build(
        _ request: RequestItem,
        resolver: VariableResolver,
        effectiveAuth: Auth
    ) throws -> BuiltRequest {
        var warnings: [String] = []
        var accessed: [URL] = []

        // 1. URL: resolve variables, then let the params table own the query.
        let resolvedBase = resolver.resolved(request.url).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !resolvedBase.isEmpty else { throw BuildError.emptyURL }

        let resolvedParams = request.params.active.map {
            KeyValue(key: resolver.resolved($0.key), value: resolver.resolved($0.value))
        }
        // With no rows in the table the URL text keeps whatever query it already has; the editor
        // keeps the two in step, so an empty table genuinely means "no query of my own".
        var urlText = resolvedParams.isEmpty
            ? resolvedBase
            : URLQuery.compose(
                base: resolvedBase, params: resolvedParams, encode: request.settings.encodeURL)

        // 2. Auth: an API key in the query has to join before the URL is parsed.
        let wireAuth = AuthResolver.wireValue(for: effectiveAuth, resolver: resolver)
        if case .query(let name, let value) = wireAuth {
            let (base, existing) = URLQuery.parse(urlText)
            urlText = URLQuery.compose(
                base: base,
                params: existing + [KeyValue(key: name, value: value)],
                encode: request.settings.encodeURL)
        }

        guard let url = Self.makeURL(from: urlText) else { throw BuildError.invalidURL(urlText) }

        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = request.method.rawValue
        urlRequest.timeoutInterval = request.settings.timeoutSeconds
        urlRequest.httpShouldHandleCookies = request.settings.sendCookies

        // 3. The user's own headers win over everything Postfrau would add.
        var automatic: [HeaderField] = []
        var userHeaderNames: Set<String> = []
        for header in request.headers.active {
            let name = resolver.resolved(header.key)
            let value = resolver.resolved(header.value)
            userHeaderNames.insert(name.lowercased())
            // Repeated header names are joined, matching how HTTP treats them.
            urlRequest.addValue(value, forHTTPHeaderField: name)
        }

        func addAutomatic(_ name: String, _ value: String) {
            guard !userHeaderNames.contains(name.lowercased()) else { return }
            urlRequest.setValue(value, forHTTPHeaderField: name)
            automatic.append(HeaderField(name: name, value: value))
        }

        // 4. Body.
        let payload = try makePayload(
            request.body, resolver: resolver, warnings: &warnings, accessed: &accessed,
            addContentType: { addAutomatic("Content-Type", $0) })

        // 5. Auth header, then the defaults.
        if case .header(let name, let value) = wireAuth {
            if userHeaderNames.contains(name.lowercased()) {
                warnings.append(
                    "Your \(name) header overrides the \(effectiveAuth.kind.displayName) auth helper.")
            } else {
                addAutomatic(name, value)
            }
        }
        addAutomatic("User-Agent", Postfrau.userAgent)
        addAutomatic("Accept", "*/*")

        switch payload {
        case .none:
            break
        case .data(let data):
            urlRequest.httpBody = data
            addAutomatic("Content-Length", String(data.count))
        case .file(let fileURL):
            urlRequest.httpBodyStream = InputStream(url: fileURL)
            if let size = try? FileManager.default
                .attributesOfItem(atPath: fileURL.path)[.size] as? Int {
                addAutomatic("Content-Length", String(size))
            }
        }

        let unresolved = collectUnresolved(request, resolver: resolver)
        if !unresolved.isEmpty {
            warnings.append(
                "Unresolved \(unresolved.count == 1 ? "variable" : "variables"): "
                    + unresolved.joined(separator: ", "))
        }

        return BuiltRequest(
            urlRequest: urlRequest, payload: payload, resolvedURL: url.absoluteString,
            automaticHeaders: automatic, warnings: warnings, accessedURLs: accessed)
    }

    // MARK: - Body

    private func makePayload(
        _ body: RequestBody,
        resolver: VariableResolver,
        warnings: inout [String],
        accessed: inout [URL],
        addContentType: (String) -> Void
    ) throws -> BodyPayload {
        switch body {
        case .none:
            return .none

        case .raw(let text, let language):
            let resolved = resolver.resolved(text)
            guard !resolved.isEmpty else { return .none }
            addContentType(language.defaultContentType)
            return .data(Data(resolved.utf8))

        case .urlEncoded(let rows):
            let active = rows.active
            guard !active.isEmpty else { return .none }
            addContentType("application/x-www-form-urlencoded")
            let encoded = active.map {
                "\(FormEncoding.encode(resolver.resolved($0.key)))"
                    + "=\(FormEncoding.encode(resolver.resolved($0.value)))"
            }.joined(separator: "&")
            return .data(Data(encoded.utf8))

        case .formData(let fields):
            let active = fields.filter { $0.enabled && !$0.key.isEmpty }
            guard !active.isEmpty else { return .none }
            let boundary = MultipartBuilder.makeBoundary()
            addContentType("multipart/form-data; boundary=\(boundary)")
            return try MultipartBuilder.build(
                fields: active, boundary: boundary, resolver: resolver,
                warnings: &warnings, accessed: &accessed)

        case .binary(let reference):
            guard let bookmark = reference.bookmark else {
                if !reference.displayName.isEmpty {
                    warnings.append("No file is attached; “\(reference.displayName)” was not found.")
                }
                return .none
            }
            let url = try SecurityScopedFile.resolve(
                bookmark: bookmark, displayName: reference.displayName, accessed: &accessed)
            addContentType(MIMEType.forExtension(url.pathExtension))
            return .file(url)
        }
    }

    /// Every unresolved variable name across the request, for the pre-send warning.
    private func collectUnresolved(_ request: RequestItem, resolver: VariableResolver) -> [String] {
        var names: [String] = []
        func scan(_ text: String) {
            for name in resolver.resolve(text).unresolved where !names.contains(name) {
                names.append(name)
            }
        }
        scan(request.url)
        for row in request.params.active { scan(row.key); scan(row.value) }
        for row in request.headers.active { scan(row.key); scan(row.value) }
        switch request.body {
        case .raw(let text, _): scan(text)
        case .urlEncoded(let rows): for row in rows.active { scan(row.key); scan(row.value) }
        case .formData(let fields):
            for field in fields where field.enabled {
                scan(field.key)
                if case .text(let value) = field.value { scan(value) }
            }
        case .none, .binary: break
        }
        return names
    }

    /// Builds a `URL`, percent-encoding anything the user left raw.
    ///
    /// `URL(string:)` is strict; a URL with a space or a UTF-8 path is common in the wild, so we
    /// fall back to `URLComponents`-style encoding before giving up. A URL with no scheme gets
    /// `https://`, which is what every other HTTP client does.
    static func makeURL(from text: String) -> URL? {
        let withScheme = hasScheme(text) ? text : "https://\(text)"
        if let url = URL(string: withScheme), url.host != nil || url.isFileURL { return url }
        guard let encoded = withScheme.addingPercentEncoding(
            withAllowedCharacters: .urlAllowedRelaxed) else { return nil }
        return URL(string: encoded)
    }

    private static func hasScheme(_ text: String) -> Bool {
        guard let colon = text.firstIndex(of: ":") else { return false }
        let scheme = text[text.startIndex..<colon]
        return !scheme.isEmpty && scheme.allSatisfy { $0.isLetter || $0.isNumber || "+-.".contains($0) }
    }
}

extension CharacterSet {
    /// Everything legal anywhere in a URL. Used only as a last-resort repair pass.
    static let urlAllowedRelaxed: CharacterSet = {
        var set = CharacterSet.alphanumerics
        set.insert(charactersIn: "-._~:/?#[]@!$&'()*+,;=%")
        return set
    }()
}

/// `application/x-www-form-urlencoded` escaping, which is not the same as URL query escaping:
/// spaces become `+` and every reserved character is escaped.
enum FormEncoding {
    static func encode(_ text: String) -> String {
        let allowed = CharacterSet(charactersIn:
            "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._*")
        return (text.addingPercentEncoding(withAllowedCharacters: allowed) ?? text)
            .replacingOccurrences(of: "%20", with: "+")
    }
}
