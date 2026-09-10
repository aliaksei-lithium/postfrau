import Foundation

/// Reading and writing everything Postfrau persists.
///
/// Two roots: the **data folder** (collections, environments, globals — syncable, coordinated,
/// relocatable) and the **local root** (settings, UI state, history, conflict copies — never
/// leaves the machine). Both are injectable so tests run against temporary directories.
///
/// The store keeps a fingerprint of every file it wrote so `FolderWatcher` (Phase 9) can tell
/// Postfrau's own writes from a change delivered by a sync client.
public actor WorkspaceStore {
    /// A problem loading one document. Loading never fails wholesale: a broken collection is
    /// reported and skipped so the rest of the workspace still opens.
    public struct LoadIssue: Sendable, Hashable {
        public var file: String
        public var message: String

        public init(file: String, message: String) {
            self.file = file
            self.message = message
        }
    }

    public struct LoadResult: Sendable {
        public var workspace: Workspace
        public var issues: [LoadIssue]

        public init(workspace: Workspace, issues: [LoadIssue] = []) {
            self.workspace = workspace
            self.issues = issues
        }
    }

    private var dataFolder: DataFolder
    /// Whether secret values are written into the workspace files.
    ///
    /// Off until something says otherwise, which is the safe way round: a caller that forgets to
    /// set it blanks secrets, as this store always used to, rather than writing them out. The app
    /// and the command line tool both set it the moment they have read the settings.
    private var writesSecretValues = false
    private let localRoot: URL
    private var fingerprints: [String: FileFingerprint] = [:]

    public init(dataFolder: DataFolder, localRoot: URL) {
        self.dataFolder = dataFolder
        self.localRoot = localRoot
    }

    public var folder: DataFolder { dataFolder }
    public var localStateRoot: URL { localRoot }

    /// Points the store at a different data folder. The caller is responsible for having moved
    /// or merged the contents first (see Phase 9's relocation flow).
    public func setDataFolder(_ folder: DataFolder) {
        dataFolder = folder
        fingerprints.removeAll()
    }

    /// The fingerprint of the last write the store made to `url`, if any.
    public func fingerprint(for url: URL) -> FileFingerprint? {
        fingerprints[url.standardizedFileURL.path]
    }

    public func allFingerprints() -> [String: FileFingerprint] { fingerprints }

    // MARK: - Local state paths

    public var settingsFile: URL { localRoot.appending(path: "settings.json", directoryHint: .notDirectory) }
    public var uiStateFile: URL { localRoot.appending(path: "ui-state.json", directoryHint: .notDirectory) }
    public var historyFile: URL { localRoot.appending(path: "history.jsonl", directoryHint: .notDirectory) }
    public var conflictsDirectory: URL { localRoot.appending(path: "conflicts", directoryHint: .isDirectory) }

    // MARK: - Loading

    /// Reads the whole workspace. Missing files are not errors; a malformed one is reported
    /// in `issues` and skipped.
    public func load() throws -> LoadResult {
        try dataFolder.prepare()
        var issues: [LoadIssue] = []

        let collections = loadDocuments(
            in: dataFolder.collectionsDirectory, as: RequestCollection.self, issues: &issues)
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }

        let environments = loadDocuments(
            in: dataFolder.environmentsDirectory, as: RequestEnvironment.self, issues: &issues)
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }

        var globals = Globals()
        if FileManager.default.fileExists(atPath: dataFolder.globalsFile.path) {
            do {
                globals = try decodeDocument(at: dataFolder.globalsFile, as: Globals.self)
            } catch {
                issues.append(LoadIssue(
                    file: dataFolder.globalsFile.lastPathComponent,
                    message: error.localizedDescription))
            }
        }

        return LoadResult(
            workspace: Workspace(
                collections: collections, environments: environments, globals: globals),
            issues: issues)
    }

    /// Reads one collection file, for the watcher's "reload just this document" path.
    public func loadCollection(id: UUID) throws -> RequestCollection {
        try decodeDocument(at: dataFolder.collectionFile(id), as: RequestCollection.self)
    }

    public func loadEnvironment(id: UUID) throws -> RequestEnvironment {
        try decodeDocument(at: dataFolder.environmentFile(id), as: RequestEnvironment.self)
    }

    // MARK: - Saving

    /// Writes a collection, bumping `revision` and `updatedAt`. Returns the stored copy so the
    /// caller can keep its in-memory model in step with what is on disk.
    @discardableResult
    public func save(collection: RequestCollection) throws -> RequestCollection {
        var stored = collection
        stored.revision += 1
        stored.updatedAt = Date()
        try write(stored, to: dataFolder.collectionFile(stored.id), revision: stored.revision)
        return stored
    }

    @discardableResult
    public func save(environment: RequestEnvironment) throws -> RequestEnvironment {
        var stored = environment
        stored.revision += 1
        stored.updatedAt = Date()
        try write(stored, to: dataFolder.environmentFile(stored.id), revision: stored.revision)
        return stored
    }

    @discardableResult
    public func save(globals: Globals) throws -> Globals {
        var stored = globals
        stored.revision += 1
        stored.updatedAt = Date()
        try write(stored, to: dataFolder.globalsFile, revision: stored.revision)
        return stored
    }

    public func delete(collectionID: UUID) throws {
        let url = dataFolder.collectionFile(collectionID)
        try AtomicFile.remove(url, coordinated: dataFolder.needsCoordination)
        fingerprints.removeValue(forKey: url.standardizedFileURL.path)
    }

    public func delete(environmentID: UUID) throws {
        let url = dataFolder.environmentFile(environmentID)
        try AtomicFile.remove(url, coordinated: dataFolder.needsCoordination)
        fingerprints.removeValue(forKey: url.standardizedFileURL.path)
    }

    // MARK: - Local state

    public func loadSettings() -> AppSettings {
        (try? decodeLocal(at: settingsFile, as: AppSettings.self)) ?? AppSettings()
    }

    public func save(settings: AppSettings) throws {
        try writeLocal(settings, to: settingsFile)
    }

    public func loadUIState() -> UIState {
        (try? decodeLocal(at: uiStateFile, as: UIState.self)) ?? UIState()
    }

    public func save(uiState: UIState) throws {
        try writeLocal(uiState, to: uiStateFile)
    }

    /// Writes a foreign version of a document next to the local state, for the conflict banner.
    /// Returns the URL of the copy.
    @discardableResult
    public func writeConflictCopy(_ data: Data, name: String, host: String) throws -> URL {
        try FileManager.default.createDirectory(at: conflictsDirectory, withIntermediateDirectories: true)
        let stamp = Self.conflictStamp(Date())
        let safeName = name.replacingOccurrences(of: "/", with: "-")
        let url = conflictsDirectory.appending(
            path: "\(safeName)-\(host)-\(stamp).json", directoryHint: .notDirectory)
        try AtomicFile.write(data, to: url, coordinated: false)
        return url
    }

    public func conflictCopies() -> [URL] {
        (try? FileManager.default.contentsOfDirectory(
            at: conflictsDirectory, includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles])) ?? []
    }

    /// `2026-09-07-1432` — sortable, filename-safe, no locale surprises.
    static func conflictStamp(_ date: Date) -> String {
        let parts = Calendar(identifier: .gregorian).dateComponents(
            [.year, .month, .day, .hour, .minute], from: date)
        return String(
            format: "%04d-%02d-%02d-%02d%02d",
            parts.year ?? 0, parts.month ?? 0, parts.day ?? 0, parts.hour ?? 0, parts.minute ?? 0)
    }

    // MARK: - Private

    private func loadDocuments<T: Decodable>(
        in directory: URL, as type: T.Type, issues: inout [LoadIssue]
    ) -> [T] {
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles])) ?? []

        var out: [T] = []
        // Only `<uuid>.json` is ours; a sync client's "conflicted copy" files are ignored.
        for url in urls.sorted(by: { $0.lastPathComponent < $1.lastPathComponent })
        where Self.isOwnedFilename(url.lastPathComponent) {
            do {
                out.append(try decodeDocument(at: url, as: type))
            } catch {
                issues.append(LoadIssue(
                    file: url.lastPathComponent, message: error.localizedDescription))
            }
        }
        return out
    }

    /// True for `<uuid>.json`, which is the only naming Postfrau writes.
    static func isOwnedFilename(_ name: String) -> Bool {
        guard name.hasSuffix(".json") else { return false }
        return UUID(uuidString: String(name.dropLast(5))) != nil
    }

    private func decodeDocument<T: Decodable>(at url: URL, as type: T.Type) throws -> T {
        let raw = try AtomicFile.read(url, coordinated: dataFolder.needsCoordination)
        let data = try Migrations.migrate(data: raw)
        let value = try Postfrau.makeDecoder().decode(type, from: data)
        fingerprints[url.standardizedFileURL.path] =
            try AtomicFile.fingerprint(of: url, data: raw, revision: 0)
        return value
    }

    /// Tells the store where secrets are kept, so it knows whether to write their values.
    public func setWritesSecretValues(_ writes: Bool) { writesSecretValues = writes }

    private func documentEncoder() -> JSONEncoder {
        let encoder = Postfrau.makeEncoder()
        encoder.userInfo[.includeSecretValues] = writesSecretValues
        return encoder
    }

    private func write<T: Encodable>(_ value: T, to url: URL, revision: Int) throws {
        let data = try documentEncoder().encode(value)
        try AtomicFile.write(data, to: url, coordinated: dataFolder.needsCoordination)
        fingerprints[url.standardizedFileURL.path] =
            try AtomicFile.fingerprint(of: url, data: data, revision: revision)
    }

    private func decodeLocal<T: Decodable>(at url: URL, as type: T.Type) throws -> T {
        let raw = try Data(contentsOf: url)
        let data = try Migrations.migrate(data: raw)
        return try Postfrau.makeDecoder().decode(type, from: data)
    }

    private func writeLocal<T: Encodable>(_ value: T, to url: URL) throws {
        let data = try Postfrau.makeEncoder().encode(value)
        try AtomicFile.write(data, to: url, coordinated: false)
    }
}
