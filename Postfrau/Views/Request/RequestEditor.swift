import SwiftUI
import PostfrauCore

/// The top half of the detail pane: URL bar plus the request's sub-tabs.
struct RequestEditor: View {
    @Environment(AppState.self) private var state
    @Bindable var tab: RequestTab
    @FocusState.Binding var urlFieldFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            URLBar(tab: tab, urlFieldFocused: $urlFieldFocused)

            // Reserves the space whether or not a request is in flight, so the layout does not
            // jump when Send is pressed.
            Group {
                if tab.isSending {
                    ProgressView().progressViewStyle(.linear)
                } else {
                    Color.clear
                }
            }
            .frame(height: 2)

            Picker("Request section", selection: $tab.selectedEditorTab) {
                ForEach(EditorTab.allCases) { editorTab in
                    Text(label(for: editorTab, unresolved: unresolved)).tag(editorTab)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 12)
            .padding(.bottom, 8)

            Divider()

            editorContent
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .background(.background)
    }

    /// Unresolved variables anywhere in this request, counted once per body evaluation.
    private var unresolved: AppState.UnresolvedCounts {
        state.unresolvedCounts(for: tab)
    }

    /// Counts and dots on the segment labels, the way Postman shows them. A section holding an
    /// unresolved `{{variable}}` is marked, since the tables themselves are not coloured (§5).
    private func label(for editorTab: EditorTab, unresolved: AppState.UnresolvedCounts) -> String {
        switch editorTab {
        case .params:
            let count = tab.draft.params.active.count
            let base = count > 0 ? "Params (\(count))" : "Params"
            return unresolved.params > 0 ? "\(base) ⚠" : base
        case .headers:
            let count = tab.draft.headers.active.count
            let base = count > 0 ? "Headers (\(count))" : "Headers"
            return unresolved.headers > 0 ? "\(base) ⚠" : base
        case .auth:
            return tab.draft.auth == .inherit || tab.draft.auth == .none ? "Auth" : "Auth •"
        case .body:
            let base = tab.draft.body.isEffectivelyEmpty ? "Body" : "Body •"
            return unresolved.body > 0 ? "\(base) ⚠" : base
        case .settings:
            return "Settings"
        }
    }

    @ViewBuilder
    private var editorContent: some View {
        switch tab.selectedEditorTab {
        case .params: ParamsTab(tab: tab)
        case .headers: HeadersTab(tab: tab)
        case .auth: AuthTab(tab: tab)
        case .body: BodyTab(tab: tab)
        case .settings: RequestSettingsPane(tab: tab)
        }
    }
}

struct RequestSettingsPane: View {
    @Environment(AppState.self) private var state
    @Bindable var tab: RequestTab

    var body: some View {
        Form {
            Toggle("Follow redirects", isOn: $tab.draft.settings.followRedirects)
            Stepper(
                "Maximum redirects: \(tab.draft.settings.maxRedirects)",
                value: $tab.draft.settings.maxRedirects, in: 0...50)
            .disabled(!tab.draft.settings.followRedirects)
            LabeledContent("Timeout") {
                HStack {
                    TextField(
                        "Timeout", value: $tab.draft.settings.timeoutSeconds,
                        format: .number.precision(.fractionLength(0...1)))
                    .frame(width: 70)
                    .labelsHidden()
                    Text("seconds").foregroundStyle(.secondary)
                }
            }
            Toggle("Verify TLS certificates", isOn: $tab.draft.settings.verifyTLS)
            Toggle("Send cookies", isOn: $tab.draft.settings.sendCookies)
            Toggle("Percent-encode the URL", isOn: $tab.draft.settings.encodeURL)
        }
        .formStyle(.grouped)
        .onChange(of: tab.draft.settings) { state.draftChanged(tab) }
    }
}
