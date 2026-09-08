import SwiftUI
import PostfrauCore

/// The strip above the editor that reports what arrived from another Mac.
///
/// Non-modal on purpose: a sync client delivers a change whenever it finishes uploading, and a
/// dialog that took the keyboard mid-edit would be worse than the conflict it announces. Nothing
/// here is urgent — the other side is already saved to `conflicts/` before the banner appears.
struct SyncBanners: View {
    @Environment(AppState.self) private var state

    var body: some View {
        VStack(spacing: 0) {
            ForEach(state.syncConflicts) { conflict in
                ConflictBanner(conflict: conflict)
                Divider()
            }
            ForEach(state.missingCollections) { missing in
                MissingBanner(missing: missing)
                Divider()
            }
        }
    }
}

private struct ConflictBanner: View {
    @Environment(AppState.self) private var state
    var conflict: AppState.SyncConflict

    var body: some View {
        BannerRow(symbol: "arrow.triangle.branch", tint: .orange) {
            Text("**\(conflict.documentName)** changed on another Mac")
            Text("Your unsaved edits are still here. The other version is saved as a copy.")
                .font(.caption)
                .foregroundStyle(.secondary)
        } actions: {
            Button("Keep Mine") { state.keepMine(conflict) }
            Button("Take Theirs") { Task { await state.takeTheirs(conflict) } }
            Button("Show Both") { state.showBoth(conflict) }
        }
    }
}

private struct MissingBanner: View {
    @Environment(AppState.self) private var state
    var missing: AppState.MissingCollection

    var body: some View {
        BannerRow(symbol: "questionmark.folder", tint: .orange) {
            Text("**\(missing.name)** is no longer in the data folder")
            Text("It was removed by something else — another Mac, or the Finder.")
                .font(.caption)
                .foregroundStyle(.secondary)
        } actions: {
            Button("Restore from Memory") { state.restoreMissing(missing) }
            Button("Remove Here Too") { state.forgetMissing(missing) }
        }
    }
}

/// One banner: an icon, two lines, and the choices.
private struct BannerRow<Content: View, Actions: View>: View {
    var symbol: String
    var tint: Color
    @ViewBuilder var content: Content
    @ViewBuilder var actions: Actions

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .foregroundStyle(tint)
                .imageScale(.large)
            VStack(alignment: .leading, spacing: 1) { content }
            Spacer(minLength: 8)
            HStack(spacing: 6) { actions }
                .controlSize(.small)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tint.opacity(0.10))
        .accessibilityElement(children: .contain)
    }
}

/// The status bar's sync chip: which folder, and when something last arrived in it.
struct SyncChip: View {
    @Environment(AppState.self) private var state
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        Button {
            openSettings()
        } label: {
            HStack(spacing: 4) {
                Image(systemName: state.dataFolder.provider.symbolName)
                Text(label)
            }
        }
        .buttonStyle(.borderless)
        .foregroundStyle(isHealthy ? .secondary : Color.orange)
        .help(helpText)
        .accessibilityLabel("Data folder: \(label). Opens settings.")
    }

    private var isHealthy: Bool { state.dataFolder.status == .ok }

    private var label: String {
        guard isHealthy else { return "folder unavailable" }
        guard let last = state.lastExternalChange else {
            return state.dataFolder.isDefault ? "local" : "watching"
        }
        // A change that just landed formats as "in 0 seconds" through the relative style, which
        // reads as the future. Anything inside a minute is simply "just now".
        let elapsed = Date().timeIntervalSince(last)
        guard elapsed >= 60 else { return "synced just now" }
        return "synced \(last.formatted(.relative(presentation: .numeric)))"
    }

    private var helpText: String {
        let where_ = state.dataFolder.isDefault
            ? "Postfrau's own folder" : state.dataFolder.root.path
        return "\(state.dataFolder.provider.displayName) · \(where_)"
    }
}
