import Foundation

/// Turning one finished exchange into the `HistoryEntry` that gets written.
///
/// The app and the `postfrau` CLI both send requests, and both have to record them the same way:
/// the same recording levels, the same redaction, the same body caps. Two copies of this would be
/// two places to fix a leak, and only one of them would get fixed — so there is one, here, and the
/// app's `SendController` and `CommandRunner` both call it.
public enum HistoryRecorder {
    /// What to keep about a send, decided before the request goes out.
    public struct Policy: Sendable {
        public var level: HistoryRecordLevel
        /// Every value that must never appear in the log — secret variables and the credentials
        /// the request itself carries.
        public var secrets: Set<String>
        public var bodyCap: Int
        public var source: HistorySource

        public init(
            level: HistoryRecordLevel,
            secrets: Set<String>,
            bodyCap: Int,
            source: HistorySource
        ) {
            self.level = level
            self.secrets = secrets
            self.bodyCap = bodyCap
            self.source = source
        }
    }

    /// What happened, as far as history cares.
    public struct Exchange: Sendable {
        public var request: RequestItem
        public var resolvedURL: String
        public var built: BuiltRequest?
        public var response: HTTPResponse?
        public var error: String?
        public var startedAt: Date
        public var collectionName: String?

        public init(
            request: RequestItem,
            resolvedURL: String,
            built: BuiltRequest? = nil,
            response: HTTPResponse? = nil,
            error: String? = nil,
            startedAt: Date,
            collectionName: String? = nil
        ) {
            self.request = request
            self.resolvedURL = resolvedURL
            self.built = built
            self.response = response
            self.error = error
            self.startedAt = startedAt
            self.collectionName = collectionName
        }
    }

    /// The entry to write, or nil when recording is off.
    ///
    /// Off the caller's actor: reading a `.full` body means touching up to `bodyCap` bytes, which
    /// must not happen on the main thread while the window is rendering the same response.
    @concurrent
    public static func entry(for exchange: Exchange, policy: Policy) async -> HistoryEntry? {
        guard policy.level != .off else { return nil }

        var entry = HistoryEntry(
            sentAt: exchange.startedAt,
            method: exchange.request.method,
            resolvedURL: HistoryRedactor.redact(
                text: exchange.resolvedURL, secrets: policy.secrets),
            statusCode: exchange.response?.statusCode,
            durationMs: exchange.response?.timing.totalMilliseconds
                ?? Date().timeIntervalSince(exchange.startedAt) * 1000,
            responseBytes: exchange.response?.byteCount ?? 0,
            requestSnapshot: snapshot(of: exchange.request, policy: policy),
            error: exchange.error,
            collectionName: exchange.collectionName,
            source: policy.source,
            recordLevel: policy.level)

        if policy.level.recordsHeaders {
            entry.requestHeaders = exchange.built.map {
                HistoryRedactor.redact(headers: $0.allHeaders, secrets: policy.secrets)
            }
            entry.responseHeaders = exchange.response.map {
                HistoryRedactor.redact(headers: $0.headers, secrets: policy.secrets)
            }
        }
        if policy.level.recordsBodies {
            entry.requestBody = requestBody(exchange.built, policy: policy)
            entry.responseBody = responseBody(exchange.response, policy: policy)
        }
        return entry
    }

    /// The stored copy of the request: redacted always, and below `.full` stripped of its body.
    ///
    /// PLAN.md §6 Phase 8 — the default level keeps what makes an entry findable and re-sendable
    /// without keeping the payload, which is the part most likely to hold something personal.
    static func snapshot(of request: RequestItem, policy: Policy) -> RequestItem {
        var stored = HistoryRedactor.redact(request: request, secrets: policy.secrets)
        if !policy.level.recordsBodies { stored.body = .none }
        return stored
    }

    static func requestBody(_ built: BuiltRequest?, policy: Policy) -> RecordedBody? {
        guard let built else { return nil }
        let data: Data?
        switch built.payload {
        case .data(let bytes): data = bytes
        // A file body is read back through a memory map: a 2 GB upload must not be pulled into
        // memory to record the first quarter-megabyte of it.
        case .file(let url): data = try? Data(contentsOf: url, options: [.mappedIfSafe])
        case .none: data = nil
        }
        guard let data, !data.isEmpty else { return nil }
        return HistoryRedactor.redact(
            body: RecordedBody.capped(
                data, cap: policy.bodyCap,
                mimeType: built.allHeaders.value(for: "Content-Type")),
            secrets: policy.secrets)
    }

    static func responseBody(_ response: HTTPResponse?, policy: Policy) -> RecordedBody? {
        // Only the capped prefix is read, so a huge response costs the cap and not its size.
        guard let response,
              let data = try? response.body.prefix(policy.bodyCap), !data.isEmpty
        else { return nil }
        return HistoryRedactor.redact(
            body: RecordedBody(
                data: data,
                truncated: response.byteCount > data.count,
                originalBytes: response.byteCount,
                mimeType: response.mimeType),
            secrets: policy.secrets)
    }

    /// The credential values a request carries, resolved.
    ///
    /// A token typed straight into the Auth tab is every bit as sensitive as one stored as a
    /// secret variable, and it comes back in the response of any endpoint that echoes headers.
    /// Redacting the header alone would leave it sitting in the recorded body.
    public static func credentials(in auth: Auth, resolver: VariableResolver) -> Set<String> {
        let values: [String]
        switch auth {
        case .none, .inherit: values = []
        case .bearer(let token): values = [token]
        case .basic(_, let password): values = [password]
        case .apiKey(_, let value, _): values = [value]
        }
        return Set(values.map { resolver.resolved($0) }.filter { !$0.isEmpty })
    }

    /// Every value that must be kept out of the log for one send.
    public static func secrets(in scope: VariableScope, auth: Auth, resolver: VariableResolver) -> Set<String> {
        Set(scope.allVariables().filter(\.isSecret).map(\.value).filter { !$0.isEmpty })
            .union(credentials(in: auth, resolver: resolver))
    }
}
