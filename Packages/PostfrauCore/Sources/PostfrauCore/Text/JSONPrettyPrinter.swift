import Foundation

/// Re-indents JSON without changing a single value.
///
/// Deliberately a tokenizer rather than `JSONSerialization`: round-tripping through Foundation
/// would reorder object keys, collapse duplicates, and silently rewrite numbers through `Double`
/// (`9007199254740993` comes back as `9007199254740992`, `1.0` as `1`). Since Postfrau shows
/// people what a server actually sent, every byte of every scalar is copied through verbatim and
/// only the whitespace between tokens is rewritten.
///
/// Works on UTF-8 bytes so a multi-megabyte body costs one pass and no `Character` grapheme
/// breaking. Any byte inside a string literal is copied without inspection, so invalid UTF-8 and
/// exotic escapes survive untouched.
public enum JSONPrettyPrinter {
    public enum PrintError: Error, LocalizedError, Equatable {
        case unexpectedByte(UInt8, offset: Int)
        case unterminatedString(offset: Int)
        case unexpectedEnd
        case trailingContent(offset: Int)

        public var errorDescription: String? {
            switch self {
            case .unexpectedByte(let byte, let offset):
                "Unexpected character “\(Character(UnicodeScalar(byte)))” at byte \(offset)."
            case .unterminatedString(let offset):
                "A string starting at byte \(offset) is never closed."
            case .unexpectedEnd:
                "The document ends in the middle of a value."
            case .trailingContent(let offset):
                "Unexpected content after the end of the document, at byte \(offset)."
            }
        }
    }

    /// Pretty-prints with `indent` spaces per level.
    public static func prettyPrint(_ text: String, indent: Int = 2) throws -> String {
        String(decoding: try format(Array(text.utf8), indent: indent), as: UTF8.self)
    }

    public static func prettyPrint(_ data: Data, indent: Int = 2) throws -> String {
        String(decoding: try format(Array(data), indent: indent), as: UTF8.self)
    }

    /// Removes all insignificant whitespace.
    public static func minify(_ text: String) throws -> String {
        String(decoding: try format(Array(text.utf8), indent: nil), as: UTF8.self)
    }

    /// A cheap check used to decide whether the Pretty tab has anything to offer.
    public static func looksLikeJSON(_ data: Data) -> Bool {
        for byte in data.prefix(64) {
            if isWhitespace(byte) { continue }
            return byte == UInt8(ascii: "{") || byte == UInt8(ascii: "[")
        }
        return false
    }

    // MARK: - Implementation

    /// - Parameter indent: spaces per level, or nil to minify.
    private static func format(_ input: [UInt8], indent: Int?) throws -> [UInt8] {
        var out: [UInt8] = []
        // Pretty output is bigger than the input; minified is smaller. Either way this avoids a
        // few reallocations on large bodies.
        out.reserveCapacity(indent == nil ? input.count : input.count + input.count / 2)

        var index = 0
        var depth = 0

        func skipWhitespace() {
            while index < input.count, isWhitespace(input[index]) { index += 1 }
        }

        func newline() {
            guard let indent else { return }
            out.append(0x0A)
            out.append(contentsOf: repeatElement(0x20, count: depth * indent))
        }

        /// Copies a string literal, honouring backslash escapes so `\"` does not end it.
        func copyString() throws {
            let start = index
            out.append(input[index])  // opening quote
            index += 1
            while index < input.count {
                let byte = input[index]
                out.append(byte)
                index += 1
                if byte == 0x5C {  // backslash: the next byte is escaped, whatever it is
                    guard index < input.count else { throw PrintError.unterminatedString(offset: start) }
                    out.append(input[index])
                    index += 1
                    continue
                }
                if byte == 0x22 { return }  // closing quote
            }
            throw PrintError.unterminatedString(offset: start)
        }

        /// Copies a number or a bare literal (`true`, `false`, `null`) verbatim.
        func copyScalar() throws {
            let start = index
            while index < input.count, !isStructural(input[index]), !isWhitespace(input[index]) {
                out.append(input[index])
                index += 1
            }
            if index == start { throw PrintError.unexpectedByte(input[index], offset: index) }
        }

        func parseValue() throws {
            skipWhitespace()
            guard index < input.count else { throw PrintError.unexpectedEnd }

            switch input[index] {
            case UInt8(ascii: "{"), UInt8(ascii: "["):
                let open = input[index]
                let close: UInt8 = open == UInt8(ascii: "{") ? UInt8(ascii: "}") : UInt8(ascii: "]")
                let isObject = open == UInt8(ascii: "{")
                out.append(open)
                index += 1
                skipWhitespace()

                // An empty container stays on one line: `{}` reads better than `{\n}`.
                if index < input.count, input[index] == close {
                    out.append(close)
                    index += 1
                    return
                }

                depth += 1
                var expectMore = true
                while expectMore {
                    newline()
                    if isObject {
                        skipWhitespace()
                        guard index < input.count else { throw PrintError.unexpectedEnd }
                        guard input[index] == 0x22 else {
                            throw PrintError.unexpectedByte(input[index], offset: index)
                        }
                        try copyString()
                        skipWhitespace()
                        guard index < input.count, input[index] == UInt8(ascii: ":") else {
                            throw index < input.count
                                ? PrintError.unexpectedByte(input[index], offset: index)
                                : PrintError.unexpectedEnd
                        }
                        index += 1
                        out.append(UInt8(ascii: ":"))
                        if indent != nil { out.append(0x20) }
                    }
                    try parseValue()
                    skipWhitespace()
                    guard index < input.count else { throw PrintError.unexpectedEnd }
                    if input[index] == UInt8(ascii: ",") {
                        index += 1
                        out.append(UInt8(ascii: ","))
                    } else {
                        expectMore = false
                    }
                }
                skipWhitespace()
                guard index < input.count, input[index] == close else {
                    throw index < input.count
                        ? PrintError.unexpectedByte(input[index], offset: index)
                        : PrintError.unexpectedEnd
                }
                index += 1
                depth -= 1
                newline()
                out.append(close)

            case 0x22:
                try copyString()

            default:
                try copyScalar()
            }
        }

        try parseValue()
        skipWhitespace()
        guard index == input.count else { throw PrintError.trailingContent(offset: index) }
        return out
    }

    private static func isWhitespace(_ byte: UInt8) -> Bool {
        byte == 0x20 || byte == 0x09 || byte == 0x0A || byte == 0x0D
    }

    private static func isStructural(_ byte: UInt8) -> Bool {
        byte == UInt8(ascii: "{") || byte == UInt8(ascii: "}")
            || byte == UInt8(ascii: "[") || byte == UInt8(ascii: "]")
            || byte == UInt8(ascii: ",") || byte == UInt8(ascii: ":")
    }
}
