import SwiftUI
import PostfrauCore

/// History, newest first, grouped by day.
struct HistoryList: View {
    @Environment(AppState.self) private var state

    var body: some View {
        let groups = state.groupedHistory
        if groups.isEmpty {
            EmptyStateRow(
                title: "No history yet",
                message: "Every request you send is recorded here.")
        } else {
            ForEach(groups, id: \.title) { group in
                Section(group.title) {
                    ForEach(group.entries) { entry in
                        HistoryRow(entry: entry)
                            .contentShape(.rect)
                            .onTapGesture(count: 2) { state.openHistoryEntry(entry) }
                    }
                }
            }
        }
    }
}

struct HistoryRow: View {
    var entry: HistoryEntry

    var body: some View {
        HStack(spacing: 6) {
            MethodBadge(method: entry.method)
            Text(entry.displayPath).lineLimit(1).truncationMode(.middle)
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
                + (entry.statusCode.map { "status \($0)" } ?? "failed"))
    }
}

extension AppState {
    struct HistoryGroup {
        var title: String
        var entries: [HistoryEntry]
    }

    /// History filtered by the sidebar field and split into day sections.
    var groupedHistory: [HistoryGroup] {
        let needle = sidebarFilter.trimmingCharacters(in: .whitespaces).lowercased()
        let matching = needle.isEmpty
            ? historyEntries
            : historyEntries.filter {
                $0.resolvedURL.lowercased().contains(needle)
                    || $0.method.rawValue.lowercased().contains(needle)
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
