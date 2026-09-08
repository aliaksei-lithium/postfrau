import Foundation
import Testing
@testable import Postfrau
import PostfrauCore

/// Phase 9 as the user meets it: another process changes the data folder, and Postfrau either
/// adopts the change or protects unsaved work from it.
@MainActor
@Suite("Data folder sync")
struct AppSyncTests {
    private func makeState() throws -> (AppState, URL) {
        let root = URL.temporaryDirectory.appending(path: "sync-\(UUID().uuidString)")
        let folder = DataFolder(root: root.appending(path: "Data"), needsCoordination: false)
        try folder.prepare()
        let state = AppState(
            store: WorkspaceStore(dataFolder: folder, localRoot: root),
            history: HistoryStore(root: root.appending(path: "history")))
        state.dataFolder = folder
        return (state, root)
    }

    /// Writes a collection the way another Mac's Postfrau would: a whole file, no fingerprint.
    private func writeExternally(_ collection: RequestCollection, in state: AppState) async throws {
        let folder = await state.store.folder
        let data = try Postfrau.makeEncoder().encode(collection)
        try data.write(to: folder.collectionFile(collection.id))
    }

    private func saveLocally(_ collection: RequestCollection, in state: AppState) async throws
        -> RequestCollection
    {
        let stored = try await state.store.save(collection: collection)
        state.workspace.collections = [stored]
        return stored
    }

    @Test func adoptsAForeignEditWhenNothingIsUnsaved() async throws {
        let (state, scratch) = try makeState()
        defer { try? FileManager.default.removeItem(at: scratch) }

        var mine = try await saveLocally(RequestCollection(name: "Acme API"), in: state)
        mine.name = "Acme API (renamed elsewhere)"
        mine.revision += 1
        try await writeExternally(mine, in: state)

        await state.absorbFolderChanges()

        #expect(state.workspace.collections.map(\.name) == ["Acme API (renamed elsewhere)"])
        #expect(state.syncConflicts.isEmpty, "nothing was unsaved, so nothing to ask about")
        #expect(state.lastExternalChange != nil)
    }

    @Test func aForeignAdditionAppears() async throws {
        let (state, scratch) = try makeState()
        defer { try? FileManager.default.removeItem(at: scratch) }

        try await writeExternally(RequestCollection(name: "From Another Mac"), in: state)
        await state.absorbFolderChanges()

        #expect(state.workspace.collections.map(\.name) == ["From Another Mac"])
    }

