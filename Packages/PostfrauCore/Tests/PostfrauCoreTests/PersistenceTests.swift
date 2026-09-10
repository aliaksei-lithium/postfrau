import Foundation
import Testing
@testable import PostfrauCore

@Suite("Workspace store")
struct WorkspaceStoreTests {
    /// A store rooted in a fresh temporary directory, plus the folder it writes to.
    private func makeStore(_ temp: borrowing TempDirectory) -> (WorkspaceStore, DataFolder, URL) {
        let dataRoot = temp.url.appending(path: "Data", directoryHint: .isDirectory)
        let localRoot = temp.url.appending(path: "Local", directoryHint: .isDirectory)
        let folder = DataFolder(root: dataRoot, isDefault: false, needsCoordination: false)
        return (WorkspaceStore(dataFolder: folder, localRoot: localRoot), folder, localRoot)
    }


    @Test("Where a secret's value ends up depends on the setting, and only on that")
    func secretValueFollowsTheStorageSetting() async throws {
        let temp = TempDirectory()
        let (store, folder, _) = makeStore(temp)
        var environment = RequestEnvironment(name: "Staging")
        environment.variables = [
            Variable(key: "token", value: "sh-abc", isSecret: true),
            Variable(key: "baseUrl", value: "https://example.com"),
        ]

        func tokenOnDisk() throws -> String {
            let file = folder.root
                .appending(path: "environments", directoryHint: .isDirectory)
                .appending(path: "\(environment.id.uuidString).json", directoryHint: .notDirectory)
            let decoded = try Postfrau.makeDecoder()
                .decode(RequestEnvironment.self, from: Data(contentsOf: file))
            return decoded.variables.first { $0.key == "token" }?.value ?? "(missing)"
        }

        // Keychain mode: the folder gets a blank where the value would be.
        await store.setWritesSecretValues(false)
        _ = try await store.save(environment: environment)
        #expect(try tokenOnDisk() == "")

        // Data-folder mode: the value is written with everything else.
        await store.setWritesSecretValues(true)
        _ = try await store.save(environment: environment)
        #expect(try tokenOnDisk() == "sh-abc")

        // And back again, so switching does not strand the value in the file.
        await store.setWritesSecretValues(false)
        _ = try await store.save(environment: environment)
        #expect(try tokenOnDisk() == "")
    }

    @Test func loadingAnEmptyFolderCreatesTheLayoutAndMarker() async throws {
        let temp = TempDirectory()
        let (store, folder, _) = makeStore(temp)

        let result = try await store.load()
        #expect(result.workspace.collections.isEmpty)
        #expect(result.issues.isEmpty)
        #expect(FileManager.default.fileExists(atPath: folder.markerFile.path))
        #expect(FileManager.default.fileExists(atPath: folder.collectionsDirectory.path))
        #expect(FileManager.default.fileExists(atPath: folder.environmentsDirectory.path))

        let marker = try Postfrau.makeDecoder().decode(
            WorkspaceMarker.self, from: Data(contentsOf: folder.markerFile))
        #expect(marker.schemaVersion == Postfrau.schemaVersion)
    }

    @Test func preparingTwiceKeepsTheSameWorkspaceID() async throws {
        let temp = TempDirectory()
        let (_, folder, _) = makeStore(temp)
        let first = try folder.prepare()
        let second = try folder.prepare()
        #expect(first.workspaceID == second.workspaceID)
    }

    @Test func savesAndReloadsACollection() async throws {
        let temp = TempDirectory()
        let (store, folder, _) = makeStore(temp)
        _ = try await store.load()

        let collection = makeSampleCollection()
        let stored = try await store.save(collection: collection)
        #expect(stored.revision == collection.revision + 1)
        #expect(FileManager.default.fileExists(atPath: folder.collectionFile(collection.id).path))

        let reloaded = try await store.load().workspace
        #expect(reloaded.collections.count == 1)
        #expect(reloaded.collections[0].name == "Acme API")
        #expect(reloaded.collections[0].requestCount == 3)
        #expect(reloaded.collections[0].revision == stored.revision)
    }

    @Test func savingBumpsTheRevisionEveryTime() async throws {
        let temp = TempDirectory()
        let (store, _, _) = makeStore(temp)
        _ = try await store.load()

        var collection = RequestCollection(name: "C")
        for expected in 2...4 {
            collection = try await store.save(collection: collection)
            #expect(collection.revision == expected)
        }
    }

