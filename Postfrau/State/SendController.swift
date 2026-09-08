import Foundation
import PostfrauCore

extension AppState {
    /// The variable scope a request sees: active environment → its folder chain → its collection
    /// → globals.
    func scope(for tab: RequestTab) -> VariableScope {
        let collection = tab.collectionID.flatMap { workspace.collection(withID: $0) }
        var chain: [Folder] = []
        if let collection, let requestID = tab.requestID,
           let ids = collection.folderChain(to: requestID) {
            chain = ids.compactMap { collection.folder(withID: $0) }
        }
        return VariableScope.build(
            environment: workspace.activeEnvironment,
            collection: collection,
            folderChain: chain,
            globals: workspace.globals)
    }

    func resolver(for tab: RequestTab) -> VariableResolver {
        VariableResolver(scope: scope(for: tab))
    }

    /// The auth a request will actually send, after walking the inherit chain.
    func effectiveAuth(for tab: RequestTab) -> EffectiveAuth {
        guard let collectionID = tab.collectionID,
              let collection = workspace.collection(withID: collectionID)
        else {
            return AuthResolver.effective(
                requestAuth: tab.draft.auth, folderChain: [], collection: nil)
        }
        let chain = (tab.requestID.flatMap { collection.folderChain(to: $0) } ?? [])
            .compactMap { collection.folder(withID: $0) }
        return AuthResolver.effective(
            requestAuth: tab.draft.auth, folderChain: chain, collection: collection)
    }

    // MARK: - Sending

    /// Sends the tab's draft. Safe to call while a send is already running: the previous one is
    /// cancelled first.
    func send(_ tab: RequestTab) {
        tab.sendTask?.cancel()
        tab.clearResponse()
        tab.isSending = true

        let request = tab.draft
        let resolver = resolver(for: tab)
        let auth = effectiveAuth(for: tab).auth
        let collectionName = tab.collectionID
            .flatMap { workspace.collection(withID: $0) }?.name
        // Captured before the send so the recording reflects the settings in force when the user
        // pressed Send, not whatever they happen to be when the response lands.
        let recording = Recording(
            level: recordLevel(forCollection: tab.collectionID),
            secrets: secretValues(for: tab)
                .union(Self.credentials(in: auth, resolver: resolver)),
            bodyCap: settings.historyBodyCapBytes)

        tab.sendTask = Task { [weak self, weak tab] in
            guard let self, let tab else { return }
            let started = Date()
            do {
                let built = try self.builtRequest(request, resolver: resolver, auth: auth)
                tab.warnings = built.warnings
                let response = try await self.executor.send(built, settings: request.settings)
                guard !Task.isCancelled else {
                    response.body.discardTemporaryFile()
                    return
                }
                tab.response = response
                tab.isSending = false
                await self.record(
                    request: request, resolvedURL: built.resolvedURL, built: built,
                    response: response, error: nil, startedAt: started,
                    collectionName: collectionName, recording: recording)
            } catch is CancellationError {
                tab.isSending = false
            } catch {
                guard !Task.isCancelled else { return }
                tab.isSending = false
                tab.errorMessage = Self.message(for: error)
                await self.record(
                    request: request, resolvedURL: request.url, built: nil,
                    response: nil, error: Self.message(for: error), startedAt: started,
                    collectionName: collectionName, recording: recording)
            }
        }
    }

    func cancelSend(_ tab: RequestTab) {
        tab.sendTask?.cancel()
        tab.sendTask = nil
        tab.isSending = false
    }

    /// Building can throw, and it is cheap; keeping it out of the task body makes the error
    /// handling above read in one piece.
    private func builtRequest(
        _ request: RequestItem, resolver: VariableResolver, auth: Auth
    ) throws -> BuiltRequest {
        try RequestBuilder().build(request, resolver: resolver, effectiveAuth: auth)
    }

    static func message(for error: any Error) -> String {
        (error as? any LocalizedError)?.errorDescription ?? error.localizedDescription
    }

    // MARK: - History

