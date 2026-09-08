import Foundation

/// What an open tab is showing.
public enum TabKind: String, Sendable, Hashable, Codable {
    /// A request — the overwhelmingly common case.
    case request
    /// A collection's own settings: name, description, auth, variables.
    case collection
    /// A folder's settings.
    case folder
}

/// One open tab, as persisted across relaunches.
///
/// A request tab either shows a saved request (`requestID` set, `draft` holding unsaved edits) or
/// a scratch/history request that lives only in the tab (`requestID` nil). Collection and folder
/// tabs identify their subject with `subjectID` and ignore `draft`.
public struct TabState: Sendable, Hashable, Codable, Identifiable {
    public var id: UUID
    public var kind: TabKind
    /// The collection or folder a non-request tab is editing.
    public var subjectID: UUID?
    public var requestID: UUID?
    public var collectionID: UUID?
    /// The request as currently edited. Always present so a relaunch restores unsaved work.
    public var draft: RequestItem
    /// True when `draft` differs from what is saved in the collection.
    public var isDirty: Bool
    /// Set for tabs opened from history, which have no home in a collection.
    public var isFromHistory: Bool
    /// The history entry a `isFromHistory` tab was opened from. The recorded exchange itself is
    /// not duplicated here: it lives in the history log, and is re-attached on restore.
    public var historyEntryID: UUID?
    /// Which request sub-tab (Params/Headers/…) was showing.
    public var selectedEditorTab: String?

    public init(
        id: UUID = UUID(),
        kind: TabKind = .request,
        subjectID: UUID? = nil,
        requestID: UUID? = nil,
        collectionID: UUID? = nil,
        draft: RequestItem = RequestItem(),
        isDirty: Bool = false,
        isFromHistory: Bool = false,
        historyEntryID: UUID? = nil,
        selectedEditorTab: String? = nil
    ) {
        self.id = id
        self.kind = kind
        self.subjectID = subjectID
        self.requestID = requestID
        self.collectionID = collectionID
        self.draft = draft
        self.isDirty = isDirty
        self.isFromHistory = isFromHistory
        self.historyEntryID = historyEntryID
        self.selectedEditorTab = selectedEditorTab
    }

    private enum CodingKeys: String, CodingKey {
        case id, kind, subjectID, requestID, collectionID, draft, isDirty
        case isFromHistory, historyEntryID, selectedEditorTab
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        kind = try c.decodeIfPresent(TabKind.self, forKey: .kind) ?? .request
        subjectID = try c.decodeIfPresent(UUID.self, forKey: .subjectID)
        requestID = try c.decodeIfPresent(UUID.self, forKey: .requestID)
        collectionID = try c.decodeIfPresent(UUID.self, forKey: .collectionID)
        draft = try c.decodeIfPresent(RequestItem.self, forKey: .draft) ?? RequestItem()
        isDirty = try c.decodeIfPresent(Bool.self, forKey: .isDirty) ?? false
        isFromHistory = try c.decodeIfPresent(Bool.self, forKey: .isFromHistory) ?? false
        historyEntryID = try c.decodeIfPresent(UUID.self, forKey: .historyEntryID)
        selectedEditorTab = try c.decodeIfPresent(String.self, forKey: .selectedEditorTab)
    }
}

/// Window and navigation state. Machine-local; written to `ui-state.json`.
public struct UIState: Sendable, Hashable, Codable {
    public var tabs: [TabState]
    public var selectedTabID: UUID?
    public var activeEnvironmentID: UUID?
    public var expandedItemIDs: [UUID]
    public var sidebarWidth: Double
    /// Fraction of the detail pane given to the request editor, 0…1.
    public var requestPaneFraction: Double
    /// `NSWindow.frameDescriptor` string, restored verbatim.
    public var windowFrame: String?
    public var sidebarSection: String?

    public init(
        tabs: [TabState] = [],
        selectedTabID: UUID? = nil,
        activeEnvironmentID: UUID? = nil,
        expandedItemIDs: [UUID] = [],
        sidebarWidth: Double = 260,
        requestPaneFraction: Double = 0.45,
        windowFrame: String? = nil,
        sidebarSection: String? = nil
    ) {
        self.tabs = tabs
        self.selectedTabID = selectedTabID
        self.activeEnvironmentID = activeEnvironmentID
        self.expandedItemIDs = expandedItemIDs
        self.sidebarWidth = sidebarWidth
        self.requestPaneFraction = requestPaneFraction
        self.windowFrame = windowFrame
        self.sidebarSection = sidebarSection
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, tabs, selectedTabID, activeEnvironmentID, expandedItemIDs
        case sidebarWidth, requestPaneFraction, windowFrame, sidebarSection
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = UIState()
        tabs = try c.decodeIfPresent([TabState].self, forKey: .tabs) ?? []
        selectedTabID = try c.decodeIfPresent(UUID.self, forKey: .selectedTabID)
        activeEnvironmentID = try c.decodeIfPresent(UUID.self, forKey: .activeEnvironmentID)
        expandedItemIDs = try c.decodeIfPresent([UUID].self, forKey: .expandedItemIDs) ?? []
        sidebarWidth = try c.decodeIfPresent(Double.self, forKey: .sidebarWidth) ?? d.sidebarWidth
        requestPaneFraction =
            try c.decodeIfPresent(Double.self, forKey: .requestPaneFraction) ?? d.requestPaneFraction
        windowFrame = try c.decodeIfPresent(String.self, forKey: .windowFrame)
        sidebarSection = try c.decodeIfPresent(String.self, forKey: .sidebarSection)
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(Postfrau.schemaVersion, forKey: .schemaVersion)
        try c.encode(tabs, forKey: .tabs)
        try c.encodeIfPresent(selectedTabID, forKey: .selectedTabID)
        try c.encodeIfPresent(activeEnvironmentID, forKey: .activeEnvironmentID)
        try c.encode(expandedItemIDs, forKey: .expandedItemIDs)
        try c.encode(sidebarWidth, forKey: .sidebarWidth)
        try c.encode(requestPaneFraction, forKey: .requestPaneFraction)
        try c.encodeIfPresent(windowFrame, forKey: .windowFrame)
        try c.encodeIfPresent(sidebarSection, forKey: .sidebarSection)
    }
}
