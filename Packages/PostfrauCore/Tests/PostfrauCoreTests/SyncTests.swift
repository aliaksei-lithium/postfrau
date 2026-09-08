import Foundation
import Testing
@testable import PostfrauCore

@Suite("Folder diff")
struct FolderDiffTests {
    /// A prepared data folder rooted at a temporary directory the caller owns.
    private func makeFolder(at root: URL) throws -> DataFolder {
        let folder = DataFolder(root: root, needsCoordination: false)
        try folder.prepare()
        return folder
    }

    private func write(_ text: String, to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    @Test func scanFindsCollectionsEnvironmentsAndGlobals() throws {
        let temp = TempDirectory()
        let folder = try makeFolder(at: temp.url)
        let id = UUID()
        try write("{}", to: folder.collectionFile(id))
        try write("{}", to: folder.environmentFile(UUID()))
        try write("{}", to: folder.globalsFile)
        try write("not ours", to: folder.root.appending(path: "notes.txt"))

        let scanned = FolderDiff.scan(folder)
        #expect(scanned.count == 3, "only JSON documents in the three known places")
        #expect(scanned.contains { $0.url.lastPathComponent == "globals.json" })
        #expect(!scanned.contains { $0.url.lastPathComponent == "notes.txt" })
    }

    @Test func aFileWeNeverWroteIsAnAddition() throws {
        let temp = TempDirectory()
        let folder = try makeFolder(at: temp.url)
        try write("{}", to: folder.collectionFile(UUID()))

        let changes = FolderDiff.changes(scanned: FolderDiff.scan(folder), lastWritten: [:])
        #expect(changes.count == 1)
        #expect(changes[0].kind == .added)
        #expect(changes[0].documentID != nil)
    }

    @Test func ourOwnWriteIsNotAChange() async throws {
        let temp = TempDirectory()
        let folder = try makeFolder(at: temp.url)
        let store = WorkspaceStore(dataFolder: folder, localRoot: temp.url.appending(path: "local"))
        _ = try await store.save(collection: makeSampleCollection())

        let changes = await FolderDiff.changes(
            scanned: FolderDiff.scan(folder), lastWritten: store.allFingerprints())
        #expect(changes.isEmpty, "the store recognises the bytes it wrote itself")
    }

    @Test func differentBytesAtTheSameSizeAndDateAreStillNoticed() throws {
        // A sync client can land a file whose size matches; only the hash settles it. The cheap
        // size-and-date check must not be able to swallow that case, so it is driven directly.
        let temp = TempDirectory()
        let folder = try makeFolder(at: temp.url)
        let url = folder.collectionFile(UUID())
        try write(#"{"a":1}"#, to: url)

        let entry = try #require(FolderDiff.scan(folder).first)
        let stale = FileFingerprint(
            revision: 1, modified: entry.modified.addingTimeInterval(-1),
            sha256: "0000", byteCount: entry.byteCount)

        let changes = FolderDiff.changes(
            scanned: [entry], lastWritten: [entry.path: stale], hash: { _ in "ffff" })
        #expect(changes.map(\.kind) == [.modified])
    }

    @Test func matchingHashMeansNoChangeEvenWhenTheDateMoved() throws {
        let temp = TempDirectory()
        let folder = try makeFolder(at: temp.url)
        let url = folder.collectionFile(UUID())
        try write(#"{"a":1}"#, to: url)

        let entry = try #require(FolderDiff.scan(folder).first)
        let touched = FileFingerprint(
            revision: 1, modified: entry.modified.addingTimeInterval(-60),
            sha256: "same", byteCount: entry.byteCount)

        let changes = FolderDiff.changes(
            scanned: [entry], lastWritten: [entry.path: touched], hash: { _ in "same" })
        #expect(changes.isEmpty, "a sync client that rewrites identical bytes is not an edit")
    }

    @Test func aFileWeWroteAndIsNowGoneIsARemoval() async throws {
        let temp = TempDirectory()
        let folder = try makeFolder(at: temp.url)
        let store = WorkspaceStore(dataFolder: folder, localRoot: temp.url.appending(path: "local"))
        let saved = try await store.save(collection: makeSampleCollection())
        try FileManager.default.removeItem(at: folder.collectionFile(saved.id))

        let changes = await FolderDiff.changes(
            scanned: FolderDiff.scan(folder), lastWritten: store.allFingerprints())
        #expect(changes.map(\.kind) == [.removed])
        #expect(changes[0].documentID == saved.id)
    }

    @Test(.timeLimit(.minutes(1)))
    func noticesWhatASecondProcessDoesToTheFolder() async throws {
        // PLAN.md §6 Phase 9: the watcher diff is exercised against a folder a second process
        // mutates, because that is exactly what a sync client is.
        let temp = TempDirectory()
        let folder = try makeFolder(at: temp.url)
        let store = WorkspaceStore(dataFolder: folder, localRoot: temp.url.appending(path: "local"))
        let mine = try await store.save(collection: makeSampleCollection())
        let doomed = try await store.save(collection: RequestCollection(name: "Removed"))
        let fingerprints = await store.allFingerprints()

        let theirs = folder.collectionFile(UUID())
        let script = """
            set -e
            cp '\(folder.collectionFile(mine.id).path)' '\(theirs.path)'
            printf '%s' '{"id":"\(mine.id.uuidString)","name":"Edited elsewhere","revision":9}' \
              > '\(folder.collectionFile(mine.id).path)'
            rm '\(folder.collectionFile(doomed.id).path)'
            """
        let process = Process()
        process.executableURL = URL(filePath: "/bin/sh")
        process.arguments = ["-c", script]
        try process.run()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)

        let changes = FolderDiff.changes(
            scanned: FolderDiff.scan(folder), lastWritten: fingerprints)
        let byKind = Dictionary(grouping: changes, by: \.kind)
        #expect(byKind[.added]?.count == 1)
        #expect(byKind[.modified]?.map(\.documentID) == [mine.id])
        #expect(byKind[.removed]?.map(\.documentID) == [doomed.id])
    }
}

@Suite("Conflict resolver")
struct ConflictResolverTests {
    @Test func namesACopyAfterTheDocumentTheHostAndTheTime() {
        let name = ConflictResolver.conflictFileName(
            documentName: "Acme API", host: "marys-macbook.local", date: fixedDate)
        #expect(name.hasPrefix("Acme API-marys-macbook-"))
        #expect(name.hasSuffix(".json"))
        #expect(!name.contains(".local"))
    }

    @Test func makesEveryNameSafeToPutOnDisk() {
        #expect(ConflictResolver.sanitize("a/b:c*d") == "a-b-c-d")
        #expect(ConflictResolver.sanitize("   ") == "Untitled")
        #expect(ConflictResolver.sanitize(String(repeating: "x", count: 200)).count == 60)
        let name = ConflictResolver.conflictFileName(
            documentName: "", host: "mac", date: fixedDate)
        #expect(name.hasPrefix("Untitled-"))
    }

    @Test func neverOverwritesAnExistingCopy() throws {
        let temp = TempDirectory()
        let first = try ConflictResolver.writeConflictCopy(
            Data("one".utf8), documentName: "Acme", in: temp.url, host: "mac", date: fixedDate)
        let second = try ConflictResolver.writeConflictCopy(
            Data("two".utf8), documentName: "Acme", in: temp.url, host: "mac", date: fixedDate)

        #expect(first != second)
        #expect(try String(contentsOf: first, encoding: .utf8) == "one")
        #expect(try String(contentsOf: second, encoding: .utf8) == "two")
    }

    @Test func recognisesApplesOwnConflictVersions() {
        let id = UUID().uuidString
        #expect(ConflictResolver.isSystemConflictVersion(
            URL(filePath: "/tmp/\(id) 2.json")))
        #expect(!ConflictResolver.isSystemConflictVersion(
            URL(filePath: "/tmp/\(id).json")))
        #expect(!ConflictResolver.isSystemConflictVersion(
            URL(filePath: "/tmp/Acme API-mac-2026-09-08-142317.json")))
    }
}

