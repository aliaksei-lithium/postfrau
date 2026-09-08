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

    /// Sections that have been opened at least once, and are therefore built and kept.
    @State private var visited: Set<EditorTab> = []

    /// Every section that has been opened stays built; switching only changes which one shows.
    ///
    /// A `switch` here reads better, but it makes each section a separate branch of the view
    /// tree, so SwiftUI tears the old one down and builds the new one on every click. These
    /// sections are full of AppKit-backed controls — checkboxes, text fields, scroll views — and
    /// rebuilding them cost ~200 ms of main-thread time per click, which is the lag you could
    /// feel. Building each section once and then just hiding it costs ~50 ms. Sections are still
    /// built lazily, so opening a request does not pay for the four tabs nobody looked at.
    ///
    /// A hidden section is `disabled`, not merely transparent: without that its text fields stay
    /// in the window's key-view loop and ⇥ walks into a tab you cannot see. See D46.
    private var editorContent: some View {
        ZStack(alignment: .topLeading) {
            ForEach(EditorTab.allCases) { editorTab in
                if visited.contains(editorTab) {
                    let isSelected = editorTab == tab.selectedEditorTab
                    section(editorTab)
                        .opacity(isSelected ? 1 : 0)
                        .disabled(!isSelected)
                        .accessibilityHidden(!isSelected)
                }
            }
        }
        .onAppear { visited.insert(tab.selectedEditorTab) }
        .onChange(of: tab.selectedEditorTab) { _, new in visited.insert(new) }
    }

    @ViewBuilder
    private func section(_ editorTab: EditorTab) -> some View {
        switch editorTab {
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
