import AppKit
import SwiftUI
import PostfrauCore

/// The URL field: a single-line editor that colours `{{variables}}` and shows what each resolves
/// to on hover.
///
/// `TextField` cannot do either — it has no access to attributed runs while editing and no
/// per-character hit testing — so this is an `NSTextView` configured to behave like a one-line
/// field: Return sends instead of inserting a newline, and there is no wrapping.
struct TokenTextField: NSViewRepresentable {
    @Binding var text: String
    var fontSize: Double
    var placeholder: String
    /// Resolves `{{…}}` so tokens can be coloured and explained. Re-created whenever the
    /// environment or the request's scope changes.
    var resolver: VariableResolver
    var onSubmit: () -> Void
    var onChange: (String) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        let textView = TokenTextViewCore()
        textView.coordinator = context.coordinator
        textView.delegate = context.coordinator
        textView.isRichText = false
        textView.isFieldEditor = false
        textView.allowsUndo = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.isGrammarCheckingEnabled = false
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 6, height: 6)
        textView.textContainer?.widthTracksTextView = false
        textView.textContainer?.size = NSSize(
            width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.lineFragmentPadding = 0
        textView.isHorizontallyResizable = true
        textView.maxSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.setAccessibilityLabel("Request URL")
        textView.setAccessibilityRole(.textField)

        scrollView.documentView = textView
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = false
        scrollView.hasHorizontalScroller = false
        scrollView.verticalScrollElasticity = .none
        scrollView.borderType = .noBorder

        context.coordinator.apply(self, to: textView, initial: true)
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? TokenTextViewCore else { return }
        context.coordinator.parent = self
        context.coordinator.apply(self, to: textView, initial: false)
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: TokenTextField
        private var displayedText: String?
        /// Tokens for the text currently on screen, used for hover tooltips.
        private(set) var tokens: [VariableToken] = []
        private(set) var currentText = ""

        init(_ parent: TokenTextField) {
            self.parent = parent
        }

        func apply(_ config: TokenTextField, to textView: NSTextView, initial: Bool) {
            let font = NSFont.monospacedSystemFont(ofSize: config.fontSize, weight: .regular)
            let textChanged = config.text != (displayedText ?? textView.string)

            if initial || textChanged {
                let selection = textView.selectedRanges
                textView.string = config.text
                displayedText = config.text
                if !initial {
                    let length = (textView.string as NSString).length
                    let valid = selection.filter { NSMaxRange($0.rangeValue) <= length }
                    if !valid.isEmpty { textView.selectedRanges = valid }
                }
            }
            highlight(textView, font: font, config: config)
        }

        /// Colours each `{{token}}`: green when it resolves, red when it does not.
        ///
        /// Re-applied on every edit. This is a single-line field, so the cost is trivial — no need
        /// for the incremental machinery a document-sized editor would want.
        private func highlight(_ textView: NSTextView, font: NSFont, config: TokenTextField) {
            guard let storage = textView.textStorage else { return }
            let text = textView.string
            currentText = text
            tokens = config.resolver.tokens(in: text)

            let full = NSRange(location: 0, length: (text as NSString).length)
            storage.beginEditing()
            storage.setAttributes([.font: font, .foregroundColor: NSColor.textColor], range: full)
            for token in tokens {
                let nsRange = NSRange(token.range, in: text)
                storage.addAttributes(
                    [
                        .foregroundColor: token.isResolved
                            ? NSColor.systemGreen : NSColor.systemRed,
                        .font: NSFont.monospacedSystemFont(ofSize: config.fontSize, weight: .medium),
                    ],
                    range: nsRange)
            }
            storage.endEditing()
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            displayedText = textView.string
            parent.text = textView.string
            parent.onChange(textView.string)
            if let tokenView = textView as? TokenTextViewCore {
                highlight(tokenView, font: tokenView.font ?? .monospacedSystemFont(
                    ofSize: parent.fontSize, weight: .regular), config: parent)
            }
        }

        /// Return sends the request rather than inserting a newline, which is what makes this
        /// behave like a text field.
        func textView(
            _ textView: NSTextView, doCommandBy commandSelector: Selector
        ) -> Bool {
            if commandSelector == #selector(NSResponder.insertNewline(_:)) {
                parent.onSubmit()
                return true
            }
            return false
        }

        /// The tooltip for a point in the view: the resolved value of the token under the cursor.
        func tooltip(at characterIndex: Int) -> String? {
            guard let token = tokens.first(where: { token in
                let range = NSRange(token.range, in: currentText)
                return NSLocationInRange(characterIndex, range)
            }) else { return nil }

            if token.isSecret { return "\(token.name) — secret (hidden)" }
            if let value = token.resolvedValue {
                return value.isEmpty ? "\(token.name) is empty" : "\(token.name) = \(value)"
            }
            return "\(token.name) is not defined in this scope"
        }
    }
}

/// The `NSTextView` subclass, which exists only to turn hover position into a tooltip.
final class TokenTextViewCore: NSTextView {
    weak var coordinator: TokenTextField.Coordinator?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect],
            owner: self))
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        let point = convert(event.locationInWindow, from: nil)
        let index = characterIndexForInsertion(at: point)
        toolTip = MainActor.assumeIsolated { coordinator?.tooltip(at: index) }
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        toolTip = nil
    }
}
