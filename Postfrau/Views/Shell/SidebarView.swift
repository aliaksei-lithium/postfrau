import SwiftUI
import PostfrauCore

/// The left column: a filter field over collections and history.
struct SidebarView: View {
    @Environment(AppState.self) private var state

    enum Section: String, CaseIterable, Identifiable {
        case collections, history
        var id: String { rawValue }
        var title: String { self == .collections ? "Collections" : "History" }
    }

    @State private var section: Section = .collections

    var body: some View {
        @Bindable var state = state
        VStack(spacing: 0) {
            Picker("Sidebar section", selection: $section) {
                ForEach(Section.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 10)
            .padding(.vertical, 8)

            List(selection: $state.sidebarSelection) {
                switch section {
                case .collections:
                    if state.workspace.collections.isEmpty {
                        EmptyStateRow(
                            title: "No collections",
                            message: "Create a request with ⌘N, or import a Postman collection.")
                    } else {
                        CollectionsTree()
                    }
                case .history:
                    HistoryList()
                }
            }
            .listStyle(.sidebar)
            .searchable(
                text: $state.sidebarFilter, placement: .sidebar,
                prompt: section == .collections ? "Filter requests" : "Filter history")
        }
        .navigationSplitViewColumnWidth(min: 220, ideal: state.sidebarWidth, max: 460)
    }
}

struct EmptyStateRow: View {
    var title: String
    var message: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.callout.weight(.medium))
            Text(message).font(.caption).foregroundStyle(.secondary)
        }
        .padding(.vertical, 6)
        .selectionDisabled()
    }
}
