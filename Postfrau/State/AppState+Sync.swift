import Foundation
import PostfrauCore

extension AppState {
    /// A foreign change Postfrau kept out of the way because there were unsaved local edits.
    ///
    /// Shown as a banner rather than a dialog: a sync client can deliver a change at any moment,
    /// and a modal that steals the keyboard mid-edit would be worse than the conflict.
    struct SyncConflict: Identifiable, Hashable {
        var id: UUID { documentID }
        var documentID: UUID
        var documentName: String
        /// Where the version that arrived was parked.
        var copy: URL
        var arrivedAt: Date
    }

    /// A collection whose file disappeared while the app was running.
    struct MissingCollection: Identifiable, Hashable {
        var id: UUID
        var name: String
        /// Kept for this session so "Restore from memory" can write it back.
        var snapshot: RequestCollection
    }

    // MARK: - Watching

    /// Starts watching the data folder. Safe to call again; the previous watcher is replaced.
    func startWatchingDataFolder() async {
        let folder = await store.folder
        // Anything iCloud has not brought down yet is asked for now, so a fresh Mac fills in
        // rather than reporting a folder full of unreadable files.
        downloadingDocuments = await Self.requestICloudDownloads(in: folder)
        let watcher = FolderWatcher(folder: folder) { [weak self] in
            self?.folderChanged()
        }
        folderWatcher?.stop()
        folderWatcher = watcher
        watcher.start()
        dataFolder = folder
    }

    func stopWatchingDataFolder() {
        folderWatcher?.stop()
        folderWatcher = nil
        folderRecoveryTask?.cancel()
        folderRecoveryTask = nil
    }

    /// Called once a burst of file-system events has settled.
    private func folderChanged() {
        syncTask?.cancel()
        syncTask = Task { [weak self] in
            await self?.absorbFolderChanges()
        }
    }

    /// Diffs the folder and applies whatever another process did to it.
    func absorbFolderChanges() async {
        guard !isAbsorbingFolderChanges else { return }
        isAbsorbingFolderChanges = true
        defer { isAbsorbingFolderChanges = false }

        let folder = await store.folder
        guard await checkFolderIsStillThere(folder) else { return }
        let fingerprints = await store.allFingerprints()
        let changes = await Self.diff(folder: folder, lastWritten: fingerprints)
        guard !changes.isEmpty else { return }

        for change in changes {
            // iCloud parks its own losing versions beside the file; Postfrau writes its own
            // copies with a name that says which Mac they came from, so adopting Apple's would
            // duplicate every conflict.
            guard !ConflictResolver.isSystemConflictVersion(change.url) else { continue }
            guard let id = change.documentID else { continue }

            switch change.kind {
            case .added, .modified:
                // Whatever just landed is here now, so it is no longer on its way.
                downloadingDocuments.remove(id)
                await adopt(id: id, at: change.url, isCollection: isCollectionFile(change.url, in: folder))
            case .removed:
                markMissing(id: id, isCollection: isCollectionFile(change.url, in: folder))
            }
        }
        lastExternalChange = Date()
    }

    /// Re-reads the folder's health, and reports whether it is worth diffing.
    ///
    /// A folder that has gone — an unmounted volume, a folder thrown away in the Finder — must not
    /// be diffed: every document would come back as removed, and the user would be handed a
    /// hundred "no longer in the data folder" banners for one event. The status is what changes.
    private func checkFolderIsStillThere(_ folder: DataFolder) async -> Bool {
        let refreshed = await Self.refreshStatus(of: folder)
        let wasHealthy = dataFolder.status == .ok
        dataFolder = refreshed

        guard refreshed.status == .ok else {
            dataFolderProblem = "The data folder is not available. Postfrau is not writing to it, "
                + "and will pick up where it left off when the folder comes back."
            if wasHealthy { startFolderRecoveryPolling() }
            return false
        }
        dataFolderProblem = nil
        return true
    }

