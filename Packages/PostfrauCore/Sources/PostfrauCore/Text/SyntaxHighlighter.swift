import Foundation

/// What a token is, independent of how it should look. The app maps these to colours through its
/// `Theme`, which keeps every palette decision out of Core.
public enum SyntaxKind: String, Sendable, Hashable, CaseIterable {
    case punctuation
    /// An object key, as distinct from a string value.
    case key
    case string
    case number
    /// `true`, `false`, `null`.
    case keyword
    case tagName
    case attributeName
    case attributeValue
    case comment
    /// Character data between tags.
    case text
}

/// A coloured run. Offsets are UTF-16 code units, which is what `NSTextStorage` wants.
public struct SyntaxToken: Sendable, Hashable {
    public var location: Int
    public var length: Int
    public var kind: SyntaxKind

    public init(location: Int, length: Int, kind: SyntaxKind) {
        self.location = location
        self.length = length
        self.kind = kind
    }
}

public protocol SyntaxHighlighter: Sendable {
    /// Tokens in document order, non-overlapping. Runs the caller does not care about (plain
    /// whitespace, unremarkable text) are simply absent.
    func tokens(in text: String) -> [SyntaxToken]
}

extension SyntaxHighlighter {
    /// Beyond this many UTF-16 units, only the head of the document is tokenized.
    ///
    /// Highlighting a 50 MB response would cost more than it is worth — nobody reads past the
    /// first screens of one, and the viewer only needs the visible part to look right.
    public static var highlightLimit: Int { 4 * 1024 * 1024 }

    /// The size above which highlighting should be moved off the main thread (`PLAN.md` §6).
    public static var backgroundThreshold: Int { 256 * 1024 }
}

/// Picks the right highlighter for a body, or none.
public enum Highlighters {
    public static func forContent(_ content: ContentKind) -> (any SyntaxHighlighter)? {
        switch content {
        case .json: JSONHighlighter()
        case .xml, .html: XMLHighlighter()
        case .text, .image, .pdf, .binary: nil
        }
    }
}
