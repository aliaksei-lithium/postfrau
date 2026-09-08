import Foundation

/// Everything the CLI can do to a workspace, without a window.
///
/// The app drives its own `AppState`; this is the same operations for a process that has no UI —
/// the `postfrau` binary, and through it any agent with a shell. It owns the same collaborators
/// the app does, so a change made here is a change the app sees, recorded in the same history
/// with the same redaction.
public actor CommandRunner {
    public let store: WorkspaceStore
    public let history: HistoryStore
    public let executor: HTTPExecutor
    public let secrets: SecretsStore

    /// Values supplied out of band, keyed by variable name.
    ///
    /// A secret named here is never looked up in the Keychain, which is what makes the CLI usable
    /// from a script or a CI job where no one can answer a keychain prompt.
    public var secretOverrides: [String: String] = [:]
    /// Whether this process may touch the Keychain at all — reading *or* writing.
    ///
    /// Off by default, and deliberately so. A second binary reaching for items the app created
    /// raises a one-time "Always Allow" dialog, and `SecItem…` then blocks until someone clicks
    /// it — which in a script or a CI job is forever. A tool that can hang indefinitely is worse
    /// than one that says a value is missing, so the CLI takes secrets from
    /// `POSTFRAU_SECRET_<KEY>` unless the user opts in with `--keychain`.
    public private(set) var usesKeychain = false

    /// Secret variables whose values could not be supplied, for the caller to explain once.
    public private(set) var unavailableSecrets: [String] = []

    /// Who to attribute sends to.
    public private(set) var source: HistorySource
    /// How much of each send to record. Nil means "whatever settings say".
    public private(set) var recordLevel: HistoryRecordLevel?

    public func setSource(_ newSource: HistorySource) { source = newSource }
    public func setRecordLevel(_ level: HistoryRecordLevel?) { recordLevel = level }

    private var workspace = Workspace()
    /// The workspace as last read, for helpers that run after `load()` has already been awaited.
    var loadedWorkspace: Workspace { workspace }
    private var settings = AppSettings()
    private var isLoaded = false

    public init(
        store: WorkspaceStore,
        history: HistoryStore,
        executor: HTTPExecutor = HTTPExecutor(),
        secrets: SecretsStore = SecretsStore(),
        source: HistorySource = .cli,
        recordLevel: HistoryRecordLevel? = nil
    ) {
        self.store = store
        self.history = history
        self.executor = executor
        self.secrets = secrets
        self.source = source
        self.recordLevel = recordLevel
    }

    public enum CommandError: Error, LocalizedError, Equatable {
        case dataFolderUnavailable(String)
        case notFound(String)
        case invalid(String)

        public var errorDescription: String? {
            switch self {
            case .dataFolderUnavailable(let detail): detail
            case .notFound(let detail): detail
            case .invalid(let detail): detail
            }
        }
    }

    // MARK: - Loading

    /// Reads the workspace once per process. Every command calls it; the second call is free.
    @discardableResult
    public func load() async throws -> Workspace {
        guard !isLoaded else { return workspace }
        settings = await store.loadSettings()

        let folder = await store.folder.refreshingStatus()
        guard folder.status == .ok else {
            throw CommandError.dataFolderUnavailable(
                "The data folder at \(folder.root.path) is not available.")
        }

        let result = try await store.load()
        workspace = result.workspace
        // The active environment is machine-local state, kept in `ui-state.json` beside the open
        // tabs rather than in the synced workspace — so it has to be read separately, or every
        // `{{variable}}` the environment defines would come back unresolved.
        workspace.activeEnvironmentID = await store.loadUIState().activeEnvironmentID
        // Secret values live in the Keychain, not in the files just read.
        workspace = await hydrated(workspace)
        isLoaded = true
        return workspace
    }

    /// Forces the next command to re-read from disk — used between steps of a long-running
    /// sequence so a change the app made in the meantime is not overwritten.
    public func invalidate() { isLoaded = false }

    public func currentWorkspace() async throws -> Workspace { try await load() }
    public func currentSettings() async throws -> AppSettings {
        try await load()
        return settings
    }

    public func setSecretOverrides(_ overrides: [String: String]) {
        secretOverrides = overrides
    }

    public func setUsesKeychain(_ enabled: Bool) { usesKeychain = enabled }

    private func hydrated(_ workspace: Workspace) async -> Workspace {
        var copy = workspace
        for index in copy.environments.indices {
            copy.environments[index].variables = await hydrate(
                copy.environments[index].variables, scope: copy.environments[index].id)
        }
        copy.globals.variables = await hydrate(
            copy.globals.variables, scope: SecretsStore.globalsScope)
        return copy
    }

    /// Fills in secret values from the overrides, and from the Keychain when that was asked for.
    private func hydrate(_ variables: [Variable], scope: UUID) async -> [Variable] {
        var filled = variables
        var missing: [String] = []
        for index in filled.indices where filled[index].isSecret {
            if let supplied = secretOverrides[filled[index].key] {
                filled[index].value = supplied
            } else if filled[index].value.isEmpty {
                missing.append(filled[index].key)
            }
        }
        guard !missing.isEmpty else { return filled }

        guard usesKeychain else {
            unavailableSecrets.append(contentsOf: missing)
            return filled
        }
        let hydrated = await secrets.hydrate(filled, scope: scope)
        unavailableSecrets.append(contentsOf: hydrated.filter {
            $0.isSecret && $0.value.isEmpty
        }.map(\.key))
        return hydrated
    }

    // MARK: - Saving

    /// Writes one collection and keeps the in-memory copy in step.
    func save(collection: RequestCollection) async throws {
        let stored = try await store.save(collection: collection)
        if let index = workspace.collections.firstIndex(where: { $0.id == stored.id }) {
            workspace.collections[index] = stored
        } else {
            workspace.collections.append(stored)
            workspace.collections.sort {
                $0.name.localizedStandardCompare($1.name) == .orderedAscending
            }
        }
    }

    func save(environment: RequestEnvironment, previous: [Variable]) async throws {
        var toStore = environment
        // Same rule as the app: a secret's value never reaches the file. Writing one needs the
        // Keychain, which this process only touches when told to — see `usesKeychain`.
        if usesKeychain {
            try await secrets.persist(
                environment.variables, previous: previous, scope: environment.id)
        } else if environment.variables.contains(where: { $0.isSecret && !$0.value.isEmpty }) {
            throw CommandError.invalid(
                "Storing a secret needs the Keychain. Pass --keychain to allow it "
                    + "(macOS will ask once), or set the value in the app.")
        }
        let stored = try await store.save(environment: toStore)
        toStore = stored
        toStore.variables = environment.variables
        if let index = workspace.environments.firstIndex(where: { $0.id == stored.id }) {
            workspace.environments[index] = toStore
        } else {
            workspace.environments.append(toStore)
        }
    }

    func saveSettings(_ newSettings: AppSettings) async throws {
        settings = newSettings
        try await store.save(settings: newSettings)
    }

    // MARK: - Resolution

    public func resolve(_ text: String) async throws -> ResolvedItem {
        let workspace = try await load()
        do {
            return try ItemResolver.resolve(text, in: workspace)
        } catch let error as ItemResolver.ResolveError {
            throw CommandError.notFound(error.localizedDescription)
        }
    }

    /// The collection a path names, for commands that edit a whole tree.
    func collection(containing item: ResolvedItem) throws -> RequestCollection {
        guard let collection = workspace.collection(withID: item.collectionID) else {
            throw CommandError.notFound("The collection holding “\(item.name)” is gone.")
        }
        return collection
    }

    // MARK: - Variables

    /// The scope a request at this path sees, exactly as the app builds it.
    public func scope(forRequestWithID id: UUID, overrides: [String: String] = [:]) -> VariableScope {
        let collection = workspace.collections.first { $0.request(withID: id) != nil }
        let chain = (collection?.folderChain(to: id) ?? [])
            .compactMap { collection?.folder(withID: $0) }
        var scope = VariableScope.build(
            environment: workspace.activeEnvironment,
            collection: collection,
            folderChain: chain,
            globals: workspace.globals)

        // `--var k=v` beats everything, so it goes on top as its own layer.
        if !overrides.isEmpty {
            scope.layers.insert(
                VariableLayer(
                    source: .environment(name: "command line"),
                    variables: overrides
                        .sorted { $0.key < $1.key }
                        .map { Variable(key: $0.key, value: $0.value) }),
                at: 0)
        }
        return scope
    }

    /// The auth a request will send after the inherit chain is walked.
    public func effectiveAuth(forRequestWithID id: UUID) -> Auth {
        guard let collection = workspace.collections.first(where: { $0.request(withID: id) != nil }),
              let request = collection.request(withID: id)
        else { return Auth.none }
        let chain = (collection.folderChain(to: id) ?? [])
            .compactMap { collection.folder(withID: $0) }
        return AuthResolver.effective(
            requestAuth: request.auth, folderChain: chain, collection: collection).auth
    }

    // MARK: - Mutating the in-memory workspace

    func withWorkspace<T>(_ body: (inout Workspace) throws -> T) async throws -> T {
        _ = try await load()
        return try body(&workspace)
    }
}
