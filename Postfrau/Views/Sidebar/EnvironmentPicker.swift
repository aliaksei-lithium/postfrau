import SwiftUI
import PostfrauCore

/// The toolbar environment switcher, plus a quick look at the resolved variables.
struct EnvironmentPicker: View {
    @Environment(AppState.self) private var state
    @State private var showingQuickLook = false

    var body: some View {
        HStack(spacing: 4) {
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
                Image(systemName: "eye")
            }
            .help("Show the variables this request will see")
            .accessibilityLabel("Show resolved variables")
            .popover(isPresented: $showingQuickLook, arrowEdge: .bottom) {
                VariableQuickLook()
                    .frame(width: 380, height: 300)
            }
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
