import Foundation

/// A single-pass XML/HTML tokenizer: tag names, attribute names, attribute values, comments and
/// character data.
///
/// Like `JSONHighlighter`, it scans UTF-16 units (every structural character is ASCII) and never
/// fails: a truncated or malformed document still gets sensible colouring, which is exactly what a
/// response viewer needs.
public struct XMLHighlighter: SyntaxHighlighter {
    public init() {}

    public func tokens(in text: String) -> [SyntaxToken] {
        let units = Array(text.utf16.prefix(Self.highlightLimit))
        var tokens: [SyntaxToken] = []
        tokens.reserveCapacity(units.count / 16)

        var index = 0
        while index < units.count {
            guard units[index] == lessThan else {
                // Character data: everything up to the next tag.
                let start = index
                while index < units.count, units[index] != lessThan { index += 1 }
                if index > start, !isAllWhitespace(units, start, index) {
                    tokens.append(SyntaxToken(location: start, length: index - start, kind: .text))
                }
                continue
            }

            if matches(units, at: index, "<!--") {
                let start = index
                index = endOfComment(units, from: index + 4)
                tokens.append(SyntaxToken(location: start, length: index - start, kind: .comment))
                continue
            }

            if matches(units, at: index, "<![CDATA[") {
                let start = index
                index = endOfCDATA(units, from: index + 9)
                tokens.append(SyntaxToken(location: start, length: index - start, kind: .text))
                continue
            }

            // `<?xml …?>` and `<!DOCTYPE …>` are punctuation as far as colouring goes.
            if matches(units, at: index, "<?") || matches(units, at: index, "<!") {
                let start = index
                while index < units.count, units[index] != greaterThan { index += 1 }
                if index < units.count { index += 1 }
                tokens.append(SyntaxToken(
                    location: start, length: index - start, kind: .comment))
                continue
            }

            index = scanTag(units, from: index, into: &tokens)
        }
        return tokens
    }

    /// Scans `<name attr="value" …>` or `</name>`, returning the index just past it.
    private func scanTag(_ units: [UInt16], from start: Int, into tokens: inout [SyntaxToken]) -> Int {
        var index = start
        let openLength = (index + 1 < units.count && units[index + 1] == slash) ? 2 : 1
        tokens.append(SyntaxToken(location: index, length: openLength, kind: .punctuation))
        index += openLength

        let nameStart = index
        while index < units.count, isNameCharacter(units[index]) { index += 1 }
        if index > nameStart {
            tokens.append(SyntaxToken(
                location: nameStart, length: index - nameStart, kind: .tagName))
        }

        while index < units.count, units[index] != greaterThan {
            if isWhitespace(units[index]) {
                index += 1
                continue
            }
            if units[index] == slash {
                index += 1
                continue
            }

            let attributeStart = index
            while index < units.count, isNameCharacter(units[index]) { index += 1 }
            if index > attributeStart {
                tokens.append(SyntaxToken(
                    location: attributeStart, length: index - attributeStart, kind: .attributeName))
            } else {
                // Nothing recognisable — skip a unit so the loop always makes progress.
                index += 1
                continue
            }

            while index < units.count, isWhitespace(units[index]) { index += 1 }
            guard index < units.count, units[index] == equals else { continue }
            index += 1
            while index < units.count, isWhitespace(units[index]) { index += 1 }

            guard index < units.count else { break }
            if units[index] == quote || units[index] == apostrophe {
                let delimiter = units[index]
                let valueStart = index
                index += 1
                while index < units.count, units[index] != delimiter { index += 1 }
                if index < units.count { index += 1 }
                tokens.append(SyntaxToken(
                    location: valueStart, length: index - valueStart, kind: .attributeValue))
            } else {
                // An unquoted HTML attribute value.
                let valueStart = index
                while index < units.count, !isWhitespace(units[index]),
                      units[index] != greaterThan { index += 1 }
                tokens.append(SyntaxToken(
                    location: valueStart, length: index - valueStart, kind: .attributeValue))
            }
        }

        if index < units.count, units[index] == greaterThan {
            // A self-closing tag's `/` was skipped above; colour it with the bracket.
            let closeStart = (index > start && units[index - 1] == slash) ? index - 1 : index
            tokens.append(SyntaxToken(
                location: closeStart, length: index - closeStart + 1, kind: .punctuation))
            index += 1
        }
        return index
    }

    private func endOfComment(_ units: [UInt16], from start: Int) -> Int {
        var index = start
        while index + 2 < units.count {
            if units[index] == dash, units[index + 1] == dash, units[index + 2] == greaterThan {
                return index + 3
            }
            index += 1
        }
        return units.count
    }

    private func endOfCDATA(_ units: [UInt16], from start: Int) -> Int {
        var index = start
        while index + 2 < units.count {
            if units[index] == closeBracket, units[index + 1] == closeBracket,
               units[index + 2] == greaterThan {
                return index + 3
            }
            index += 1
        }
        return units.count
    }

    private func matches(_ units: [UInt16], at index: Int, _ needle: String) -> Bool {
        let expected = Array(needle.utf16)
        guard index + expected.count <= units.count else { return false }
        for offset in expected.indices where units[index + offset] != expected[offset] {
            return false
        }
        return true
    }

    private func isAllWhitespace(_ units: [UInt16], _ start: Int, _ end: Int) -> Bool {
        for index in start..<end where !isWhitespace(units[index]) { return false }
        return true
    }

    private func isNameCharacter(_ unit: UInt16) -> Bool {
        (unit >= 0x61 && unit <= 0x7A) || (unit >= 0x41 && unit <= 0x5A)
            || (unit >= 0x30 && unit <= 0x39)
            || unit == 0x3A || unit == 0x2D || unit == 0x5F || unit == 0x2E || unit > 0x7F
    }

    private func isWhitespace(_ unit: UInt16) -> Bool {
        unit == 0x20 || unit == 0x09 || unit == 0x0A || unit == 0x0D
    }

    private let lessThan: UInt16 = 0x3C
    private let greaterThan: UInt16 = 0x3E
    private let slash: UInt16 = 0x2F
    private let equals: UInt16 = 0x3D
    private let quote: UInt16 = 0x22
    private let apostrophe: UInt16 = 0x27
    private let dash: UInt16 = 0x2D
    private let closeBracket: UInt16 = 0x5D
}
