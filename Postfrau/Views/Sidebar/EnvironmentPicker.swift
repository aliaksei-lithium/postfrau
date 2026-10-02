import SwiftUI
import PostfrauCore

/// The toolbar environment switcher, plus a quick look at the resolved variables.
struct EnvironmentPicker: View {
    /// The variable the clipboard button writes. A JWT that has just been minted somewhere else
    /// nearly always ends up here, and going through the environments window to paste it is four
    /// clicks and a window.
    static let clipboardSecretKey = "token"

    @Environment(AppState.self) private var state
    @Environment(\.openWindow) private var openWindow
    @State private var showingQuickLook = false
    @State private var pasteOutcome: PasteOutcome?

    private enum PasteOutcome { case set, failed }

    var body: some View {
        HStack(spacing: 4) {
            pasteTokenButton

            // A menu rather than a bare picker, so the way into the environments window sits
            // right where environments are chosen — the picker alone left it reachable only by a
            // shortcut nobody could see.
            Menu {
                Picker("Environment", selection: activeEnvironment) {
                    Text("No environment").tag(UUID?.none)
                    if !state.workspace.environments.isEmpty {
                        Divider()
                        ForEach(state.workspace.environments) { environment in
                            Text(environment.name).tag(UUID?.some(environment.id))
                        }
                    }
                }
                .pickerStyle(.inline)
                .labelsHidden()

                Divider()
                Button("Manage Environments…") { openWindow(id: EnvironmentsWindowID.value) }
            } label: {
                Text(state.workspace.activeEnvironment?.name ?? "No environment")
                    .lineLimit(1)
            }
            .frame(minWidth: 150)
            .accessibilityLabel("Active environment")

            Button {
                showingQuickLook.toggle()
            } label: {
                // A stack, because that is what the popover shows: environment over folder over
                // collection over globals, with the winning value on top.
                Image(systemName: "square.3.layers.3d")
                    .imageScale(.small)
            }
            .help("Show and edit the variables this request will see")
            .accessibilityLabel("Show resolved variables")
            .popover(isPresented: $showingQuickLook, arrowEdge: .bottom) {
                VariableQuickLook {
                    showingQuickLook = false
                    openWindow(id: EnvironmentsWindowID.value)
                }
                .frame(width: 400, height: 320)
            }
        }
    }

    /// Pastes the clipboard into the `token` secret of the active environment.
    ///
    /// The clipboard is read on the click, never in `body`: reading it is a real cost and this
    /// view is rebuilt whenever anything in the toolbar changes.
    private var pasteTokenButton: some View {
        Button {
            let value = Pasteboard.text ?? ""
            let ok = state.setActiveEnvironmentSecret(
                named: Self.clipboardSecretKey, to: value)
            pasteOutcome = ok ? .set : .failed
            // Long enough to notice, short enough not to become part of the furniture.
            Task {
                try? await Task.sleep(for: .seconds(1.5))
                pasteOutcome = nil
            }
        } label: {
            Image(systemName: symbol)
                .imageScale(.small)
                .foregroundStyle(tint)
        }
        .disabled(state.workspace.activeEnvironmentID == nil)
        .help(state.workspace.activeEnvironmentID == nil
            ? "Choose an environment first"
            : "Set “\(Self.clipboardSecretKey)” from the clipboard")
        .accessibilityLabel("Set \(Self.clipboardSecretKey) from the clipboard")
        .accessibilityValue(accessibilityOutcome)
    }

    private var symbol: String {
        switch pasteOutcome {
        case .set: "checkmark.circle.fill"
        case .failed: "exclamationmark.circle.fill"
        case nil: "key.horizontal.fill"
        }
    }

    private var tint: AnyShapeStyle {
        switch pasteOutcome {
        case .set: AnyShapeStyle(.green)
        case .failed: AnyShapeStyle(.orange)
        case nil: AnyShapeStyle(.primary)
        }
    }

    private var accessibilityOutcome: String {
        switch pasteOutcome {
        case .set: "Set"
        case .failed: "Nothing on the clipboard"
        case nil: ""
        }
    }

    private var activeEnvironment: Binding<UUID?> {
        Binding(
            get: { state.workspace.activeEnvironmentID },
            set: {
                state.workspace.activeEnvironmentID = $0
                state.markUIStateDirty()
            })
    }
}