@Suite("Workspace merge")
struct WorkspaceMergeTests {
    private func collection(
        _ id: UUID, name: String, revision: Int, updated: Date = fixedDate
    ) -> RequestCollection {
        RequestCollection(
            id: id, name: name, createdAt: fixedDate, updatedAt: updated, revision: revision)
    }

    @Test func idsOnlyOnOneSideComeAcrossUntouched() {
        let mine = collection(UUID(), name: "Mine", revision: 1)
        let theirs = collection(UUID(), name: "Theirs", revision: 1)

        let result = WorkspaceMerge.merge(local: [mine], incoming: [theirs])
        #expect(result.merged.map(\.name) == ["Mine", "Theirs"])
        #expect(result.conflicts.isEmpty)
    }

    @Test func theHigherRevisionWinsAndTheLoserIsKept() {
        let id = UUID()
        let mine = collection(id, name: "Mine", revision: 3)
        let theirs = collection(id, name: "Theirs", revision: 7)

        let result = WorkspaceMerge.merge(local: [mine], incoming: [theirs])
        #expect(result.merged.map(\.name) == ["Theirs"])
        #expect(result.conflicts.map(\.name) == ["Mine"])
    }

    @Test func theOlderRevisionLosesEvenWhenItArrivesSecond() {
        let id = UUID()
        let result = WorkspaceMerge.merge(
            local: [collection(id, name: "Mine", revision: 9)],
            incoming: [collection(id, name: "Theirs", revision: 2)])
        #expect(result.merged.map(\.name) == ["Mine"])
        #expect(result.conflicts.map(\.name) == ["Theirs"])
    }

    @Test func theTimestampBreaksARevisionTie() {
        // Two Macs editing while apart land on the same revision number easily.
        let id = UUID()
        let result = WorkspaceMerge.merge(
            local: [collection(id, name: "Mine", revision: 4, updated: fixedDate)],
            incoming: [collection(
                id, name: "Theirs", revision: 4, updated: fixedDate.addingTimeInterval(60))])
        #expect(result.merged.map(\.name) == ["Theirs"])
        #expect(result.conflicts.map(\.name) == ["Mine"])
    }

