import SwiftUI
import PostfrauCore

/// Auth for one request: Inherit, None, Basic, Bearer or API Key.
struct AuthTab: View {
    @Environment(AppState.self) private var state
    @Bindable var tab: RequestTab

    var body: some View {
        Form {
            Picker("Type", selection: authKind) {
                ForEach(Auth.Kind.allCases, id: \.self) { kind in
                    Text(kind.displayName).tag(kind)
                }
            }
            .accessibilityLabel("Authentication type")

            switch tab.draft.auth {
            case .inherit:
                inheritedSummary
            case .none:
                Text("No authentication will be sent with this request.")
                    .foregroundStyle(.secondary)
            case .basic:
                RevealableField("Username", text: field(.basicUsername), isSecret: false)
                RevealableField("Password", text: field(.basicPassword), isSecret: true)
            case .bearer:
                RevealableField("Token", text: field(.bearerToken), isSecret: true)
            case .apiKey:
                RevealableField("Key", text: field(.apiKeyName), isSecret: false)
                RevealableField("Value", text: field(.apiKeyValue), isSecret: true)
                Picker("Add to", selection: apiKeyLocation) {
                    ForEach(APIKeyLocation.allCases, id: \.self) { location in
                        Text(location.displayName).tag(location)
                    }
                }
            }

            if tab.draft.auth != .inherit, tab.draft.auth != .none {
                Section {
                    wirePreview
                } header: {
                    Text("On the wire")
                }
            }
        }
        .formStyle(.grouped)
        .onChange(of: tab.draft.auth) { state.draftChanged(tab) }
    }

    // MARK: - Pieces

    @ViewBuilder
    private var inheritedSummary: some View {
        let effective = state.effectiveAuth(for: tab)
        switch effective.source {
        case .folder(let name):
            LabeledContent("Inherited from") {
                Label(name, systemImage: "folder").foregroundStyle(.secondary)
            }
            LabeledContent("Type") {
                Text(effective.auth.kind.displayName).foregroundStyle(.secondary)
            }
        case .collection(let name):
            LabeledContent("Inherited from") {
                Label(name, systemImage: "shippingbox").foregroundStyle(.secondary)
            }
            LabeledContent("Type") {
                Text(effective.auth.kind.displayName).foregroundStyle(.secondary)
            }
        case .none, .request:
            Text("Nothing up the chain defines authentication, so none will be sent.")
                .foregroundStyle(.secondary)
        }
    }

    /// Shows exactly what will be added, with the secret part masked.
    @ViewBuilder
    private var wirePreview: some View {
        if let wire = AuthResolver.wireValue(
            for: tab.draft.auth, resolver: state.resolver(for: tab)) {
            let label = switch wire {
            case .header: "Header"
            case .query: "Query parameter"
            }
            LabeledContent(label) {
                Text("\(wire.name): \(masked(wire.value))")
                    .font(.system(.callout, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        } else {
            Text("Nothing yet — fill in the fields above.")
                .font(.callout)
                .foregroundStyle(.tertiary)
        }
    }

    /// Keeps the scheme visible ("Bearer …") but hides the credential.
    private func masked(_ value: String) -> String {
        guard let space = value.firstIndex(of: " ") else {
            return String(repeating: "•", count: min(value.count, 12))
        }
        return String(value[value.startIndex...space]) + String(repeating: "•", count: 8)
    }

    // MARK: - Bindings
    //
    // `Auth` is an enum with associated values, so editing one field means rebuilding the whole
    // case. `field(_:)` names the slot being edited and does that rebuild in one place.

    private enum AuthField {
        case basicUsername, basicPassword, bearerToken, apiKeyName, apiKeyValue
    }

    private func field(_ slot: AuthField) -> Binding<String> {
        Binding(
            get: {
                switch (slot, tab.draft.auth) {
                case (.basicUsername, .basic(let username, _)): username
                case (.basicPassword, .basic(_, let password)): password
                case (.bearerToken, .bearer(let token)): token
                case (.apiKeyName, .apiKey(let key, _, _)): key
                case (.apiKeyValue, .apiKey(_, let value, _)): value
                default: ""
                }
            },
            set: { newValue in
                switch (slot, tab.draft.auth) {
                case (.basicUsername, .basic(_, let password)):
                    tab.draft.auth = .basic(username: newValue, password: password)
                case (.basicPassword, .basic(let username, _)):
                    tab.draft.auth = .basic(username: username, password: newValue)
                case (.bearerToken, .bearer):
                    tab.draft.auth = .bearer(token: newValue)
                case (.apiKeyName, .apiKey(_, let value, let location)):
                    tab.draft.auth = .apiKey(key: newValue, value: value, location: location)
                case (.apiKeyValue, .apiKey(let key, _, let location)):
                    tab.draft.auth = .apiKey(key: key, value: newValue, location: location)
                default:
                    break
                }
            })
    }

    private var authKind: Binding<Auth.Kind> {
        Binding(
            get: { tab.draft.auth.kind },
            set: { tab.draft.auth = .empty($0) })
    }

    private var apiKeyLocation: Binding<APIKeyLocation> {
        Binding(
            get: {
                if case .apiKey(_, _, let location) = tab.draft.auth { return location }
                return .header
            },
            set: {
                guard case .apiKey(let key, let value, _) = tab.draft.auth else { return }
                tab.draft.auth = .apiKey(key: key, value: value, location: $0)
            })
    }
}

/// A labelled field that hides its contents until asked, for anything credential-shaped.
struct RevealableField: View {
    var label: String
    @Binding var text: String
    var isSecret: Bool

    @State private var isRevealed = false

    init(_ label: String, text: Binding<String>, isSecret: Bool) {
        self.label = label
        _text = text
        self.isSecret = isSecret
    }

    var body: some View {
        LabeledContent(label) {
            HStack(spacing: 6) {
                if isSecret && !isRevealed {
                    SecureField(label, text: $text)
                        .textFieldStyle(.roundedBorder)
                } else {
                    TextField(label, text: $text)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.body, design: .monospaced))
                }
                if isSecret {
                    Button {
                        isRevealed.toggle()
                    } label: {
                        Image(systemName: isRevealed ? "eye.slash" : "eye")
                    }
                    .buttonStyle(.borderless)
                    .help(isRevealed ? "Hide" : "Reveal")
                    .accessibilityLabel(isRevealed ? "Hide \(label)" : "Reveal \(label)")
                }
            }
            .accessibilityLabel(label)
        }
    }
}
