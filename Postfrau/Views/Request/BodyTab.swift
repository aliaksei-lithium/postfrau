import SwiftUI
import PostfrauCore

/// Every request body mode.
struct BodyTab: View {
    @Environment(AppState.self) private var state
    @Bindable var tab: RequestTab

    @State private var beautifyError: String?

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            content
        }
        .background(.background)
    }

    private var toolbar: some View {
        HStack(spacing: 10) {
            Picker("Body type", selection: bodyKind) {
                ForEach(RequestBody.Kind.allCases, id: \.self) { kind in
                    Text(kind.displayName).tag(kind)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .accessibilityLabel("Body type")

            if case .raw(_, let language) = tab.draft.body {
                Picker("Language", selection: rawLanguage) {
                    ForEach(RawLanguage.allCases, id: \.self) { candidate in
                        Text(candidate.displayName).tag(candidate)
                    }
                }
                .labelsHidden()
                .fixedSize()
                .accessibilityLabel("Body language")

                if language == .json {
                    Button("Beautify", action: beautify)
                        .help("Re-indent the JSON without changing any value")
                        .accessibilityLabel("Beautify the JSON body")
                }
            }

            Spacer()

            if let beautifyError {
                Label(beautifyError, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .lineLimit(1)
                    .help(beautifyError)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private var content: some View {
        switch tab.draft.body {
        case .none:
            CenteredMessage(
                symbol: "circle.slash", title: "No body",
                message: "This request sends no body.")

        case .raw:
            CodeTextView(
                text: rawText,
                isEditable: true,
                fontSize: state.settings.editorFontSize,
                wrapsLines: state.settings.wrapResponseLines,
                accessibilityLabel: "Request body")

        case .urlEncoded:
            KeyValueEditor(
                rows: urlEncodedRows,
                keyPrompt: "Field",
                valuePrompt: "Value",
                showsDescription: false,
                onChange: { state.draftChanged(tab) })
            .accessibilityLabel("URL-encoded body fields")

        case .formData:
            FormDataEditor(tab: tab)

        case .binary:
            BinaryBodyPicker(tab: tab)
        }
    }

    private func beautify() {
        guard case .raw(let text, let language) = tab.draft.body, language == .json else { return }
        do {
            let pretty = try JSONPrettyPrinter.prettyPrint(text)
            tab.draft.body = .raw(text: pretty, language: .json)
            beautifyError = nil
            state.draftChanged(tab)
        } catch {
            beautifyError = AppState.message(for: error)
        }
    }

    // MARK: - Bindings

    private var bodyKind: Binding<RequestBody.Kind> {
        Binding(
            get: { tab.draft.body.kind },
            set: {
                tab.draft.body = .empty($0)
                beautifyError = nil
                state.draftChanged(tab)
            })
    }

    private var rawLanguage: Binding<RawLanguage> {
        Binding(
            get: {
                if case .raw(_, let language) = tab.draft.body { return language }
                return .json
            },
            set: {
                guard case .raw(let text, _) = tab.draft.body else { return }
                tab.draft.body = .raw(text: text, language: $0)
                state.draftChanged(tab)
            })
    }

    private var rawText: Binding<String> {
        Binding(
            get: {
                if case .raw(let text, _) = tab.draft.body { return text }
                return ""
            },
            set: {
                guard case .raw(_, let language) = tab.draft.body else { return }
                tab.draft.body = .raw(text: $0, language: language)
                state.draftChanged(tab)
            })
    }

    private var urlEncodedRows: Binding<[KeyValue]> {
        Binding(
            get: {
                if case .urlEncoded(let rows) = tab.draft.body { return rows }
                return []
            },
            set: { tab.draft.body = .urlEncoded($0) })
    }
}

/// `multipart/form-data`: each field is either text or a file.
struct FormDataEditor: View {
    @Environment(AppState.self) private var state
    @Bindable var tab: RequestTab

    @State private var hoveredRow: UUID?

    private var fields: [FormField] {
        if case .formData(let fields) = tab.draft.body { return fields }
        return []
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(fields) { field in
                        row(field)
                        Divider().opacity(0.4)
                    }
                }
            }
        }
        .onAppear { normalize() }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Color.clear.frame(width: 18)
            Text("Field").frame(maxWidth: .infinity, alignment: .leading)
            Text("Type").frame(width: 70, alignment: .leading)
            Text("Value").frame(maxWidth: .infinity, alignment: .leading)
            Color.clear.frame(width: 20)
        }
        .font(.caption.weight(.medium))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .accessibilityHidden(true)
    }

    private func row(_ field: FormField) -> some View {
        let isBlank = field.isEmpty

        return HStack(spacing: 8) {
            Toggle("", isOn: binding(field, \.enabled))
                .labelsHidden()
                .toggleStyle(.checkbox)
                .frame(width: 18)
                .disabled(isBlank)
                .opacity(isBlank ? 0.35 : 1)
                .accessibilityLabel("Enable \(field.key.isEmpty ? "this field" : field.key)")

            TextField("Field", text: binding(field, \.key))
                .textFieldStyle(.plain)
                .frame(maxWidth: .infinity)
                .accessibilityLabel("Field name")

            Picker("Type", selection: valueKind(field)) {
                Text("Text").tag(false)
                Text("File").tag(true)
            }
            .labelsHidden()
            .frame(width: 70)
            .accessibilityLabel("Field type")

            valueEditor(field)
                .frame(maxWidth: .infinity)

            Button {
                update { $0.removeAll { $0.id == field.id } }
            } label: {
                Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
            }
            .buttonStyle(.plain)
            .frame(width: 20)
            .opacity(hoveredRow == field.id && !isBlank ? 1 : 0)
            .disabled(isBlank)
            .accessibilityLabel("Delete \(field.key)")
        }
        .font(.callout)
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
        .opacity(field.enabled || isBlank ? 1 : 0.5)
        .onHover { hoveredRow = $0 ? field.id : nil }
    }

    @ViewBuilder
    private func valueEditor(_ field: FormField) -> some View {
        switch field.value {
        case .text:
            TextField("Value", text: binding(field, \.textValue))
                .textFieldStyle(.plain)
                .accessibilityLabel("Field value")
        case .file(let reference):
            HStack(spacing: 6) {
                Button {
                    guard let picked = FileDialogs.chooseFile(prompt: "Attach") else { return }
                    update { fields in
                        guard let index = fields.firstIndex(where: { $0.id == field.id }) else { return }
                        fields[index].value = .file(picked)
                    }
                } label: {
                    Label(
                        reference.displayName.isEmpty ? "Choose File…" : reference.displayName,
                        systemImage: reference.bookmark == nil ? "doc.badge.plus" : "doc")
                    .lineLimit(1)
                    .truncationMode(.middle)
                }
                // `.borderless`, not `.link`: this performs an action, and a link role tells
                // VoiceOver (and XCUITest) the wrong thing about it.
                .buttonStyle(.borderless)
                .accessibilityLabel(
                    reference.displayName.isEmpty
                        ? "Choose a file for \(field.key)"
                        : "File \(reference.displayName) — click to change")

                if reference.bookmark == nil, !reference.displayName.isEmpty {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .help("This file came from an import and is not attached. Pick it again.")
                }
            }
        }
    }

    // MARK: - Editing

    private func binding<Value>(
        _ field: FormField, _ keyPath: WritableKeyPath<FormField, Value>
    ) -> Binding<Value> {
        Binding(
            get: {
                fields.first { $0.id == field.id }?[keyPath: keyPath]
                    ?? field[keyPath: keyPath]
            },
            set: { newValue in
                update { fields in
                    guard let index = fields.firstIndex(where: { $0.id == field.id }) else { return }
                    fields[index][keyPath: keyPath] = newValue
                }
            })
    }

    private func valueKind(_ field: FormField) -> Binding<Bool> {
        Binding(
            get: { if case .file = field.value { return true } else { return false } },
            set: { isFile in
                update { fields in
                    guard let index = fields.firstIndex(where: { $0.id == field.id }) else { return }
                    fields[index].value = isFile ? .file(FileReference()) : .text("")
                }
            })
    }

    private func update(_ change: (inout [FormField]) -> Void) {
        var updated = fields
        change(&updated)
        tab.draft.body = .formData(updated.withTrailingBlank)
        state.draftChanged(tab)
    }

    private func normalize() {
        let normalized = fields.withTrailingBlank
        if normalized != fields { tab.draft.body = .formData(normalized) }
    }
}

extension FormField {
    /// The text value, for binding a plain `TextField` to a `.text` case.
    var textValue: String {
        get {
            if case .text(let value) = value { return value }
            return ""
        }
        set { value = .text(newValue) }
    }
}

/// A single file sent as the whole body.
struct BinaryBodyPicker: View {
    @Environment(AppState.self) private var state
    @Bindable var tab: RequestTab

    private var reference: FileReference {
        if case .binary(let reference) = tab.draft.body { return reference }
        return FileReference()
    }

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: reference.bookmark == nil ? "doc.badge.plus" : "doc.fill")
                .font(.system(size: 28))
                .foregroundStyle(.tertiary)

            if reference.displayName.isEmpty {
                Text("No file chosen").foregroundStyle(.secondary)
            } else {
                Text(reference.displayName)
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
                if reference.bookmark == nil {
                    Label(
                        "Not attached — this came from an import. Choose the file again.",
                        systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .foregroundStyle(.orange)
                }
            }

            HStack {
                Button(reference.bookmark == nil ? "Choose File…" : "Change File…") {
                    guard let picked = FileDialogs.chooseFile(prompt: "Attach") else { return }
                    tab.draft.body = .binary(picked)
                    state.draftChanged(tab)
                }
                if reference.bookmark != nil {
                    Button("Remove") {
                        tab.draft.body = .binary(FileReference())
                        state.draftChanged(tab)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Binary body")
    }
}
