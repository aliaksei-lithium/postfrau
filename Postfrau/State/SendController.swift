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
                    request: request, resolvedURL: built.resolvedURL, response: response,
                    error: nil, startedAt: started, collectionName: collectionName)
            } catch is CancellationError {
                tab.isSending = false
            } catch {
                guard !Task.isCancelled else { return }
                tab.isSending = false
                tab.errorMessage = Self.message(for: error)
                await self.record(
                    request: request, resolvedURL: request.url, response: nil,
                    error: Self.message(for: error), startedAt: started,
                    collectionName: collectionName)
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

    private func record(
        request: RequestItem,
        resolvedURL: String,
        response: HTTPResponse?,
        error: String?,
        startedAt: Date,
        collectionName: String?
    ) async {
        let entry = HistoryEntry(
            sentAt: startedAt,
            method: request.method,
            resolvedURL: resolvedURL,
            statusCode: response?.statusCode,
            durationMs: response?.timing.totalMilliseconds
                ?? Date().timeIntervalSince(startedAt) * 1000,
            responseBytes: response?.byteCount ?? 0,
            requestSnapshot: request,
            error: error,
            collectionName: collectionName)

        try? await historyLog.append(entry)
        historyEntries.insert(entry, at: 0)
        if historyEntries.count > settings.maxHistoryEntries {
            historyEntries.removeLast(historyEntries.count - settings.maxHistoryEntries)
        }
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
