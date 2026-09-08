import Foundation

/// A hand-rolled argument parser.
///
/// `swift-argument-parser` would do this better, but §0 of the plan rules out third-party
/// dependencies and the surface here is small: flags, flags with values, repeatable flags, and
/// positional arguments. Nothing clever, and nothing that behaves differently from what a person
/// expects a Unix tool to do.
struct Arguments {
    /// Everything that was not a flag, in order.
    private(set) var positional: [String] = []
    /// Flags and their values. A flag given twice keeps both.
    private(set) var flags: [String: [String]] = [:]

    enum ParseError: Error, LocalizedError {
        case missingValue(String)

        var errorDescription: String? {
            switch self {
            case .missingValue(let flag): "\(flag) needs a value."
            }
        }
    }

    /// - Parameter valueFlags: flags that take a value. Everything else is a boolean, so an
    ///   unknown flag can never swallow the argument after it.
    init(_ arguments: [String], valueFlags: Set<String>) throws {
        var index = 0
        var afterDoubleDash = false

        while index < arguments.count {
            let argument = arguments[index]
            index += 1

            if afterDoubleDash {
                positional.append(argument)
                continue
            }
            if argument == "--" {
                afterDoubleDash = true
                continue
            }
            // A bare "-" is stdin, not a flag.
            guard argument.hasPrefix("-"), argument != "-" else {
                positional.append(argument)
                continue
            }

            let (name, inline) = Self.split(argument)
            guard valueFlags.contains(name) else {
                flags[name, default: []].append("")
                continue
            }
            if let inline {
                flags[name, default: []].append(inline)
                continue
            }
            guard index < arguments.count else { throw ParseError.missingValue(name) }
            flags[name, default: []].append(arguments[index])
            index += 1
        }
    }

    /// `--name=value` → `("--name", "value")`; `-Hvalue` → `("-H", "value")`.
    static func split(_ argument: String) -> (name: String, inline: String?) {
        if argument.hasPrefix("--") {
            guard let equals = argument.firstIndex(of: "=") else { return (argument, nil) }
            return (String(argument[argument.startIndex..<equals]),
                    String(argument[argument.index(after: equals)...]))
        }
        guard argument.count > 2 else { return (argument, nil) }
        return (String(argument.prefix(2)), String(argument.dropFirst(2)))
    }

    // MARK: - Reading

    func has(_ names: String...) -> Bool {
        names.contains { flags[$0] != nil }
    }

    func value(_ names: String...) -> String? {
        for name in names {
            if let values = flags[name], let last = values.last, !last.isEmpty { return last }
        }
        return nil
    }

    func values(_ names: String...) -> [String] {
        names.flatMap { flags[$0] ?? [] }.filter { !$0.isEmpty }
    }

    func positional(_ index: Int) -> String? {
        positional.indices.contains(index) ? positional[index] : nil
    }

    /// The same arguments with the verb removed, so `postfrau --json ls Acme` and
    /// `postfrau ls --json Acme` mean the same thing.
    func droppingVerb() -> Arguments {
        var copy = self
        if !copy.positional.isEmpty { copy.positional.removeFirst() }
        return copy
    }

    /// Every flag that was given but is not in `known` — so a typo is reported rather than ignored.
    func unknownFlags(known: Set<String>) -> [String] {
        flags.keys.filter { !known.contains($0) }.sorted()
    }

    // MARK: - Shared value shapes

    /// `k=v` pairs from a repeatable flag, in order.
    func pairs(_ names: String...) -> [(key: String, value: String)] {
        names.flatMap { flags[$0] ?? [] }.compactMap { text in
            guard let equals = text.firstIndex(of: "=") else { return nil }
            return (String(text[text.startIndex..<equals]),
                    String(text[text.index(after: equals)...]))
        }
    }

    /// `k:v` pairs, for headers, where the value may itself contain a colon.
    func colonPairs(_ names: String...) -> [(key: String, value: String)] {
        names.flatMap { flags[$0] ?? [] }.compactMap { text in
            guard let colon = text.firstIndex(of: ":") else { return nil }
            return (String(text[text.startIndex..<colon]).trimmingCharacters(in: .whitespaces),
                    String(text[text.index(after: colon)...]).trimmingCharacters(in: .whitespaces))
        }
    }

    /// `64k`, `2m`, `1024` → bytes.
    static func byteCount(_ text: String) -> Int? {
        let lowered = text.lowercased()
        let multipliers: [(String, Int)] = [("kb", 1024), ("mb", 1024 * 1024),
                                            ("k", 1024), ("m", 1024 * 1024), ("b", 1)]
        for (suffix, multiplier) in multipliers where lowered.hasSuffix(suffix) {
            guard let number = Int(lowered.dropLast(suffix.count)) else { return nil }
            return number * multiplier
        }
        return Int(lowered)
    }

    /// `2h`, `30m`, `7d` → the date that long ago.
    static func since(_ text: String, from now: Date = Date()) -> Date? {
        let units: [(Character, TimeInterval)] = [
            ("s", 1), ("m", 60), ("h", 3600), ("d", 86_400), ("w", 604_800),
        ]
        guard let last = text.last, let unit = units.first(where: { $0.0 == last })?.1,
              let number = Double(text.dropLast())
        else { return nil }
        return now.addingTimeInterval(-number * unit)
    }
}