    /// Waits for a folder that went away to come back.
    ///
    /// The `DispatchSource` watching a deleted directory fires once and then never again, so
    /// without this an unmounted volume would need a relaunch. Polling is the honest tool here:
    /// there is nothing left to subscribe to.
    private func startFolderRecoveryPolling() {
        folderRecoveryTask?.cancel()
        folderRecoveryTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(3))
                guard let self else { return }
                let folder = await self.store.folder
                guard await Self.refreshStatus(of: folder).status == .ok else { continue }
                // It is back: rebuild the watchers, then take whatever changed while it was away.
                await self.startWatchingDataFolder()
                await self.absorbFolderChanges()
                return
            }
        }
    }

    @concurrent
    private static func refreshStatus(of folder: DataFolder) async -> DataFolder {
        folder.refreshingStatus()
    }

    @concurrent
    private static func requestICloudDownloads(in folder: DataFolder) async -> Set<UUID> {
        Set(UbiquitousDownloads.requestAll(in: folder).compactMap(\.documentID))
    }

    /// The scan and diff, off the main thread: a folder with hundreds of documents means hundreds
    /// of `stat` calls and, for anything that looks changed, a SHA-256 of the file.
    @concurrent
    private static func diff(
        folder: DataFolder, lastWritten: [String: FileFingerprint]
    ) async -> [FolderChange] {
        FolderDiff.changes(scanned: FolderDiff.scan(folder), lastWritten: lastWritten)
    }

    private func isCollectionFile(_ url: URL, in folder: DataFolder) -> Bool {
        url.deletingLastPathComponent().standardizedFileURL
            == folder.collectionsDirectory.standardizedFileURL
    }

    // MARK: - Applying one change

    /// Takes a foreign version of a document, unless the user is in the middle of editing it.
    private func adopt(id: UUID, at url: URL, isCollection: Bool) async {
        guard isCollection else {
            if let environment = try? await store.loadEnvironment(id: id) {
                replaceEnvironment(environment)
            }
            return
        }

        guard let incoming = try? await store.loadCollection(id: id) else { return }

        if hasUnsavedEdits(forCollection: id) {
            // Local work wins the screen; the other side is written where it can be looked at.
            await parkConflict(incoming)
            return
        }
        replaceCollection(incoming)
    }

    /// True when this collection has edits that have not reached the disk: a queued autosave, or
    /// an open tab with a dirty draft.
    func hasUnsavedEdits(forCollection id: UUID) -> Bool {
        if isDirty(collection: id) { return true }
        return tabs.contains { $0.collectionID == id && $0.isDirty }
    }

    private func replaceCollection(_ incoming: RequestCollection) {
        if let index = workspace.collections.firstIndex(where: { $0.id == incoming.id }) {
            workspace.collections[index] = incoming
        } else {
            workspace.collections.append(incoming)
            workspace.collections.sort {
                $0.name.localizedStandardCompare($1.name) == .orderedAscending
            }
        }
        missingCollections.removeAll { $0.id == incoming.id }
        invalidateSidebarCache()

        // An open tab on an untouched request follows the file; a dirty one is left alone, which
        // `hasUnsavedEdits` has already guaranteed for this collection.
        for tab in tabs where tab.collectionID == incoming.id {
            guard let requestID = tab.requestID,
                  let request = incoming.request(withID: requestID)
            else { continue }
            tab.draft = request
            tab.markSaved()
        }
    }

    private func replaceEnvironment(_ incoming: RequestEnvironment) {
        if let index = workspace.environments.firstIndex(where: { $0.id == incoming.id }) {
            workspace.environments[index] = incoming
        } else {
            workspace.environments.append(incoming)
            workspace.environments.sort {
                $0.name.localizedStandardCompare($1.name) == .orderedAscending
            }
        }
    }

    private func parkConflict(_ incoming: RequestCollection) async {
        guard let data = try? Postfrau.makeEncoder().encode(incoming) else { return }
        let directory = await store.conflictsDirectory
        guard let copy = try? ConflictResolver.writeConflictCopy(
            data, documentName: incoming.name, in: directory)
        else { return }

        syncConflicts.removeAll { $0.documentID == incoming.id }
        syncConflicts.append(SyncConflict(
            documentID: incoming.id, documentName: incoming.name,
            copy: copy, arrivedAt: Date()))
    }

    private func markMissing(id: UUID, isCollection: Bool) {
        guard isCollection, let collection = workspace.collection(withID: id) else { return }
        // Deletions this app made are already reflected in the workspace, so a document that is
        // still in memory when its file goes is one another process removed.
        guard !missingCollections.contains(where: { $0.id == id }) else { return }
        missingCollections.append(MissingCollection(
            id: id, name: collection.name, snapshot: collection))
    }

    // MARK: - Resolving a conflict

    /// Keeps what is on screen and writes it back over the version that arrived.
    func keepMine(_ conflict: SyncConflict) {
        syncConflicts.removeAll { $0.id == conflict.id }
        markDirty(collection: conflict.documentID)
    }

    /// Adopts the version that arrived, discarding the local edits.
    func takeTheirs(_ conflict: SyncConflict) async {
        syncConflicts.removeAll { $0.id == conflict.id }
        guard let data = try? Data(contentsOf: conflict.copy),
              let incoming = try? Postfrau.makeDecoder().decode(RequestCollection.self, from: data)
        else { return }
        clearDirty(collection: conflict.documentID)
        replaceCollection(incoming)
        markDirty(collection: incoming.id)
    }

    /// Opens the parked version as a second, read-only collection so both can be compared.
    func showBoth(_ conflict: SyncConflict) {
        syncConflicts.removeAll { $0.id == conflict.id }
        guard let data = try? Data(contentsOf: conflict.copy),
              var incoming = try? Postfrau.makeDecoder().decode(RequestCollection.self, from: data)
        else { return }
        // A new id throughout, or it would collide with the collection it conflicts with and be
        // written straight back over it.
        incoming = incoming.duplicated(named: "\(conflict.documentName) (from another Mac)")
        workspace.collections.append(incoming)
        expandedIDs.insert(incoming.id)
        invalidateSidebarCache()
        markDirty(collection: incoming.id)
    }

    /// Writes a collection whose file vanished back to the folder.
    func restoreMissing(_ missing: MissingCollection) {
        missingCollections.removeAll { $0.id == missing.id }
        if !workspace.collections.contains(where: { $0.id == missing.id }) {
            workspace.collections.append(missing.snapshot)
            invalidateSidebarCache()
        }
        markDirty(collection: missing.id)
    }

    /// Accepts the removal: the collection goes from the sidebar too.
    func forgetMissing(_ missing: MissingCollection) {
        missingCollections.removeAll { $0.id == missing.id }
        workspace.collections.removeAll { $0.id == missing.id }
        tabs.filter { $0.collectionID == missing.id }.forEach { closeTab($0) }
        invalidateSidebarCache()
    }
}

