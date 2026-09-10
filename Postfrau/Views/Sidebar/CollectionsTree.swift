import SwiftUI
import UniformTypeIdentifiers
import PostfrauCore

/// The collections outline: create, rename, duplicate, delete, and drag to reorder or re-home.
struct CollectionsTree: View {
    @Environment(AppState.self) private var state

    var body: some View {
        // One snapshot for the whole tree: the filtered collections and the folders that have to
        // be forced open. Deriving either per row is what made a 5 000-request collection unusable.
        let snapshot = state.sidebarSnapshot

        if snapshot.collections.isEmpty {
            EmptyStateRow(
                title: state.sidebarFilter.isEmpty ? "No collections" : "No matches",
                message: state.sidebarFilter.isEmpty
                    ? "Create one with ⌘⇧N, or import a Postman collection."
                    : "Nothing matches “\(state.sidebarFilter)”.")
        } else {
            ForEach(snapshot.collections) { collection in
                CollectionRow(collection: collection, forcedOpen: snapshot.forcedOpenIDs)
            }
            if snapshot.isTruncated {
                Text("Showing \(AppState.sidebarMatchLimit) of \(snapshot.totalMatches) matches — "
                    + "narrow the filter to see the rest.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.vertical, 4)
                .selectionDisabled()
            }
        }
    }
}

/// The wash under a hovered sidebar row.
///
/// `listRowBackground` rather than `background`, so it takes the row's own shape and inset
/// instead of hugging the text. Never drawn under a selected row: `List` draws its highlight
/// there, and tinting over the top of it only muddies the blue.
///
/// The pointer is watched on that background too, not on the row's content. A nested row's
/// content starts after the disclosure indent — some 40 points in — so hovering the left edge of
/// a row lit nothing, even though the wash that would appear covers the whole width. The
/// background is the only part of the row that is actually the width of the row.
private struct RowHover: ViewModifier {
    var isSelected = false

    @State private var isHovering = false

    func body(content: Content) -> some View {
        content.listRowBackground(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.primary.opacity(isHovering && !isSelected ? 0.06 : 0))
                .padding(.horizontal, 10)
                .contentShape(.rect)
                .onHover { isHovering = $0 })
    }
}

extension View {
    fileprivate func rowHover(isSelected: Bool = false) -> some View {
        modifier(RowHover(isSelected: isSelected))
    }
}

struct CollectionRow: View {
    @Environment(AppState.self) private var state
    var collection: RequestCollection
    var forcedOpen: Set<UUID>

    @State private var isRenaming = false
    @State private var draftName = ""
    @State private var isConfirmingDelete = false
    @FocusState private var renameFocused: Bool

    private var isMissing: Bool {
        state.missingCollections.contains { $0.id == collection.id }
    }

    private var isDownloading: Bool {
        state.downloadingDocuments.contains(collection.id)
    }

    /// Says what sync is doing to this collection: still coming down from iCloud, or gone from
    /// the folder entirely. The banner carries the actions; this is only the marker.
    @ViewBuilder
    private var syncMarker: some View {
        if isDownloading {
            ProgressView()
                .controlSize(.mini)
                .help("Downloading from iCloud")
        } else if isMissing {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(.orange)
                .help("This collection is no longer in the data folder")
        }
    }

    private var syncDescription: String {
        if isDownloading { return ", downloading from iCloud" }
        if isMissing { return ", missing from the data folder" }
        return ""
    }

    var body: some View {
        DisclosureGroup(
            isExpanded: state.expansionBinding(for: collection.id, forcedOpen: forcedOpen)
        ) {
            ItemRows(
                items: collection.items, collectionID: collection.id, parentID: nil,
                forcedOpen: forcedOpen)
            // A drop onto the collection itself lands at the root of its tree.
            .dropDestination(for: DraggedItem.self) { items, _ in
                return state.handleDrop(items, collectionID: collection.id, parentID: nil)
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "shippingbox").foregroundStyle(.secondary)
                if isRenaming {
                    TextField("Name", text: $draftName)
                        .textFieldStyle(.plain)
                        .focused($renameFocused)
                        .onSubmit(commitRename)
                        .onExitCommand { isRenaming = false }
                        .onChange(of: renameFocused) { _, focused in if !focused { commitRename() } }
                } else {
                    HighlightedText(collection.name, matching: state.sidebarFilter)
                        .font(.callout.weight(.medium))
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                syncMarker
            }
            .accessibilityElement(children: isRenaming ? .contain : .ignore)
            .accessibilityLabel("Collection \(collection.name)\(syncDescription)")
            .contentShape(.rect)
            // Collections and folders carry no `.tag`, so they are not selectable and a plain
            // tap gesture costs nothing here. Requests are the ones that had to change.
            .onTapGesture(count: 2) { state.openCollectionEditor(collection.id) }
            .contextMenu { menu }
            .dropDestination(for: DraggedItem.self) { items, _ in
                return state.handleDrop(items, collectionID: collection.id, parentID: nil)
            }
            .confirmationDialog(
                "Delete “\(collection.name)”?", isPresented: $isConfirmingDelete
            ) {
                Button("Delete", role: .destructive) { state.deleteCollection(id: collection.id) }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("\(collection.requestCount) request(s) will be removed. This can be undone.")
            }
        }
        .rowHover()
    }

