import Foundation
import Testing
@testable import Postfrau
import PostfrauCore

/// What one SwiftUI body evaluation costs.
///
/// Switching between Params and Headers, or Pretty and Raw, re-evaluates the editor's body. Every
/// derived value read in that body is recomputed, so anything expensive there is felt as lag on a
/// click that should be instant.
@MainActor
@Suite("Render cost", .serialized)
struct RenderCostTests {
    private func makeState() -> (AppState, URL) {
        let root = URL.temporaryDirectory.appending(path: "cost-\(UUID().uuidString)")
        let folder = DataFolder(root: root.appending(path: "Data"), needsCoordination: false)
        return (AppState(
            store: WorkspaceStore(dataFolder: folder, localRoot: root),
            history: HistoryStore(root: root.appending(path: "history"))), root)
    }

    /// A request of the size people actually work with: a JSON body of a few hundred lines,
    /// a dozen headers, and variables that have to be resolved.
    private func realisticTab(_ state: AppState) -> RequestTab {
        var collection = RequestCollection(name: "API")
        collection.variables = [
            Variable(key: "baseUrl", value: "https://api.example.com"),
            Variable(key: "token", value: "abcdef123456"),
        ]
        var request = RequestItem(
            name: "Create", method: .post, url: "{{baseUrl}}/v1/things?trace={{token}}")
        request.headers = (0..<12).map {
            KeyValue(key: "X-Header-\($0)", value: "value-\($0) {{token}}")
        }
        request.params = (0..<8).map { KeyValue(key: "p\($0)", value: "{{token}}") }
        let row = #"{"id":"00000000-0000-0000-0000-000000000000","name":"{{token}}","n":1},"#
        request.body = .raw(
            text: "[\n" + String(repeating: row + "\n", count: 300) + "]", language: .json)
        request.auth = .bearer(token: "{{token}}")

        collection.items = [.request(request)]
        state.workspace.collections = [collection]

        let tab = RequestTab(
            requestID: request.id, collectionID: collection.id, draft: request)
        state.tabs = [tab]
        state.selectedTabID = tab.id
        return tab
    }

    private func measure(_ name: String, _ body: () -> Void) -> Duration {
        body()  // warm
        let started = ContinuousClock.now
        for _ in 0..<10 { body() }
        let each = started.duration(to: .now) / 10
        print("  \(name): \(each)")
        return each
    }

    /// The budget for one body evaluation. A click has ~16 ms before it stops feeling instant,
    /// and the whole body has to fit in that — not one value read inside it.
    static let budget = Duration.milliseconds(2)

    @Test func theSegmentedControlsBadgeCountsAreCheap() {
        let (state, scratch) = makeState()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let tab = realisticTab(state)

        let cost = measure("unresolvedCounts") { _ = state.unresolvedCounts(for: tab) }
        #expect(cost < Self.budget, "unresolvedCounts costs \(cost) per render")
    }

    @Test func theSendButtonsTooltipIsCheap() {
        let (state, scratch) = makeState()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let tab = realisticTab(state)

        let cost = measure("warnings") { _ = state.warnings(for: tab) }
        #expect(cost < Self.budget, "warnings(for:) costs \(cost) per render")
    }

    @Test func theHeadersTabsComputedListIsCheap() {
        let (state, scratch) = makeState()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let tab = realisticTab(state)

        let cost = measure("automaticHeaders") { _ = state.automaticHeaders(for: tab) }
        #expect(cost < Self.budget, "automaticHeaders(for:) costs \(cost) per render")
    }

    // MARK: - The cache has to be right, not just fast

    @Test func editingTheDraftIsSeenImmediately() {
        let (state, scratch) = makeState()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let tab = realisticTab(state)

        #expect(state.unresolvedCounts(for: tab).url == 0, "{{baseUrl}} and {{token}} resolve")

        tab.draft.url = "{{baseUrl}}/v1/{{nothingDefinesThis}}"
        #expect(state.unresolvedCounts(for: tab).url == 1, "a new variable is noticed at once")

        tab.draft.headers.append(KeyValue(key: "X-New", value: "{{alsoUndefined}}"))
        #expect(state.unresolvedCounts(for: tab).headers == 1,
                "appending through a binding-style mutation invalidates too")
    }

    @Test func changingTheEnvironmentIsSeenImmediately() {
        let (state, scratch) = makeState()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let tab = realisticTab(state)
        tab.draft.url = "{{baseUrl}}/{{fromEnvironment}}"
        #expect(state.unresolvedCounts(for: tab).url == 1)

        var environment = RequestEnvironment(name: "Staging")
        environment.variables = [Variable(key: "fromEnvironment", value: "x")]
        state.workspace.environments = [environment]
        state.workspace.activeEnvironmentID = environment.id
        state.markDirty(environment: environment.id)

        #expect(state.unresolvedCounts(for: tab).url == 0,
                "the variable now resolves, without touching the draft")
    }

    @Test func theComputedHeaderListFollowsTheDraft() {
        let (state, scratch) = makeState()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let tab = realisticTab(state)

        #expect(state.automaticHeaders(for: tab).contains { $0.name == "Authorization" })
        tab.draft.auth = Auth.none
        #expect(!state.automaticHeaders(for: tab).contains { $0.name == "Authorization" },
                "dropping the auth drops the header it would have added")
    }

    @Test func renderingAMultipartRequestLeavesNoTemporaryFiles() throws {
        // `build` streams a multipart body to a temporary file. Rendering must not litter.
        let (state, scratch) = makeState()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let tab = realisticTab(state)
        tab.draft.body = .formData([
            FormField(key: "caption", value: .text("hello")),
            FormField(key: "other", value: .text("world")),
        ])

        let temporaries = { try? FileManager.default
            .contentsOfDirectory(atPath: FileManager.default.temporaryDirectory.path)
            .filter { $0.hasPrefix("postfrau-upload-") }.count }
        let before = temporaries() ?? 0
        for _ in 0..<20 {
            tab.draft.name = "render \(UUID().uuidString)"  // force a fresh derivation each time
            _ = state.warnings(for: tab)
        }
        #expect((temporaries() ?? 0) == before, "twenty renders left temporary files behind")
    }

    @Test func awholeEditorBodyEvaluationIsCheap() {
        let (state, scratch) = makeState()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let tab = realisticTab(state)

        // What RequestEditor + URLBar + HeadersTab read between them.
        let cost = measure("one body evaluation") {
            _ = state.unresolvedCounts(for: tab)
            _ = state.warnings(for: tab)
            _ = state.automaticHeaders(for: tab)
        }
        #expect(cost < Self.budget, "one body evaluation costs \(cost)")
    }
}
