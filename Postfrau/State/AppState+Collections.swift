import AppKit
import Foundation
import SwiftUI
import PostfrauCore

/// Structural editing of the collections tree.
///
/// Every mutation goes through here so it can mark the right document dirty and register an undo.
/// Undo works on whole-collection snapshots: the trees are small (a 5 000-request collection is
/// ~4 MB of model), the operations are user-scale rather than per-keystroke, and a snapshot cannot
/// get the tree into a state a hand-written inverse would have missed.
extension AppState {
    // MARK: - Creating

    @discardableResult
    func newCollection(named name: String = "New Collection") -> RequestCollection {
        let collection = RequestCollection(name: name)
        registerUndo(actionName: "New Collection") { state in
            state.deleteCollection(id: collection.id, registerUndo: true)
        }
        workspace.collections.append(collection)
        workspace.collections.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        expandedIDs.insert(collection.id)
        markDirty(collection: collection.id)
        markUIStateDirty()
        return collection
    }

    /// Adds a folder inside `parentID`, or at the root of `collectionID` when it is nil.
    @discardableResult
    func newFolder(in collectionID: UUID, parentID: UUID?, named name: String = "New Folder") -> UUID? {
        let folder = Folder(name: name)
        guard mutate(collectionID, actionName: "New Folder", { collection in
            collection.insert(.folder(folder), into: parentID)
        }) else { return nil }
        expandedIDs.insert(folder.id)
        if let parentID { expandedIDs.insert(parentID) }
        markUIStateDirty()
        return folder.id
    }

    @discardableResult
    func newRequest(in collectionID: UUID, parentID: UUID?, named name: String = "New Request") -> UUID? {
        let request = RequestItem(name: name)
        guard mutate(collectionID, actionName: "New Request", { collection in
            collection.insert(.request(request), into: parentID)
        }) else { return nil }
        if let parentID { expandedIDs.insert(parentID) }
        expandedIDs.insert(collectionID)
        openRequest(id: request.id)
        return request.id
    }

    // MARK: - Duplicating and deleting

    @discardableResult
    func duplicate(itemWithID id: UUID) -> UUID? {
        guard let collection = workspace.collectionContaining(itemID: id),
              let item = collection.item(withID: id)
        else { return nil }

        let copy: CollectionItem
        switch item {
        case .request(let request):
            copy = .request(request.duplicated())
        case .folder(var folder):
            folder.name = "\(folder.name) copy"
            copy = RequestCollection.reidentify([.folder(folder)])[0]
        }

        let parentID = collection.currentParentID(of: id)
        let index = collection.currentIndex(of: id).map { $0 + 1 }
        _ = mutate(collection.id, actionName: "Duplicate") { collection in
            collection.insert(copy, into: parentID, at: index)
        }
        return copy.id
    }

    func duplicateCollection(id: UUID) {
        guard let original = workspace.collection(withID: id) else { return }
        let copy = original.duplicated()
        registerUndo(actionName: "Duplicate Collection") { state in
            state.deleteCollection(id: copy.id, registerUndo: true)
        }
        workspace.collections.append(copy)
        workspace.collections.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        markDirty(collection: copy.id)
    }

    func delete(itemWithID id: UUID) {
        guard let collection = workspace.collectionContaining(itemID: id), collection.id != id
        else { return }
        _ = mutate(collection.id, actionName: "Delete") { collection in
            collection.remove(itemWithID: id) != nil
        }
        // Any tab showing the deleted request is now orphaned; it keeps its draft but loses its home.
        for tab in tabs where tab.requestID == id {
            tab.requestID = nil
            tab.collectionID = nil
        }
        markUIStateDirty()
    }

    func deleteCollection(id: UUID, registerUndo shouldRegisterUndo: Bool = true) {
        guard let index = workspace.collections.firstIndex(where: { $0.id == id }) else { return }
        let removed = workspace.collections[index]

        if shouldRegisterUndo {
            registerUndo(actionName: "Delete Collection") { state in
                state.restore(collection: removed)
            }
        }
        workspace.collections.remove(at: index)
        deletedCollectionIDs.insert(id)
        for tab in tabs where tab.collectionID == id {
            tab.requestID = nil
            tab.collectionID = nil
        }
        markUIStateDirty()
    }

