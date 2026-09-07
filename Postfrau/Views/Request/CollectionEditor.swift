import SwiftUI
import PostfrauCore

/// The tab that edits a collection's own settings: name, description, auth and variables.
struct CollectionEditor: View {
    @Environment(AppState.self) private var state
    var collectionID: UUID

    private enum Section: String, CaseIterable, Identifiable {
        case overview, auth, variables
        var id: String { rawValue }
        var title: String {
            switch self {
            case .overview: "Overview"
            case .auth: "Auth"
            case .variables: "Variables"
            }
        }
    }

    @State private var section: Section = .overview

    var body: some View {
        if let collection = state.workspace.collection(withID: collectionID) {
            VStack(spacing: 0) {
                header(collection)
                Picker("Section", selection: $section) {
                    ForEach(Section.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .padding(.horizontal, 12)
                .padding(.bottom, 8)
                Divider()
                content(collection)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
            .background(.background)
        } else {
            CenteredMessage(
                symbol: "questionmark.folder", title: "Collection not found",
                message: "It may have been deleted.")
        }
    }

    private func header(_ collection: RequestCollection) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "shippingbox").foregroundStyle(.secondary)
            TextField("Name", text: binding(collection, \.name))
                .textFieldStyle(.roundedBorder)
                .font(.title3)
                .accessibilityLabel("Collection name")
            Spacer()
            Text("\(collection.requestCount) request(s)")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private func content(_ collection: RequestCollection) -> some View {
        switch section {
        case .overview:
            Form {
                LabeledContent("Description") {
                    TextEditor(text: Binding(
                        get: { collection.description ?? "" },
                        set: { text in
                            guard var updated = state.workspace.collection(withID: collectionID)
                            else { return }
                            updated.description = text.isEmpty ? nil : text
                            state.updateCollection(updated)
                        }))
                    .frame(minHeight: 80)
                    .accessibilityLabel("Collection description")
                }
            }
            .formStyle(.grouped)
        case .auth:
            CollectionAuthEditor(
                auth: binding(collection, \.auth),
                allowsInherit: false,
                resolver: state.resolver(for: collectionID))
        case .variables:
            VariablesEditor(
                variables: binding(collection, \.variables),
                onChange: {})
            .accessibilityLabel("Collection variables")
        }
    }

    /// Writes straight through to the workspace: a collection editor has no separate draft, so
    /// there is nothing to save and nothing to lose.
    private func binding<Value>(
        _ collection: RequestCollection, _ keyPath: WritableKeyPath<RequestCollection, Value>
    ) -> Binding<Value> {
        Binding(
            get: { state.workspace.collection(withID: collectionID)?[keyPath: keyPath]
                ?? collection[keyPath: keyPath] },
            set: { newValue in
                guard var updated = state.workspace.collection(withID: collectionID) else { return }
                updated[keyPath: keyPath] = newValue
                state.updateCollection(updated)
            })
    }

}

/// The tab that edits a folder's settings.
struct FolderEditor: View {
    @Environment(AppState.self) private var state
    var folderID: UUID
    var collectionID: UUID

    private enum Section: String, CaseIterable, Identifiable {
        case overview, auth, variables
        var id: String { rawValue }
        var title: String {
            switch self {
            case .overview: "Overview"
            case .auth: "Auth"
            case .variables: "Variables"
            }
        }
    }

    @State private var section: Section = .overview

    var body: some View {
        if let folder = state.workspace.collection(withID: collectionID)?.folder(withID: folderID) {
            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    Image(systemName: "folder").foregroundStyle(.secondary)
                    TextField("Name", text: binding(\.name))
                        .textFieldStyle(.roundedBorder)
                        .font(.title3)
                        .accessibilityLabel("Folder name")
                    Spacer()
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)

                Picker("Section", selection: $section) {
                    ForEach(Section.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .padding(.horizontal, 12)
                .padding(.bottom, 8)
                Divider()

                Group {
                    switch section {
                    case .overview:
                        Form {
                            LabeledContent("Description") {
                                TextEditor(text: Binding(
                                    get: { folder.description ?? "" },
                                    set: { text in
                                        var updated = folder
                                        updated.description = text.isEmpty ? nil : text
                                        state.updateFolder(updated, in: collectionID)
                                    }))
                            }
                        }
                        .formStyle(.grouped)
                    case .auth:
                        CollectionAuthEditor(
                            auth: binding(\.auth),
                            allowsInherit: true,
                            resolver: state.resolver(for: collectionID))
                    case .variables:
                        VariablesEditor(variables: binding(\.variables))
                            .accessibilityLabel("Folder variables")
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
            .background(.background)
        } else {
            CenteredMessage(
                symbol: "questionmark.folder", title: "Folder not found",
                message: "It may have been deleted.")
        }
    }

    private func binding<Value>(_ keyPath: WritableKeyPath<Folder, Value>) -> Binding<Value> {
        Binding(
            get: {
                state.workspace.collection(withID: collectionID)?
                    .folder(withID: folderID)?[keyPath: keyPath] ?? Folder()[keyPath: keyPath]
            },
            set: { newValue in
                guard var folder = state.workspace.collection(withID: collectionID)?
                    .folder(withID: folderID) else { return }
                folder[keyPath: keyPath] = newValue
                state.updateFolder(folder, in: collectionID)
            })
    }
}

/// The auth editor shared by collections and folders.
struct CollectionAuthEditor: View {
    @Binding var auth: Auth
    var allowsInherit: Bool
    var resolver: VariableResolver

    private var kinds: [Auth.Kind] {
        allowsInherit ? Auth.Kind.allCases : Auth.Kind.allCases.filter { $0 != .inherit }
    }

    var body: some View {
        Form {
            Picker("Type", selection: Binding(
                get: { auth.kind },
                set: { auth = .empty($0) })
            ) {
                ForEach(kinds, id: \.self) { Text($0.displayName).tag($0) }
            }
            .accessibilityLabel("Authentication type")

            switch auth {
            case .inherit:
                Text("Requests here inherit whatever the collection defines.")
                    .foregroundStyle(.secondary)
            case .none:
                Text("Requests here send no authentication unless they define their own.")
                    .foregroundStyle(.secondary)
            case .basic:
                RevealableField("Username", text: field(.basicUsername), isSecret: false)
                RevealableField("Password", text: field(.basicPassword), isSecret: true)
            case .bearer:
                RevealableField("Token", text: field(.bearerToken), isSecret: true)
            case .apiKey:
                RevealableField("Key", text: field(.apiKeyName), isSecret: false)
                RevealableField("Value", text: field(.apiKeyValue), isSecret: true)
                Picker("Add to", selection: Binding(
                    get: {
                        if case .apiKey(_, _, let location) = auth { return location }
                        return .header
                    },
                    set: {
                        guard case .apiKey(let key, let value, _) = auth else { return }
                        auth = .apiKey(key: key, value: value, location: $0)
                    })
                ) {
                    ForEach(APIKeyLocation.allCases, id: \.self) { Text($0.displayName).tag($0) }
                }
            }
        }
        .formStyle(.grouped)
    }

    private enum AuthField {
        case basicUsername, basicPassword, bearerToken, apiKeyName, apiKeyValue
    }

    private func field(_ slot: AuthField) -> Binding<String> {
        Binding(
            get: {
                switch (slot, auth) {
                case (.basicUsername, .basic(let username, _)): username
                case (.basicPassword, .basic(_, let password)): password
                case (.bearerToken, .bearer(let token)): token
                case (.apiKeyName, .apiKey(let key, _, _)): key
                case (.apiKeyValue, .apiKey(_, let value, _)): value
                default: ""
                }
            },
            set: { newValue in
                switch (slot, auth) {
                case (.basicUsername, .basic(_, let password)):
                    auth = .basic(username: newValue, password: password)
                case (.basicPassword, .basic(let username, _)):
                    auth = .basic(username: username, password: newValue)
                case (.bearerToken, .bearer):
                    auth = .bearer(token: newValue)
                case (.apiKeyName, .apiKey(_, let value, let location)):
                    auth = .apiKey(key: newValue, value: value, location: location)
                case (.apiKeyValue, .apiKey(let key, _, let location)):
                    auth = .apiKey(key: key, value: newValue, location: location)
                default:
                    break
                }
            })
    }
}
