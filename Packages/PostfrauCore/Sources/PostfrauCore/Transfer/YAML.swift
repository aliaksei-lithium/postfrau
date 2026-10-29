import Foundation

/// A reader for the subset of YAML that OpenAPI documents are written in.
///
/// Not a YAML implementation. It reads what spec files actually contain — block mappings and
/// sequences (including `- key: value` items), flow `[…]` and `{…}`, plain, single- and
/// double-quoted scalars that may run over several lines, `|` and `>` block scalars with their
/// chomping and indentation indicators, comments, anchors, aliases and `<<` merge keys — into the
/// same `JSONValue` the JSON path produces, so everything downstream is shared.
///
/// Scalars resolve by the YAML 1.2 core schema: `true`/`false`, `null`/`~`/empty, decimal
/// numbers. Everything else is a string — including `yes`, `on` and `1.2.3` — and so is a number
/// with a leading zero, because in an API spec `0042` is an account number, not forty-two.
///
/// Left out on purpose: multiple documents (the first is read), complex `? key` entries, tags
/// (`!!str` and friends are skipped, not applied), and tabs as indentation. Each fails with the
/// line it happened on rather than producing something subtly wrong.
public enum YAML {
    public struct ParseError: Error, LocalizedError, Equatable {
        public var line: Int
        public var message: String

        public var errorDescription: String? { "YAML line \(line): \(message)" }
    }

    public static func parse(_ text: String) throws -> JSONValue {
        var parser = Parser(text: text)
        return try parser.parseDocument()
    }

    public static func parse(_ data: Data) throws -> JSONValue {
        try parse(String(decoding: data, as: UTF8.self))
    }
}

private struct Line {
    /// Leading spaces.
    var indent: Int
    /// Everything after them, comments included — a block scalar needs the raw text.
    var text: Substring
    /// 1-based, for error messages.
    var number: Int

    var isBlank: Bool {
        let trimmed = text.drop { $0 == " " || $0 == "\t" }
        return trimmed.isEmpty || trimmed.first == "#"
    }
}

private struct Parser {
    var lines: [Line]
    var index = 0
    var anchors: [String: JSONValue] = [:]

    init(text: String) {
        var lines: [Line] = []
        var number = 0
        // "\r\n" is a single `Character` in Swift, so it has to be named as a separator itself.
        for raw in text.split(
            omittingEmptySubsequences: false,
            whereSeparator: { $0 == "\n" || $0 == "\r\n" || $0 == "\r" }
        ) {
            number += 1
            var line = raw
            if number == 1, line.first == "\u{FEFF}" { line = line.dropFirst() }
            let indent = line.prefix { $0 == " " }.count
            lines.append(Line(indent: indent, text: line.dropFirst(indent), number: number))
        }
        self.lines = lines
    }

    func error(_ message: String, at line: Int? = nil) -> YAML.ParseError {
        YAML.ParseError(
            line: line ?? (index < lines.count ? lines[index].number : lines.count),
            message: message)
    }

    // MARK: - Document

    mutating func parseDocument() throws -> JSONValue {
        // Directives and the `---` that opens the first document.
        while index < lines.count {
            let line = lines[index]
            if line.isBlank || (line.indent == 0 && line.text.hasPrefix("%")) {
                index += 1
            } else if line.indent == 0, isMarker(line.text, "---") {
                let rest = line.text.dropFirst(3).drop { $0 == " " }
                if rest.isEmpty || rest.first == "#" {
                    index += 1
                } else {
                    // `--- value` on one line.
                    lines[index] = Line(indent: 4, text: rest, number: line.number)
                    break
                }
            } else {
                break
            }
        }
        // Anything after a second `---` or a `...` is another document; only the first is read.
        if let end = lines[index...].firstIndex(where: {
            $0.indent == 0 && (isMarker($0.text, "---") || isMarker($0.text, "..."))
        }) {
            lines.removeSubrange(end...)
        }
        guard skipBlank() else { return .null }
        let value = try parseNode(minimumIndent: 0)
        if skipBlank() {
            throw error("unexpected content, indented less than what came before it")
        }
        return value
    }

    private func isMarker(_ text: Substring, _ marker: String) -> Bool {
        guard text.hasPrefix(marker) else { return false }
        let rest = text.dropFirst(marker.count)
        return rest.isEmpty || rest.first == " " || rest.first == "\t"
    }

