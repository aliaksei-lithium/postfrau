import SwiftUI
import PostfrauCore

/// The collections outline. Read-only in Phase 3; editing arrives in Phase 6.
struct CollectionsTree: View {
    @Environment(AppState.self) private var state

    var body: some View {
        @Bindable var state = state
        ForEach(state.workspace.collections) { collection in
            DisclosureGroup(isExpanded: expansion(for: collection.id)) {
                ItemRows(items: collection.items)
            } label: {
                Label(collection.name, systemImage: "shippingbox")
                    .font(.callout.weight(.medium))
                    .accessibilityLabel("Collection \(collection.name)")
            }
        }
    }

    private func expansion(for id: UUID) -> Binding<Bool> {
        Binding(
            get: { state.expandedIDs.contains(id) },
            set: { isExpanded in
                if isExpanded { state.expandedIDs.insert(id) } else { state.expandedIDs.remove(id) }
                state.markUIStateDirty()
            })
    }
}

/// One level of the tree. Split out so the recursion is explicit and cheap.
struct ItemRows: View {
    @Environment(AppState.self) private var state
    var items: [CollectionItem]

    var body: some View {
        ForEach(items) { item in
            switch item {
            case .folder(let folder):
                DisclosureGroup(isExpanded: expansion(for: folder.id)) {
                    ItemRows(items: folder.items)
                } label: {
                    Label(folder.name, systemImage: "folder")
                        .accessibilityLabel("Folder \(folder.name)")
                }
            case .request(let request):
                RequestRow(request: request)
            }
        }
    }

    private func expansion(for id: UUID) -> Binding<Bool> {
        Binding(
            get: { state.expandedIDs.contains(id) },
            set: { isExpanded in
                if isExpanded { state.expandedIDs.insert(id) } else { state.expandedIDs.remove(id) }
                state.markUIStateDirty()
            })
    }
}

struct RequestRow: View {
    @Environment(AppState.self) private var state
    var request: RequestItem

    var body: some View {
        HStack(spacing: 6) {
            MethodBadge(method: request.method).accessibilityHidden(true)
            Text(request.name).lineLimit(1)
        }
        // `.ignore` plus an explicit label: the row is one element that reads "GET List", rather
        // than two unnamed fragments that VoiceOver cannot make sense of.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(request.method.rawValue) \(request.name)")
        .accessibilityAddTraits(.isButton)
        .contentShape(.rect)
        .onTapGesture(count: 2) { state.openRequest(id: request.id) }
        .tag(request.id)
    }
}
