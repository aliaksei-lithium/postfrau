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

            if tab.isSending {
                ProgressView().progressViewStyle(.linear).frame(height: 2)
            } else {
                Color.clear.frame(height: 2)
            }

            Picker("Request section", selection: $tab.selectedEditorTab) {
                ForEach(EditorTab.allCases) { editorTab in
                    Text(label(for: editorTab)).tag(editorTab)
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

    /// Counts on the segment labels, the way Postman shows them.
    private func label(for editorTab: EditorTab) -> String {
        switch editorTab {
        case .params:
            let count = tab.draft.params.active.count
            return count > 0 ? "Params (\(count))" : "Params"
        case .headers:
            let count = tab.draft.headers.active.count
            return count > 0 ? "Headers (\(count))" : "Headers"
        case .auth:
            return tab.draft.auth == .inherit ? "Auth" : "Auth •"
        case .body:
            return tab.draft.body.isEffectivelyEmpty ? "Body" : "Body •"
        case .settings:
            return "Settings"
        }
    }

    @ViewBuilder
    private var editorContent: some View {
        // Phase 4 replaces these placeholders with the real editors.
        switch tab.selectedEditorTab {
        case .params:
            PlaceholderPane(
                title: "Query parameters",
                message: "The key–value editor arrives in Phase 4. "
                    + "For now, type the query directly in the URL.")
        case .headers:
            PlaceholderPane(
                title: "Headers",
                message: automaticHeaderSummary)
        case .auth:
            PlaceholderPane(title: "Auth", message: authSummary)
        case .body:
            BodyPlaceholderPane(tab: tab)
        case .settings:
            RequestSettingsPane(tab: tab)
        }
    }

    private var automaticHeaderSummary: String {
        let effective = state.effectiveAuth(for: tab)
        var lines = ["User-Agent: \(Postfrau.userAgent)", "Accept: */*"]
        if let wire = AuthResolver.wireValue(
            for: effective.auth, resolver: state.resolver(for: tab)),
           case .header(let name, _) = wire {
            lines.append("\(name): … (from \(effective.auth.kind.displayName) auth)")
        }
        return "Postfrau will add:\n" + lines.joined(separator: "\n")
    }

    private var authSummary: String {
        let effective = state.effectiveAuth(for: tab)
        switch effective.source {
        case .request: return "This request uses \(effective.auth.kind.displayName)."
        case .folder(let name): return "Inherited from the folder “\(name)”."
        case .collection(let name): return "Inherited from the collection “\(name)”."
        case .none: return "No authentication will be sent."
        }
    }
}

struct PlaceholderPane: View {
    var title: String
    var message: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.callout.weight(.medium))
            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
        }
        .padding(16)
    }
}

/// A minimal raw-body editor so an end-to-end POST is possible before Phase 4.
struct BodyPlaceholderPane: View {
    @Environment(AppState.self) private var state
    @Bindable var tab: RequestTab

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Picker("Body", selection: bodyKind) {
                ForEach([RequestBody.Kind.none, .raw], id: \.self) { kind in
                    Text(kind.displayName).tag(kind)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 180)
            .padding(12)

            if case .raw = tab.draft.body {
                CodeTextView(
                    text: rawText,
                    isEditable: true,
                    fontSize: state.settings.editorFontSize,
                    wrapsLines: true,
                    accessibilityLabel: "Request body")
            } else {
                PlaceholderPane(
                    title: "No body",
                    message: "Form data, URL-encoded and binary bodies arrive in Phase 4.")
                Spacer()
            }
        }
    }

    private var bodyKind: Binding<RequestBody.Kind> {
        Binding(
            get: { tab.draft.body.kind == .raw ? .raw : .none },
            set: { kind in
                tab.draft.body = kind == .raw ? .raw(text: "", language: .json) : .none
                state.draftChanged(tab)
            })
    }

    private var rawText: Binding<String> {
        Binding(
            get: {
                if case .raw(let text, _) = tab.draft.body { return text }
                return ""
            },
            set: { text in
                guard case .raw(_, let language) = tab.draft.body else { return }
                tab.draft.body = .raw(text: text, language: language)
                state.draftChanged(tab)
            })
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