    /// Moves past blank and comment lines. False at the end of the input.
    @discardableResult
    mutating func skipBlank() -> Bool {
        while index < lines.count, lines[index].isBlank { index += 1 }
        return index < lines.count
    }

    // MARK: - Block nodes

    /// The block node starting at the current line, which must be indented at least this far.
    mutating func parseNode(minimumIndent: Int) throws -> JSONValue {
        guard skipBlank() else { return .null }
        let line = lines[index]
        guard line.indent >= minimumIndent else { return .null }
        if line.text.first == "\t" { throw error("tabs cannot be used for indentation") }
        if Self.isSequenceEntry(line.text) {
            return try parseSequence(indent: line.indent)
        }
        if Self.splitMappingEntry(stripComment(line.text)) != nil {
            return try parseMapping(indent: line.indent)
        }
        // A bare scalar or flow collection standing on its own.
        let text = stripComment(line.text)
        index += 1
        return try parseInlineValue(text, parentIndent: line.indent - 1, line: line.number)
    }

    static func isSequenceEntry(_ text: Substring) -> Bool {
        text.first == "-" && (text.count == 1 || text.dropFirst().first == " ")
    }

    mutating func parseSequence(indent: Int) throws -> JSONValue {
        var items: [JSONValue] = []
        while skipBlank() {
            let line = lines[index]
            guard line.indent == indent, Self.isSequenceEntry(line.text) else {
                if line.indent > indent { throw error("bad indentation in a list") }
                break
            }
            let afterDash = line.text.dropFirst()
            let spaces = afterDash.prefix { $0 == " " }.count
            let rest = afterDash.dropFirst(spaces)
            if rest.isEmpty || rest.first == "#" {
                index += 1
                items.append(try parseValue(after: "", parentIndent: indent, line: line.number))
                continue
            }
            // `- key: value` or `- - x`: the rest of the line is a node of its own, indented to
            // where its text starts. Rewriting the line in place lets the ordinary block parser
            // read it, and the lines after it at that indent continue it.
            let column = indent + 1 + spaces
            let stripped = stripComment(rest)
            if Self.isSequenceEntry(rest)
                || Self.splitMappingEntry(stripped) != nil
                || Self.anchorThenBlock(stripped) {
                if Self.anchorThenBlock(stripped) {
                    // `- &name` followed by an indented block.
                    index += 1
                    items.append(try parseValue(after: stripped, parentIndent: indent, line: line.number))
                    continue
                }
                lines[index] = Line(indent: column, text: rest, number: line.number)
                items.append(try parseNode(minimumIndent: column))
            } else {
                index += 1
                items.append(try parseValue(after: stripped, parentIndent: indent, line: line.number))
            }
        }
        return .array(items)
    }

    /// `&anchor` or `!tag` with nothing after it on the line.
    static func anchorThenBlock(_ text: Substring) -> Bool {
        let parts = text.split(separator: " ")
        return !parts.isEmpty && parts.allSatisfy { $0.first == "&" || $0.first == "!" }
    }

    mutating func parseMapping(indent: Int) throws -> JSONValue {
        var object: [String: JSONValue] = [:]
        var merged: [String: JSONValue] = [:]
        while skipBlank() {
            let line = lines[index]
            guard line.indent == indent else {
                if line.indent > indent { throw error("bad indentation in a mapping") }
                break
            }
            let stripped = stripComment(line.text)
            guard let (key, rest) = Self.splitMappingEntry(stripped) else {
                if Self.isSequenceEntry(line.text) { break }
                throw error("expected “key: value”")
            }
            index += 1
            let value = try parseValue(after: rest, parentIndent: indent, line: line.number, inMapping: true)
            if key == "<<" {
                // Merge keys: the mapping's own entries win, whatever order they appear in.
                for source in value.arrayValue ?? [value] {
                    for (k, v) in source.objectValue ?? [:] where merged[k] == nil {
                        merged[k] = v
                    }
                }
            } else {
                object[key] = value
            }
        }
        for (k, v) in merged where object[k] == nil { object[k] = v }
        return .object(object)
    }

