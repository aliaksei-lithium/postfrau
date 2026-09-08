import Foundation
import PostfrauCore

extension AppState {
    /// Which half of the sidebar is showing.
    enum SidebarSection: String, CaseIterable, Identifiable {
        case collections, history
        var id: String { rawValue }
        var title: String { self == .collections ? "Collections" : "History" }
    }

    /// Which sends the sidebar shows.
    enum HistorySourceFilter: String, CaseIterable, Identifiable {
        case all, app, automated

        var id: String { rawValue }

        var displayName: String {
            switch self {
            case .all: "All sends"
            case .app: "From the app"
            case .automated: "Agents only"
            }
        }

        func matches(_ entry: HistoryEntry) -> Bool {
            switch self {
            case .all: true
            case .app: !entry.source.isAutomated
            case .automated: entry.source.isAutomated
            }
        }
    }

    // MARK: - Loading

    /// Reads history at launch, migrating the pre-Phase-8 `history.jsonl` the first time.
    func loadHistory() async {
        let legacy = await store.localStateRoot
            .appending(path: "history.jsonl", directoryHint: .notDirectory)
        await history.migrateLegacyLog(at: legacy)
        historyEntries = await history.load(limit: settings.maxHistoryEntries)
        lastKnownHistoryCount = await history.count()
        reattachRecordedTabs()
    }

    /// Gives restored history tabs their recording back.
    ///
    /// The exchange is not written into the UI state — it is already in the history log, and
    /// duplicating a capped body into `ui-state.json` on every quit would be wasteful. Instead the
    /// tab remembers which entry it was showing and looks it up once history has been read.
    func reattachRecordedTabs() {
        let byID = Dictionary(historyEntries.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for tab in tabs {
            guard let id = tab.restoredHistoryEntryID, let entry = byID[id] else { continue }
            tab.restoredHistoryEntryID = nil
            guard entry.hasRecordedExchange else { continue }
            tab.recordedEntry = entry
            tab.response = Self.recordedResponse(for: entry)
            tab.selectedResponseTab = entry.responseBody == nil ? .headers : .pretty
        }
    }

    /// Re-reads history if something else has written to it.
    ///
    /// The `postfrau` CLI writes into the same folder, so an agent's sends land while the app is
    /// sitting there. Checked when the app becomes active — coming back from the terminal is
    /// exactly when the sidebar would otherwise be stale — and only re-read when the count has
    /// actually moved, since a directory listing is far cheaper than decoding every entry.
    func refreshHistoryIfChanged() async {
        let onDisk = await history.count()
        guard onDisk != lastKnownHistoryCount else { return }
        lastKnownHistoryCount = onDisk
        historyEntries = await history.load(limit: settings.maxHistoryEntries)
        reattachRecordedTabs()
    }

    // MARK: - Recording

    /// The recording level in force for a request: the collection's override, else the app setting.
    func recordLevel(forCollection id: UUID?) -> HistoryRecordLevel {
        id.flatMap { workspace.collection(withID: $0)?.historyRecording } ?? settings.historyRecording
    }

    /// Every resolved secret value in scope, so redaction can catch a token wherever it landed —
    /// in a header the user typed by hand, in a query string, in a body.
    func secretValues(for tab: RequestTab) -> Set<String> {
        Set(scope(for: tab).allVariables()
            .filter(\.isSecret)
            .map(\.value)
            .filter { !$0.isEmpty })
    }

    /// Adds an entry to the log and to the sidebar. `.off` entries are dropped by the store.
    func appendHistory(_ entry: HistoryEntry) async {
        guard entry.recordLevel != .off else { return }
        try? await history.append(entry)
        lastKnownHistoryCount += 1
        historyEntries.insert(entry, at: 0)
        if historyEntries.count > settings.maxHistoryEntries {
            historyEntries.removeLast(historyEntries.count - settings.maxHistoryEntries)
        }
    }

    // MARK: - Removing

    func deleteHistoryEntry(_ entry: HistoryEntry) {
        historyEntries.removeAll { $0.id == entry.id }
        lastKnownHistoryCount = max(0, lastKnownHistoryCount - 1)
        enqueueHistoryWork { await $0.delete(id: entry.id) }
    }

    func clearHistory() {
        historyEntries = []
        lastKnownHistoryCount = 0
        enqueueHistoryWork { await $0.clear() }
    }

    /// Runs a store mutation in the background, chained after any earlier one.
    ///
    /// Chained rather than fired off independently so two removals cannot race, and tracked so
    /// `flush()` can wait for them: quitting straight after "Delete All" must not leave the files
    /// behind.
    private func enqueueHistoryWork(_ work: @escaping @Sendable (HistoryStore) async -> Void) {
        let previous = pendingHistoryWork
        let store = history
        pendingHistoryWork = Task {
            await previous?.value
            await work(store)
        }
    }

    /// Waits for every queued removal to reach the disk.
    func drainHistoryWork() async {
        await pendingHistoryWork?.value
        pendingHistoryWork = nil
    }

    // MARK: - Reuse

    /// Copies a recorded request into a collection, so a one-off send can become a saved request.
    ///
    /// The snapshot is stored redacted, so a request saved from a `.headers` or `.full` entry
    /// carries `•••` where a credential was. The auth block keeps its shape, which is the useful
    /// part: the user re-enters the token once and the request works.
    @discardableResult
    func saveHistoryEntryToCollection(_ entry: HistoryEntry, collectionID: UUID) -> UUID? {
        var request = entry.requestSnapshot
        request.id = UUID()
        if request.name.trimmingCharacters(in: .whitespaces).isEmpty {
            request.name = entry.displayPath
        }
        guard mutate(collectionID, actionName: "Save to Collection", { collection in
            collection.insert(.request(request), into: nil)
        }) else { return nil }
        expandedIDs.insert(collectionID)
        openRequest(id: request.id)
        return request.id
    }
}
