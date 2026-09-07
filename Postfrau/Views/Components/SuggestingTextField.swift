import SwiftUI

/// A text field with an inline completion list.
///
/// macOS has `NSComboBox`, but it insists on a fixed list and its own styling; the Headers tab
/// needs suggestions that change with what has been typed and a field that still looks like every
/// other cell in the table. Keyboard handling matches the rest of macOS: ↑/↓ move, ↩ or ⇥ accepts,
/// ⎋ dismisses.
struct SuggestingTextField: View {
    @Binding var text: String
    var prompt: String
    var suggestions: (String) -> [String]
    var onCommit: () -> Void = {}

    @FocusState private var isFocused: Bool
    @State private var highlighted = 0
    @State private var isDismissed = false

    private var matches: [String] {
        guard isFocused, !isDismissed else { return [] }
        let found = suggestions(text)
        // A single suggestion identical to what is typed is noise, not help.
        if found.count == 1, found[0].caseInsensitiveCompare(text) == .orderedSame { return [] }
        return found
    }

    var body: some View {
        TextField(prompt, text: $text)
            .textFieldStyle(.plain)
            .focused($isFocused)
            .onChange(of: text) { isDismissed = false; highlighted = 0 }
            .onChange(of: isFocused) { _, focused in if !focused { isDismissed = false } }
            .onSubmit {
                if !matches.isEmpty { accept(matches[min(highlighted, matches.count - 1)]) }
                onCommit()
            }
            .onKeyPress(.downArrow) {
                guard !matches.isEmpty else { return .ignored }
                highlighted = min(highlighted + 1, matches.count - 1)
                return .handled
            }
            .onKeyPress(.upArrow) {
                guard !matches.isEmpty else { return .ignored }
                highlighted = max(highlighted - 1, 0)
                return .handled
            }
            .onKeyPress(.escape) {
                guard !matches.isEmpty else { return .ignored }
                isDismissed = true
                return .handled
            }
            .onKeyPress(.tab) {
                guard !matches.isEmpty else { return .ignored }
                accept(matches[min(highlighted, matches.count - 1)])
                return .handled
            }
            .overlay(alignment: .topLeading) { completionList }
    }

    @ViewBuilder
    private var completionList: some View {
        if !matches.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(matches.enumerated()), id: \.element) { index, suggestion in
                    Text(suggestion)
                        .font(.callout)
                        .lineLimit(1)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(index == highlighted ? Color.accentColor.opacity(0.85) : .clear)
                        .foregroundStyle(index == highlighted ? .white : .primary)
                        .contentShape(.rect)
                        .onTapGesture { accept(suggestion) }
                }
            }
            .frame(minWidth: 180, alignment: .leading)
            .padding(.vertical, 4)
            // A floating panel, so glass is right here (§5: glass on chrome, not on content).
            .glassEffect(in: .rect(cornerRadius: 8))
            .offset(y: 22)
            .zIndex(1)
            .accessibilityLabel("Suggestions for \(prompt)")
        }
    }

    private func accept(_ suggestion: String) {
        text = suggestion
        isDismissed = true
        highlighted = 0
    }
}