extension AppState {
    // MARK: - Choosing the folder

    /// Points the store at whatever folder settings name, before anything is read.
    ///
    /// A bookmark that will not resolve is not fatal: the app falls back to the folder inside its
    /// own container and says so through `DataFolder.status`, which the Data pane explains. An
    /// unmounted volume or a folder the user threw away must not stop Postfrau from opening.
    func resolveDataFolder() async {
        let localRoot = await store.localStateRoot
        let (folder, refreshed, accessed) = DataFolderBookmark.folder(
            from: settings, localRoot: localRoot)

        if let refreshed {
            // The folder moved or was renamed; store the rebuilt bookmark so the next launch
            // does not have to do this again.
            settings.dataFolderBookmark = refreshed
            markSettingsDirty()
        }
        securityScopedRoot = accessed
        dataFolder = folder
        await store.setDataFolder(folder)

        if case .staleBookmark = folder.status {
            dataFolderProblem = "Postfrau could not open the folder it was using, "
                + "so it is running on the local copy. Choose the folder again in Settings ▸ Data."
        } else {
            dataFolderProblem = nil
        }
    }

    /// Switches to a folder the user picked, applying their choice about the data in it.
    ///
    /// Nothing is ever deleted: `useDataInFolder` leaves the local copy where it is and writes a
    /// backup beside it, and `merge` writes every losing version to `conflicts/`.
    func relocateDataFolder(to url: URL, choice: RelocationChoice) async {
        let bookmark: Data
        do {
            bookmark = try DataFolderBookmark.create(for: url)
        } catch {
            dataFolderProblem = AppState.message(for: error)
            return
        }

        stopWatchingDataFolder()
        let previousRoot = dataFolder.root
        let target = DataFolder(root: url, isDefault: false, needsCoordination: true)
        do { try target.prepare() } catch {
            dataFolderProblem = AppState.message(for: error)
            await startWatchingDataFolder()
            return
        }

        let localCollections = workspace.collections
        let localEnvironments = workspace.environments
        let localGlobals = workspace.globals

        // Read what is already there before the store is pointed anywhere new.
        let existing = await Self.readWorkspace(at: target)

        switch choice {
        case .moveDataHere:
            for collection in existing.collections {
                await writeBackup(collection, reason: "replaced")
            }
            workspace.collections = localCollections
            workspace.environments = localEnvironments
            workspace.globals = localGlobals

        case .useDataInFolder:
            await writeLocalBackup(
                collections: localCollections, environments: localEnvironments,
                previousRoot: previousRoot)
            workspace.collections = existing.collections
            workspace.environments = existing.environments
            workspace.globals = existing.globals

        case .merge:
            let collections = WorkspaceMerge.merge(
                local: localCollections, incoming: existing.collections)
            let environments = WorkspaceMerge.merge(
                local: localEnvironments, incoming: existing.environments)
            for loser in collections.conflicts { await writeBackup(loser, reason: "conflict") }
            for loser in environments.conflicts { await writeBackup(loser, reason: "conflict") }
            workspace.collections = collections.merged
            workspace.environments = environments.merged
        }

        settings.dataFolderBookmark = bookmark
        settings.dataFolderPath = url.path
        markSettingsDirty()

        await store.setDataFolder(target.refreshingStatus())
        dataFolder = await store.folder
        dataFolderProblem = nil

        // Everything in memory is now the truth; write it all so the folder holds a complete copy.
        if choice != .useDataInFolder {
            for collection in workspace.collections { markDirty(collection: collection.id) }
            for environment in workspace.environments { markDirty(environment: environment.id) }
            markGlobalsDirty()
        }
        invalidateSidebarCache()
        await startWatchingDataFolder()
    }