    /// Puts a deleted collection back, cancelling the pending delete if it has not been written yet.
    func restore(collection: RequestCollection) {
        registerUndo(actionName: "Delete Collection") { state in
            state.deleteCollection(id: collection.id, registerUndo: true)
        }
        deletedCollectionIDs.remove(collection.id)
        workspace.collections.append(collection)
        workspace.collections.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        markDirty(collection: collection.id)
        markUIStateDirty()
    }

    // MARK: - Moving

    /// Moves an item, possibly into a different collection.
    @discardableResult
    func move(itemWithID id: UUID, toCollection targetCollectionID: UUID, target: DropTarget) -> Bool {
        guard let source = workspace.collectionContaining(itemID: id) else { return false }

        if source.id == targetCollectionID {
            return mutate(source.id, actionName: "Move") { collection in
                collection.move(itemWithID: id, to: target)
            }
        }

        // Across collections: take it out of one and put it in the other, with a single undo
        // covering both halves.
        guard var targetCollection = workspace.collection(withID: targetCollectionID),
              let item = source.item(withID: id)
        else { return false }
        if let parentID = target.parentID, targetCollection.folder(withID: parentID) == nil {
            return false
        }

        let sourceBefore = source
        let targetBefore = targetCollection
        registerUndo(actionName: "Move") { state in
            state.replace(collection: sourceBefore)
            state.replace(collection: targetBefore)
        }

        var updatedSource = source
        guard updatedSource.remove(itemWithID: id) != nil,
              targetCollection.insert(item, into: target.parentID, at: target.index)
        else { return false }

        replace(collection: updatedSource, registerUndo: false)
        replace(collection: targetCollection, registerUndo: false)
        for tab in tabs where tab.requestID == id { tab.collectionID = targetCollectionID }
        markUIStateDirty()
        return true
    }

    // MARK: - Editing a collection or folder

    func updateCollection(_ collection: RequestCollection, actionName: String = "Edit Collection") {
        replace(collection: collection, actionName: actionName)
    }

    func updateFolder(_ folder: Folder, in collectionID: UUID) {
        _ = mutate(collectionID, actionName: "Edit Folder") { collection in
            collection.replace(.folder(folder))
        }
    }

    // MARK: - Plumbing

    /// Applies a change to one collection, snapshotting it first so the change can be undone.
    @discardableResult
    func mutate(
        _ collectionID: UUID, actionName: String, _ change: (inout RequestCollection) -> Bool
    ) -> Bool {
        guard let index = workspace.collections.firstIndex(where: { $0.id == collectionID })
        else { return false }

        let before = workspace.collections[index]
        var updated = before
        guard change(&updated) else { return false }

        registerUndo(actionName: actionName) { state in
            state.replace(collection: before)
        }
        workspace.collections[index] = updated
        markDirty(collection: collectionID)
        return true
    }

    /// Overwrite a whole collection — the shape every undo takes.
    func replace(collection: RequestCollection, registerUndo shouldRegister: Bool = true,
                 actionName: String = "Edit") {
        guard let index = workspace.collections.firstIndex(where: { $0.id == collection.id })
        else { return }
        if shouldRegister {
            let before = workspace.collections[index]
            registerUndo(actionName: actionName) { state in
                state.replace(collection: before)
            }
        }
        workspace.collections[index] = collection
        markDirty(collection: collection.id)
        refreshOpenTabs(for: collection)
    }

    /// Keeps open tabs in step with a collection that changed underneath them.
    private func refreshOpenTabs(for collection: RequestCollection) {
        for tab in tabs where tab.collectionID == collection.id {
            guard let requestID = tab.requestID,
                  let saved = collection.request(withID: requestID) else { continue }
            tab.savedSnapshot = saved
            if !tab.isDirty { tab.draft = saved }
        }
    }

    /// Registers one undo step. The closure receives the state so it never captures `self`.
    func registerUndo(actionName: String, _ undo: @escaping (AppState) -> Void) {
        guard let undoManager else { return }
        undoManager.setActionName(actionName)
        undoManager.registerUndo(withTarget: self) { state in
            MainActor.assumeIsolated { undo(state) }
        }
    }
}

extension AppState {
    // MARK: - Sidebar support

