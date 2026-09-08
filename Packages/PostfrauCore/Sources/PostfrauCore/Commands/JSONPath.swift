import Foundation

/// The small slice of JSONPath `--capture` needs: `$.a.b[0].c`.
///
/// Deliberately not a full implementation. Filters, wildcards and recursive descent would each be
/// a source of surprise in a flag whose whole job is "pull the token out of the login response",
/// and a expression that does not match says so rather than guessing.
public enum JSONPath {
    /// The value at `expression`, rendered as the string a variable would hold.
    ///
    /// A string comes back unquoted, a number or boolean in its JSON form, and an object or array
    /// re-encoded — so `--capture body=$` is a way to keep the whole response.
    public static func evaluate(_ expression: String, on root: JSONValue) -> String? {
        guard let value = value(at: expression, in: root) else { return nil }
        switch value {
        case .string(let text): return text
        case .number(let literal):
            // `JSONValue` decodes numbers through `Int64` and `Decimal`, never `Double`, so a
            // captured id keeps every digit the server sent. What is preserved is the value, not
            // the spelling: `19.90` comes back as `19.9`.
            return literal
        case .bool(let flag): return flag ? "true" : "false"
        case .null: return "null"
        case .object, .array:
            guard let data = try? Postfrau.makeEncoder(pretty: false).encode(value) else {
                return nil
            }
            return String(decoding: data, as: UTF8.self)
        }
    }

    /// The raw value at `expression`, or nil when the path matches nothing.
    public static func value(at expression: String, in root: JSONValue) -> JSONValue? {
        guard let steps = parse(expression) else { return nil }
        var current = root
        for step in steps {
            switch step {
            case .key(let name):
                guard let next = current.objectValue?[name] else { return nil }
                current = next
            case .index(let index):
                guard let array = current.arrayValue else { return nil }
                // A negative index counts from the end, which is how people ask for the last one.
                let resolved = index < 0 ? array.count + index : index
                guard array.indices.contains(resolved) else { return nil }
                current = array[resolved]
            }
        }
        return current
    }

    enum Step: Equatable {
        case key(String)
        case index(Int)
    }

    /// `$.data.items[0].name` → `[.key("data"), .key("items"), .index(0), .key("name")]`.
    ///
    /// A leading `$` is optional, and `['a.b']` addresses a key that itself contains a dot.
    static func parse(_ expression: String) -> [Step]? {
        var text = expression.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return nil }
        if text == "$" { return [] }
        if text.hasPrefix("$") { text.removeFirst() }
        if text.hasPrefix(".") { text.removeFirst() }

        var steps: [Step] = []
        var current = ""
        let characters = Array(text)
        var index = 0

        func flushKey() -> Bool {
            guard !current.isEmpty else { return true }
            steps.append(.key(current))
            current = ""
            return true
        }

        while index < characters.count {
            switch characters[index] {
            case ".":
                _ = flushKey()
                index += 1

            case "[":
                _ = flushKey()
                index += 1
                var inner = ""
                while index < characters.count, characters[index] != "]" {
                    inner.append(characters[index])
                    index += 1
                }
                guard index < characters.count else { return nil }  // unclosed bracket
                index += 1

                let trimmed = inner.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("'") && trimmed.hasSuffix("'") && trimmed.count >= 2 {
                    steps.append(.key(String(trimmed.dropFirst().dropLast())))
                } else if trimmed.hasPrefix("\"") && trimmed.hasSuffix("\"") && trimmed.count >= 2 {
                    steps.append(.key(String(trimmed.dropFirst().dropLast())))
                } else if let number = Int(trimmed) {
                    steps.append(.index(number))
                } else {
                    return nil
                }

            default:
                current.append(characters[index])
                index += 1
            }
        }
        _ = flushKey()
        return steps
    }
}
