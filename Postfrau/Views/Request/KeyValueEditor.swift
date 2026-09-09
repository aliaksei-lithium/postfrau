import SwiftUI
import PostfrauCore

/// The table used by Params, Headers, the urlencoded body and the variables editor.
///
/// Always shows one blank row to type into (`KeyValueRows.withTrailingBlank`), which is why dirty
/// tracking compares *normalized* requests — see `RequestItem.normalized()`.
struct KeyValueEditor: View {
    @Binding var rows: [KeyValue]
    var keyPrompt = "Key"
    var valuePrompt = "Value"
    var showsDescription = true
    /// Suggestions for the key field, given what has been typed.
    var keySuggestions: (String) -> [String] = { _ in [] }
    /// Suggestions for the value field, given the row's key and what has been typed.
    var valueSuggestions: (String, String) -> [String] = { _, _ in [] }
    /// Called after any edit so `AppState` can mark the tab dirty.
    var onChange: () -> Void = {}

    @State private var hoveredRow: UUID?

    var body: some View {
        VStack(spacing: 0) {
            headerRow
            Divider()
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach($rows) { $row in
                        rowView($row)
                        Divider().opacity(0.4)
                    }
                }
            }
        }
        .background(.background)
        .onAppear { normalize() }
    }

    private var headerRow: some View {
        // `Spacer`, not `Color.clear`: a `Color` is greedy in *both* axes, so constraining only
        // its width left these standing in for the checkbox and delete button while stretching
        // the header to the full height of the pane.
        HStack(spacing: 8) {
            Spacer().frame(width: 18)
            Text(keyPrompt).frame(maxWidth: .infinity, alignment: .leading)
            Text(valuePrompt).frame(maxWidth: .infinity, alignment: .leading)
            if showsDescription {
                Text("Description").frame(maxWidth: .infinity, alignment: .leading)
            }
            Spacer().frame(width: 20)
        }
        .font(.caption.weight(.medium))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .accessibilityHidden(true)
    }

    private func rowView(_ row: Binding<KeyValue>) -> some View {
        let isBlank = row.wrappedValue.isEmpty

        return HStack(spacing: 8) {
            // Drawn rather than `Toggle(.checkbox)`. That style is an `NSButton`, and a table of
            // them is re-driven through AppKit on every tab switch — four of them cost 8 ms of
            // the switch. This is a plain SwiftUI button that looks the same.
            Button {
                row.enabled.wrappedValue.toggle()
                commit()
            } label: {
                Image(systemName: row.wrappedValue.enabled ? "checkmark.square.fill" : "square")
                    .font(.system(size: 13))
                    .foregroundStyle(
                        row.wrappedValue.enabled ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
            }
            .buttonStyle(.plain)
            .frame(width: 18)
            // The blank row has nothing to enable yet.
            .disabled(isBlank)
            .opacity(isBlank ? 0.35 : 1)
            .accessibilityLabel(
                row.wrappedValue.key.isEmpty
                    ? "Enable this row" : "Enable \(row.wrappedValue.key)")
            .accessibilityAddTraits(row.wrappedValue.enabled ? [.isToggle, .isSelected] : .isToggle)

            // No placeholder: the column header above already says "Parameter" or "Header", and
            // repeating it in every empty cell reads as a wall of the same word.
            SuggestingTextField(
                text: row.key, prompt: "", suggestions: keySuggestions, onCommit: commit)
            .frame(maxWidth: .infinity)
            .accessibilityLabel("\(keyPrompt) name")
            .onChange(of: row.wrappedValue.key) { commit() }

            SuggestingTextField(
                text: row.value, prompt: "",
                suggestions: { valueSuggestions(row.wrappedValue.key, $0) }, onCommit: commit)
            .frame(maxWidth: .infinity)
            .accessibilityLabel("\(keyPrompt) value")
            .onChange(of: row.wrappedValue.value) { commit() }

            if showsDescription {
                TextField("", text: Binding(
                    get: { row.wrappedValue.description ?? "" },
                    set: { row.wrappedValue.description = $0.isEmpty ? nil : $0 }))
                .textFieldStyle(.plain)
                .frame(maxWidth: .infinity)
                .accessibilityLabel("Description")
                .onChange(of: row.wrappedValue.description) { commit() }
            }

            // Built only for the row under the pointer. As `.opacity(0)` on every row this was
            // a live button per row, constructed and laid out on every rebuild — and the table
            // is rebuilt on every tab switch. The `Spacer` keeps the column width steady.
            if hoveredRow == row.wrappedValue.id && !isBlank {
                Button {
                    delete(row.wrappedValue.id)
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .frame(width: 20)
                .help("Delete this row")
                .accessibilityLabel("Delete \(row.wrappedValue.key)")
            } else {
                Spacer().frame(width: 20)
            }
        }
        .font(.callout)
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
        .opacity(row.wrappedValue.enabled || isBlank ? 1 : 0.5)
        .onHover { hoveredRow = $0 ? row.wrappedValue.id : nil }
        // The delete button above exists only while the pointer is on the row, so the row itself
        // carries the action — otherwise VoiceOver, which never hovers, could not reach it.
        .accessibilityAction(named: "Delete this row") {
            guard !isBlank else { return }
            delete(row.wrappedValue.id)
        }
        // ⌘⌫ removes the row the cursor is in, matching the shortcut in §5.
        .onKeyPress(keys: [.delete], phases: .down) { press in
            guard press.modifiers.contains(.command), !isBlank else { return .ignored }
            delete(row.wrappedValue.id)
            return .handled
        }
    }

    private func delete(_ id: UUID) {
        rows.removeAll { $0.id == id }
        normalize()
        onChange()
    }

    private func commit() {
        normalize()
        onChange()
    }

    /// Keeps exactly one blank row at the end, without disturbing the row being edited.
    private func normalize() {
        let normalized = KeyValueRows.withTrailingBlank(rows)
        if normalized != rows { rows = normalized }
    }
}
