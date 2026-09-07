import Foundation

/// A single-pass JSON tokenizer.
///
/// Scans the UTF-16 view because every character JSON gives structural meaning is ASCII: anything
/// non-ASCII can only appear inside a string or a comment, where it is copied over without
/// inspection. That also makes the offsets directly usable as `NSRange`s.
///
/// Deliberately not regex-based (`PLAN.md` §6): a regex over a multi-megabyte document is both
/// slow and prone to catastrophic backtracking on unbalanced input, and this has to run on
/// malformed bodies too — a highlighter that gives up on a truncated response is useless.
public struct JSONHighlighter: SyntaxHighlighter {
    public init() {}

    public func tokens(in text: String) -> [SyntaxToken] {
        let units = Array(text.utf16.prefix(Self.highlightLimit))
        var tokens: [SyntaxToken] = []
        tokens.reserveCapacity(units.count / 12)

        var index = 0
        while index < units.count {
            let unit = units[index]

            switch unit {
            case openBrace, closeBrace, openBracket, closeBracket, colon, comma:
                tokens.append(SyntaxToken(location: index, length: 1, kind: .punctuation))
                index += 1

            case quote:
                let start = index
                index = endOfString(units, from: index)
                // A string is a key when the next meaningful character is a colon.
                let isKey = nextMeaningful(units, from: index) == colon
                tokens.append(SyntaxToken(
                    location: start, length: index - start, kind: isKey ? .key : .string))

            case let byte where isNumberStart(byte):
                let start = index
                while index < units.count, isNumberBody(units[index]) { index += 1 }
                tokens.append(SyntaxToken(location: start, length: index - start, kind: .number))

            case let byte where isLetter(byte):
                let start = index
                while index < units.count, isLetter(units[index]) { index += 1 }
                tokens.append(SyntaxToken(location: start, length: index - start, kind: .keyword))

            default:
                index += 1
            }
        }
        return tokens
    }

    /// The index just past the closing quote, honouring backslash escapes. An unterminated string
    /// runs to the end of the document rather than throwing — malformed input still gets coloured.
    private func endOfString(_ units: [UInt16], from start: Int) -> Int {
        var index = start + 1
        while index < units.count {
            if units[index] == backslash {
                index += 2
                continue
            }
            if units[index] == quote { return index + 1 }
            index += 1
        }
        return units.count
    }

    private func nextMeaningful(_ units: [UInt16], from start: Int) -> UInt16? {
        var index = start
        while index < units.count, isWhitespace(units[index]) { index += 1 }
        return index < units.count ? units[index] : nil
    }

    private func isNumberStart(_ unit: UInt16) -> Bool {
        (unit >= zero && unit <= nine) || unit == minus
    }

    private func isNumberBody(_ unit: UInt16) -> Bool {
        (unit >= zero && unit <= nine) || unit == minus || unit == plus
            || unit == dot || unit == lowerE || unit == upperE
    }

    private func isLetter(_ unit: UInt16) -> Bool {
        (unit >= 0x61 && unit <= 0x7A) || (unit >= 0x41 && unit <= 0x5A)
    }

    private func isWhitespace(_ unit: UInt16) -> Bool {
        unit == 0x20 || unit == 0x09 || unit == 0x0A || unit == 0x0D
    }

    // Named constants keep the switch above readable.
    private let quote: UInt16 = 0x22
    private let backslash: UInt16 = 0x5C
    private let openBrace: UInt16 = 0x7B
    private let closeBrace: UInt16 = 0x7D
    private let openBracket: UInt16 = 0x5B
    private let closeBracket: UInt16 = 0x5D
    private let colon: UInt16 = 0x3A
    private let comma: UInt16 = 0x2C
    private let zero: UInt16 = 0x30
    private let nine: UInt16 = 0x39
    private let minus: UInt16 = 0x2D
    private let plus: UInt16 = 0x2B
    private let dot: UInt16 = 0x2E
    private let lowerE: UInt16 = 0x65
    private let upperE: UInt16 = 0x45
}
