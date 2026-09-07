import Foundation
import Observation
import PostfrauCore

/// The single source of truth for the app.
///
/// Every model mutation goes through a method here, which updates the in-memory `Workspace`,
/// marks the affected document dirty, and lets the debounced autosave task write it out. No view
/// ever touches the filesystem. `AppState` is main-actor by default (the target's isolation
/// setting); all the slow work — file IO, networking — happens in Core's actors.
@Observable
final class AppState {
    // MARK: Model

    var workspace = Workspace()
    var settings = AppSettings()
    var loadIssues: [WorkspaceStore.LoadIssue] = []

    // MARK: Tabs and selection

    var tabs: [RequestTab] = []
    var selectedTabID: UUID?
    var sidebarSelection: UUID?
    var expandedIDs: Set<UUID> = []
    var sidebarFilter = ""

    // MARK: Layout

    var sidebarWidth: Double = 260
    var requestPaneFraction: Double = 0.45

    // MARK: Status

    enum SaveState: Equatable {
        case idle
        case saving
        case saved(Date)
        case failed(String)
    }

    var saveState: SaveState = .idle
    var historyEntries: [HistoryEntry] = []
    /// Bumped by ⌘L; the window watches it and moves focus into the URL field.
    private(set) var urlFocusRequests = 0

    func focusURLField() { urlFocusRequests += 1 }

    // MARK: Collaborators

    let store: WorkspaceStore
    let historyLog: HistoryLog
    let executor: HTTPExecutor
    private let builder = RequestBuilder()

    // MARK: Dirty tracking

    /// Everything the autosave task watches. Kept as observable stored properties so
    /// `Observations` can coalesce a burst of edits into one write.
    private var dirtyCollectionIDs: Set<UUID> = []
    private var dirtyEnvironmentIDs: Set<UUID> = []
    private var deletedCollectionIDs: Set<UUID> = []
    private var deletedEnvironmentIDs: Set<UUID> = []
    private var globalsDirty = false
    private var settingsDirty = false
    private var uiStateDirty = false

    @ObservationIgnored private var autosaveTask: Task<Void, Never>?

    /// How long edits are batched before they are written.
    static let autosaveDebounce = Duration.milliseconds(300)

    init(
        store: WorkspaceStore,
        historyLog: HistoryLog,
        executor: HTTPExecutor = HTTPExecutor()
    ) {
        self.store = store
        self.historyLog = historyLog
        self.executor = executor
    }

    /// Builds the state the app actually runs with: the container's local root and the data
    /// folder recorded in settings (Phase 9 resolves the bookmark; for now it is the default).
    ///
    /// The machine-local state can be relocated, which Phase 9 uses to run a second instance
    /// against the same data folder and the UI tests use to start from a clean slate.
    static func makeDefault() -> AppState {
        let localRoot = overriddenLocalRoot() ?? DataFolder.defaultLocalRoot()
        let dataFolder = DataFolder.defaultFolder(localRoot: localRoot)
        let store = WorkspaceStore(dataFolder: dataFolder, localRoot: localRoot)
        let historyLog = HistoryLog(
            fileURL: localRoot.appending(path: "history.jsonl", directoryHint: .notDirectory))
        return AppState(store: store, historyLog: historyLog)
    }

    /// Where machine-local state lives, honouring the launch overrides.
    ///
    /// Three ways in, in priority order:
    ///
    /// - `--local-root <absolute path>` — a launch argument, used by Phase 9's second-instance test.
    /// - `POSTFRAU_LOCAL_ROOT` — an environment variable, for launching from a shell. (XCUITest's
    ///   `launchEnvironment` does *not* reach an app launched through LaunchServices, which is why
    ///   the argument form exists as well.)
    /// - `--local-root-name <name>` — a folder under the app's *own* container. The XCUITest runner
    ///   is itself sandboxed, so it cannot name a directory the app is allowed to write; it names a
    ///   folder instead and lets the app place it.
    ///
    /// `--reset-state` empties the resolved folder first, so each UI test starts from nothing.
    static func overriddenLocalRoot() -> URL? {
        var resolved: URL?
        if let path = launchArgument(named: "--local-root") {
            resolved = URL(fileURLWithPath: path, isDirectory: true)
        } else if let path = ProcessInfo.processInfo.environment["POSTFRAU_LOCAL_ROOT"],
                  !path.isEmpty {
            resolved = URL(fileURLWithPath: path, isDirectory: true)
        } else if let name = launchArgument(named: "--local-root-name") {
            resolved = DataFolder.defaultLocalRoot()
                .appending(path: "TestRuns", directoryHint: .isDirectory)
                .appending(path: name, directoryHint: .isDirectory)
        }

        if let resolved, ProcessInfo.processInfo.arguments.contains("--reset-state") {
            try? FileManager.default.removeItem(at: resolved)
        }
        return resolved
    }

