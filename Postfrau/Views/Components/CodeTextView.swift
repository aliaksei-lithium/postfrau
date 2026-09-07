import AppKit
import SwiftUI
import PostfrauCore

/// A monospaced text view backed by `NSTextView` (TextKit 2).
///
/// SwiftUI's `TextEditor` gained rich text in macOS 26 but is still not a code editor: no control
/// over line wrapping, no cheap way to apply thousands of attributed runs, no ruler, and no find
/// integration. Everything Postfrau shows as code — request bodies, response bodies — uses this.
///
/// Highlighting arrives as `[SyntaxToken]` from Core rather than as an `AttributedString`: applying
/// runs straight to the text storage avoids building a second copy of a multi-megabyte document.
struct CodeTextView: NSViewRepresentable {
    @Binding var text: String
    var isEditable: Bool
    var fontSize: Double
    /// Off means an unbounded text container, which forces TextKit to measure the *whole* widest
    /// line up front. A minified JSON response is one line several megabytes long, and measuring it
    /// blocks the main thread for tens of seconds — so wrapping defaults on for response bodies.
    var wrapsLines: Bool
    var showsLineNumbers: Bool = false
    /// Colouring for the current text. Offsets are UTF-16 units, matching `NSTextStorage`.
    var tokens: [SyntaxToken] = []
    var theme: Theme = .default
    /// Bumped to open the system find bar.
    var findTrigger: Int = 0
    var accessibilityLabel: String
    var onChange: ((String) -> Void)?

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSTextView.scrollableTextView()
        guard let textView = scrollView.documentView as? NSTextView else { return scrollView }
        object_setClass(scrollView, RulerRedrawingScrollView.self)

        textView.delegate = context.coordinator
        textView.isRichText = false
        textView.allowsUndo = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isGrammarCheckingEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        // The system find bar gives search, match count, wrap and next/previous for free, and
        // behaves the way every other Mac app does.
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true
        textView.textContainerInset = NSSize(width: 8, height: 8)
        textView.drawsBackground = false

        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true

        let ruler = LineNumberRuler(textView: textView)
        scrollView.verticalRulerView = ruler
        scrollView.hasVerticalRuler = true
        scrollView.rulersVisible = showsLineNumbers

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
        private var displayedText: String?
        private var displayedTokenCount = -1
        private var displayedFindTrigger = 0

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

            applyWrapping(config, textView: textView, scrollView: scrollView)

            if scrollView.rulersVisible != config.showsLineNumbers {
                scrollView.rulersVisible = config.showsLineNumbers
            }

            let textChanged = config.text != (displayedText ?? textView.string)
            let tokensChanged = config.tokens.count != displayedTokenCount

            if initial || textChanged {
                let selection = textView.selectedRanges
                textView.string = config.text
                displayedText = config.text
                if !initial, config.isEditable {
                    let length = (textView.string as NSString).length
                    let valid = selection.filter { NSMaxRange($0.rangeValue) <= length }
                    if !valid.isEmpty { textView.selectedRanges = valid }
                }
            }

            if initial || textChanged || tokensChanged {
                applyHighlighting(config, textView: textView, font: font)
                displayedTokenCount = config.tokens.count
                // Counted over UTF-8 rather than `Character`s: grapheme breaking a megabyte of
                // text costs several milliseconds on every update for no benefit here.
                (scrollView.verticalRulerView as? LineNumberRuler)?
                    .updateThickness(forLineCount: 1 + config.text.utf8.count { $0 == 0x0A })
            }

            if config.findTrigger != displayedFindTrigger {
                displayedFindTrigger = config.findTrigger
                showFindBar(in: textView)
            }
        }

        private func applyWrapping(
            _ config: CodeTextView, textView: NSTextView, scrollView: NSScrollView
        ) {
            // Wrapping is a text-container property; off means an unbounded width and a
            // horizontal scroller.
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
        }

        private func applyHighlighting(
            _ config: CodeTextView, textView: NSTextView, font: NSFont
        ) {
            guard let storage = textView.textStorage else { return }
            let length = (textView.string as NSString).length
            let full = NSRange(location: 0, length: length)

            storage.beginEditing()
            storage.setAttributes([.font: font, .foregroundColor: config.theme.plain], range: full)
            for token in config.tokens {
                let end = token.location + token.length
                // Tokens are computed off-main against a snapshot; if the text moved on since,
                // skip anything that no longer fits rather than trapping on a bad range.
                guard token.location >= 0, end <= length else { continue }
                storage.addAttribute(
                    .foregroundColor,
                    value: config.theme.color(for: token.kind),
                    range: NSRange(location: token.location, length: token.length))
            }
            storage.endEditing()
        }

        /// Opens the system find bar, which supplies search, match count, wrap and next/previous.
        private func showFindBar(in textView: NSTextView) {
            let item = NSMenuItem()
            item.tag = NSTextFinder.Action.showFindInterface.rawValue
            textView.performTextFinderAction(item)
            textView.window?.makeFirstResponder(textView)
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            displayedText = textView.string
            parent.text = textView.string
            parent.onChange?(textView.string)
        }
    }
}

/// Keeps the line-number gutter in step with the text as it scrolls.
///
/// `NSRulerView` redraws its own decorations, but a ruler that draws per-line labels has to be
/// invalidated whenever the clip view moves. Doing it here rather than through a notification
/// observer keeps the coordinator free of teardown it cannot perform from a nonisolated `deinit`.
final class RulerRedrawingScrollView: NSScrollView {
    override func reflectScrolledClipView(_ clipView: NSClipView) {
        super.reflectScrolledClipView(clipView)
        verticalRulerView?.needsDisplay = true
    }
}