    /// The value that follows `key:` or `- ` on a line, which may continue onto the lines below.
    mutating func parseValue(
        after rawText: Substring, parentIndent: Int, line: Int, inMapping: Bool = false
    ) throws -> JSONValue {
        var text = rawText.trimmingSpaces()
        var anchor: String?
        // Properties first: `&anchor` and `!tag`, in either order.
        while let first = text.first, first == "&" || first == "!" {
            let word = text.prefix { $0 != " " }
            if first == "&" { anchor = String(word.dropFirst()) }
            text = text.dropFirst(word.count).trimmingSpaces()
        }

        let value: JSONValue
        if text.isEmpty {
            // The value is the block below — more indented, or, for a mapping, a list at the same
            // indent (`key:\n- a\n- b` is legal and common).
            if skipBlank() {
                let next = lines[index]
                if next.indent > parentIndent {
                    value = try parseNode(minimumIndent: parentIndent + 1)
                } else if inMapping, next.indent == parentIndent, Self.isSequenceEntry(next.text) {
                    value = try parseSequence(indent: parentIndent)
                } else {
                    value = .null
                }
            } else {
                value = .null
            }
        } else {
            value = try parseInlineValue(text, parentIndent: parentIndent, line: line)
        }
        if let anchor { anchors[anchor] = value }
        return value
    }

    /// A value that starts on the current line: a scalar, a flow collection, a block scalar or an
    /// alias. The lines it continues onto are consumed.
    mutating func parseInlineValue(
        _ text: Substring, parentIndent: Int, line: Int
    ) throws -> JSONValue {
        switch text.first {
        case "*":
            let name = String(text.dropFirst())
            guard let value = anchors[name] else { throw error("unknown alias *\(name)", at: line) }
            return value
        case "|", ">":
            return .string(try parseBlockScalar(header: text, parentIndent: parentIndent, line: line))
        case "[", "{":
            let source = try gatherFlow(text, parentIndent: parentIndent, line: line)
            var flow = FlowParser(text: source, line: line, anchors: anchors)
            let value = try flow.parseValue()
            flow.skipSpace()
            guard flow.isAtEnd else { throw error("unexpected text after a closing bracket", at: line) }
            return value
        case "\"", "'":
            let source = try gatherQuoted(text, parentIndent: parentIndent, line: line)
            var flow = FlowParser(text: source, line: line, anchors: anchors)
            let value = try flow.parseQuoted()
            flow.skipSpace()
            guard flow.isAtEnd else {
                throw error("unexpected text after a quoted string", at: line)
            }
            return .string(value)
        default:
            // A plain scalar may fold onto more-indented lines below.
            var parts = [String(text)]
            var pendingBreaks = 0
            while index < lines.count {
                let next = lines[index]
                let trimmed = next.text.trimmingSpaces()
                if trimmed.isEmpty {
                    pendingBreaks += 1
                    index += 1
                    continue
                }
                // A continuation is more indented than the parent and is not itself an entry.
                guard next.indent > parentIndent, trimmed.first != "#",
                      !Self.isSequenceEntry(next.text),
                      Self.splitMappingEntry(stripComment(next.text)) == nil
                else { break }
                if pendingBreaks > 0 {
                    parts.append(String(repeating: "\n", count: pendingBreaks))
                } else {
                    parts.append(" ")
                }
                pendingBreaks = 0
                parts.append(String(stripComment(trimmed)))
                index += 1
            }
            let joined = parts.joined()
            return parts.count == 1 ? Self.resolvePlain(joined) : .string(joined)
        }
    }

    // MARK: - Multi-line inline values

    /// A flow collection that may run onto following lines: everything up to the bracket that
    /// balances the first one.
    mutating func gatherFlow(_ first: Substring, parentIndent: Int, line: Int) throws -> String {
        var source = String(stripComment(first))
        while !Self.flowIsBalanced(source) {
            guard index < lines.count else { throw error("unclosed [ or {", at: line) }
            source += " " + stripComment(lines[index].text)
            index += 1
        }
        return source
    }

    static func flowIsBalanced(_ text: String) -> Bool {
        var depth = 0
        var quote: Character?
        var previous: Character = " "
        var iterator = text.makeIterator()
        while let c = iterator.next() {
            if let q = quote {
                if c == "\\" && q == "\"" { _ = iterator.next(); continue }
                if c == q { quote = nil }
            } else if (c == "\"" || c == "'") && " [{,:".contains(previous) {
                quote = c
            } else if c == "[" || c == "{" {
                depth += 1
            } else if c == "]" || c == "}" {
                depth -= 1
            }
            previous = c
        }
        return depth <= 0 && quote == nil
    }

