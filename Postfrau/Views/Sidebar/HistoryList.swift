import SwiftUI
import PostfrauCore

/// History, newest first, grouped by day.
struct HistoryList: View {
    @Environment(AppState.self) private var state

    var body: some View {
        let groups = state.groupedHistory
        if groups.isEmpty {
            EmptyStateRow(
                title: state.historyEntries.isEmpty ? "No history yet" : "No matches",
                message: state.historyEntries.isEmpty
                    ? "Every request you send is recorded here."
                    : "No recorded send matches this filter.")
        } else {
            ForEach(groups, id: \.title) { group in
                Section(group.title) {
                    ForEach(group.entries) { entry in
                        HistoryRow(entry: entry)
                            .contentShape(.rect)
                            .onTapGesture(count: 2) { state.openHistoryEntry(entry) }
                            .contextMenu { HistoryEntryMenu(entry: entry) }
                    }
                }
            }
        }
    }
}

/// The actions on one recorded send. Shared by the row's context menu and the History menu.
struct HistoryEntryMenu: View {
    @Environment(AppState.self) private var state
    var entry: HistoryEntry

    var body: some View {
        Button("Open in a Tab") { state.openHistoryEntry(entry) }
        Menu("Save to Collection") {
            if state.workspace.collections.isEmpty {
                Text("No collections yet")
            } else {
                ForEach(state.workspace.collections) { collection in
                    Button(collection.name) {
                        state.saveHistoryEntryToCollection(entry, collectionID: collection.id)
                    }
                }
            }
        }
        Divider()
        Button("Copy URL") { Pasteboard.copy(entry.resolvedURL) }
        Button("Delete", role: .destructive) { state.deleteHistoryEntry(entry) }
    }
}

struct HistoryRow: View {
    var entry: HistoryEntry

    var body: some View {
        HStack(spacing: 6) {
            MethodBadge(method: entry.method)
            VStack(alignment: .leading, spacing: 1) {
                Text(entry.displayPath).lineLimit(1).truncationMode(.middle)
                HStack(spacing: 4) {
                    // Non-app sends carry a badge; the app is the unremarkable case and gets none.
                    if entry.source.isAutomated {
                        Label(entry.source.displayName, systemImage: entry.source.symbolName)
                            .labelStyle(.titleAndIcon)
                            .font(.caption2)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(.quaternary, in: .capsule)
                    }
                    Text(entry.sentAt, format: .relative(presentation: .numeric))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            Spacer(minLength: 4)
            if let status = entry.statusCode {
                Text("\(status)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(status < 400 ? Color.secondary : .red)
            } else {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .help(entry.error ?? "Failed")
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "\(entry.method.rawValue) \(entry.displayPath), "
                + (entry.statusCode.map { "status \($0)" } ?? "failed")
                + (entry.source.isAutomated ? ", sent by \(entry.source.displayName)" : ""))
    }
}

/// The filter row above the history list: source, and a shortcut for the agent case.
struct HistoryFilterBar: View {
    @Environment(AppState.self) private var state

    var body: some View {
        @Bindable var state = state
        HStack(spacing: 8) {
            Picker("Sent by", selection: $state.historySourceFilter) {
                ForEach(AppState.HistorySourceFilter.allCases) { Text($0.displayName).tag($0) }
            }
            .labelsHidden()
            .controlSize(.small)
            .accessibilityLabel("Filter history by who sent it")

            Spacer()

            Button("Clear…", role: .destructive) { state.isConfirmingClearHistory = true }
                .controlSize(.small)
                .buttonStyle(.borderless)
                .disabled(state.historyEntries.isEmpty)
                .help("Delete every recorded send")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
    }
}

extension AppState {
    struct HistoryGroup {
        var title: String
        var entries: [HistoryEntry]
    }

    /// History filtered by the sidebar field and the source picker, split into day sections.
    var groupedHistory: [HistoryGroup] {
        let needle = sidebarFilter.trimmingCharacters(in: .whitespaces).lowercased()
        let matching = historyEntries.filter { entry in
            guard historySourceFilter.matches(entry) else { return false }
            guard !needle.isEmpty else { return true }
            return entry.resolvedURL.lowercased().contains(needle)
                || entry.method.rawValue.lowercased().contains(needle)
                || entry.source.displayName.lowercased().contains(needle)
        }

        var order: [String] = []
        var buckets: [String: [HistoryEntry]] = [:]
        for entry in matching {
            let title = Self.dayTitle(for: entry.sentAt)
            if buckets[title] == nil { order.append(title) }
            buckets[title, default: []].append(entry)
        }
        return order.map { HistoryGroup(title: $0, entries: buckets[$0] ?? []) }
    }

    static func dayTitle(for date: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) { return "Today" }
        if calendar.isDateInYesterday(date) { return "Yesterday" }
        return date.formatted(.dateTime.weekday(.wide).month().day())
    }
}
