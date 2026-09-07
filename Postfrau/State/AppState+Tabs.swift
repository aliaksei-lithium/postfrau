import Foundation
import PostfrauCore

extension AppState {
    var selectedTab: RequestTab? {
        tabs.first { $0.id == selectedTabID }
    }

    // MARK: - Opening

    /// Opens a new empty tab and selects it.
    @discardableResult
    func newTab() -> RequestTab {
        let tab = RequestTab(draft: RequestItem(name: "New Request"))
        tabs.append(tab)
        selectedTabID = tab.id
        markUIStateDirty()
        return tab
    }

    /// Opens a saved request, reusing an existing tab for it if one is already open.
    @discardableResult
    func openRequest(id requestID: UUID) -> RequestTab? {
        guard let collection = workspace.collectionContaining(itemID: requestID),
              let request = collection.request(withID: requestID)
        else { return nil }

        if let existing = tabs.first(where: { $0.requestID == requestID }) {
            selectedTabID = existing.id
            markUIStateDirty()
            return existing
        }

        let tab = RequestTab(requestID: requestID, collectionID: collection.id, draft: request)
        // Replace a pristine, empty "New Request" tab rather than piling up next to it.
        if let index = tabs.firstIndex(where: { $0.isScratchAndUntouched }) {
            tabs[index] = tab
        } else {
            tabs.append(tab)
        }
        selectedTabID = tab.id
        markUIStateDirty()
        return tab
    }

    /// Opens a history entry as an unsaved tab.
    @discardableResult
    func openHistoryEntry(_ entry: HistoryEntry) -> RequestTab {
        let tab = RequestTab(draft: entry.requestSnapshot, isFromHistory: true)
        tabs.append(tab)
        selectedTabID = tab.id
        markUIStateDirty()
        return tab
    }

    // MARK: - Closing

    func closeTab(_ tab: RequestTab) {
        guard let index = tabs.firstIndex(where: { $0.id == tab.id }) else { return }
        tab.sendTask?.cancel()
        tab.response?.body.discardTemporaryFile()
        tabs.remove(at: index)

        if selectedTabID == tab.id {
            selectedTabID = tabs.indices.contains(index)
                ? tabs[index].id
                : tabs.last?.id
        }
        if tabs.isEmpty { newTab() }
        markUIStateDirty()
    }

    /// Set by ⌘W when the selected tab has unsaved work; the tab bar shows the dialog.
    func closeSelectedTab() {
        guard let selectedTab else { return }
        if closingLosesWork(selectedTab) {
            tabPendingCloseConfirmation = selectedTab.id
        } else {
            closeTab(selectedTab)
        }
    }

    func closeOtherTabs(keeping tab: RequestTab) {
        for other in tabs where other.id != tab.id {
            other.sendTask?.cancel()
            other.response?.body.discardTemporaryFile()
        }
        tabs = [tab]
        selectedTabID = tab.id
        markUIStateDirty()
    }

    // MARK: - Navigating

    func selectNextTab() { cycleTab(by: 1) }
    func selectPreviousTab() { cycleTab(by: -1) }

    private func cycleTab(by offset: Int) {
        guard !tabs.isEmpty,
              let current = tabs.firstIndex(where: { $0.id == selectedTabID })
        else { return }
        let next = (current + offset + tabs.count) % tabs.count
        selectedTabID = tabs[next].id
        markUIStateDirty()
    }

    func selectTab(at index: Int) {
        guard tabs.indices.contains(index) else { return }
        selectedTabID = tabs[index].id
        markUIStateDirty()
    }

    func moveTab(from source: Int, to destination: Int) {
        guard tabs.indices.contains(source), destination >= 0, destination <= tabs.count else { return }
        let tab = tabs.remove(at: source)
        tabs.insert(tab, at: min(destination > source ? destination - 1 : destination, tabs.count))
        markUIStateDirty()
    }

    // MARK: - Saving a tab back into its collection

    /// Writes the tab's draft back to the collection it came from.
    /// Returns false when the tab has no home yet — the caller should offer "Save As…".
    @discardableResult
    func saveTab(_ tab: RequestTab) -> Bool {
        guard let collectionID = tab.collectionID, tab.requestID != nil,
              let index = workspace.collections.firstIndex(where: { $0.id == collectionID })
        else { return false }

        // The blank editor rows are scaffolding, not data; they never reach the collection.
        guard workspace.collections[index].replace(.request(tab.savableDraft)) else { return false }
        tab.markSaved()
        markDirty(collection: collectionID)
        markUIStateDirty()
        return true
    }

    /// The tab the close confirmation is about, if one is pending.
    var tabAwaitingCloseConfirmation: RequestTab? {
        tabPendingCloseConfirmation.flatMap { id in tabs.first { $0.id == id } }
    }

    /// Answers the pending close confirmation.
    func resolveCloseConfirmation(saving: Bool) {
        guard let tab = tabAwaitingCloseConfirmation else { return }
        tabPendingCloseConfirmation = nil
        if saving { saveTab(tab) }
        closeTab(tab)
    }

    /// True when closing this tab would throw away work the user could still save.
    func closingLosesWork(_ tab: RequestTab) -> Bool {
        tab.isDirty && tab.requestID != nil && !tab.isFromHistory
    }

    /// Renames a request everywhere at once: the open tab and the collection it lives in.
    func rename(_ tab: RequestTab, to newName: String) {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != tab.draft.name else { return }
        tab.draft.name = trimmed
        if tab.requestID != nil, tab.collectionID != nil {
            saveTab(tab)
        } else {
            markUIStateDirty()
        }
    }

    /// Renames a saved request from the sidebar, updating any tab that has it open.
    func renameRequest(id requestID: UUID, to newName: String) {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let collectionIndex = workspace.collections.firstIndex(
                where: { $0.item(withID: requestID) != nil }),
              var request = workspace.collections[collectionIndex].request(withID: requestID),
              request.name != trimmed
        else { return }

        request.name = trimmed
        workspace.collections[collectionIndex].replace(.request(request))
        markDirty(collection: workspace.collections[collectionIndex].id)

        for tab in tabs where tab.requestID == requestID {
            tab.draft.name = trimmed
            tab.savedSnapshot.name = trimmed
        }
        markUIStateDirty()
    }

    /// Called whenever the editor changes the draft.
    func draftChanged(_ tab: RequestTab) {
        markUIStateDirty()
    }
}

extension RequestTab {
    /// A never-edited "New Request" tab, which `openRequest` is free to replace.
    var isScratchAndUntouched: Bool {
        requestID == nil && !isFromHistory && !isDirty
            && draft.url.isEmpty && response == nil
    }
}

extension AppState {
    /// Flips the request/response split between stacked and side-by-side.
    func toggleResponseLayout() {
        settings.responseLayout = settings.responseLayout == .vertical ? .horizontal : .vertical
        markSettingsDirty()
    }
}
