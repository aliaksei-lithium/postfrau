import Foundation
import PostfrauCore

/// Which sub-tab of the request editor is showing.
enum EditorTab: String, CaseIterable, Identifiable, Sendable {
    case params, headers, auth, body, settings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .params: "Params"
        case .headers: "Headers"
        case .auth: "Auth"
        case .body: "Body"
        case .settings: "Settings"
        }
    }
}

/// Which view of the response is showing.
enum ResponseTab: String, CaseIterable, Identifiable, Sendable {
    case pretty, raw, preview, headers, cookies

    var id: String { rawValue }

    var title: String {
        switch self {
        case .pretty: "Pretty"
        case .raw: "Raw"
        case .preview: "Preview"
        case .headers: "Headers"
        case .cookies: "Cookies"
        }
    }
}

/// One open tab: an editable draft plus whatever the last send produced.
///
/// The saved snapshot is what the collection holds; `isDirty` is the difference between the two.
/// Response state lives here rather than in `AppState` so switching tabs restores what you were
/// looking at.
@Observable
final class RequestTab: Identifiable {
    let id: UUID
    /// The request this tab edits, when it is saved in a collection.
    var requestID: UUID?
    var collectionID: UUID?
    var draft: RequestItem
    /// The last state that was saved (or loaded). `nil` only while a tab is being constructed.
    var savedSnapshot: RequestItem
    /// True for tabs opened from history: they have no home in a collection.
    var isFromHistory: Bool

    var response: HTTPResponse?
    var errorMessage: String?
    var warnings: [String] = []
    var isSending = false
    /// Set while a send is in flight so Esc / the Cancel button can stop it.
    @ObservationIgnored var sendTask: Task<Void, Never>?

    var selectedEditorTab: EditorTab = .params
    var selectedResponseTab: ResponseTab = .pretty

    init(
        id: UUID = UUID(),
        requestID: UUID? = nil,
        collectionID: UUID? = nil,
        draft: RequestItem,
        isFromHistory: Bool = false
    ) {
        self.id = id
        self.requestID = requestID
        self.collectionID = collectionID
        self.draft = draft
        self.savedSnapshot = draft
        self.isFromHistory = isFromHistory
    }

    var isDirty: Bool { draft != savedSnapshot }

    /// What the tab bar shows.
    var title: String {
        if isFromHistory { return "History · \(draft.method.rawValue) \(shortPath)" }
        if !draft.name.isEmpty && draft.name != "New Request" { return draft.name }
        return draft.url.isEmpty ? "New Request" : shortPath
    }

    private var shortPath: String {
        let stripped = draft.url
            .replacingOccurrences(of: "https://", with: "")
            .replacingOccurrences(of: "http://", with: "")
        return stripped.isEmpty ? "New Request" : stripped
    }

    /// Discards the previous response's spill file before a new send replaces it.
    func clearResponse() {
        response?.body.discardTemporaryFile()
        response = nil
        errorMessage = nil
        warnings = []
    }

    func markSaved() {
        savedSnapshot = draft
    }

    /// The persisted form of this tab.
    func snapshot() -> TabState {
        TabState(
            id: id,
            requestID: requestID,
            collectionID: collectionID,
            draft: draft,
            isDirty: isDirty,
            isFromHistory: isFromHistory,
            selectedEditorTab: selectedEditorTab.rawValue)
    }

    convenience init(restoring state: TabState) {
        self.init(
            id: state.id,
            requestID: state.requestID,
            collectionID: state.collectionID,
            draft: state.draft,
            isFromHistory: state.isFromHistory)
        selectedEditorTab = state.selectedEditorTab.flatMap(EditorTab.init(rawValue:)) ?? .params
        // The restored draft is treated as clean here. A tab backed by a saved request gets its
        // real saved copy re-attached in `AppState.restore`, which is what makes the dirty dot
        // come back; a scratch tab has nothing to compare against, so "dirty" is meaningless.
    }
}