    /// What the sidebar should draw: the collections pruned by the filter, the folders that have
    /// to be forced open, and how many matches were left out.
    ///
    /// Computed once per filter change rather than per row. The obvious implementation — every
    /// disclosure row asking "should I be open?", each answer re-filtering the tree — is
    /// O(rows x tree) *per frame*, which wedged the main thread outright on a 5 000-request
    /// collection. The match cap is the other half of that fix: a broad query matches thousands of
    /// requests, and drawing thousands of force-expanded rows is slow no matter how fast the
    /// filtering is.
    var sidebarSnapshot: FilteredCollections {
        let query = appliedSidebarFilter.trimmingCharacters(in: .whitespaces)
        let key = SidebarCacheKey(
            query: query,
            collectionCount: workspace.collections.count,
            generation: sidebarCacheGeneration)
        if let cached = cachedSidebar, cached.key == key { return cached.snapshot }

        let snapshot = CollectionFilter.filter(
            workspace.collections, query: query, limit: Self.sidebarMatchLimit)
        cachedSidebar = (key, snapshot)
        return snapshot
    }

    /// How many matching requests the sidebar will draw before it stops and says so.
    static let sidebarMatchLimit = 200

    var filteredCollections: [RequestCollection] { sidebarSnapshot.collections }

    /// A binding for one disclosure triangle.
    ///
    /// While a filter is active every ancestor of a match is forced open — otherwise the results
    /// would be hidden inside collapsed folders — and the user's own expansion state is left
    /// untouched so it comes back when the filter is cleared.
    ///
    /// - Parameter forcedOpen: the snapshot's forced-open set, passed in so this does not have to
    ///   re-derive it for every row.
    func expansionBinding(for id: UUID, forcedOpen: Set<UUID>) -> Binding<Bool> {
        Binding(
            get: { [weak self] in
                guard let self else { return false }
                return forcedOpen.contains(id) || self.expandedIDs.contains(id)
            },
            set: { [weak self] isExpanded in
                guard let self else { return }
                if isExpanded { self.expandedIDs.insert(id) } else { self.expandedIDs.remove(id) }
                self.markUIStateDirty()
            })
    }

    /// Handles a sidebar drop. Returns true when something actually moved.
    func handleDrop(_ items: [DraggedItem], collectionID: UUID, parentID: UUID?) -> Bool {
        var moved = false
        for item in items {
            if move(
                itemWithID: item.id, toCollection: collectionID,
                target: DropTarget(parentID: parentID)) {
                moved = true
            }
        }
        if moved, let parentID { expandedIDs.insert(parentID) }
        return moved
    }
}

extension AppState {
    // MARK: - Collection and folder editor tabs

    /// Opens (or focuses) the tab that edits a collection's own settings.
    func openCollectionEditor(_ collectionID: UUID) {
        guard let collection = workspace.collection(withID: collectionID) else { return }
        openEditorTab(kind: .collection, subjectID: collectionID,
                      collectionID: collectionID, title: collection.name)
    }

    func openFolderEditor(_ folderID: UUID, in collectionID: UUID) {
        guard let folder = workspace.collection(withID: collectionID)?.folder(withID: folderID)
        else { return }
        openEditorTab(kind: .folder, subjectID: folderID,
                      collectionID: collectionID, title: folder.name)
    }

    private func openEditorTab(
        kind: TabKind, subjectID: UUID, collectionID: UUID, title: String
    ) {
        if let existing = tabs.first(where: { $0.kind == kind && $0.subjectID == subjectID }) {
            selectedTabID = existing.id
            markUIStateDirty()
            return
        }
        // `draft.name` is what the tab bar shows for a non-request tab.
        let tab = RequestTab(
            kind: kind, subjectID: subjectID, collectionID: collectionID,
            draft: RequestItem(name: title))
        if let index = tabs.firstIndex(where: { $0.isScratchAndUntouched }) {
            tabs[index] = tab
        } else {
            tabs.append(tab)
        }
        selectedTabID = tab.id
        markUIStateDirty()
    }
}

#if DEBUG
extension AppState {
    /// Adds a large generated collection so the sidebar can be measured at the scale §1 requires.
    func generateStressCollection(requestCount: Int = 5000) {
        let collection = RequestCollection.makeStressCollection(requestCount: requestCount)
        registerUndo(actionName: "Generate Stress Collection") { state in
            state.deleteCollection(id: collection.id, registerUndo: true)
        }
        workspace.collections.append(collection)
        workspace.collections.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        markDirty(collection: collection.id)
        markUIStateDirty()
    }
}
#endif
