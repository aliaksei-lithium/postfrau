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
            secrets: HistoryRecorder.secrets(
                in: scope(for: tab), auth: auth, resolver: resolver),
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

    /// The sentence to show a user for an error. `nonisolated` because parsing and importing
    /// happen off the main actor and still need to name what went wrong.
    nonisolated static func message(for error: any Error) -> String {
        (error as? any LocalizedError)?.errorDescription ?? error.localizedDescription
    }

    // MARK: - History

    /// What history should keep about one send, decided before the request goes out.
    struct Recording: Sendable {
        var level: HistoryRecordLevel
        var secrets: Set<String>
        var bodyCap: Int
    }

    /// Hands the exchange to `HistoryRecorder`, which the CLI uses too.
    ///
    /// The app and `postfrau` record the same way on purpose: two copies of the redaction rules
    /// would be two places to fix a leak, and only one of them would get fixed.
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
        let entry = await HistoryRecorder.entry(
            for: HistoryRecorder.Exchange(
                request: request,
                resolvedURL: resolvedURL,
                built: built,
                response: response,
                error: error,
                startedAt: startedAt,
                collectionName: collectionName),
            policy: HistoryRecorder.Policy(
                level: recording.level,
                secrets: recording.secrets,
                bodyCap: recording.bodyCap,
                source: .app))

        guard let entry else { return }
        await appendHistory(entry)
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
