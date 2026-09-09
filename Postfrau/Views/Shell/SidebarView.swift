import SwiftUI
import PostfrauCore

/// The left column: a filter field over collections and history.
struct SidebarView: View {
    @Environment(AppState.self) private var state

    var body: some View {
        @Bindable var state = state
        let section = state.sidebarSection
        VStack(spacing: 0) {
            Picker("Sidebar section", selection: $state.sidebarSection) {
                ForEach(AppState.SidebarSection.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 10)
            .padding(.vertical, 8)

            if section == .history { HistoryFilterBar() }

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
            .onChange(of: state.sidebarSelection) { ClickProbe.marked("select") }
            // Dropping a file on the sidebar is the other obvious way to import one.
            .dropDestination(for: URL.self) { urls, _ in
                guard let url = urls.first else { return false }
                Task { await state.importFile(at: url) }
                return true
            }
            .searchable(
                text: $state.sidebarFilter, placement: .sidebar,
                prompt: section == .collections ? "Filter requests" : "Filter history")
            .confirmationDialog(
                "Delete all history?",
                isPresented: $state.isConfirmingClearHistory,
                titleVisibility: .visible
            ) {
                Button("Delete All", role: .destructive) { state.clearHistory() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("\(state.historyEntries.count) recorded send(s) will be removed from this Mac.")
            }
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