    @Test func keepsLocalEditsAndParksTheForeignVersion() async throws {
        let (state, scratch) = try makeState()
        defer { try? FileManager.default.removeItem(at: scratch) }

        let mine = try await saveLocally(RequestCollection(name: "Acme API"), in: state)
        // An edit that has not been written yet.
        state.workspace.collections[0].name = "Acme API (mine)"
        state.markDirty(collection: mine.id)

        var theirs = mine
        theirs.name = "Acme API (theirs)"
        theirs.revision += 1
        try await writeExternally(theirs, in: state)

        await state.absorbFolderChanges()

        #expect(state.workspace.collections.map(\.name) == ["Acme API (mine)"],
                "what is on screen is not yanked away mid-edit")
        let conflict = try #require(state.syncConflicts.first)
        #expect(conflict.documentID == mine.id)
        #expect(FileManager.default.fileExists(atPath: conflict.copy.path),
                "the other version is on disk before the banner claims it is")

        let parked = try Postfrau.makeDecoder().decode(
            RequestCollection.self, from: Data(contentsOf: conflict.copy))
        #expect(parked.name == "Acme API (theirs)")
    }

    @Test func aDirtyOpenTabAlsoCountsAsUnsavedWork() async throws {
        let (state, scratch) = try makeState()
        defer { try? FileManager.default.removeItem(at: scratch) }

        let mine = try await saveLocally(makeCollectionWithOneRequest(), in: state)
        let requestID = try #require(firstRequestID(in: mine))
        let tab = RequestTab(requestID: requestID, collectionID: mine.id, draft: RequestItem())
        tab.draft.url = "https://edited.example"   // dirty: differs from the saved snapshot
        state.tabs = [tab]

        #expect(state.hasUnsavedEdits(forCollection: mine.id))

        var theirs = mine
        theirs.name = "Theirs"
        theirs.revision += 1
        try await writeExternally(theirs, in: state)
        await state.absorbFolderChanges()

        #expect(state.syncConflicts.count == 1)
        #expect(state.workspace.collections.map(\.name) == [mine.name])
    }

    @Test func takingTheirsReplacesTheLocalVersion() async throws {
        let (state, scratch) = try makeState()
        defer { try? FileManager.default.removeItem(at: scratch) }

        let mine = try await saveLocally(RequestCollection(name: "Acme API"), in: state)
        state.workspace.collections[0].name = "Mine"
        state.markDirty(collection: mine.id)
        var theirs = mine
        theirs.name = "Theirs"
        theirs.revision += 1
        try await writeExternally(theirs, in: state)
        await state.absorbFolderChanges()

        let conflict = try #require(state.syncConflicts.first)
        await state.takeTheirs(conflict)

        #expect(state.workspace.collections.map(\.name) == ["Theirs"])
        #expect(state.syncConflicts.isEmpty)
    }

    @Test func keepingMineQueuesItToBeWrittenBack() async throws {
        let (state, scratch) = try makeState()
        defer { try? FileManager.default.removeItem(at: scratch) }

        let mine = try await saveLocally(RequestCollection(name: "Acme API"), in: state)
        state.workspace.collections[0].name = "Mine"
        state.markDirty(collection: mine.id)
        var theirs = mine
        theirs.name = "Theirs"
        theirs.revision += 1
        try await writeExternally(theirs, in: state)
        await state.absorbFolderChanges()

        state.keepMine(try #require(state.syncConflicts.first))
        #expect(state.workspace.collections.map(\.name) == ["Mine"])
        #expect(state.isDirty(collection: mine.id), "it will be written over theirs")
        #expect(state.syncConflicts.isEmpty)
    }

    @Test func showingBothOpensTheOtherVersionAsItsOwnCollection() async throws {
        let (state, scratch) = try makeState()
        defer { try? FileManager.default.removeItem(at: scratch) }

        let mine = try await saveLocally(RequestCollection(name: "Acme API"), in: state)
        state.workspace.collections[0].name = "Mine"
        state.markDirty(collection: mine.id)
        var theirs = mine
        theirs.name = "Theirs"
        theirs.revision += 1
        try await writeExternally(theirs, in: state)
        await state.absorbFolderChanges()

        state.showBoth(try #require(state.syncConflicts.first))

        #expect(state.workspace.collections.count == 2)
        let copy = try #require(state.workspace.collections.last)
        #expect(copy.name.contains("from another Mac"))
        #expect(copy.id != mine.id, "a fresh id, or it would be written straight back over theirs")
    }

    @Test(.timeLimit(.minutes(1)))
    func aFileRemovedByAnotherProcessBecomesMissingAndCanBeRestored() async throws {
        let (state, scratch) = try makeState()
        defer { try? FileManager.default.removeItem(at: scratch) }

        let mine = try await saveLocally(RequestCollection(name: "Acme API"), in: state)
        let folder = await state.store.folder

        // A second process removes it, exactly as a sync client deleting on another Mac would.
        let process = Process()
        process.executableURL = URL(filePath: "/bin/rm")
        process.arguments = [folder.collectionFile(mine.id).path]
        try process.run()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)

        await state.absorbFolderChanges()

        let missing = try #require(state.missingCollections.first)
        #expect(missing.id == mine.id)
        #expect(state.workspace.collections.count == 1, "it stays visible until the user decides")

        state.restoreMissing(missing)
        #expect(state.missingCollections.isEmpty)
        #expect(state.isDirty(collection: mine.id), "restoring writes it back")
    }

    @Test func acceptingARemovalTakesItOutOfTheSidebar() async throws {
        let (state, scratch) = try makeState()
        defer { try? FileManager.default.removeItem(at: scratch) }

        let mine = try await saveLocally(RequestCollection(name: "Acme API"), in: state)
        let folder = await state.store.folder
        try FileManager.default.removeItem(at: folder.collectionFile(mine.id))
        await state.absorbFolderChanges()

        state.forgetMissing(try #require(state.missingCollections.first))
        #expect(state.workspace.collections.isEmpty)
        #expect(state.missingCollections.isEmpty)
    }

    @Test func ignoresTheConflictVersionsICloudMakesItself() async throws {
        let (state, scratch) = try makeState()
        defer { try? FileManager.default.removeItem(at: scratch) }

        let mine = try await saveLocally(RequestCollection(name: "Acme API"), in: state)
        let folder = await state.store.folder
        // What iCloud parks beside a file when it cannot merge: `<uuid> 2.json`.
        let apples = folder.collectionsDirectory
            .appending(path: "\(mine.id.uuidString) 2.json", directoryHint: .notDirectory)
        try Postfrau.makeEncoder().encode(mine).write(to: apples)

        await state.absorbFolderChanges()

        #expect(state.workspace.collections.count == 1,
                "Postfrau makes its own conflict copies; adopting Apple's would double them")
    }

    @Test func anOpenTabFollowsAForeignEditToItsRequest() async throws {
        let (state, scratch) = try makeState()
        defer { try? FileManager.default.removeItem(at: scratch) }

        let mine = try await saveLocally(makeCollectionWithOneRequest(), in: state)
        let requestID = try #require(firstRequestID(in: mine))
        let saved = try #require(mine.request(withID: requestID))
        let tab = RequestTab(requestID: requestID, collectionID: mine.id, draft: saved)
        state.tabs = [tab]
        #expect(!tab.isDirty)

        var theirs = mine
        theirs.revision += 1
        var edited = saved
        edited.url = "https://changed.example"
        _ = theirs.replace(.request(edited))
        try await writeExternally(theirs, in: state)
        await state.absorbFolderChanges()

        #expect(tab.draft.url == "https://changed.example")
        #expect(!tab.isDirty, "adopting a foreign version does not make the tab look unsaved")
    }

    // MARK: - Helpers

    private func makeCollectionWithOneRequest() -> RequestCollection {
        RequestCollection(
            name: "Acme API",
            items: [.request(RequestItem(name: "List", url: "https://api.example/users"))])
    }

    private func firstRequestID(in collection: RequestCollection) -> UUID? {
        for item in collection.items {
            if case .request(let request) = item { return request.id }
        }
        return nil
    }
}