    /// A quoted scalar that may run onto following lines.
    mutating func gatherQuoted(_ first: Substring, parentIndent: Int, line: Int) throws -> String {
        var source = String(first)
        while !Self.quoteIsClosed(source) {
            guard index < lines.count else { throw error("unclosed quoted string", at: line) }
            let next = lines[index].text.trimmingSpaces()
            // Line folding inside quotes: a break becomes a space, an empty line a newline.
            if next.isEmpty {
                source += "\n"
            } else {
                if !source.hasSuffix("\n") { source += " " }
                source += next
            }
            index += 1
        }
        return source
    }

    static func quoteIsClosed(_ text: String) -> Bool {
        guard let quote = text.first else { return true }
        var iterator = text.dropFirst().makeIterator()
        while let c = iterator.next() {
            if quote == "\"" && c == "\\" { _ = iterator.next(); continue }
            if c == quote {
                // `''` inside single quotes is an escaped quote, not the end.
                if quote == "'" {
                    var lookahead = iterator
                    if lookahead.next() == "'" { iterator = lookahead; continue }
                }
                return true
            }
        }
        return false
    }

    /// `|` keeps line breaks, `>` folds them; `-` strips the final break, `+` keeps them all.
    mutating func parseBlockScalar(header: Substring, parentIndent: Int, line: Int) throws -> String {
        let style = header.first!
        var chomp: Character = " "
        var explicitIndent: Int?
        for c in stripComment(header.dropFirst()).trimmingSpaces() {
            if c == "-" || c == "+" { chomp = c }
            else if let digit = c.wholeNumberValue { explicitIndent = digit }
            else { throw error("bad block scalar header “\(header)”", at: line) }
        }

        // The content's indent: stated, or that of its first non-empty line.
        var blockIndent: Int?
        if let explicitIndent { blockIndent = max(parentIndent, 0) + explicitIndent }
        var collected: [String] = []
        while index < lines.count {
            let next = lines[index]
            if next.text.isEmpty || next.text.allSatisfy({ $0 == " " }) {
                collected.append("")
                index += 1
                continue
            }
            if blockIndent == nil {
                guard next.indent > parentIndent else { break }
                blockIndent = next.indent
            }
            guard next.indent >= blockIndent! else { break }
            collected.append(String(repeating: " ", count: next.indent - blockIndent!) + next.text)
            index += 1
        }
        // Trailing empty lines are the chomping indicator's business.
        var trailing = 0
        while collected.last == "" { collected.removeLast(); trailing += 1 }

        var body: String
        if style == "|" {
            body = collected.joined(separator: "\n")
        } else {
            // Folding: lines join with a space; an empty line is a newline; more-indented lines
            // keep their breaks, which is how a code sample survives inside a `>` block.
            body = ""
            var previousWasText = false
            var previousMoreIndented = false
            for content in collected {
                let moreIndented = content.first == " "
                if content.isEmpty {
                    body += "\n"
                    previousWasText = false
                } else {
                    if previousWasText {
                        body += (moreIndented || previousMoreIndented) ? "\n" : " "
                    }
                    body += content
                    previousWasText = true
                }
                previousMoreIndented = moreIndented
            }
        }
        switch chomp {
        case "-": return body
        case "+": return collected.isEmpty ? String(repeating: "\n", count: trailing) : body + String(repeating: "\n", count: trailing + 1)
        default: return collected.isEmpty ? "" : body + "\n"
        }
    }

    // MARK: - Lexical helpers

    /// The text with a trailing `# comment` removed. A `#` only starts a comment at the start of
    /// the text or after whitespace, and never inside quotes.
    func stripComment(_ text: Substring) -> Substring {
        var quote: Character?
        var previous: Character = " "
        var i = text.startIndex
        while i < text.endIndex {
            let c = text[i]
            if let q = quote {
                if c == "\\" && q == "\"" {
                    i = text.index(after: i)
                    if i < text.endIndex { i = text.index(after: i) }
                    previous = "x"
                    continue
                }
                if c == q {
                    // `''` is an escaped quote inside single quotes, not the end of them.
                    let next = text.index(after: i)
                    if q == "'", next < text.endIndex, text[next] == "'" {
                        i = text.index(after: next)
                        continue
                    }
                    quote = nil
                }
            } else if (c == "\"" || c == "'") && " [{,:-?".contains(previous) {
                quote = c
            } else if c == "#" && (previous == " " || previous == "\t") {
                return text[text.startIndex..<i].trimmingSpaces()
            } else if c == "#" && i == text.startIndex {
                return text[text.startIndex..<i]
            }
            previous = c
            i = text.index(after: i)
        }
        return text.trimmingSpaces()
    }

