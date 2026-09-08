import SwiftUI
import PostfrauCore

/// Method picker, URL field and the Send button.
struct URLBar: View {
    @Environment(AppState.self) private var state
    @Bindable var tab: RequestTab
    @FocusState.Binding var urlFieldFocused: Bool

    var body: some View {
        HStack(spacing: 8) {
            MethodPicker(method: $tab.draft.method)
                .onChange(of: tab.draft.method) { state.draftChanged(tab) }

            TokenTextField(
                text: Binding(get: { tab.draft.url }, set: { tab.urlEdited(to: $0) }),
                fontSize: state.settings.editorFontSize,
                placeholder: "Enter a URL",
                resolver: state.resolver(for: tab),
                onSubmit: { state.send(tab) },
                onChange: { text in
                    // Pasting a curl command into the URL field fills in the whole request —
                    // method, headers, auth and body — rather than leaving the command sitting
                    // there as a URL that cannot be sent.
                    guard !state.handlePastedCurl(text, into: tab) else { return }
                    state.draftChanged(tab)
                })
            .frame(height: 26)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color(nsColor: .textBackgroundColor)))
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(Color(nsColor: .separatorColor), lineWidth: 1))
            .focused($urlFieldFocused)
            .accessibilityLabel("Request URL")
            .accessibilityValue(tab.draft.url)

            sendButton
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private var sendButton: some View {
        if tab.isSending {
            Button("Cancel") { state.cancelSend(tab) }
                .keyboardShortcut(.cancelAction)
                .accessibilityLabel("Cancel the request")
        } else {
            let warnings = state.warnings(for: tab)
            Button("Send") { state.send(tab) }
                .buttonStyle(.glassProminent)
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(tab.draft.url.trimmingCharacters(in: .whitespaces).isEmpty)
                .help(warnings.isEmpty ? "Send this request (⌘↩)" : warnings.joined(separator: "\n"))
                .overlay(alignment: .topTrailing) {
                    if !warnings.isEmpty {
                        Circle()
                            .fill(.orange)
                            .frame(width: 7, height: 7)
                            .offset(x: 3, y: -3)
                            .accessibilityHidden(true)
                    }
                }
                .accessibilityLabel("Send the request")
                .accessibilityHint(warnings.joined(separator: ". "))
        }
    }
}

struct MethodPicker: View {
    @Binding var method: HTTPMethod

    var body: some View {
        Picker("Method", selection: $method) {
            ForEach(HTTPMethod.allCases, id: \.rawValue) { candidate in
                Text(candidate.rawValue)
                    .foregroundStyle(candidate.tint)
                    .tag(candidate)
            }
            // A method that came from an import but is not in the standard list still needs a row.
            if !HTTPMethod.allCases.contains(method) {
                Divider()
                Text(method.rawValue).tag(method)
            }
        }
        .labelsHidden()
        .frame(width: 104)
        .accessibilityLabel("HTTP method")
    }
}