    @ViewBuilder
    private var menu: some View {
        Button("New Request") { state.newRequest(in: collection.id, parentID: nil) }
        Button("New Folder") { state.newFolder(in: collection.id, parentID: nil) }
        Divider()
        Button("Edit Collection…") { state.openCollectionEditor(collection.id) }
        Button("Rename…") { beginRename() }
        Button("Duplicate") { state.duplicateCollection(id: collection.id) }
        Divider()
        Button("Export as Postman Collection…") { state.exportCollection(collection.id) }
        Divider()
        Button("Delete…", role: .destructive) { isConfirmingDelete = true }
    }

    private func beginRename() {
        draftName = collection.name
        isRenaming = true
        renameFocused = true
    }

    private func commitRename() {
        guard isRenaming else { return }
        isRenaming = false
        let trimmed = draftName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != collection.name else { return }
        var updated = collection
        updated.name = trimmed
        state.updateCollection(updated, actionName: "Rename Collection")
    }
}

/// One level of the tree.
struct ItemRows: View {
    @Environment(AppState.self) private var state
    var items: [CollectionItem]
    var collectionID: UUID
    var parentID: UUID?
    var forcedOpen: Set<UUID>

    var body: some View {
        ForEach(items) { item in
            switch item {
            case .folder(let folder):
                FolderRow(folder: folder, collectionID: collectionID, forcedOpen: forcedOpen)
            case .request(let request):
                RequestRow(request: request, collectionID: collectionID)
            }
        }
    }
}

struct FolderRow: View {
    @Environment(AppState.self) private var state
    var folder: Folder
    var collectionID: UUID
    var forcedOpen: Set<UUID>

    @State private var isRenaming = false
    @State private var draftName = ""
    @FocusState private var renameFocused: Bool

    var body: some View {
        DisclosureGroup(
            isExpanded: state.expansionBinding(for: folder.id, forcedOpen: forcedOpen)
        ) {
            ItemRows(
                items: folder.items, collectionID: collectionID, parentID: folder.id,
                forcedOpen: forcedOpen)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "folder").foregroundStyle(.secondary)
                if isRenaming {
                    TextField("Name", text: $draftName)
                        .textFieldStyle(.plain)
                        .focused($renameFocused)
                        .onSubmit(commitRename)
                        .onExitCommand { isRenaming = false }
                        .onChange(of: renameFocused) { _, focused in if !focused { commitRename() } }
                } else {
                    HighlightedText(folder.name, matching: state.sidebarFilter).lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .accessibilityElement(children: isRenaming ? .contain : .ignore)
            .accessibilityLabel("Folder \(folder.name)")
            .contentShape(.rect)
            .onTapGesture(count: 2) { state.openFolderEditor(folder.id, in: collectionID) }
            .contextMenu {
                Button("New Request") { state.newRequest(in: collectionID, parentID: folder.id) }
                Button("New Folder") { state.newFolder(in: collectionID, parentID: folder.id) }
                Divider()
                Button("Edit Folder…") { state.openFolderEditor(folder.id, in: collectionID) }
                Button("Rename…") { beginRename() }
                Button("Duplicate") { state.duplicate(itemWithID: folder.id) }
                Divider()
                Button("Delete", role: .destructive) { state.delete(itemWithID: folder.id) }
            }
            .draggable(DraggedItem(id: folder.id, collectionID: collectionID))
            .dropDestination(for: DraggedItem.self) { items, _ in
                return state.handleDrop(items, collectionID: collectionID, parentID: folder.id)
            }
        }
        .rowHover()
    }

    private func beginRename() {
        draftName = folder.name
        isRenaming = true
        renameFocused = true
    }

