import SwiftUI
import PostfrauCore

/// What an import did, and what it could not do.
///
/// Shown after the fact rather than as a confirmation: the import has already happened and can be
/// undone with ⌘Z, so the sheet is a report, not a gate. The warnings are the point — an import
/// that quietly dropped a file attachment or an auth scheme is how people lose an afternoon.
struct ImportReportSheet: View {
    var report: AppState.ImportReport
    var onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: report.warnings.isEmpty
                      ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .imageScale(.large)
                .foregroundStyle(report.warnings.isEmpty ? Color.green : .orange)
                VStack(alignment: .leading, spacing: 2) {
                    Text(report.title).font(.headline)
                    Text(report.detail)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }

            if !report.warnings.isEmpty {
                Divider()
                Text("\(report.warnings.count) thing(s) need your attention")
                    .font(.callout.weight(.medium))
                ScrollView {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(Array(report.warnings.enumerated()), id: \.offset) { _, warning in
                            HStack(alignment: .firstTextBaseline, spacing: 6) {
                                Text("•").foregroundStyle(.secondary)
                                Text(warning)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            .font(.callout)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 220)
            }

            HStack {
                if !report.warnings.isEmpty {
                    Button("Copy Warnings") {
                        Pasteboard.copy(report.warnings.joined(separator: "\n"))
                    }
                }
                Spacer()
                Button("Done") { onDismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 480)
        .accessibilityLabel("Import report: \(report.title)")
    }
}