    /// The value following `name` in the launch arguments, if any.
    static func launchArgument(named name: String) -> String? {
        let arguments = ProcessInfo.processInfo.arguments
        guard let flag = arguments.firstIndex(of: name) else { return nil }
        let value = arguments.index(after: flag)
        guard value < arguments.endIndex, !arguments[value].hasPrefix("--") else { return nil }
        return arguments[value]
    }

    // MARK: - Lifecycle

    /// Loads everything from disk and restores the previous session. Called once at launch.
    func load() async {
        settings = await store.loadSettings()
        await historyLog.setMaxEntries(settings.maxHistoryEntries)

        do {
            let result = try await store.load()
            workspace = result.workspace
            loadIssues = result.issues
        } catch {
            loadIssues = [WorkspaceStore.LoadIssue(
                file: "data folder", message: error.localizedDescription)]
        }

        // The UI state is restored *before* the sample collection is installed: `restore` replaces
        // the expansion set wholesale, so installing first would silently discard the sample's
        // "start expanded" flag.
        let uiState = await store.loadUIState()
        restore(uiState)

        if workspace.collections.isEmpty {
            await installSampleCollection()
        }

        historyEntries = (try? await historyLog.load(limit: settings.maxHistoryEntries)) ?? []

        startAutosave()
    }

    /// Writes everything pending. Called on quit and when the window closes.
    func flush() async {
        autosaveTask?.cancel()
        autosaveTask = nil
        await writePendingChanges()
        await saveUIState()
    }

    private func restore(_ uiState: UIState) {
        sidebarWidth = uiState.sidebarWidth
        requestPaneFraction = uiState.requestPaneFraction
        expandedIDs = Set(uiState.expandedItemIDs)
        workspace.activeEnvironmentID = uiState.activeEnvironmentID.flatMap { id in
            workspace.environments.contains { $0.id == id } ? id : nil
        }

        tabs = uiState.tabs.map { state in
            let tab = RequestTab(restoring: state)
            // Re-attach the saved copy so the dirty dot reflects the collection, not the file.
            if let requestID = state.requestID,
               let collection = workspace.collectionContaining(itemID: requestID),
               let saved = collection.request(withID: requestID) {
                tab.savedSnapshot = saved
                tab.collectionID = collection.id
            }
            return tab
        }
        selectedTabID = uiState.selectedTabID.flatMap { id in
            tabs.contains { $0.id == id } ? id : tabs.first?.id
        } ?? tabs.first?.id

        if tabs.isEmpty { newTab() }
    }

