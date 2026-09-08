import SwiftUI
import PostfrauCore

/// The variables table, used by collections, folders and (in Phase 7) environments.
///
/// Same shape as `KeyValueEditor` but with a secret toggle, and it hides a secret's value behind
/// a reveal button so a value never sits on screen by accident.
struct VariablesEditor: View {
    @Binding var variables: [Variable]
    var showsSecretToggle = true
    var onChange: () -> Void = {}

    @State private var hoveredRow: UUID?
    @State private var revealed: Set<UUID> = []

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach($variables) { $variable in
                        row($variable)
                        Divider().opacity(0.4)
                    }
                }
            }
        }
        .onAppear(perform: normalize)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Spacer().frame(width: 18)
            Text("Variable").frame(maxWidth: .infinity, alignment: .leading)
            Text("Value").frame(maxWidth: .infinity, alignment: .leading)
            if showsSecretToggle { Text("Secret").frame(width: 52) }
            Spacer().frame(width: 20)
        }
        .font(.caption.weight(.medium))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .accessibilityHidden(true)
    }

    private func row(_ variable: Binding<Variable>) -> some View {
        let value = variable.wrappedValue
        let isBlank = value.isEmpty
        let isHidden = value.isSecret && !revealed.contains(value.id)

        return HStack(spacing: 8) {
            Toggle("", isOn: variable.enabled)
                .labelsHidden()
                .toggleStyle(.checkbox)
                .frame(width: 18)
                .disabled(isBlank)
                .opacity(isBlank ? 0.35 : 1)
                .accessibilityLabel("Enable \(value.key.isEmpty ? "this variable" : value.key)")
                .onChange(of: variable.wrappedValue.enabled) { commit() }

            TextField("Variable", text: variable.key)
                .textFieldStyle(.plain)
                .frame(maxWidth: .infinity)
                .accessibilityLabel("Variable name")
                .onChange(of: variable.wrappedValue.key) { commit() }

            HStack(spacing: 4) {
                if isHidden {
                    SecureField("Value", text: variable.value)
                        .textFieldStyle(.plain)
                } else {
                    TextField("Value", text: variable.value)
                        .textFieldStyle(.plain)
                }
                if value.isSecret {
                    Button {
                        if revealed.contains(value.id) {
                            revealed.remove(value.id)
                        } else {
                            revealed.insert(value.id)
                        }
                    } label: {
                        Image(systemName: isHidden ? "eye" : "eye.slash")
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel(isHidden ? "Reveal \(value.key)" : "Hide \(value.key)")
                }
            }
            .frame(maxWidth: .infinity)
            .accessibilityLabel("Variable value")
            .onChange(of: variable.wrappedValue.value) { commit() }

            if showsSecretToggle {
                Toggle("", isOn: variable.isSecret)
                    .labelsHidden()
                    .toggleStyle(.checkbox)
                    .frame(width: 52)
                    .disabled(isBlank)
                    .help("Secret values are kept in the Keychain and never written to the data folder")
                    .accessibilityLabel("\(value.key) is secret")
                    .onChange(of: variable.wrappedValue.isSecret) { commit() }
            }

            Button {
                variables.removeAll { $0.id == value.id }
                commit()
            } label: {
                Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
            }
            .buttonStyle(.plain)
            .frame(width: 20)
            .opacity(hoveredRow == value.id && !isBlank ? 1 : 0)
            .disabled(isBlank)
            .accessibilityLabel("Delete \(value.key)")
        }
        .font(.callout)
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
        .opacity(value.enabled || isBlank ? 1 : 0.5)
        .onHover { hoveredRow = $0 ? value.id : nil }
    }

    private func commit() {
        normalize()
        onChange()
    }

    /// One blank row at the end to type into, matching every other table in the app.
    private func normalize() {
        var kept = variables.filter { !$0.isEmpty }
        kept.append(variables.last(where: { $0.isEmpty }) ?? Variable())
        if kept != variables { variables = kept }
    }
}