/// Every variable visible to the selected tab, with its source, shadowing and secrets masked.
///
/// Values are editable in place and save themselves: an edit goes back to whichever layer defined
/// the row — environment, folder, collection or globals — through `AppState`, and from there to
/// disk with the ordinary autosave.
struct VariableQuickLook: View {
    @Environment(AppState.self) private var state
    var manageEnvironments: () -> Void = {}
    @State private var revealed: Set<String> = []

    var body: some View {
        let tab = state.selectedTab
        let variables = tab.map { state.scope(for: $0).allVariables() } ?? []

        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Variables in scope")
                    .font(.headline)
                Spacer()
                Button("Manage…", action: manageEnvironments)
                    .controlSize(.small)
                    .help("Open the environments window (⌘E)")
            }
            .padding(12)

            if variables.isEmpty {
                CenteredMessage(
                    symbol: "curlybraces", title: "No variables",
                    message: "Add them to an environment, a collection, or globals.")
            } else if let tab {
                List(Array(variables.enumerated()), id: \.offset) { _, variable in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(variable.key)
                                .font(.system(.callout, design: .monospaced))
                                .strikethrough(variable.isShadowed)
                            Text(variable.source.categoryName + " · " + variable.source.displayName)
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                        Spacer(minLength: 8)
                        value(for: variable, in: tab)
                    }
                    .opacity(variable.isShadowed ? 0.5 : 1)
                    .help(variable.isShadowed
                        ? "Shadowed by a higher-precedence definition"
                        : variable.source.categoryName)
                }
                .listStyle(.inset)
            }
        }
    }

    /// Identifies a row across edits: the same key can appear once per layer.
    private func revealKey(_ variable: ResolvedVariable) -> String {
        "\(variable.source.categoryName)/\(variable.source.displayName)/\(variable.key)"
    }

    @ViewBuilder
    private func value(for variable: ResolvedVariable, in tab: RequestTab) -> some View {
        if variable.isSecret && !revealed.contains(revealKey(variable)) {
            Button("•••••") { revealed.insert(revealKey(variable)) }
                .buttonStyle(.plain)
                .font(.system(.callout, design: .monospaced))
                .foregroundStyle(.secondary)
                .help("Click to reveal and edit")
                .accessibilityLabel("Secret value for \(variable.key), click to reveal")
        } else {
            VariableValueField(value: variable.value) { newValue in
                _ = state.setScopedVariable(
                    variable.key, in: variable.source, to: newValue, for: tab)
            }
            .accessibilityLabel("Value of \(variable.key)")
        }
    }
}

/// One editable value in the quick look. Saves a moment after typing stops, on Return, when focus
/// leaves, and when the popover closes — there is no Save button to forget.
private struct VariableValueField: View {
    var value: String
    var commit: (String) -> Void

    @State private var text = ""
    @State private var pendingCommit: Task<Void, Never>?
    @FocusState private var isFocused: Bool

    var body: some View {
        TextField("—", text: $text)
            .textFieldStyle(.plain)
            .font(.system(.callout, design: .monospaced))
            .foregroundStyle(isFocused ? .primary : .secondary)
            .multilineTextAlignment(.trailing)
            .lineLimit(1)
            .truncationMode(.middle)
            .focused($isFocused)
            .frame(maxWidth: 220)
            .onAppear { text = value }
            // Something else changed the value — the environments window, the CLI, a capture.
            // Take it, unless the user is midway through typing over it.
            .onChange(of: value) { _, newValue in
                if !isFocused { text = newValue }
            }
            .onChange(of: text) { _, newValue in
                guard newValue != value else { return }
                pendingCommit?.cancel()
                // A pause rather than every keystroke: each commit marks the layer dirty and, for
                // a Keychain secret, goes to the Keychain.
                pendingCommit = Task {
                    try? await Task.sleep(for: .milliseconds(400))
                    guard !Task.isCancelled else { return }
                    commit(newValue)
                }
            }
            .onSubmit(flush)
            .onChange(of: isFocused) { _, focused in if !focused { flush() } }
            .onDisappear(perform: flush)
    }

    private func flush() {
        pendingCommit?.cancel()
        pendingCommit = nil
        if text != value { commit(text) }
    }
}