    /// Splits `key: rest` (with comments already stripped), or nil when the text is not a
    /// mapping entry.
    static func splitMappingEntry(_ text: Substring) -> (key: String, rest: Substring)? {
        guard let first = text.first else { return nil }
        if first == "\"" || first == "'" {
            var flow = FlowParser(text: String(text), line: 0, anchors: [:])
            guard let key = try? flow.parseQuoted() else { return nil }
            let rest = text.dropFirst(flow.offset).drop { $0 == " " }
            guard rest.first == ":" else { return nil }
            let after = rest.dropFirst()
            guard after.isEmpty || after.first == " " else { return nil }
            return (key, after)
        }
        if "[{#&*!|>%@`".contains(first) || isSequenceEntry(text) { return nil }
        var i = text.startIndex
        while i < text.endIndex {
            if text[i] == ":" {
                let next = text.index(after: i)
                if next == text.endIndex || text[next] == " " || text[next] == "\t" {
                    let key = text[text.startIndex..<i].trimmingSpaces()
                    return (String(key), text[next...])
                }
            }
            i = text.index(after: i)
        }
        return nil
    }

    /// The YAML 1.2 core schema, minus the parts nobody puts in a spec.
    static func resolvePlain(_ text: String) -> JSONValue {
        switch text {
        case "", "~", "null", "Null", "NULL": return .null
        case "true", "True", "TRUE": return .bool(true)
        case "false", "False", "FALSE": return .bool(false)
        default: break
        }
        if isNumber(text) {
            return .number(text.hasPrefix("+") ? String(text.dropFirst()) : text)
        }
        return .string(text)
    }

    static func isNumber(_ text: String) -> Bool {
        var s = Substring(text)
        if s.first == "-" || s.first == "+" { s = s.dropFirst() }
        let integer = s.prefix { $0.isASCII && $0.isNumber }
        // `0042` stays a string: in an API spec it is an identifier, not a number.
        if integer.count > 1 && integer.first == "0" { return false }
        s = s.dropFirst(integer.count)
        var digits = integer.count
        if s.first == "." {
            s = s.dropFirst()
            let fraction = s.prefix { $0.isASCII && $0.isNumber }
            digits += fraction.count
            s = s.dropFirst(fraction.count)
        }
        guard digits > 0 else { return false }
        if s.first == "e" || s.first == "E" {
            s = s.dropFirst()
            if s.first == "-" || s.first == "+" { s = s.dropFirst() }
            let exponent = s.prefix { $0.isASCII && $0.isNumber }
            guard !exponent.isEmpty else { return false }
            s = s.dropFirst(exponent.count)
        }
        return s.isEmpty
    }
}

/// The flow syntax — `[a, b]`, `{k: v}`, quoted strings — on a single string.
private struct FlowParser {
    let chars: [Character]
    var position = 0
    let line: Int
    let anchors: [String: JSONValue]

    init(text: String, line: Int, anchors: [String: JSONValue]) {
        chars = Array(text)
        self.line = line
        self.anchors = anchors
    }

    var isAtEnd: Bool { position >= chars.count }
    /// How many characters have been consumed, for callers that work on the original text.
    var offset: Int { position }

    func error(_ message: String) -> YAML.ParseError {
        YAML.ParseError(line: line, message: message)
    }

    mutating func skipSpace() {
        while position < chars.count, chars[position] == " " || chars[position] == "\t" {
            position += 1
        }
    }

    mutating func parseValue() throws -> JSONValue {
        skipSpace()
        guard position < chars.count else { return .null }
        // Properties are skipped; an anchor inside flow is rare enough to ignore.
        while position < chars.count, chars[position] == "&" || chars[position] == "!" {
            while position < chars.count, chars[position] != " " { position += 1 }
            skipSpace()
        }
        guard position < chars.count else { return .null }
        switch chars[position] {
        case "[": return try parseSequence()
        case "{": return try parseMapping()
        case "\"", "'": return .string(try parseQuoted())
        case "*":
            position += 1
            let name = plain(stoppingAtColon: false)
            guard let value = anchors[name] else { throw error("unknown alias *\(name)") }
            return value
        default:
            return Parser.resolvePlain(plain(stoppingAtColon: false))
        }
    }