    /// The stored copy of the request: redacted always, and below `.full` stripped of its body.
    ///
    /// PLAN.md §6 Phase 8 — the default level keeps what makes an entry findable and re-sendable
    /// without keeping the payload. The body is the part most likely to hold something personal.
    static func snapshot(of request: RequestItem, recording: Recording) -> RequestItem {
        var stored = HistoryRedactor.redact(request: request, secrets: recording.secrets)
        if !recording.level.recordsBodies { stored.body = .none }
        return stored
    }

    /// The credential values a request carries, resolved.
    ///
    /// A token typed straight into the Auth tab is every bit as sensitive as one stored as a
    /// secret variable, and it comes back in the response of any endpoint that echoes headers.
    /// Redacting the header alone would leave it sitting in the recorded body.
    static func credentials(in auth: Auth, resolver: VariableResolver) -> Set<String> {
        let values: [String]
        switch auth {
        case .none, .inherit: values = []
        case .bearer(let token): values = [token]
        case .basic(_, let password): values = [password]
        case .apiKey(_, let value, _): values = [value]
        }
        return Set(values.map { resolver.resolved($0) }.filter { !$0.isEmpty })
    }

    /// What history should keep about one send, decided before the request goes out.
    struct Recording: Sendable {
        var level: HistoryRecordLevel
        var secrets: Set<String>
        var bodyCap: Int
    }

    private func record(
        request: RequestItem,
        resolvedURL: String,
        built: BuiltRequest?,
        response: HTTPResponse?,
        error: String?,
        startedAt: Date,
        collectionName: String?,
        recording: Recording
    ) async {
        guard recording.level != .off else { return }

        var entry = HistoryEntry(
            sentAt: startedAt,
            method: request.method,
            resolvedURL: HistoryRedactor.redact(text: resolvedURL, secrets: recording.secrets),
            statusCode: response?.statusCode,
            durationMs: response?.timing.totalMilliseconds
                ?? Date().timeIntervalSince(startedAt) * 1000,
            responseBytes: response?.byteCount ?? 0,
            requestSnapshot: Self.snapshot(of: request, recording: recording),
            error: error,
            collectionName: collectionName,
            source: .app,
            recordLevel: recording.level)

        if recording.level.recordsHeaders {
            entry.requestHeaders = built.map {
                HistoryRedactor.redact(headers: $0.allHeaders, secrets: recording.secrets)
            }
            entry.responseHeaders = response.map {
                HistoryRedactor.redact(headers: $0.headers, secrets: recording.secrets)
            }
        }
        if recording.level.recordsBodies {
            entry.requestBody = await Self.recordedRequestBody(built, recording: recording)
            entry.responseBody = await Self.recordedResponseBody(response, recording: recording)
        }

        await appendHistory(entry)
    }

    /// Reads the bodies off the main thread — a `.full` recording of a 20 MB response must not
    /// stall the window that is busy rendering it.
    @concurrent
    private static func recordedRequestBody(
        _ built: BuiltRequest?, recording: Recording
    ) async -> RecordedBody? {
        guard let built else { return nil }
        let data: Data?
        switch built.payload {
        case .data(let bytes): data = bytes
        case .file(let url): data = try? Data(contentsOf: url, options: [.mappedIfSafe])
        case .none: data = nil
        }
        guard let data, !data.isEmpty else { return nil }
        let body = RecordedBody.capped(
            data, cap: recording.bodyCap,
            mimeType: built.allHeaders.value(for: "Content-Type"))
        return HistoryRedactor.redact(body: body, secrets: recording.secrets)
    }

    @concurrent
    private static func recordedResponseBody(
        _ response: HTTPResponse?, recording: Recording
    ) async -> RecordedBody? {
        guard let response else { return nil }
        // Only the capped prefix is read, so a huge response costs the cap and not its size.
        guard let data = try? response.body.prefix(recording.bodyCap), !data.isEmpty else {
            return nil
        }
        let body = RecordedBody(
            data: data,
            truncated: response.byteCount > data.count,
            originalBytes: response.byteCount,
            mimeType: response.mimeType)
        return HistoryRedactor.redact(body: body, secrets: recording.secrets)
    }
}

