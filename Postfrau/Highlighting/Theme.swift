import AppKit
import PostfrauCore

/// Maps Core's `SyntaxKind`s to colours.
///
/// Core produces kinds, not colours, so the tokenizers stay testable with plain `swift test` and
/// carry no opinion about appearance. Everything here is built from system colours, which means
/// light, dark and Increase Contrast are handled by AppKit rather than by a hand-tuned palette.
struct Theme: Sendable {
    var colors: [SyntaxKind: NSColor]
    var plain: NSColor

    static let `default` = Theme(
        colors: [
            .punctuation: .tertiaryLabelColor,
            .key: .systemBlue,
            .string: .systemRed,
            .number: .systemPurple,
            .keyword: .systemOrange,
            .tagName: .systemBlue,
            .attributeName: .systemPurple,
            .attributeValue: .systemRed,
            .comment: .secondaryLabelColor,
            .text: .labelColor,
        ],
        plain: .textColor)

    func color(for kind: SyntaxKind) -> NSColor {
        colors[kind] ?? plain
    }
}
