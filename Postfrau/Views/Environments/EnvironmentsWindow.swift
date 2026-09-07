import SwiftUI
import PostfrauCore

/// The ⌘E window: environments on the left, their variables on the right, globals pinned first.
struct EnvironmentsWindow: View {
    @Environment(AppState.self) private var state

    /// Which row of the list is selected. Globals have no id of their own, so they get `nil`.
    @State private var selection: Selection = .globals

    private enum Selection: Hashable {
        case globals
        case environment(UUID)
    }

    var body: some View {
        NavigationSplitView {
            list
                .navigationSplitViewColumnWidth(min: 180, ideal: 220, max: 320)
        } detail: {
            detail
        }
        .frame(minWidth: 720, minHeight: 420)
        .onAppear(perform: selectSomethingSensible)
        .safeAreaInset(edge: .bottom) {
            if let error = state.secretsError {
                NoticeBanner(symbol: "key.slash", message: error)
                    .accessibilityLabel("Keychain problem: \(error)")
            }
        }
    }

    // MARK: - List

    private var list: some View {
        @Bindable var state = state
        return List(selection: $selection) {
            Section {
                Label("Globals", systemImage: "globe")
                    .tag(Selection.globals)
                    .accessibilityLabel("Globals")
            }
            Section("Environments") {
                ForEach(state.workspace.environments) { environment in
                    row(environment)
                }
            }
        }
        .listStyle(.sidebar)
        .toolbar {
            ToolbarItem {
                Button {
                    let created = state.newEnvironment()
                    selection = .environment(created.id)
                } label: {
                    Label("New Environment", systemImage: "plus")
                }
                .help("New environment")
            }
        }
    }

    private func row(_ environment: RequestEnvironment) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "cube")
                .foregroundStyle(
                    state.workspace.activeEnvironmentID == environment.id
                        ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.secondary))
            Text(environment.name).lineLimit(1)
            Spacer(minLength: 0)
            if environment.variables.contains(where: \.isSecret) {
                Image(systemName: "key.fill")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .help("Has secret variables")
            }
        }
        .tag(Selection.environment(environment.id))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            "Environment \(environment.name)"
                + (state.workspace.activeEnvironmentID == environment.id ? ", active" : ""))
        .contextMenu {
            Button("Make Active") { state.setActiveEnvironment(environment.id) }
            Button("Duplicate") {
                if let copy = state.duplicateEnvironment(id: environment.id) {
                    selection = .environment(copy.id)
                }
            }
            Divider()
            Button("Delete", role: .destructive) {
                state.deleteEnvironment(id: environment.id)
                selection = .globals
            }
        }
    }

    // MARK: - Detail

    @ViewBuilder
    private var detail: some View {
        switch selection {
        case .globals:
            EnvironmentDetail(
                title: "Globals",
                subtitle: "Visible to every request, whatever environment is active.",
                isActive: false,
                variables: Binding(
                    get: { state.workspace.globals.variables },
                    set: { variables in
                        var globals = state.workspace.globals
                        globals.variables = variables
                        state.updateGlobals(globals)
                    }),
                name: nil,
                onActivate: nil)

        case .environment(let id):
            if let environment = state.workspace.environments.first(where: { $0.id == id }) {
                EnvironmentDetail(
                    title: environment.name,
                    subtitle: nil,
                    isActive: state.workspace.activeEnvironmentID == id,
                    variables: Binding(
                        get: { environment.variables },
                        set: { variables in
                            var updated = environment
                            updated.variables = variables
                            state.update(updated)
                        }),
                    name: Binding(
                        get: { environment.name },
                        set: { newName in
                            let trimmed = newName.trimmingCharacters(in: .whitespaces)
                            guard !trimmed.isEmpty else { return }
                            var updated = environment
                            updated.name = trimmed
                            state.update(updated)
                        }),
                    onActivate: { state.setActiveEnvironment(id) })
            } else {
                CenteredMessage(
                    symbol: "cube", title: "No environment selected",
                    message: "Pick one on the left, or create a new one.")
            }
        }
    }

    /// Keeps the selection on something that exists — an environment can be deleted from the
    /// sidebar's context menu while it is showing.
    private func selectSomethingSensible() {
        if case .environment(let id) = selection,
           !state.workspace.environments.contains(where: { $0.id == id }) {
            selection = .globals
        }
    }
}

/// The right-hand pane: a name, an "active" control, and the variables table.
struct EnvironmentDetail: View {
    var title: String
    var subtitle: String?
    var isActive: Bool
    @Binding var variables: [Variable]
    /// Nil for globals, which cannot be renamed.
    var name: Binding<String>?
    var onActivate: (() -> Void)?

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                if let name {
                    TextField("Name", text: name)
                        .textFieldStyle(.roundedBorder)
                        .font(.title3)
                        .frame(maxWidth: 280)
                        .accessibilityLabel("Environment name")
                } else {
                    Text(title).font(.title3)
                }

                Spacer()

                if let onActivate {
                    if isActive {
                        Label("Active", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.tint)
                            .accessibilityLabel("This environment is active")
                    } else {
                        Button("Make Active", action: onActivate)
                    }
                }
            }
            .padding(.horizontal, 14)
            .padding(.top, 12)

            if let subtitle {
                Text(subtitle)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 14)
                    .padding(.top, 2)
            }

            Divider().padding(.top, 12)

            VariablesEditor(variables: $variables)
                .accessibilityLabel("\(title) variables")
        }
        .background(.background)
    }
}
