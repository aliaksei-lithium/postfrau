import AppKit
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
    /// What the filter field holds. The sidebar draws from `appliedSidebarFilter`, which lags it
    /// by `filterDebounce` so a burst of typing is rendered once rather than once per keystroke —
    /// each intermediate query matches far more than the final one, and drawing those throwaway
    /// results is what makes a large collection feel slow.
    var sidebarFilter = ""
    private(set) var appliedSidebarFilter = ""
    /// Bumped by every collection edit, so the sidebar's filter cache knows when it is stale.
    private(set) var sidebarCacheGeneration = 0

    /// How long typing settles before the sidebar re-filters.
    static let filterDebounce = Duration.milliseconds(200)

    @ObservationIgnored private var filterTask: Task<Void, Never>?

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
    /// Which half of the sidebar is showing. On `AppState` rather than the view's own `@State`
    /// so the History menu can switch to it.
    var sidebarSection: SidebarSection = .collections
    var historyEntries: [HistoryEntry] = []

    // MARK: Sync

    /// The data folder as it was last resolved, for the Data pane and the status chip.
    var dataFolder = DataFolder(root: URL(filePath: NSTemporaryDirectory()), isDefault: true)
    /// Foreign changes held back because the same document had unsaved local edits.
    var syncConflicts: [SyncConflict] = []
    /// Collections whose files disappeared while the app was running.
    var missingCollections: [MissingCollection] = []
    /// When another process last touched the folder, for the status chip.
    var lastExternalChange: Date?
    /// Guards against a second diff starting while one is still applying.
    var isAbsorbingFolderChanges = false
    /// Set when the data folder could not be opened; shown in the Data pane.
    var dataFolderProblem: String?
    /// Documents iCloud has been asked for but has not delivered yet, for the sidebar spinner.
    var downloadingDocuments: Set<UUID> = []
    /// What the last import did, shown in a sheet. Nil when there is nothing worth saying.
    var importReport: ImportReport?
    /// Help ▸ Keyboard Shortcuts, and the About window.
    var isShortcutsPresented = false
    var isAboutPresented = false
    /// The security-scoped URL whose access is open for the life of the process.
    @ObservationIgnored var securityScopedRoot: URL?
    @ObservationIgnored var folderWatcher: FolderWatcher?
    @ObservationIgnored var syncTask: Task<Void, Never>?
    /// Per-tab derived values, keyed by the draft and variables generations. See `derivation`.
    @ObservationIgnored var derivationCache: [UUID: Derivation] = [:]

    /// Rendered response bodies, so switching Pretty ↔ Raw does not redo the work.
    ///
    /// Reading a body off disk, decoding it, re-indenting and tokenizing is the same result every
    /// time for the same response — but it was repeated on every switch between the two tabs,
    /// which is exactly the click a person makes most.
    struct RenderedBody: Sendable {
        var text: String
        var tokens: [SyntaxToken]
        var truncated: Bool
        var prettyFailure: String?
    }

    @ObservationIgnored private var renderedBodies: [String: RenderedBody] = [:]
    @ObservationIgnored private var renderedBodyOrder: [String] = []

    func renderedBody(for key: String) -> RenderedBody? { renderedBodies[key] }

    func cacheRenderedBody(_ body: RenderedBody, for key: String) {
        if renderedBodies[key] == nil { renderedBodyOrder.append(key) }
        renderedBodies[key] = body
        // A handful of megabyte strings is plenty to keep; beyond that the oldest goes.
        while renderedBodyOrder.count > 8 {
            renderedBodies.removeValue(forKey: renderedBodyOrder.removeFirst())
        }
    }

    /// Polls for a data folder that went away, since a dead directory sends no more events.
    @ObservationIgnored var folderRecoveryTask: Task<Void, Never>?
    /// Which sends the History sidebar shows. Not persisted: a filter that survives a relaunch
    /// looks like missing history.
    var historySourceFilter: HistorySourceFilter = .all
    var isConfirmingClearHistory = false
    /// How many entries were on disk when history was last read, so a refresh can be skipped
    /// when nothing has changed.
    @ObservationIgnored var lastKnownHistoryCount = 0
    /// Bumped by ⌘L; the window watches it and moves focus into the URL field.
    private(set) var urlFocusRequests = 0
    /// Set when a menu command wants to close a tab that has unsaved work; the tab bar owns the
    /// dialog, so the command hands the decision over rather than presenting one itself.
    var tabPendingCloseConfirmation: UUID?
    /// The last Keychain problem, shown in the environments window. Nil when all is well.
    var secretsError: String?
    /// Whether the ⌘K panel is showing, and what has been typed into it.
    ///
    /// The query lives here rather than in the panel's own `@State` because the panel is presented
    /// from an overlay whose identity SwiftUI is free to reset — which silently threw away every
    /// keystroke, leaving the field showing text the results had never been computed from.
    var isQuickOpenPresented = false {
        didSet {
            if isQuickOpenPresented != oldValue {
                quickOpenQuery = ""
                quickOpenSelection = 0
            }
        }
    }
    var quickOpenQuery = ""
    var quickOpenSelection = 0
    /// Sniffing a body means reading its first bytes, which for an on-disk response is real IO;
    /// the answer never changes for a given response, so it is remembered.
    @ObservationIgnored var contentKindCache: [String: ContentKind] = [:]
    /// The sidebar's filtered tree, memoized — see `sidebarSnapshot`.
    @ObservationIgnored var cachedSidebar: (key: SidebarCacheKey, snapshot: FilteredCollections)?

    struct SidebarCacheKey: Equatable {
        var query: String
        var collectionCount: Int
        var generation: Int
    }
    /// The window's undo manager, handed over once the window exists. Structural sidebar edits
    /// register their undo here so ⌘Z works the way it does everywhere else on the Mac.
    @ObservationIgnored weak var undoManager: UndoManager?

    func focusURLField() { urlFocusRequests += 1 }

    // MARK: Collaborators

    let store: WorkspaceStore
    let history: HistoryStore
    let executor: HTTPExecutor
    /// Secret variable values. Kept out of the data folder entirely — see `SecretsStore`.
    let secretsStore: SecretsStore
    private let builder = RequestBuilder()

    // MARK: Dirty tracking

    /// Everything the autosave task watches. Kept as observable stored properties so
    /// `Observations` can coalesce a burst of edits into one write.
    private var dirtyCollectionIDs: Set<UUID> = []
    private var dirtyEnvironmentIDs: Set<UUID> = []
    var deletedCollectionIDs: Set<UUID> = []
    var deletedEnvironmentIDs: Set<UUID> = []
    private var globalsDirty = false
    private var settingsDirty = false
    private var uiStateDirty = false

    @ObservationIgnored private var autosaveTask: Task<Void, Never>?
    /// History removals in flight. `flush()` waits for them; see `enqueueHistoryWork`.
    @ObservationIgnored var pendingHistoryWork: Task<Void, Never>?

    /// How long edits are batched before they are written.
    static let autosaveDebounce = Duration.milliseconds(300)

    init(
        store: WorkspaceStore,
        history: HistoryStore,
        executor: HTTPExecutor = HTTPExecutor(),
        secretsStore: SecretsStore = SecretsStore()
    ) {
        self.store = store
        self.history = history
        self.executor = executor
        self.secretsStore = secretsStore
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
        let history = HistoryStore(
            root: localRoot.appending(path: "history", directoryHint: .isDirectory))
        return AppState(store: store, history: history)
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
        applyAppearance()
        applyLocalAPI()
        await history.setMaxEntries(settings.maxHistoryEntries)
        await resolveDataFolder()

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
        // Before anything is written: the store blanks secrets on encode unless told otherwise.
        await store.setWritesSecretValues(settings.secretStorage == .dataFolder)
        await loadSecrets()

        let uiState = await store.loadUIState()
        restore(uiState)

        if workspace.collections.isEmpty {
            await installSampleCollection()
        }

        await loadHistory()

        startAutosave()
        startFilterDebounce()
        await startWatchingDataFolder()
    }

    /// Writes everything pending. Called on quit and when the window closes.
    func flush() async {
        autosaveTask?.cancel()
        autosaveTask = nil
        filterTask?.cancel()
        filterTask = nil
        await writePendingChanges()
        await saveUIState()
        await drainHistoryWork()
        stopWatchingDataFolder()
    }

    private func restore(_ uiState: UIState) {
        sidebarSection = uiState.sidebarSection
            .flatMap(SidebarSection.init(rawValue:)) ?? .collections
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
    func installSampleCollection() async {
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

    /// Watches the filter field and applies it once typing pauses.
    private func startFilterDebounce() {
        filterTask?.cancel()
        filterTask = Task { [weak self] in
            guard let self else { return }
            for await typed in Observations({ self.sidebarFilter }) {
                if typed == self.appliedSidebarFilter { continue }
                // An empty field should feel instant — there is nothing to compute.
                if typed.isEmpty {
                    self.appliedSidebarFilter = ""
                    continue
                }
                try? await Task.sleep(for: Self.filterDebounce)
                if Task.isCancelled { return }
                self.appliedSidebarFilter = self.sidebarFilter
            }
        }
    }

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
        invalidateSidebarCache()
        // A collection carries variables and auth that requests inherit.
        invalidateVariables()
    }

    /// Bumped whenever anything a variable could resolve from changes.
    ///
    /// Keyed on by the per-tab derivation cache, so a request's badges and computed headers are
    /// recomputed when an environment changes but not on every redraw.
    private(set) var variablesGeneration = 0

    func invalidateVariables() { variablesGeneration &+= 1 }

    /// Tells the sidebar its memoized tree snapshot is out of date.
    ///
    /// Separate from `markDirty` because a collection can change without becoming dirty: a version
    /// arriving from another Mac is already on disk, and marking it dirty would write it straight
    /// back.
    func invalidateSidebarCache() { sidebarCacheGeneration &+= 1 }

    func markDirty(environment id: UUID) {
        dirtyEnvironmentIDs.insert(id)
        invalidateVariables()
    }

    /// True when this collection has an edit queued that has not reached the disk.
    func isDirty(collection id: UUID) -> Bool { dirtyCollectionIDs.contains(id) }

    /// Drops a queued edit — used when the user chooses the version that arrived from another Mac
    /// over their own, which must not then be written back on the next autosave.
    func clearDirty(collection id: UUID) { dirtyCollectionIDs.remove(id) }

    func markGlobalsDirty() {
        globalsDirty = true
        invalidateVariables()
    }
    func markSettingsDirty() {
        settingsDirty = true
        // Every settings change comes through here, so this is the one place the appearance and
        // the loopback API can be applied without each control having to remember to.
        applyAppearance()
        applyLocalAPI()
    }

    /// Applies the light/dark preference to the whole app.
    ///
    /// Set on `NSApplication` rather than with `preferredColorScheme` on a view: Postfrau has
    /// three windows — main, Environments and Settings — and the menu bar besides, and only the
    /// application-level appearance covers all of them. `nil` means "follow the system".
    /// The loopback API, when settings ask for one. Nil whenever it is switched off.
    private var localAPI: LocalAPIServer?

    /// Starts, stops or restarts the loopback API to match settings.
    ///
    /// Called from the same place as `applyAppearance()` — every settings change goes through
    /// `markSettingsDirty()` — and once at launch. Restarting on every call would drop live
    /// connections, so the port and token are compared first.
    func applyLocalAPI() {
        let wanted: (port: UInt16, token: String)? =
            settings.localAPIEnabled && !settings.localAPIToken.isEmpty
            ? (UInt16(clamping: settings.localAPIPort), settings.localAPIToken)
            : nil

        guard runningLocalAPI?.port != wanted?.port || runningLocalAPI?.token != wanted?.token
        else { return }

        let previous = localAPI
        localAPI = nil
        runningLocalAPI = wanted

        guard let wanted else {
            Task { await previous?.stop() }
            return
        }

        // The store is an actor, so the folder it is using can only be read off the main actor —
        // which is why the server is built inside the task rather than handed in ready-made.
        let store = store, history = history, executor = executor, secrets = secretsStore
        Task { [weak self] in
            await previous?.stop()
            let server = LocalAPIServer(
                port: wanted.port, token: wanted.token,
                runner: CommandRunner(
                    store: store, history: history, executor: executor, secrets: secrets,
                    source: .agent(name: "api")),
                dataFolderPath: await store.folder.root.path)
            do {
                try await server.start()
                self?.adopt(server)
                self?.localAPIError = nil
            } catch {
                self?.reportLocalAPIFailure(error)
            }
        }
    }

    private func adopt(_ server: LocalAPIServer) { localAPI = server }

    /// What the running server was built with, so an unchanged setting does not restart it.
    private var runningLocalAPI: (port: UInt16, token: String)?

    /// Surfaced in Settings ▸ Advanced; the usual cause is the port already being in use.
    private(set) var localAPIError: String?

    private func reportLocalAPIFailure(_ error: any Error) {
        localAPIError = error.localizedDescription
        settings.localAPIEnabled = false
        settingsDirty = true
    }

    func applyAppearance() {
        let wanted: NSAppearance? = switch settings.appearance {
        case .system: nil
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        }
        // Assigning pushes an appearance change through every view in every window, so only do it
        // when the value actually differs.
        guard NSApplication.shared.appearance?.name != wanted?.name else { return }
        NSApplication.shared.appearance = wanted
    }
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
            requestPaneFraction: requestPaneFraction,
            sidebarSection: sidebarSection.rawValue)
        try? await store.save(uiState: state)
    }
}