    /// Ships a small collection on first run so the app is not an empty box.
    private func installSampleCollection() async {
        guard let url = Bundle.main.url(forResource: "SampleCollection", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let collection = try? Postfrau.makeDecoder().decode(RequestCollection.self, from: data)
        else { return }

        // Fresh ids so the sample is a normal, fully editable collection.
        var sample = collection.duplicated(named: collection.name)
        sample.createdAt = Date()
        workspace.collections = [sample]
        expandedIDs.insert(sample.id)
        markDirty(collection: sample.id)
        markUIStateDirty()
    }

    // MARK: - Autosave

    private func startAutosave() {
        autosaveTask?.cancel()
        autosaveTask = Task { [weak self] in
            guard let self else { return }
            // `Observations` coalesces a burst of edits; the sleep turns that into a debounce.
            for await _ in Observations({ self.pendingWorkFingerprint }) {
                guard self.hasPendingWork else { continue }
                try? await Task.sleep(for: Self.autosaveDebounce)
                if Task.isCancelled { return }
                await self.writePendingChanges()
                await self.saveUIState()
            }
        }
    }

    /// A cheap value that changes whenever there is something new to write. Observing this rather
    /// than the whole workspace keeps the autosave task from waking on every keystroke's
    /// downstream effects.
    private var pendingWorkFingerprint: Int {
        var hasher = Hasher()
        hasher.combine(dirtyCollectionIDs)
        hasher.combine(dirtyEnvironmentIDs)
        hasher.combine(deletedCollectionIDs)
        hasher.combine(deletedEnvironmentIDs)
        hasher.combine(globalsDirty)
        hasher.combine(settingsDirty)
        hasher.combine(uiStateDirty)
        return hasher.finalize()
    }

    private var hasPendingWork: Bool {
        !dirtyCollectionIDs.isEmpty || !dirtyEnvironmentIDs.isEmpty
            || !deletedCollectionIDs.isEmpty || !deletedEnvironmentIDs.isEmpty
            || globalsDirty || settingsDirty || uiStateDirty
    }

    func markDirty(collection id: UUID) {
        touchUpdatedAt(collection: id)
        dirtyCollectionIDs.insert(id)
    }

    func markDirty(environment id: UUID) {
        dirtyEnvironmentIDs.insert(id)
    }

    func markGlobalsDirty() { globalsDirty = true }
    func markSettingsDirty() { settingsDirty = true }
    func markUIStateDirty() { uiStateDirty = true }

    private func touchUpdatedAt(collection id: UUID) {
        guard let index = workspace.collections.firstIndex(where: { $0.id == id }) else { return }
        workspace.collections[index].updatedAt = Date()
    }

    private func writePendingChanges() async {
        guard hasPendingWork else { return }
        saveState = .saving

        let collectionIDs = dirtyCollectionIDs
        let environmentIDs = dirtyEnvironmentIDs
        let removedCollections = deletedCollectionIDs
        let removedEnvironments = deletedEnvironmentIDs
        let writeGlobals = globalsDirty
        let writeSettings = settingsDirty
        dirtyCollectionIDs.removeAll()
        dirtyEnvironmentIDs.removeAll()
        deletedCollectionIDs.removeAll()
        deletedEnvironmentIDs.removeAll()
        globalsDirty = false
        settingsDirty = false

        var failure: String?

        for id in removedCollections {
            do { try await store.delete(collectionID: id) }
            catch { failure = error.localizedDescription }
        }
        for id in removedEnvironments {
            do { try await store.delete(environmentID: id) }
            catch { failure = error.localizedDescription }
        }
        for id in collectionIDs {
            guard let collection = workspace.collection(withID: id) else { continue }
            do {
                let stored = try await store.save(collection: collection)
                // Keep the in-memory revision in step without re-marking the document dirty.
                if let index = workspace.collections.firstIndex(where: { $0.id == id }) {
                    workspace.collections[index].revision = stored.revision
                    workspace.collections[index].updatedAt = stored.updatedAt
                }
            } catch {
                failure = error.localizedDescription
            }
        }
        for id in environmentIDs {
            guard let environment = workspace.environments.first(where: { $0.id == id })
            else { continue }
            do {
                let stored = try await store.save(environment: environment)
                if let index = workspace.environments.firstIndex(where: { $0.id == id }) {
                    workspace.environments[index].revision = stored.revision
                    workspace.environments[index].updatedAt = stored.updatedAt
                }
            } catch {
                failure = error.localizedDescription
            }
        }
        if writeGlobals {
            do {
                let stored = try await store.save(globals: workspace.globals)
                workspace.globals.revision = stored.revision
                workspace.globals.updatedAt = stored.updatedAt
            } catch {
                failure = error.localizedDescription
            }
        }
        if writeSettings {
            do { try await store.save(settings: settings) }
            catch { failure = error.localizedDescription }
        }

        saveState = failure.map { .failed($0) } ?? .saved(Date())
    }

    private func saveUIState() async {
        guard uiStateDirty else { return }
        uiStateDirty = false
        let state = UIState(
            tabs: tabs.map { $0.snapshot() },
            selectedTabID: selectedTabID,
            activeEnvironmentID: workspace.activeEnvironmentID,
            expandedItemIDs: Array(expandedIDs),
            sidebarWidth: sidebarWidth,
            requestPaneFraction: requestPaneFraction)
        try? await store.save(uiState: state)
    }
}
