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

            TextField("Enter a URL", text: $tab.draft.url)
                .textFieldStyle(.roundedBorder)
                .font(.system(.body, design: .monospaced))
                .focused($urlFieldFocused)
                .onSubmit { state.send(tab) }
                .onChange(of: tab.draft.url) { state.draftChanged(tab) }
                .accessibilityLabel("Request URL")

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
            Button("Send") { state.send(tab) }
                .buttonStyle(.glassProminent)
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(tab.draft.url.trimmingCharacters(in: .whitespaces).isEmpty)
                .accessibilityLabel("Send the request")
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