    @Test func savesEnvironmentsAndGlobals() async throws {
        let temp = TempDirectory()
        let (store, _, _) = makeStore(temp)
        _ = try await store.load()

        let environment = RequestEnvironment(
            name: "Staging", variables: [Variable(key: "baseUrl", value: "https://staging.test")])
        _ = try await store.save(environment: environment)
        _ = try await store.save(globals: Globals(variables: [Variable(key: "ua", value: "postfrau")]))

        let workspace = try await store.load().workspace
        #expect(workspace.environments.map(\.name) == ["Staging"])
        #expect(workspace.environments[0].variables.first?.value == "https://staging.test")
        #expect(workspace.globals.variables.first?.key == "ua")
    }

    @Test func deletesCollectionsAndEnvironments() async throws {
        let temp = TempDirectory()
        let (store, folder, _) = makeStore(temp)
        _ = try await store.load()

        let collection = RequestCollection(name: "Doomed")
        _ = try await store.save(collection: collection)
        try await store.delete(collectionID: collection.id)
        #expect(!FileManager.default.fileExists(atPath: folder.collectionFile(collection.id).path))

        let environment = RequestEnvironment(name: "Doomed")
        _ = try await store.save(environment: environment)
        try await store.delete(environmentID: environment.id)
        #expect(try await store.load().workspace.environments.isEmpty)

        // Deleting something that is already gone is not an error.
        try await store.delete(collectionID: UUID())
    }

    /// The default, which is what a caller that never mentions secrets gets. Writing them out is
    /// opt-in — see `setWritesSecretValues` and `secretValueFollowsTheStorageSetting`.
    @Test func secretValuesNeverReachTheDataFolder() async throws {
        let temp = TempDirectory()
        let (store, folder, _) = makeStore(temp)
        _ = try await store.load()

        let environment = RequestEnvironment(
            name: "Prod", variables: [Variable(key: "token", value: "hunter2", isSecret: true)])
        _ = try await store.save(environment: environment)

        let text = try String(contentsOf: folder.environmentFile(environment.id), encoding: .utf8)
        #expect(!text.contains("hunter2"))
        #expect(text.contains("\"isSecret\" : true"))
    }

    @Test func aMalformedCollectionIsReportedAndSkipped() async throws {
        let temp = TempDirectory()
        let (store, folder, _) = makeStore(temp)
        _ = try await store.load()
        _ = try await store.save(collection: RequestCollection(name: "Good"))

        let brokenID = UUID()
        try Data("{ this is not json".utf8).write(to: folder.collectionFile(brokenID))

        let result = try await store.load()
        #expect(result.workspace.collections.map(\.name) == ["Good"])
        #expect(result.issues.count == 1)
        #expect(result.issues[0].file == "\(brokenID.uuidString).json")
    }

    @Test func filesThatAreNotOursAreIgnored() async throws {
        let temp = TempDirectory()
        let (store, folder, _) = makeStore(temp)
        _ = try await store.load()
        _ = try await store.save(collection: RequestCollection(name: "Mine"))

        // The shapes sync clients leave behind.
        try Data("{}".utf8).write(to: folder.collectionsDirectory
            .appending(path: "Acme (conflicted copy 2026-09-07).json"))
        try Data("{}".utf8).write(to: folder.collectionsDirectory.appending(path: "notes.txt"))

        let result = try await store.load()
        #expect(result.workspace.collections.map(\.name) == ["Mine"])
        #expect(result.issues.isEmpty)
    }

    @Test func recognisesItsOwnFilenames() {
        #expect(WorkspaceStore.isOwnedFilename("\(UUID().uuidString).json"))
        #expect(!WorkspaceStore.isOwnedFilename("globals.json"))
        #expect(!WorkspaceStore.isOwnedFilename("\(UUID().uuidString).txt"))
        #expect(!WorkspaceStore.isOwnedFilename("\(UUID().uuidString) copy.json"))
    }

    @Test func fingerprintsEveryFileItWrites() async throws {
        let temp = TempDirectory()
        let (store, folder, _) = makeStore(temp)
        _ = try await store.load()

        let collection = RequestCollection(name: "Tracked")
        _ = try await store.save(collection: collection)

        let url = folder.collectionFile(collection.id)
        let fingerprint = try #require(await store.fingerprint(for: url))
        #expect(fingerprint.revision == 2)
        #expect(fingerprint.byteCount > 0)
        #expect(fingerprint.sha256.count == 64)

        // The recorded digest matches what is actually on disk.
        #expect(fingerprint.sha256 == AtomicFile.digest(try Data(contentsOf: url)))
    }

