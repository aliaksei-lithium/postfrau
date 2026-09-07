import AppKit
import SwiftUI

/// A monospaced text view backed by `NSTextView` (TextKit 2).
///
/// SwiftUI's `TextEditor` gained rich text in macOS 26 but is still not a code editor: no control
/// over line wrapping, no cheap way to apply attributed runs to a large document, and no find
/// integration. Everything Postfrau shows as code — request bodies, response bodies — uses this.
struct CodeTextView: NSViewRepresentable {
    /// The text to display. For read-only views this is set from outside only.
    @Binding var text: String
    var isEditable: Bool
    var fontSize: Double
    var wrapsLines: Bool
    /// Applied on top of the plain text once highlighting exists (Phase 5).
    var attributedText: AttributedString?
    /// Set on the `NSTextView` itself: SwiftUI's `.accessibilityLabel` does not reach inside an
    /// `NSViewRepresentable`, so VoiceOver (and XCUITest) would otherwise see an unnamed text view.
    var accessibilityLabel: String
    var onChange: ((String) -> Void)?

    init(
        text: Binding<String>,
        isEditable: Bool = false,
        fontSize: Double = 12,
        wrapsLines: Bool = false,
        attributedText: AttributedString? = nil,
        accessibilityLabel: String,
        onChange: ((String) -> Void)? = nil
    ) {
        _text = text
        self.isEditable = isEditable
        self.fontSize = fontSize
        self.wrapsLines = wrapsLines
        self.attributedText = attributedText
        self.accessibilityLabel = accessibilityLabel
        self.onChange = onChange
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSTextView.scrollableTextView()
        guard let textView = scrollView.documentView as? NSTextView else { return scrollView }

        textView.delegate = context.coordinator
        textView.isRichText = false
        textView.allowsUndo = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isGrammarCheckingEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true
        textView.textContainerInset = NSSize(width: 8, height: 8)
        textView.drawsBackground = false
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true

        context.coordinator.apply(self, to: textView, scrollView: scrollView, initial: true)
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView else { return }
        context.coordinator.parent = self
        context.coordinator.apply(self, to: textView, scrollView: scrollView, initial: false)
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: CodeTextView
        /// What the view currently shows, so an external update can be told apart from an echo of
        /// the user's own typing.
        private var displayedText: String?
        private var displayedAttributes: AttributedString?

        init(_ parent: CodeTextView) {
            self.parent = parent
        }

        func apply(
            _ config: CodeTextView, to textView: NSTextView, scrollView: NSScrollView, initial: Bool
        ) {
            textView.isEditable = config.isEditable
            textView.isSelectable = true
            textView.setAccessibilityLabel(config.accessibilityLabel)
            textView.setAccessibilityRole(.textArea)
            let font = NSFont.monospacedSystemFont(ofSize: config.fontSize, weight: .regular)
            textView.font = font

            // Wrapping is a text-container property; turning it off means an unbounded width
            // plus a horizontal scroller.
            if config.wrapsLines {
                scrollView.hasHorizontalScroller = false
                textView.textContainer?.widthTracksTextView = true
                textView.textContainer?.size = NSSize(
                    width: scrollView.contentSize.width, height: CGFloat.greatestFiniteMagnitude)
                textView.isHorizontallyResizable = false
                textView.maxSize = NSSize(
                    width: scrollView.contentSize.width, height: CGFloat.greatestFiniteMagnitude)
            } else {
                scrollView.hasHorizontalScroller = true
                textView.textContainer?.widthTracksTextView = false
                textView.textContainer?.size = NSSize(
                    width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
                textView.isHorizontallyResizable = true
                textView.maxSize = NSSize(
                    width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
            }

            let attributesChanged = config.attributedText != displayedAttributes
            let textChanged = config.text != (displayedText ?? textView.string)
            guard initial || textChanged || attributesChanged else { return }

            let selection = textView.selectedRanges
            if let attributed = config.attributedText {
                let string = NSMutableAttributedString(attributed)
                string.addAttributes(
                    [.font: font], range: NSRange(location: 0, length: string.length))
                textView.textStorage?.setAttributedString(string)
            } else {
                textView.string = config.text
                textView.textStorage?.addAttributes(
                    [.font: font, .foregroundColor: NSColor.textColor],
                    range: NSRange(location: 0, length: (config.text as NSString).length))
            }
            displayedText = config.text
            displayedAttributes = config.attributedText

            // Restoring the selection keeps the caret still while typing; on a fresh document
            // there is nothing to restore.
            if !initial, config.isEditable {
                let length = (textView.string as NSString).length
                let valid = selection.compactMap { value -> NSValue? in
                    let range = value.rangeValue
                    return NSMaxRange(range) <= length ? value : nil
                }
                if !valid.isEmpty { textView.selectedRanges = valid }
            }
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            displayedText = textView.string
            parent.text = textView.string
            parent.onChange?(textView.string)
        }
    }
}
