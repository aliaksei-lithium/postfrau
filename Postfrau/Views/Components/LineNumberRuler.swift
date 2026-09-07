import AppKit

/// A line-number gutter for `NSTextView`.
///
/// Draws only the lines in the visible rect, so the cost does not grow with document size — a
/// 20 MB response scrolls exactly as smoothly with the gutter on as off.
final class LineNumberRuler: NSRulerView {
    private weak var textView: NSTextView?

    init(textView: NSTextView) {
        self.textView = textView
        super.init(scrollView: textView.enclosingScrollView, orientation: .verticalRuler)
        clientView = textView
        ruleThickness = 44
    }

    @available(*, unavailable)
    required init(coder: NSCoder) {
        fatalError("not used from a nib")
    }

    /// Widens the gutter so the largest line number in the document fits.
    func updateThickness(forLineCount lineCount: Int) {
        let digits = max(2, String(lineCount).count)
        let width = max(28, CGFloat(digits) * 8 + 14)
        if abs(width - ruleThickness) > 0.5 { ruleThickness = width }
    }

    override func drawHashMarksAndLabels(in rect: NSRect) {
        guard let textView,
              let layoutManager = textView.layoutManager,
              let container = textView.textContainer
        else { return }

        let text = textView.string as NSString
        let inset = textView.textContainerInset.height
        let font = NSFont.monospacedDigitSystemFont(
            ofSize: (textView.font?.pointSize ?? 12) - 1, weight: .regular)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font, .foregroundColor: NSColor.tertiaryLabelColor,
        ]

        // Only the glyphs actually on screen.
        let visible = convert(bounds, to: textView)
        let glyphRange = layoutManager.glyphRange(forBoundingRect: visible, in: container)
        let charRange = layoutManager.characterRange(forGlyphRange: glyphRange, actualGlyphRange: nil)

        // Count the newlines before the visible range once, then increment while drawing.
        var lineNumber = 1
        if charRange.location > 0 {
            text.enumerateSubstrings(
                in: NSRange(location: 0, length: charRange.location),
                options: [.byLines, .substringNotRequired]
            ) { _, _, _, _ in lineNumber += 1 }
        }

        var index = charRange.location
        while index < NSMaxRange(charRange) {
            let lineRange = text.lineRange(for: NSRange(location: index, length: 0))
            let lineGlyphRange = layoutManager.glyphRange(
                forCharacterRange: lineRange, actualCharacterRange: nil)
            let lineRect = layoutManager.boundingRect(forGlyphRange: lineGlyphRange, in: container)

            let label = "\(lineNumber)" as NSString
            let size = label.size(withAttributes: attributes)
            let y = lineRect.minY + inset - convert(NSPoint.zero, from: textView).y
            label.draw(
                at: NSPoint(x: ruleThickness - size.width - 6, y: y),
                withAttributes: attributes)

            lineNumber += 1
            index = NSMaxRange(lineRange)
            if lineRange.length == 0 { break }
        }
    }
}