    @Test func aForeignWriteChangesTheDigestOnDisk() async throws {
        let temp = TempDirectory()
        let (store, folder, _) = makeStore(temp)
        _ = try await store.load()
        let collection = RequestCollection(name: "Watched")
        _ = try await store.save(collection: collection)

        let url = folder.collectionFile(collection.id)
        let mine = try #require(await store.fingerprint(for: url))

        // Simulate another Mac's copy landing in the folder.
        var edited = collection
        edited.name = "Edited elsewhere"
        edited.revision = 99
        try Postfrau.makeEncoder().encode(edited).write(to: url)

        let onDisk = AtomicFile.digest(try Data(contentsOf: url))
        #expect(onDisk != mine.sha256)
    }

    @Test func roundTripsLocalSettingsAndUIState() async throws {
        let temp = TempDirectory()
        let (store, _, localRoot) = makeStore(temp)

        #expect(await store.loadSettings() == AppSettings())
        #expect(await store.loadUIState() == UIState())

        var settings = AppSettings()
        settings.editorFontSize = 15
        settings.maxHistoryEntries = 42
        settings.dataFolderPath = "/tmp/anywhere"
        try await store.save(settings: settings)

        let state = UIState(
            tabs: [TabState(draft: RequestItem(name: "Open"), isDirty: true)],
            sidebarWidth: 321)
        try await store.save(uiState: state)

        #expect(await store.loadSettings() == settings)
        #expect(await store.loadUIState() == state)
        #expect(FileManager.default.fileExists(
            atPath: localRoot.appending(path: "settings.json").path))
    }

    @Test func localStateStaysOutOfTheDataFolder() async throws {
        let temp = TempDirectory()
        let (store, folder, _) = makeStore(temp)
        _ = try await store.load()
        try await store.save(settings: AppSettings())
        try await store.save(uiState: UIState())

        let dataFiles = try FileManager.default.contentsOfDirectory(atPath: folder.root.path)
        #expect(!dataFiles.contains("settings.json"))
        #expect(!dataFiles.contains("ui-state.json"))
    }

    @Test func writesConflictCopiesWithASortableName() async throws {
        let temp = TempDirectory()
        let (store, _, _) = makeStore(temp)

        let url = try await store.writeConflictCopy(
            Data("{}".utf8), name: "Acme API", host: "other-mac")
        #expect(url.lastPathComponent.hasPrefix("Acme API-other-mac-"))
        #expect(url.pathExtension == "json")
        #expect(await store.conflictCopies().count == 1)
    }

    @Test func conflictStampIsFilenameSafeAndSortable() {
        let stamp = WorkspaceStore.conflictStamp(Date(timeIntervalSince1970: 1_757_260_800))
        #expect(stamp.count == 15)
        #expect(!stamp.contains("/"))
        #expect(!stamp.contains(":"))
    }

    @Test func switchingDataFolderRelocatesWrites() async throws {
        let temp = TempDirectory()
        let (store, _, _) = makeStore(temp)
        _ = try await store.load()
        _ = try await store.save(collection: RequestCollection(name: "Original"))

        let second = DataFolder(
            root: temp.url.appending(path: "Elsewhere", directoryHint: .isDirectory),
            needsCoordination: false)
        await store.setDataFolder(second)
        let result = try await store.load()
        #expect(result.workspace.collections.isEmpty)
        #expect(FileManager.default.fileExists(atPath: second.markerFile.path))
    }
}

@Suite("Atomic file")
struct AtomicFileTests {
    @Test func writesAndReadsBack() throws {
        let temp = TempDirectory()
        let url = temp.url.appending(path: "nested/deep/file.json")
        let payload = Data("hello".utf8)

        let fingerprint = try AtomicFile.write(payload, to: url, coordinated: false)
        #expect(try AtomicFile.read(url, coordinated: false) == payload)
        #expect(fingerprint.byteCount == 5)
        #expect(fingerprint.sha256 == AtomicFile.digest(payload))
    }

    @Test func leavesNoTemporaryFilesBehind() throws {
        let temp = TempDirectory()
        let url = temp.url.appending(path: "file.json")
        try AtomicFile.write(Data("a".utf8), to: url, coordinated: false)
        try AtomicFile.write(Data("bb".utf8), to: url, coordinated: false)

        let contents = try FileManager.default.contentsOfDirectory(atPath: temp.url.path)
        #expect(contents == ["file.json"])
        #expect(try AtomicFile.read(url, coordinated: false) == Data("bb".utf8))
    }