extension AppState {
    /// The headers Postfrau would add to this request if it were sent right now.
    ///
    /// Built by running the real `RequestBuilder`, so the Headers tab can never drift from what
    /// actually goes on the wire. A request that cannot be built yet (no URL) simply has none.
    func automaticHeaders(for tab: RequestTab) -> [HeaderField] {
        let built = try? RequestBuilder().build(
            tab.draft, resolver: resolver(for: tab), effectiveAuth: effectiveAuth(for: tab).auth)
        return built?.automaticHeaders ?? []
    }

    /// Everything that would go wrong with this request, for the Send button's tooltip.
    func warnings(for tab: RequestTab) -> [String] {
        let built = try? RequestBuilder().build(
            tab.draft, resolver: resolver(for: tab), effectiveAuth: effectiveAuth(for: tab).auth)
        return built?.warnings ?? []
    }
}

extension AppState {
    /// What a response body actually is, header and bytes both considered.
    ///
    /// Cached per response so switching tabs does not re-sniff a 50 MB body.
    func contentKind(for response: HTTPResponse) -> ContentKind {
        let key = "\(response.finalURL)|\(response.byteCount)|\(response.mimeType ?? "")"
        if let cached = contentKindCache[key] { return cached }
        let head = (try? response.body.prefix(1024)) ?? Data()
        let kind = ContentTypeSniffer.kind(mimeType: response.mimeType, bytes: head)
        contentKindCache[key] = kind
        return kind
    }

    /// Reads a response body off the main actor, for copy and save.
    func readBody(_ response: HTTPResponse) async -> Data? {
        await Self.read(response.body)
    }

    @concurrent
    private static func read(_ body: ResponseBody) async -> Data? {
        try? body.data()
    }

    /// A sensible filename for "Save Body…", derived from the URL and the content type.
    func suggestedFilename(for response: HTTPResponse) -> String {
        let components = URLComponents(string: response.finalURL)
        let lastPath = components?.path
            .split(separator: "/").last.map(String.init) ?? "response"
        let base = lastPath.isEmpty ? "response" : lastPath
        if base.contains(".") { return base }

        let ext = switch contentKind(for: response) {
        case .json: "json"
        case .xml: "xml"
        case .html: "html"
        case .text: "txt"
        case .pdf: "pdf"
        case .image(let subtype): subtype == "jpeg" ? "jpg" : subtype
        case .binary: "bin"
        }
        return "\(base).\(ext)"
    }
}

extension AppState {
    /// The variable scope a collection's own settings see: the active environment, the
    /// collection's variables, then globals. No folder chain, because there is no request.
    func resolver(for collectionID: UUID) -> VariableResolver {
        VariableResolver(scope: VariableScope.build(
            environment: workspace.activeEnvironment,
            collection: workspace.collection(withID: collectionID),
            folderChain: [],
            globals: workspace.globals))
    }
}

extension AppState {
    /// Unresolved `{{variable}}` names, per section of the request editor.
    ///
    /// The URL bar colours its own tokens; the key/value tables and the body editor would be slow
    /// to colour per character, so §5's fallback applies — a count on the section's tab, with the
    /// names in the Send button's tooltip.
    struct UnresolvedCounts {
        var url = 0
        var params = 0
        var headers = 0
        var body = 0

        var total: Int { url + params + headers + body }
    }

    func unresolvedCounts(for tab: RequestTab) -> UnresolvedCounts {
        let resolver = resolver(for: tab)
        var counts = UnresolvedCounts()
        var seen: Set<String> = []

        func count(_ text: String) -> Int {
            var found = 0
            for name in resolver.resolve(text).unresolved where seen.insert(name).inserted {
                found += 1
            }
            return found
        }

        counts.url = count(tab.draft.url)
        for row in tab.draft.params.active { counts.params += count(row.key) + count(row.value) }
        for row in tab.draft.headers.active { counts.headers += count(row.key) + count(row.value) }
        switch tab.draft.body {
        case .raw(let text, _):
            counts.body = count(text)
        case .urlEncoded(let rows):
            for row in rows.active { counts.body += count(row.key) + count(row.value) }
        case .formData(let fields):
            for field in fields where field.enabled {
                counts.body += count(field.key)
                if case .text(let value) = field.value { counts.body += count(value) }
            }
        case .none, .binary:
            break
        }
        return counts
    }
}