    private func commitRename() {
        guard isRenaming else { return }
        isRenaming = false
        let trimmed = draftName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != folder.name else { return }
        var updated = folder
        updated.name = trimmed
        state.updateFolder(updated, in: collectionID)
    }
}

struct RequestRow: View {
    @Environment(AppState.self) private var state
    // Set by `List` on the selected row. Read here rather than comparing against
    // `state.sidebarSelection`, which would make all forty rows rebuild on every selection change.
    @Environment(\.backgroundProminence) private var prominence
    var request: RequestItem
    var collectionID: UUID

    @State private var isRenaming = false
    @State private var draftName = ""
    @FocusState private var renameFocused: Bool

    private var isSelected: Bool { prominence == .increased }

    var body: some View {
        HStack(spacing: 6) {
            MethodBadge(method: request.method).accessibilityHidden(true)
            if isRenaming {
                TextField("Name", text: $draftName)
                    .textFieldStyle(.plain)
                    .focused($renameFocused)
                    .onSubmit(commitRename)
                    .onExitCommand { isRenaming = false }
                    .onChange(of: renameFocused) { _, focused in if !focused { commitRename() } }
                    .accessibilityLabel("Rename \(request.name)")
            } else {
                HighlightedText(request.name, matching: state.sidebarFilter).lineLimit(1)
            }
            // Fills the row, the way `CollectionRow` and `FolderRow` already did. Without it the
            // content is only as wide as the name, so hovering — or right-clicking — the empty
            // space beside a short name did nothing.
            Spacer(minLength: 0)
        }
        // `.ignore` plus an explicit label: the row is one element that reads "GET List", rather
        // than two unnamed fragments that VoiceOver cannot make sense of.
        .accessibilityElement(children: isRenaming ? .contain : .ignore)
        .accessibilityLabel("\(request.method.rawValue) \(request.name)")
        .accessibilityAddTraits(.isButton)
        .contentShape(.rect)
        // No tap gesture of any kind on the row.
        //
        // Selection is the list's own, and `PressToSelect` moves it onto the press so the
        // highlight does not wait for the button to come up. Opening on double click is the
        // list's `primaryAction`. Both live outside this view because every gesture tried here
        // cost something: a `count: 2` tap swallows single clicks so the list stops selecting,
        // pairing it with a single tap holds that click for the whole double-click interval, and
        // any gesture at all — `simultaneousGesture` included — stops `draggable` ever starting.
        // See `docs/decisions.md` D54 and D55.
        .rowHover(isSelected: isSelected)
        .contextMenu {
            Button("Open") { state.openRequest(id: request.id) }
            Button("Rename…") { beginRename() }
            Button("Duplicate") { state.duplicate(itemWithID: request.id) }
            Divider()
            Button("Delete", role: .destructive) { state.delete(itemWithID: request.id) }
        }
        .draggable(DraggedItem(id: request.id, collectionID: collectionID))
        .tag(request.id)
    }

    private func beginRename() {
        draftName = request.name
        isRenaming = true
        renameFocused = true
    }

    private func commitRename() {
        guard isRenaming else { return }
        isRenaming = false
        state.renameRequest(id: request.id, to: draftName)
    }
}

/// Text with the sidebar filter's match highlighted.
struct HighlightedText: View {
    var text: String
    var needle: String

    init(_ text: String, matching needle: String) {
        self.text = text
        self.needle = needle.trimmingCharacters(in: .whitespaces)
    }

    var body: some View {
        if needle.isEmpty || !text.localizedCaseInsensitiveContains(needle) {
            Text(text)
        } else {
            // One attributed run per match keeps this cheap even in a long list.
            Text(attributed)
        }
    }

    private var attributed: AttributedString {
        var result = AttributedString(text)
        var searchRange = result.startIndex..<result.endIndex
        while let found = result[searchRange].range(of: needle, options: .caseInsensitive) {
            result[found].inlinePresentationIntent = .stronglyEmphasized
            result[found].foregroundColor = .accentColor
            guard found.upperBound < result.endIndex else { break }
            searchRange = found.upperBound..<result.endIndex
        }
        return result
    }
}

/// What a sidebar drag carries: which item, and which collection it came from.
struct DraggedItem: Codable, Transferable, Sendable {
    var id: UUID
    var collectionID: UUID

    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .postfrauItem)
    }
}

extension UTType {
    /// A private type, so a drag out of Postfrau's sidebar cannot be dropped somewhere it would
    /// be meaningless.
    nonisolated static let postfrauItem = UTType(exportedAs: "com.postfrau.collection-item")
}
