import Foundation

/// Supplies the `{{$name}}` values. Injectable so tests can be deterministic.
public protocol DynamicVariableProvider: Sendable {
    /// `name` excludes the leading `$`. Returns nil for names this provider does not know.
    func value(for name: String) -> String?
}

/// The dynamic variables Postfrau ships with. Every occurrence is evaluated independently,
/// so two `{{$guid}}` in one request produce two different ids — same as Postman.
public struct SystemDynamicVariables: DynamicVariableProvider {
    public init() {}

    /// The names offered in autocomplete, in the order the UI should show them.
    public static let knownNames = [
        "guid", "randomUUID", "timestamp", "isoTimestamp", "randomInt",
    ]

    public func value(for name: String) -> String? {
        switch name {
        case "guid", "randomUUID":
            UUID().uuidString.lowercased()
        case "timestamp":
            String(Int(Date().timeIntervalSince1970))
        case "isoTimestamp":
            Date().ISO8601Format()
        case "randomInt":
            String(Int.random(in: 0...1000))
        default:
            nil
        }
    }
}