    mutating func parseSequence() throws -> JSONValue {
        position += 1
        var items: [JSONValue] = []
        while true {
            skipSpace()
            guard position < chars.count else { throw error("unclosed [") }
            if chars[position] == "]" { position += 1; return .array(items) }
            // A single-pair mapping inside a sequence: `[a: 1, b: 2]`.
            let value = try parseValue()
            skipSpace()
            if position < chars.count, chars[position] == ":", let key = value.stringValue {
                position += 1
                items.append(.object([key: try parseValue()]))
            } else {
                items.append(value)
            }
            skipSpace()
            guard position < chars.count else { throw error("unclosed [") }
            if chars[position] == "," { position += 1 }
            else if chars[position] != "]" { throw error("expected , or ] in a flow list") }
        }
    }

    mutating func parseMapping() throws -> JSONValue {
        position += 1
        var object: [String: JSONValue] = [:]
        while true {
            skipSpace()
            guard position < chars.count else { throw error("unclosed {") }
            if chars[position] == "}" { position += 1; return .object(object) }
            let key: String
            if chars[position] == "\"" || chars[position] == "'" {
                key = try parseQuoted()
            } else {
                key = plain(stoppingAtColon: true)
            }
            skipSpace()
            var value = JSONValue.null
            if position < chars.count, chars[position] == ":" {
                position += 1
                skipSpace()
                if position < chars.count, chars[position] != ",", chars[position] != "}" {
                    value = try parseValue()
                }
            }
            object[key] = value
            skipSpace()
            guard position < chars.count else { throw error("unclosed {") }
            if chars[position] == "," { position += 1 }
            else if chars[position] != "}" { throw error("expected , or } in a flow mapping") }
        }
    }

    /// A plain scalar inside flow: up to `,`, `]`, `}`, and — for a key — `: `.
    mutating func plain(stoppingAtColon: Bool) -> String {
        var out = ""
        while position < chars.count {
            let c = chars[position]
            if c == "," || c == "]" || c == "}" { break }
            if c == ":" {
                let next = position + 1 < chars.count ? chars[position + 1] : " "
                if stoppingAtColon || next == " " || next == "," || next == "]" || next == "}" {
                    break
                }
            }
            if c == "#", out.last == " " { position = chars.count; break }
            out.append(c)
            position += 1
        }
        return out.trimmingCharacters(in: .whitespaces)
    }

    /// A single- or double-quoted scalar, with its escapes and line folding applied.
    mutating func parseQuoted() throws -> String {
        let quote = chars[position]
        position += 1
        var out = ""
        while position < chars.count {
            let c = chars[position]
            position += 1
            if c == quote {
                if quote == "'", position < chars.count, chars[position] == "'" {
                    out.append("'")
                    position += 1
                    continue
                }
                return out
            }
            if quote == "\"", c == "\\" {
                guard position < chars.count else { break }
                let e = chars[position]
                position += 1
                switch e {
                case "n": out.append("\n")
                case "t", "\t": out.append("\t")
                case "r": out.append("\r")
                case "0": out.append("\0")
                case "b": out.append("\u{8}")
                case "f": out.append("\u{C}")
                case "e": out.append("\u{1B}")
                case "a": out.append("\u{7}")
                case "v": out.append("\u{B}")
                case " ": out.append(" ")
                case "_": out.append("\u{A0}")
                case "N": out.append("\u{85}")
                case "x", "u", "U":
                    let count = e == "x" ? 2 : (e == "u" ? 4 : 8)
                    guard position + count <= chars.count,
                          let code = UInt32(String(chars[position..<(position + count)]), radix: 16),
                          let scalar = Unicode.Scalar(code)
                    else { throw error("bad \\\(e) escape") }
                    out.append(Character(scalar))
                    position += count
                case "\n":
                    // An escaped line break joins the lines with nothing between them.
                    while position < chars.count, chars[position] == " " { position += 1 }
                default:
                    out.append(e)
                }
                continue
            }
            out.append(c)
        }
        throw error("unclosed quoted string")
    }
}

extension Substring {
    fileprivate func trimmingSpaces() -> Substring {
        var s = self
        while let f = s.first, f == " " || f == "\t" { s = s.dropFirst() }
        while let l = s.last, l == " " || l == "\t" { s = s.dropLast() }
        return s
    }
}
