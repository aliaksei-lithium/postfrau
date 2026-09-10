import SwiftUI
import PostfrauCore

/// The toolbar environment switcher, plus a quick look at the resolved variables.
struct EnvironmentPicker: View {
    /// The variable the clipboard button writes. A JWT that has just been minted somewhere else
    /// nearly always ends up here, and going through the environments window to paste it is four
    /// clicks and a window.
    static let clipboardSecretKey = "token"

    @Environment(AppState.self) private var state
    @State private var showingQuickLook = false
    @State private var pasteOutcome: PasteOutcome?

    private enum PasteOutcome { case set, failed }

    var body: some View {
        HStack(spacing: 4) {
            pasteTokenButton

            Picker("Environment", selection: activeEnvironment) {
                Text("No environment").tag(UUID?.none)
                if !state.workspace.environments.isEmpty {
                    Divider()
                    ForEach(state.workspace.environments) { environment in
                        Text(environment.name).tag(UUID?.some(environment.id))
                    }
                }
            }
            .labelsHidden()
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
            .help("Show the variables this request will see")
            .accessibilityLabel("Show resolved variables")
            .popover(isPresented: $showingQuickLook, arrowEdge: .bottom) {
                VariableQuickLook()
                    .frame(width: 380, height: 300)
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
struct VariableQuickLook: View {
    @Environment(AppState.self) private var state
    @State private var revealed: Set<String> = []

    var body: some View {
        let variables = state.selectedTab.map { state.scope(for: $0).allVariables() } ?? []

        VStack(alignment: .leading, spacing: 0) {
            Text("Variables in scope")
                .font(.headline)
                .padding(12)

            if variables.isEmpty {
                CenteredMessage(
                    symbol: "curlybraces", title: "No variables",
                    message: "Add them to an environment, a collection, or globals.")
            } else {
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
                        value(for: variable)
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

    @ViewBuilder
    private func value(for variable: ResolvedVariable) -> some View {
        if variable.isSecret && !revealed.contains(variable.key) {
            Button("•••••") { revealed.insert(variable.key) }
                .buttonStyle(.plain)
                .font(.system(.callout, design: .monospaced))
                .foregroundStyle(.secondary)
                .help("Click to reveal")
                .accessibilityLabel("Secret value for \(variable.key), click to reveal")
        } else {
            Text(variable.value.isEmpty ? "—" : variable.value)
                .font(.system(.callout, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
        }
    }
}
