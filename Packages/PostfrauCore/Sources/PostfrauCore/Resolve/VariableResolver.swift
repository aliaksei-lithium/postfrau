import Foundation

/// The outcome of substituting `{{variables}}` into a string.
public struct ResolveResult: Sendable, Hashable {
    public var text: String
    /// Names that had no definition, in first-seen order, without duplicates.
    public var unresolved: [String]
    /// Names that referenced themselves (directly or transitively) or nested too deeply.
    public var cycles: [String]

    public init(text: String, unresolved: [String] = [], cycles: [String] = []) {
        self.text = text
        self.unresolved = unresolved
        self.cycles = cycles
    }

    public var isFullyResolved: Bool { unresolved.isEmpty && cycles.isEmpty }
}

/// One `{{…}}` occurrence found in a string, for the URL bar's token colouring.
public struct VariableToken: Sendable, Hashable {
    public var range: Range<String.Index>
    public var name: String
    public var resolvedValue: String?
    public var isDynamic: Bool
    public var isSecret: Bool

    public var isResolved: Bool { resolvedValue != nil }
}

/// Substitutes `{{variables}}` using a `VariableScope`, recursively and cycle-safely.
///
/// - Precedence is whatever order the scope's layers are in (see `VariableScope.build`).
/// - `{{$dynamic}}` names are evaluated last and can never be shadowed by a user variable.
/// - `\{{` escapes a literal `{{`; the backslash is consumed and no substitution happens.
/// - A name that cannot be resolved is left in the output verbatim as `{{name}}` and reported,
///   so the user sees exactly what would go on the wire.
public struct VariableResolver: Sendable {
    /// How deep a value may reference other values before we call it a cycle.
    public static let maxDepth = 10

    private let values: [String: String]
    private let secretKeys: Set<String>
    private let dynamics: any DynamicVariableProvider

    public init(scope: VariableScope, dynamics: any DynamicVariableProvider = SystemDynamicVariables()) {
        self.values = scope.effectiveValues()
        var secrets: Set<String> = []
        for variable in scope.allVariables() where variable.isSecret && !variable.isShadowed {
            secrets.insert(variable.key)
        }
        self.secretKeys = secrets
        self.dynamics = dynamics
    }

    public init(values: [String: String], dynamics: any DynamicVariableProvider = SystemDynamicVariables()) {
        self.values = values
        self.secretKeys = []
        self.dynamics = dynamics
    }

    public func resolve(_ input: String) -> ResolveResult {
        var unresolved: [String] = []
        var cycles: [String] = []
        let text = expand(input, expanding: [], depth: 0, unresolved: &unresolved, cycles: &cycles)
        return ResolveResult(text: text, unresolved: unresolved, cycles: cycles)
    }

    /// Convenience for call sites that only want the text.
    public func resolved(_ input: String) -> String {
        resolve(input).text
    }

    /// Resolves every enabled row's key and value, dropping disabled and unnamed rows.
    public func resolve(rows: [KeyValue]) -> [(key: String, value: String)] {
        rows.active.map { (resolved($0.key), resolved($0.value)) }
    }

    /// Locates the `{{…}}` occurrences in `input` so the UI can colour them.
    /// Escaped `\{{` sequences are skipped.
    public func tokens(in input: String) -> [VariableToken] {
        var tokens: [VariableToken] = []
        var index = input.startIndex
        while index < input.endIndex {
            guard let open = input.range(of: "{{", range: index..<input.endIndex) else { break }
            if isEscaped(input, openingAt: open.lowerBound) {
                index = open.upperBound
                continue
            }
            guard let close = input.range(of: "}}", range: open.upperBound..<input.endIndex) else { break }
            let rawName = String(input[open.upperBound..<close.lowerBound])
            let name = rawName.trimmingCharacters(in: .whitespaces)
            let dynamic = name.hasPrefix("$")
            tokens.append(VariableToken(
                range: open.lowerBound..<close.upperBound,
                name: name,
                resolvedValue: dynamic
                    ? dynamics.value(for: String(name.dropFirst()))
                    : values[name],
                isDynamic: dynamic,
                isSecret: secretKeys.contains(name)))
            index = close.upperBound
        }
        return tokens
    }

    // MARK: - Expansion

    private func expand(
        _ input: String,
        expanding: [String],
        depth: Int,
        unresolved: inout [String],
        cycles: inout [String]
    ) -> String {
        guard input.contains("{{") else { return input }
        var out = ""
        out.reserveCapacity(input.count)
        var index = input.startIndex

        while index < input.endIndex {
            guard let open = input.range(of: "{{", range: index..<input.endIndex) else {
                out += input[index...]
                break
            }
            // `\{{` is an escape: emit `{{` and skip the substitution.
            if isEscaped(input, openingAt: open.lowerBound) {
                out += input[index..<input.index(before: open.lowerBound)]
                out += "{{"
                index = open.upperBound
                continue
            }
            guard let close = input.range(of: "}}", range: open.upperBound..<input.endIndex) else {
                out += input[index...]
                break
            }
            out += input[index..<open.lowerBound]

            let name = input[open.upperBound..<close.lowerBound]
                .trimmingCharacters(in: .whitespaces)
            let literal = String(input[open.lowerBound..<close.upperBound])
            out += substitution(
                for: name, literal: literal, expanding: expanding, depth: depth,
                unresolved: &unresolved, cycles: &cycles)
            index = close.upperBound
        }
        return out
    }

    private func substitution(
        for name: String,
        literal: String,
        expanding: [String],
        depth: Int,
        unresolved: inout [String],
        cycles: inout [String]
    ) -> String {
        if name.isEmpty { return literal }

        // Dynamic variables win over everything and never recurse.
        if name.hasPrefix("$") {
            if let value = dynamics.value(for: String(name.dropFirst())) { return value }
            append(name, to: &unresolved)
            return literal
        }

        guard let value = values[name] else {
            append(name, to: &unresolved)
            return literal
        }

        if expanding.contains(name) || depth >= Self.maxDepth {
            append(name, to: &cycles)
            return literal
        }

        return expand(
            value, expanding: expanding + [name], depth: depth + 1,
            unresolved: &unresolved, cycles: &cycles)
    }

    /// True when the `{{` at `position` is preceded by a backslash.
    private func isEscaped(_ input: String, openingAt position: String.Index) -> Bool {
        guard position > input.startIndex else { return false }
        return input[input.index(before: position)] == "\\"
    }

    private func append(_ name: String, to list: inout [String]) {
        if !list.contains(name) { list.append(name) }
    }
}
