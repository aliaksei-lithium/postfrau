import Foundation

/// Postman environment files: `{name, values: [{key, value, enabled, type}]}`.
///
/// A separate format from collections, and a much smaller one. Secrets are the only subtlety:
/// Postman marks them `type: "secret"` and exports the value anyway. Postfrau imports the flag,
/// keeps the value in the Keychain, and exports the flag with an empty value — an environment
/// file is the thing people paste into tickets.
public enum PostmanEnvironment {
    public enum ImportError: Error, LocalizedError, Equatable {
        case notAnEnvironment

        public var errorDescription: String? {
            "That does not look like a Postman environment — it has no “values” list."
        }
    }

    public static func `import`(_ data: Data) throws -> RequestEnvironment {
        guard let root = try? Postfrau.makeDecoder().decode(JSONValue.self, from: data),
              let object = root.objectValue
        else { throw ImportError.notAnEnvironment }
        return try `import`(object)
    }

    public static func `import`(_ object: [String: JSONValue]) throws -> RequestEnvironment {
        guard let values = object["values"]?.arrayValue else { throw ImportError.notAnEnvironment }

        var environment = RequestEnvironment(
            name: object["name"]?.stringValue ?? "Imported environment")
        environment.variables = values.compactMap { entry in
            guard let pair = entry.objectValue,
                  let key = pair["key"]?.stringValue, !key.isEmpty
            else { return nil }
            return Variable(
                key: key,
                value: pair["value"]?.stringValue ?? "",
                enabled: pair["enabled"]?.boolValue != false,
                isSecret: pair["type"]?.stringValue == "secret")
        }
        return environment
    }

    /// True when a JSON object is an environment rather than a collection, for File ▸ Import.
    public static func looksLikeEnvironment(_ object: [String: JSONValue]) -> Bool {
        object["values"]?.arrayValue != nil && object["item"] == nil
    }

    public static func export(_ environment: RequestEnvironment) -> JSONValue {
        .object([
            "id": .string(environment.id.uuidString.lowercased()),
            "name": .string(environment.name),
            "values": .array(environment.variables.map { variable in
                .object([
                    "key": .string(variable.key),
                    // Blank for secrets: the value is in the Keychain, and an environment file is
                    // exactly the kind of thing that gets pasted into a ticket.
                    "value": .string(variable.isSecret ? "" : variable.value),
                    "enabled": .bool(variable.enabled),
                    "type": .string(variable.isSecret ? "secret" : "default"),
                ])
            }),
            "_postman_variable_scope": .string("environment"),
        ])
    }

    public static func data(for environment: RequestEnvironment) throws -> Data {
        try Postfrau.makeEncoder(pretty: true).encode(export(environment))
    }
}
