import Foundation
import Testing
@testable import Postfrau
import PostfrauCore

/// PLAN.md §6 Phase 8 acceptance: "switching to **full** records a body and the file on disk has
/// the bearer token replaced by •••".
///
/// Driven through the real `AppState.send` against a local in-process listener, so what is asserted
/// is what the app actually writes — not what a mock says it would.
@MainActor
@Suite("History recording")
struct HistoryRecordingTests {
    /// An `AppState` on a throwaway folder, with history at the given level and every request
    /// answered by `EchoURLProtocol`.
    /// The returned folder is the test's to remove; these live inside the app's own container,
    /// where a leftover folder would outlive the run.
    private func makeState(level: HistoryRecordLevel) -> (AppState, URL) {
        EchoURLProtocol.reset()
        let root = URL.temporaryDirectory.appending(path: "history-\(UUID().uuidString)")
        let state = AppState(
            store: WorkspaceStore(
                dataFolder: DataFolder(root: root, needsCoordination: false), localRoot: root),
            history: HistoryStore(root: root.appending(path: "history")),
            executor: HTTPExecutor(protocolClasses: [EchoURLProtocol.self]))
        state.settings.historyRecording = level
        return (state, root)
    }

    private let baseURL = "https://echo.test"

    /// Every history file's raw text, so assertions can look at the bytes on disk.
    private func filesOnDisk(under root: URL) throws -> [String] {
        let history = root.appending(path: "history")
        let days = (try? FileManager.default.contentsOfDirectory(atPath: history.path)) ?? []
        return try days.flatMap { day -> [String] in
            let folder = history.appending(path: day)
            return try ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [])
                .filter { $0.hasSuffix(".json") }
                .map { try String(contentsOf: folder.appending(path: $0), encoding: .utf8) }
        }
    }

    private func send(_ state: AppState, _ request: RequestItem) async {
        let tab = RequestTab(draft: request)
        state.tabs = [tab]
        state.send(tab)
        await tab.sendTask?.value
        // The recording is appended from inside the send task, which has already finished.
        #expect(tab.errorMessage == nil, "send failed: \(tab.errorMessage ?? "")")
    }

    @Test func fullRecordingKeepsTheBodyButNotTheBearerToken() async throws {
        let (state, scratch) = makeState(level: .full)
        defer { try? FileManager.default.removeItem(at: scratch) }

        await send(state, RequestItem(
            name: "Create user",
            method: .post,
            url: "\(baseURL)/users",
            auth: .bearer(token: "super-secret-token-123"),
            body: .raw(text: #"{"name":"Ada"}"#, language: .json)))

        let files = try filesOnDisk(under: scratch)
        #expect(files.count == 1)
        let text = try #require(files.first)

        #expect(!text.contains("super-secret-token-123"), "the token must not reach the disk")
        #expect(text.contains(HistoryRedactor.placeholder), "it is replaced, not merely dropped")

        let entry = try #require(state.historyEntries.first)
        #expect(entry.recordLevel == .full)
        #expect(entry.source == .app)
        #expect(entry.statusCode == 200)
        // The endpoint echoes the headers it received, real token and all; what is *stored* is
        // the redacted copy. This is the case a header-only redaction would miss.
        let responseBody = try #require(entry.responseBody)
        #expect(responseBody.text.contains("POST"))
        #expect(!responseBody.text.contains("super-secret-token-123"))
        #expect(try #require(entry.requestBody).text.contains("Ada"))
        #expect(entry.requestHeaders?.first { $0.name.lowercased() == "authorization" }?.value
            == HistoryRedactor.placeholder)
    }

    @Test func metadataRecordingKeepsNoHeadersOrBodies() async throws {
        let (state, scratch) = makeState(level: .metadata)
        defer { try? FileManager.default.removeItem(at: scratch) }

        await send(state, RequestItem(
            method: .get, url: "\(baseURL)/health",
            auth: .bearer(token: "super-secret-token-123")))

        let entry = try #require(state.historyEntries.first)
        #expect(!entry.hasRecordedExchange)
        #expect(entry.statusCode == 200)
        #expect(entry.requestSnapshot.auth == .bearer(token: HistoryRedactor.placeholder))
        let text = try #require(try filesOnDisk(under: scratch).first)
        #expect(!text.contains("super-secret-token-123"))
    }

    @Test func offRecordsNothingAtAll() async throws {
        let (state, scratch) = makeState(level: .off)
        defer { try? FileManager.default.removeItem(at: scratch) }

        await send(state, RequestItem(method: .get, url: "\(baseURL)/health"))

        #expect(state.historyEntries.isEmpty)
        #expect(try filesOnDisk(under: scratch).isEmpty)
        #expect(await state.history.count() == 0)
    }

    @Test func aCollectionCanOverrideTheAppLevel() async throws {
        let (state, scratch) = makeState(level: .full)
        defer { try? FileManager.default.removeItem(at: scratch) }
        var collection = RequestCollection(name: "Payments")
        collection.historyRecording = .off
        state.workspace.collections = [collection]

        #expect(state.recordLevel(forCollection: collection.id) == .off)
        #expect(state.recordLevel(forCollection: nil) == .full)

        state.workspace.collections[0].historyRecording = nil
        #expect(state.recordLevel(forCollection: collection.id) == .full, "nil inherits")
    }

    @Test func aFailedSendIsRecordedWithItsError() async throws {
        let (state, scratch) = makeState(level: .metadata)
        defer { try? FileManager.default.removeItem(at: scratch) }
        // The transport fails; history must record the attempt and its error.
        await withKnownIssue("the send is expected to fail") {
            let tab = RequestTab(draft: RequestItem(method: .get, url: "\(baseURL)\(EchoURLProtocol.failingPathMarker)"))
            state.tabs = [tab]
            state.send(tab)
            await tab.sendTask?.value
            #expect(tab.errorMessage == nil)
        }

        let entry = try #require(state.historyEntries.first)
        #expect(entry.statusCode == nil)
        #expect(entry.error?.isEmpty == false)
    }

    @Test func openingARecordedEntryShowsItReadOnly() async throws {
        let (state, scratch) = makeState(level: .full)
        defer { try? FileManager.default.removeItem(at: scratch) }

        await send(state, RequestItem(method: .get, url: "\(baseURL)/users"))
        let entry = try #require(state.historyEntries.first)

        let tab = state.openHistoryEntry(entry)
        #expect(tab.isFromHistory)
        #expect(tab.recordedEntry?.id == entry.id)
        #expect(tab.title.hasPrefix("History · GET"))
        let response = try #require(tab.response)
        #expect(response.statusCode == 200)
        #expect(try response.body.data().count > 0)
        #expect(!response.headers.isEmpty)

        #expect(state.openHistoryEntry(entry) === tab, "opening it again reuses the tab")
        #expect(state.tabs.count { $0.isFromHistory } == 1)

        // Re-sending the tab replaces the recording with a live response; the banner must go.
        state.send(tab)
        await tab.sendTask?.value
        #expect(tab.recordedEntry == nil)
        #expect(tab.response != nil)
    }

    @Test func aRestoredHistoryTabGetsItsRecordingBack() async throws {
        let (state, scratch) = makeState(level: .full)
        defer { try? FileManager.default.removeItem(at: scratch) }

        await send(state, RequestItem(method: .get, url: "\(baseURL)/users"))
        let entry = try #require(state.historyEntries.first)
        let tab = state.openHistoryEntry(entry)

        // What a quit writes, and what the next launch reads back.
        let stored = tab.snapshot()
        #expect(stored.historyEntryID == entry.id)

        let restored = RequestTab(restoring: stored)
        #expect(restored.recordedEntry == nil, "the recording is not carried in the UI state")
        state.tabs = [restored]
        await state.loadHistory()

        // Compared by id: the copy read back from disk has its timestamp rounded to the
        // millisecond the ISO-8601 coder writes, so the values are not byte-identical.
        #expect(restored.recordedEntry?.id == entry.id)
        #expect(restored.recordedEntry?.responseBody?.text == entry.responseBody?.text)
        #expect(restored.response?.statusCode == 200)
        #expect(restored.restoredHistoryEntryID == nil, "the lookup happens once")
    }

    @Test func savingAHistoryEntryToACollectionMakesARealRequest() async throws {
        let (state, scratch) = makeState(level: .metadata)
        defer { try? FileManager.default.removeItem(at: scratch) }
        state.workspace.collections = [RequestCollection(name: "Saved")]
        let collectionID = state.workspace.collections[0].id

        await send(state, RequestItem(name: "", method: .get, url: "\(baseURL)/users"))
        let entry = try #require(state.historyEntries.first)

        let newID = try #require(state.saveHistoryEntryToCollection(entry, collectionID: collectionID))
        let saved = try #require(state.workspace.collection(withID: collectionID)?.request(withID: newID))
        #expect(saved.url == "\(baseURL)/users")
        #expect(!saved.name.isEmpty, "an unnamed send is named after its path")
    }

    @Test func deletingAndClearingReachTheDisk() async throws {
        let (state, scratch) = makeState(level: .metadata)
        defer { try? FileManager.default.removeItem(at: scratch) }

        await send(state, RequestItem(method: .get, url: "\(baseURL)/a"))
        await send(state, RequestItem(method: .get, url: "\(baseURL)/b"))
        #expect(try filesOnDisk(under: scratch).count == 2)

        let doomed = try #require(state.historyEntries.first)
        state.deleteHistoryEntry(doomed)
        #expect(state.historyEntries.count == 1)
        // The removal is queued in the background; wait for it to reach the disk.
        await state.drainHistoryWork()
        #expect(try filesOnDisk(under: scratch).count == 1)

        state.clearHistory()
        await state.drainHistoryWork()
        #expect(state.historyEntries.isEmpty)
        #expect(try filesOnDisk(under: scratch).isEmpty)
    }

    @Test func theSidebarFiltersByTextAndBySource() {
        let (state, scratch) = makeState(level: .metadata)
        defer { try? FileManager.default.removeItem(at: scratch) }
        state.historyEntries = [
            HistoryEntry(sentAt: Date(), method: .get, resolvedURL: "https://a.test/users",
                         statusCode: 200, source: .app),
            HistoryEntry(sentAt: Date(), method: .post, resolvedURL: "https://a.test/orders",
                         statusCode: 201, source: .agent(name: "claude")),
            HistoryEntry(sentAt: Date(), method: .get, resolvedURL: "https://a.test/health",
                         statusCode: 200, source: .cli),
        ]

        #expect(state.groupedHistory.flatMap(\.entries).count == 3)

        state.historySourceFilter = .automated
        #expect(state.groupedHistory.flatMap(\.entries).count == 2)

        state.historySourceFilter = .app
        #expect(state.groupedHistory.flatMap(\.entries).map(\.resolvedURL) == ["https://a.test/users"])

        state.historySourceFilter = .all
        state.sidebarFilter = "orders"
        #expect(state.groupedHistory.flatMap(\.entries).count == 1)

        state.sidebarFilter = "claude"
        #expect(state.groupedHistory.flatMap(\.entries).count == 1, "the source name is searchable")
    }
}
