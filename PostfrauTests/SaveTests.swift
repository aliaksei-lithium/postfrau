import Foundation
import Testing
import PostfrauCore
@testable import Postfrau

/// ⌘S on a request that has no collection yet.
@Suite("Saving a request with no collection")
@MainActor
struct SaveTests {
    private func makeState() -> (AppState, URL) {
        let root = URL.temporaryDirectory.appending(path: "save-tests-\(UUID().uuidString)")
        let state = AppState(
            store: WorkspaceStore(
                dataFolder: DataFolder(root: root, needsCoordination: false), localRoot: root),
            history: HistoryStore(root: root.appending(path: "history")),
            secretsStore: SecretsStore(service: "com.postfrau.tests.\(UUID().uuidString)"))
        return (state, root)
    }

    @Test("A new request is saved into Drafts, which is created once and then reused")
    func newRequestGoesToDrafts() throws {
        let (state, root) = makeState()
        defer { try? FileManager.default.removeItem(at: root) }

        let first = state.newTab()
        first.urlEdited(to: "https://api.test/users")
        #expect(state.saveTab(first))

        let drafts = try #require(
            state.workspace.collections.first { $0.name == AppState.draftsCollectionName })
        let requestID = try #require(first.requestID)
        #expect(first.collectionID == drafts.id)
        #expect(drafts.request(withID: requestID)?.url == "https://api.test/users")
        #expect(drafts.request(withID: requestID)?.name == "api.test/users",
                "an unnamed request is named after its URL")
        #expect(!first.isDirty)
        #expect(state.expandedIDs.contains(drafts.id), "it should be visible in the sidebar")

        // A second one joins the first rather than starting another collection.
        let second = state.newTab()
        #expect(state.saveTab(second))
        #expect(state.workspace.collections.filter {
            $0.name == AppState.draftsCollectionName
        }.count == 1)
        #expect(state.workspace.collection(withID: drafts.id)?.requestCount == 2)

        // From now on the tab saves in place, like any other saved request.
        first.urlEdited(to: "https://api.test/users/1")
        #expect(state.saveTab(first))
        #expect(state.workspace.collection(withID: drafts.id)?.request(withID: requestID)?.url
                == "https://api.test/users/1")
        #expect(state.workspace.collection(withID: drafts.id)?.requestCount == 2)
    }
}
