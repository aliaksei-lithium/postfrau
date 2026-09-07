import Foundation

/// Sends requests and collects responses.
///
/// One `URLSession` is cached per *profile* — the combination of settings that cannot be varied
/// per request (TLS verification, cookie handling). Timeouts and redirect policy travel with the
/// request and its task delegate, so they do not multiply the session cache.
///
/// Bodies are streamed: everything up to `spillThreshold` stays in memory, beyond that it goes to
/// a temporary file, and past `hardCap` the transfer is abandoned with a clear error.
public actor HTTPExecutor {
    /// Above this many bytes the body is written to a temporary file instead of held in memory.
    public static let spillThreshold = 20 * 1024 * 1024
    /// Past this the transfer is abandoned; no response Postfrau can usefully show is this large.
    public static let hardCap = 200 * 1024 * 1024

    public enum ExecutorError: Error, LocalizedError {
        case tooLarge(limit: Int)
        case notHTTP
        case transport(URLError)
        case cancelled

        public var errorDescription: String? {
            switch self {
            case .tooLarge(let limit):
                "The response is larger than \(ByteCount.format(limit)) and was not downloaded."
            case .notHTTP:
                "The server did not return an HTTP response."
            case .cancelled:
                "The request was cancelled."
            case .transport(let error):
                Self.describe(error)
            }
        }

        /// A short, human explanation for the most common transport failures.
        static func describe(_ error: URLError) -> String {
            switch error.code {
            case .notConnectedToInternet: "No internet connection."
            case .cannotFindHost: "Could not find that host. Check the URL."
            case .cannotConnectToHost: "The server refused the connection."
            case .timedOut: "The request timed out."
            case .networkConnectionLost: "The network connection was lost."
            case .dnsLookupFailed: "DNS lookup failed."
            case .secureConnectionFailed: "The secure connection failed."
            case .serverCertificateUntrusted, .serverCertificateHasBadDate,
                 .serverCertificateHasUnknownRoot, .serverCertificateNotYetValid:
                "The server's TLS certificate was rejected. "
                    + "Turn off “Verify TLS certificates” in Settings to send anyway."
            case .unsupportedURL: "That URL scheme is not supported."
            case .httpTooManyRedirects: "Too many redirects."
            case .cancelled: "The request was cancelled."
            default: error.localizedDescription
            }
        }
    }

    /// The settings that force a separate `URLSession`.
    struct SessionProfile: Hashable, Sendable {
        var verifyTLS: Bool
        var sendCookies: Bool
    }

    private var sessions: [SessionProfile: URLSession] = [:]
    /// Injectable so tests can register a `URLProtocol` mock.
    private let protocolClasses: [AnyClass]?

    public init(protocolClasses: [AnyClass]? = nil) {
        self.protocolClasses = protocolClasses
    }

    /// Sends a built request. Cancelling the surrounding `Task` cancels the transfer.
    public func send(_ built: BuiltRequest, settings: RequestSettings) async throws -> HTTPResponse {
        defer {
            SecurityScopedFile.stopAccessing(built.accessedURLs)
            if let temporary = built.payload.temporaryFileToClean {
                try? FileManager.default.removeItem(at: temporary)
            }
        }

        let session = session(for: SessionProfile(
            verifyTLS: settings.verifyTLS, sendCookies: settings.sendCookies))
        let observer = TaskObserver(options: TaskObserver.Options(
            verifyTLS: settings.verifyTLS,
            followRedirects: settings.followRedirects,
            maxRedirects: settings.maxRedirects,
            byteCap: Self.hardCap))

        let started = ContinuousClock.now
        do {
            let (body, response) = try await fetch(built.urlRequest, on: session, observer: observer)
            guard let http = response as? HTTPURLResponse else { throw ExecutorError.notHTTP }
            let elapsed = started.duration(to: .now).seconds

            let headers = Self.orderedHeaders(from: http)
            return HTTPResponse(
                statusCode: http.statusCode,
                reasonPhrase: ReasonPhrase.forStatus(http.statusCode),
                headers: headers,
                body: body,
                mimeType: http.mimeType,
                textEncodingName: http.textEncodingName,
                timing: observer.timing(fallbackTotal: elapsed),
                redirects: observer.redirects,
                finalURL: http.url?.absoluteString ?? built.resolvedURL,
                cookies: CookieParser.parse(headers: headers),
                sentHeaders: built.allHeaders,
                wasTruncated: false)
        } catch let error as ExecutorError {
            throw error
        } catch let error as URLError {
            // Our own size guard cancels the task, so check that before blaming the user.
            if observer.exceededByteCap { throw ExecutorError.tooLarge(limit: Self.hardCap) }
            if error.code == .cancelled { throw ExecutorError.cancelled }
            throw ExecutorError.transport(error)
        } catch is CancellationError {
            throw ExecutorError.cancelled
        }
    }

    /// Drops every cached session. Called when the app quits and after a settings change that
    /// would otherwise leave a stale connection pool behind.
    public func invalidateSessions() {
        for session in sessions.values { session.finishTasksAndInvalidate() }
        sessions.removeAll()
    }

    // MARK: - Private

    private func session(for profile: SessionProfile) -> URLSession {
        if let existing = sessions[profile] { return existing }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = profile.sendCookies
        configuration.httpCookieAcceptPolicy = profile.sendCookies ? .onlyFromMainDocumentDomain : .never
        // Each profile gets its own cookie jar so "don't send cookies" really means none, and one
        // request's session cookie cannot leak into a request that opted out.
        configuration.httpCookieStorage = profile.sendCookies ? HTTPCookieStorage() : nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        // Redirect and timeout limits are enforced per task, not per session.
        configuration.httpMaximumConnectionsPerHost = 6
        if let protocolClasses {
            configuration.protocolClasses = protocolClasses
        }

        let session = URLSession(configuration: configuration)
        sessions[profile] = session
        return session
    }

    /// Runs the transfer, streaming the body to disk and keeping it there only if it is big.
    ///
    /// `download(for:)` rather than `bytes(for:)`: `URLSession.AsyncBytes` yields one `UInt8` per
    /// iteration, which measured ~40x slower than either alternative (556 ms versus 8–13 ms for a
    /// 9 MB body on this machine) and would put a visible stall in front of every large response.
    /// `download` streams to a file with flat memory use, so the spill path and the cap come for
    /// free; a small body is read back into memory immediately, which costs a fraction of a
    /// millisecond. See `docs/decisions.md` D9.
    private func fetch(
        _ request: URLRequest, on session: URLSession, observer: TaskObserver
    ) async throws -> (ResponseBody, URLResponse) {
        let (downloadURL, response) = try await session.download(for: request, delegate: observer)
        defer { try? FileManager.default.removeItem(at: downloadURL) }

        let size = (try? FileManager.default
            .attributesOfItem(atPath: downloadURL.path)[.size] as? Int) ?? 0
        if size > Self.hardCap { throw ExecutorError.tooLarge(limit: Self.hardCap) }

        if size <= Self.spillThreshold {
            return (.inMemory(try Data(contentsOf: downloadURL)), response)
        }

        // Adopt the file rather than copying it: a 50 MB body should not be written twice.
        let spillURL = FileManager.default.temporaryDirectory
            .appending(path: "postfrau-response-\(UUID().uuidString)", directoryHint: .notDirectory)
        try FileManager.default.moveItem(at: downloadURL, to: spillURL)
        return (.onDisk(spillURL, byteCount: size), response)
    }

    /// `HTTPURLResponse.allHeaderFields` is an unordered dictionary that folds duplicates.
    /// `value(forHTTPHeaderField:)` joins them the same way, so we keep the dictionary's contents
    /// but present them in a stable, readable order.
    static func orderedHeaders(from response: HTTPURLResponse) -> [HeaderField] {
        response.allHeaderFields
            .compactMap { key, value in
                guard let name = key as? String else { return nil }
                return HeaderField(name: name, value: String(describing: value))
            }
            .sorted { $0.name.lowercased() < $1.name.lowercased() }
    }
}

extension Duration {
    /// The duration in seconds, as a `TimeInterval`.
    var seconds: TimeInterval {
        let (whole, attoseconds) = components
        return TimeInterval(whole) + TimeInterval(attoseconds) / 1e18
    }
}