extension AppSyncTests {
    @Test func aFolderThatVanishesIsReportedRatherThanDiffed() async throws {
        let root = URL.temporaryDirectory.appending(path: "sync-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = DataFolder(root: root.appending(path: "Data"), needsCoordination: false)
        try folder.prepare()
        let state = AppState(
            store: WorkspaceStore(dataFolder: folder, localRoot: root),
            history: HistoryStore(root: root.appending(path: "history")))
        state.dataFolder = folder

        let stored = try await state.store.save(collection: RequestCollection(name: "Acme API"))
        state.workspace.collections = [stored]

        // The volume unmounts, or the folder is thrown away.
        try FileManager.default.removeItem(at: folder.root)
        await state.absorbFolderChanges()

        #expect(state.dataFolder.status == .missing)
        #expect(state.dataFolderProblem != nil)
        #expect(state.missingCollections.isEmpty,
                "one folder going is one event, not a banner per document")
        #expect(state.workspace.collections.count == 1, "nothing is thrown away")

        state.stopWatchingDataFolder()
    }

    @Test func theFolderComingBackClearsTheProblem() async throws {
        let root = URL.temporaryDirectory.appending(path: "sync-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = DataFolder(root: root.appending(path: "Data"), needsCoordination: false)
        try folder.prepare()
        let state = AppState(
            store: WorkspaceStore(dataFolder: folder, localRoot: root),
            history: HistoryStore(root: root.appending(path: "history")))
        state.dataFolder = folder

        try FileManager.default.removeItem(at: folder.root)
        await state.absorbFolderChanges()
        #expect(state.dataFolderProblem != nil)

        try folder.prepare()
        await state.absorbFolderChanges()
        #expect(state.dataFolder.status == .ok)
        #expect(state.dataFolderProblem == nil)

        state.stopWatchingDataFolder()
    }
}