    @Test func environmentsMergeByTheSameRules() {
        let id = UUID()
        let result = WorkspaceMerge.merge(
            local: [RequestEnvironment(id: id, name: "Local", revision: 1)],
            incoming: [RequestEnvironment(id: id, name: "Remote", revision: 5)])
        #expect(result.merged.map(\.name) == ["Remote"])
        #expect(result.conflicts.map(\.name) == ["Local"])
    }

    @Test func everyChoiceExplainsItself() {
        for choice in RelocationChoice.allCases {
            #expect(!choice.displayName.isEmpty)
            #expect(!choice.explanation.isEmpty)
        }
    }
}

@Suite("Data folder bookmarks")
struct DataFolderBookmarkTests {
    @Test func noBookmarkMeansTheDefaultFolder() {
        let temp = TempDirectory()
        let (folder, refreshed, accessed) = DataFolderBookmark.folder(
            from: AppSettings(), localRoot: temp.url)
        #expect(folder.isDefault)
        #expect(!folder.needsCoordination, "the container folder is ours alone")
        #expect(refreshed == nil)
        #expect(accessed == nil)
    }

    @Test func aBookmarkThatCannotBeResolvedFallsBackAndSaysSo() {
        let temp = TempDirectory()
        var settings = AppSettings()
        settings.dataFolderBookmark = Data("not a bookmark".utf8)

        let (folder, _, _) = DataFolderBookmark.folder(from: settings, localRoot: temp.url)
        #expect(folder.isDefault)
        #expect(folder.status == .staleBookmark, "the app still starts, and the UI can explain")
    }

    @Test func aBookmarkToAMissingFolderIsRefused() throws {
        let temp = TempDirectory()
        let target = temp.url.appending(path: "chosen", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        let bookmark = try DataFolderBookmark.create(for: target)
        try FileManager.default.removeItem(at: target)

        #expect(throws: DataFolderBookmark.BookmarkError.self) {
            try DataFolderBookmark.resolve(bookmark)
        }
    }

    @Test func aBookmarkRoundTripsToTheSameFolder() throws {
        let temp = TempDirectory()
        let target = temp.url.appending(path: "chosen", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)

        let resolved = try DataFolderBookmark.resolve(DataFolderBookmark.create(for: target))
        defer { if resolved.isAccessing { resolved.url.stopAccessingSecurityScopedResource() } }
        #expect(resolved.url.standardizedFileURL == target.standardizedFileURL)
        #expect(!resolved.isStale)
    }

    @Test func detectsTheSyncProviderFromThePath() {
        func provider(_ path: String) -> DataFolder.Provider {
            DataFolder(root: URL(filePath: path)).provider
        }
        #expect(provider("/Users/a/Library/Mobile Documents/com~apple~CloudDocs/Postfrau") == .iCloudDrive)
        #expect(provider("/Users/a/Library/CloudStorage/GoogleDrive-a@b.com/My Drive/P") == .googleDrive)
        #expect(provider("/Users/a/Library/CloudStorage/Dropbox/P") == .dropbox)
        #expect(provider("/Users/a/Dropbox/P") == .dropbox)
        #expect(provider("/Users/a/Library/CloudStorage/OneDrive-Personal/P") == .oneDrive)
        #expect(provider("/Users/a/Projects/postfrau-data") == .plain)
    }
}

extension DataFolderBookmarkTests {
    @Test func aPlainPathIsUsedWhenThereIsNoBookmark() throws {
        // The second instance, and the Phase 11 CLI: neither can hold the app's bookmark.
        let temp = TempDirectory()
        let shared = temp.url.appending(path: "Shared", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: shared, withIntermediateDirectories: true)

        var settings = AppSettings()
        settings.dataFolderPath = shared.path

        let (folder, _, _) = DataFolderBookmark.folder(from: settings, localRoot: temp.url)
        #expect(!folder.isDefault)
        #expect(folder.root.standardizedFileURL == shared.standardizedFileURL)
        #expect(folder.status == .ok)
        #expect(folder.needsCoordination, "two processes share it, so writes must be coordinated")
    }

    @Test func aPlainPathToNowhereReportsItselfMissing() {
        let temp = TempDirectory()
        var settings = AppSettings()
        settings.dataFolderPath = temp.url.appending(path: "gone").path

        let (folder, _, _) = DataFolderBookmark.folder(from: settings, localRoot: temp.url)
        #expect(folder.status == .missing, "the app still starts and the Data pane explains")
    }

    @Test func theBookmarkWinsOverThePath() throws {
        let temp = TempDirectory()
        let bookmarked = temp.url.appending(path: "Bookmarked", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: bookmarked, withIntermediateDirectories: true)

        var settings = AppSettings()
        settings.dataFolderBookmark = try DataFolderBookmark.create(for: bookmarked)
        settings.dataFolderPath = "/somewhere/else"

        let (folder, _, accessed) = DataFolderBookmark.folder(from: settings, localRoot: temp.url)
        defer { accessed?.stopAccessingSecurityScopedResource() }
        #expect(folder.root.standardizedFileURL == bookmarked.standardizedFileURL)
    }
}
