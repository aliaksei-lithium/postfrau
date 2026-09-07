import SwiftUI
import PostfrauCore

/// The user's headers, plus a read-only list of the ones Postfrau adds for them.
struct HeadersTab: View {
    @Environment(AppState.self) private var state
    @Bindable var tab: RequestTab

    var body: some View {
        VSplitView {
            KeyValueEditor(
                rows: $tab.draft.headers,
                keyPrompt: "Header",
                valuePrompt: "Value",
                keySuggestions: { HeaderCatalog.completions(for: $0) },
                valueSuggestions: { HeaderCatalog.valueCompletions(forHeader: $0, prefix: $1) },
                onChange: { state.draftChanged(tab) })
            .accessibilityLabel("Request headers")
            .frame(minHeight: 120)

            AutomaticHeadersView(tab: tab)
                .frame(minHeight: 80)
        }
    }
}

/// What Postfrau will add on the user's behalf, so nothing about the request is a surprise.
///
/// Computed by building the request exactly the way `SendController` will, then showing the
/// headers the builder marked automatic.
struct AutomaticHeadersView: View {
    @Environment(AppState.self) private var state
    var tab: RequestTab

    var body: some View {
        let headers = state.automaticHeaders(for: tab)

        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Text("Postfrau will also send")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                Image(systemName: "info.circle")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .help("Add a header of the same name above to override any of these.")
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)

            Divider()

            if headers.isEmpty {
                Text("Nothing — every header comes from the table above.")
                    .font(.callout)
                    .foregroundStyle(.tertiary)
                    .padding(12)
                Spacer()
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(headers) { header in
                            HStack(spacing: 8) {
                                Text(header.name)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                Text(header.value)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                            .font(.system(.callout, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 4)
                            .accessibilityElement(children: .ignore)
                            .accessibilityLabel("Automatic header \(header.name): \(header.value)")
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
        }
        .background(.background)
    }
}
