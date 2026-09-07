import Foundation

/// Re-indents XML and HTML.
///
/// Like `JSONPrettyPrinter` this rewrites only the whitespace *between* nodes — never the nodes
/// themselves. Attribute order, entity spellings, CDATA, comments and processing instructions come
/// through byte for byte, because the point of the Pretty tab is to make a response readable, not
/// to normalise it.
public enum XMLPrettyPrinter {
    public enum PrintError: Error, LocalizedError, Equatable {
        case notMarkup

        public var errorDescription: String? {
            switch self {
            case .notMarkup: "This response does not look like XML or HTML."
            }
        }
    }

    /// HTML elements that never have a closing tag, so they must not open an indent level.
    private static let voidElements: Set<String> = [
        "area", "base", "br", "col", "embed", "hr", "img", "input",
        "link", "meta", "param", "source", "track", "wbr",
    ]

    /// Elements whose contents are significant whitespace and must be copied verbatim.
    private static let preformatted: Set<String> = ["pre", "textarea", "script", "style"]

    public static func prettyPrint(_ text: String, indent: Int = 2) throws -> String {
        let nodes = parse(Array(text.utf16))
        guard nodes.contains(where: { if case .open = $0.kind { return true } else { return false } })
        else { throw PrintError.notMarkup }

        var out = ""
        out.reserveCapacity(text.utf16.count + text.utf16.count / 4)
        var depth = 0
        var verbatimDepth: Int?

        func newline() {
            if !out.isEmpty { out += "\n" }
            out += String(repeating: " ", count: depth * indent)
        }

        for (position, node) in nodes.enumerated() {
            // Inside <pre>/<script>/<style>, everything is copied exactly as it came.
            if let started = verbatimDepth {
                out += node.text
                if case .close(let name) = node.kind, preformatted.contains(name), depth == started {
                    verbatimDepth = nil
                }
                if case .close = node.kind, depth == started { depth -= 1 }
                continue
            }

            switch node.kind {
            case .text:
                let trimmed = node.text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { continue }
                // `<a>text</a>` stays on one line; text with siblings gets its own.
                if isOnlyChild(nodes, at: position) {
                    out += trimmed
                } else {
                    newline()
                    out += trimmed
                }

            case .open(let name):
                newline()
                out += node.text
                if preformatted.contains(name) {
                    verbatimDepth = depth
                    depth += 1
                } else if !voidElements.contains(name) {
                    depth += 1
                }

            case .close:
                depth = max(0, depth - 1)
                // The matching open tag put its only text child on the same line; stay there.
                if !(position > 0 && nodes[position - 1].kind.isText
                    && isOnlyChild(nodes, at: position - 1)) {
                    newline()
                }
                out += node.text

            case .selfClosing, .comment, .instruction, .cdata, .doctype:
                newline()
                out += node.text
            }
        }
        return out
    }

    /// True when the node at `position` is a lone text child between its parent's tags.
    private static func isOnlyChild(_ nodes: [Node], at position: Int) -> Bool {
        guard position > 0, position + 1 < nodes.count else { return false }
        guard case .open = nodes[position - 1].kind else { return false }
        guard case .close = nodes[position + 1].kind else { return false }
        return !nodes[position].text.contains("\n")
    }

    // MARK: - Parsing

    private struct Node {
        var kind: Kind
        /// The exact source text of this node.
        var text: String
    }

    private enum Kind {
        case open(name: String)
        case close(name: String)
        case selfClosing
        case text
        case comment
        case instruction
        case cdata
        case doctype

        var isText: Bool { if case .text = self { return true } else { return false } }
    }

    private static func parse(_ units: [UInt16]) -> [Node] {
        var nodes: [Node] = []
        var index = 0

        func slice(_ from: Int, _ to: Int) -> String {
            String(decoding: units[from..<to], as: UTF16.self)
        }

        while index < units.count {
            guard units[index] == 0x3C else {  // <
                let start = index
                while index < units.count, units[index] != 0x3C { index += 1 }
                nodes.append(Node(kind: .text, text: slice(start, index)))
                continue
            }

            let start = index
            if matches(units, index, "<!--") {
                index = find(units, from: index + 4, terminator: "-->")
                nodes.append(Node(kind: .comment, text: slice(start, index)))
                continue
            }
            if matches(units, index, "<![CDATA[") {
                index = find(units, from: index + 9, terminator: "]]>")
                nodes.append(Node(kind: .cdata, text: slice(start, index)))
                continue
            }
            if matches(units, index, "<?") {
                index = find(units, from: index + 2, terminator: "?>")
                nodes.append(Node(kind: .instruction, text: slice(start, index)))
                continue
            }
            if matches(units, index, "<!") {
                index = find(units, from: index + 2, terminator: ">")
                nodes.append(Node(kind: .doctype, text: slice(start, index)))
                continue
            }

            // An ordinary tag. Quoted attribute values may contain `>`.
            let isClosing = index + 1 < units.count && units[index + 1] == 0x2F
            index += isClosing ? 2 : 1
            let nameStart = index
            while index < units.count, isNameCharacter(units[index]) { index += 1 }
            let name = slice(nameStart, index).lowercased()

            var quoteCharacter: UInt16?
            while index < units.count {
                let unit = units[index]
                if let active = quoteCharacter {
                    if unit == active { quoteCharacter = nil }
                } else if unit == 0x22 || unit == 0x27 {
                    quoteCharacter = unit
                } else if unit == 0x3E {  // >
                    break
                }
                index += 1
            }
            let selfClosing = index > 0 && units[index - 1] == 0x2F
            if index < units.count { index += 1 }

            let text = slice(start, index)
            if isClosing {
                nodes.append(Node(kind: .close(name: name), text: text))
            } else if selfClosing {
                nodes.append(Node(kind: .selfClosing, text: text))
            } else {
                nodes.append(Node(kind: .open(name: name), text: text))
            }
        }
        return nodes
    }

    private static func find(_ units: [UInt16], from start: Int, terminator: String) -> Int {
        let needle = Array(terminator.utf16)
        var index = start
        while index + needle.count <= units.count {
            var matched = true
            for offset in needle.indices where units[index + offset] != needle[offset] {
                matched = false
                break
            }
            if matched { return index + needle.count }
            index += 1
        }
        return units.count
    }

    private static func matches(_ units: [UInt16], _ index: Int, _ needle: String) -> Bool {
        let expected = Array(needle.utf16)
        guard index + expected.count <= units.count else { return false }
        for offset in expected.indices where units[index + offset] != expected[offset] {
            return false
        }
        return true
    }

    private static func isNameCharacter(_ unit: UInt16) -> Bool {
        (unit >= 0x61 && unit <= 0x7A) || (unit >= 0x41 && unit <= 0x5A)
            || (unit >= 0x30 && unit <= 0x39)
            || unit == 0x3A || unit == 0x2D || unit == 0x5F || unit == 0x2E || unit > 0x7F
    }
}
