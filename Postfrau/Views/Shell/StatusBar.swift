import SwiftUI
import PostfrauCore

/// The thin bar along the bottom: what is loaded, whether it is saved, which environment is active.
struct StatusBar: View {
    @Environment(AppState.self) private var state

    var body: some View {
        HStack(spacing: 12) {
            Text(countsSummary)
            if !state.loadIssues.isEmpty {
                let detail = state.loadIssues
                    .map { "\($0.file): \($0.message)" }
                    .joined(separator: "\n")
                Label(
                    "\(state.loadIssues.count) file(s) could not be read",
                    systemImage: "exclamationmark.triangle")
                .foregroundStyle(.orange)
                .help(detail)
                .accessibilityLabel("Could not read \(state.loadIssues.count) file(s). \(detail)")
            }
            Spacer()
            saveIndicator
            Divider().frame(height: 12)
            Text(state.workspace.activeEnvironment?.name ?? "No environment")
                .foregroundStyle(.secondary)
        }
        .font(.caption)
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
        .frame(height: 22)
        .background(.bar)
        .overlay(alignment: .top) {
            Rectangle().fill(Color(nsColor: .separatorColor)).frame(height: 1)
        }
        .accessibilityElement(children: .contain)
    }

    private var countsSummary: String {
        let collections = state.workspace.collections.count
        let requests = state.workspace.totalRequestCount
        return "\(collections) collection\(collections == 1 ? "" : "s") · "
            + "\(requests) request\(requests == 1 ? "" : "s") · "
            + "history \(state.historyEntries.count)"
    }

    @ViewBuilder
    private var saveIndicator: some View {
        switch state.saveState {
        case .idle:
            EmptyView()
        case .saving:
            Label("Saving…", systemImage: "arrow.triangle.2.circlepath")
                .foregroundStyle(.secondary)
        case .saved:
            Label("Saved", systemImage: "checkmark")
                .foregroundStyle(.secondary)
        case .failed(let message):
            Label("Save failed", systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
                .help(message)
        }
    }
}