    /// Returns to the folder inside the app container.
    func useDefaultDataFolder() async {
        stopWatchingDataFolder()
        settings.dataFolderBookmark = nil
        settings.dataFolderPath = nil
        markSettingsDirty()
        await resolveDataFolder()
        await reloadWorkspaceFromFolder()
        await startWatchingDataFolder()
    }

    /// Re-reads the whole workspace from whatever folder the store is now pointed at.
    func reloadWorkspaceFromFolder() async {
        do {
            let result = try await store.load()
            workspace.collections = result.workspace.collections
            workspace.environments = result.workspace.environments
            workspace.globals = result.workspace.globals
            loadIssues = result.issues
        } catch {
            loadIssues = [WorkspaceStore.LoadIssue(
                file: "data folder", message: AppState.message(for: error))]
        }
        missingCollections.removeAll()
        syncConflicts.removeAll()
        invalidateSidebarCache()
    }

    /// Reads a folder without disturbing the store, so the relocation sheet can say what is in it.
    static func readWorkspace(at folder: DataFolder) async -> Workspace {
        let store = WorkspaceStore(dataFolder: folder, localRoot: folder.root)
        return (try? await store.load().workspace) ?? Workspace()
    }

    /// True when the chosen folder already holds someone's workspace, so the sheet must ask.
    @concurrent
    static func containsWorkspace(_ url: URL) async -> Bool {
        DataFolder(root: url).containsWorkspace
    }

    private func writeBackup(_ document: some MergeableDocument & Encodable, reason: String) async {
        guard let data = try? Postfrau.makeEncoder().encode(document) else { return }
        let directory = await store.conflictsDirectory
        _ = try? ConflictResolver.writeConflictCopy(
            data, documentName: "\(document.name) (\(reason))", in: directory)
    }

    /// Keeps a copy of everything this Mac had before adopting a folder's contents.
    private func writeLocalBackup(
        collections: [RequestCollection],
        environments: [RequestEnvironment],
        previousRoot: URL
    ) async {
        for collection in collections { await writeBackup(collection, reason: "before switch") }
        for environment in environments { await writeBackup(environment, reason: "before switch") }
    }
}
