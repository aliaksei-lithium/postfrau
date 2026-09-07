import Foundation

/// Schema migrations for documents in the data folder.
///
/// Every persisted root carries `schemaVersion`. When Postfrau reads a document written by an
/// older build, the raw JSON passes through `migrate(_:from:)` before decoding, so the model
/// types never need to know about historical shapes. Bumping `Postfrau.schemaVersion` requires
/// adding a step here **and** a fixture test that loads a real old document.
public enum Migrations {
    public enum MigrationError: Error, LocalizedError {
        case fromTheFuture(found: Int, supported: Int)

        public var errorDescription: String? {
            switch self {
            case .fromTheFuture(let found, let supported):
                "This file was written by a newer version of Postfrau "
                    + "(schema \(found); this build understands \(supported)). "
                    + "Update Postfrau to open it."
            }
        }
    }

    /// The `schemaVersion` of a raw document, defaulting to 1 for files that predate the field.
    public static func schemaVersion(of json: [String: Any]) -> Int {
        json["schemaVersion"] as? Int ?? 1
    }

    /// Brings a decoded-but-not-yet-typed document up to the current schema.
    ///
    /// - Throws: `MigrationError.fromTheFuture` when the document is newer than this build.
    public static func migrate(_ json: [String: Any]) throws -> [String: Any] {
        var document = json
        var version = schemaVersion(of: document)

        guard version <= Postfrau.schemaVersion else {
            throw MigrationError.fromTheFuture(found: version, supported: Postfrau.schemaVersion)
        }

        // Each step migrates one version forward and is applied in order.
        while version < Postfrau.schemaVersion {
            guard let step = steps[version] else { break }
            document = step(document)
            version += 1
            document["schemaVersion"] = version
        }
        return document
    }

    /// `steps[n]` migrates a schema-`n` document to schema `n + 1`. Empty while v1 is current.
    private static let steps: [Int: @Sendable ([String: Any]) -> [String: Any]] = [:]

    /// Runs `migrate` over raw bytes. Returns the original bytes when nothing had to change,
    /// which is the common case and avoids a pointless re-serialization.
    public static func migrate(data: Data) throws -> Data {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return data
        }
        let version = schemaVersion(of: json)
        guard version <= Postfrau.schemaVersion else {
            throw MigrationError.fromTheFuture(found: version, supported: Postfrau.schemaVersion)
        }
        guard version < Postfrau.schemaVersion else { return data }
        let migrated = try migrate(json)
        return try JSONSerialization.data(withJSONObject: migrated)
    }
}