    @Test func coordinatedWritesWork() throws {
        let temp = TempDirectory()
        let url = temp.url.appending(path: "coordinated.json")
        try AtomicFile.write(Data("x".utf8), to: url, coordinated: true)
        #expect(try AtomicFile.read(url, coordinated: true) == Data("x".utf8))
        try AtomicFile.remove(url, coordinated: true)
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    @Test func removingAMissingFileIsHarmless() throws {
        let temp = TempDirectory()
        try AtomicFile.remove(temp.url.appending(path: "never-existed"), coordinated: false)
    }

    @Test func digestIsStableAndHexEncoded() {
        let digest = AtomicFile.digest(Data("postfrau".utf8))
        #expect(digest.count == 64)
        #expect(digest == AtomicFile.digest(Data("postfrau".utf8)))
        #expect(digest != AtomicFile.digest(Data("postfrav".utf8)))
        #expect(digest.allSatisfy { $0.isHexDigit })
    }
}

@Suite("Data folder")
struct DataFolderTests {
    @Test func detectsSyncProviders() {
        func provider(_ path: String) -> DataFolder.Provider {
            DataFolder(root: URL(fileURLWithPath: path)).provider
        }
        #expect(provider("/Users/x/Library/Mobile Documents/com~apple~CloudDocs/Postfrau") == .iCloudDrive)
        #expect(provider("/Users/x/Library/CloudStorage/GoogleDrive-a@b.com/My Drive/Postfrau") == .googleDrive)
        #expect(provider("/Users/x/Library/CloudStorage/Dropbox/Postfrau") == .dropbox)
        #expect(provider("/Users/x/Library/CloudStorage/OneDrive-Personal/Postfrau") == .oneDrive)
        #expect(provider("/Users/x/Documents/Postfrau") == .plain)
    }

    @Test func reportsMissingAndHealthyFolders() {
        let temp = TempDirectory()
        let ok = DataFolder(root: temp.url).refreshingStatus()
        #expect(ok.status == .ok)

        let gone = DataFolder(root: temp.url.appending(path: "nope")).refreshingStatus()
        #expect(gone.status == .missing)
    }

    @Test func recognisesEmptyAndPopulatedFolders() throws {
        let temp = TempDirectory()
        let folder = DataFolder(root: temp.url, needsCoordination: false)
        #expect(folder.isEmptyDirectory)
        #expect(!folder.containsWorkspace)

        try folder.prepare()
        #expect(!folder.isEmptyDirectory)
        #expect(folder.containsWorkspace)
    }

    @Test func buildsDocumentPaths() {
        let id = UUID()
        let folder = DataFolder(root: URL(fileURLWithPath: "/tmp/pf"))
        #expect(folder.collectionFile(id).lastPathComponent == "\(id.uuidString).json")
        #expect(folder.environmentFile(id).path.contains("/environments/"))
        #expect(folder.globalsFile.lastPathComponent == "globals.json")
        #expect(folder.markerFile.lastPathComponent == "postfrau-workspace.json")
    }

    @Test func defaultFolderLivesUnderTheLocalRootAndNeedsNoCoordination() {
        let folder = DataFolder.defaultFolder(localRoot: URL(fileURLWithPath: "/tmp/pf"))
        #expect(folder.isDefault)
        #expect(!folder.needsCoordination)
        #expect(folder.root.lastPathComponent == "Data")
    }
}

@Suite("Migrations")
struct MigrationsTests {
    @Test func documentsWithoutAVersionAreTreatedAsVersionOne() {
        #expect(Migrations.schemaVersion(of: [:]) == 1)
        #expect(Migrations.schemaVersion(of: ["schemaVersion": 3]) == 3)
    }

    @Test func currentVersionPassesThroughUntouched() throws {
        let data = Data(#"{"schemaVersion":1,"name":"C"}"#.utf8)
        #expect(try Migrations.migrate(data: data) == data)
    }

    @Test func aDocumentFromTheFutureIsRejectedWithAReadableMessage() {
        let data = Data(#"{"schemaVersion":99}"#.utf8)
        #expect(throws: Migrations.MigrationError.self) {
            try Migrations.migrate(data: data)
        }
        let error = Migrations.MigrationError.fromTheFuture(found: 99, supported: 1)
        #expect(error.errorDescription?.contains("newer version") == true)
    }

    @Test func nonObjectJSONIsLeftAlone() throws {
        let data = Data("[1,2,3]".utf8)
        #expect(try Migrations.migrate(data: data) == data)
    }
}
