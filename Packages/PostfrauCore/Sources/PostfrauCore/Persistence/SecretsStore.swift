import Foundation

/// Reads and writes the values of secret variables.
///
/// A secret's value never reaches the data folder — `Variable.encode` writes an empty string for
/// one — so it has to live somewhere else, and that somewhere is the Keychain. This actor owns
/// that relationship: the in-memory model carries real values, disk carries blanks, and the
/// Keychain is the bridge. Being an actor also keeps Keychain calls off the main thread, which
/// matters because `SecItem*` can block.
public actor SecretsStore {
    /// The scope id used for globals, which have no environment of their own.
    public static let globalsScope = Keychain.globalsScope

    private var keychain: Keychain

    public init(service: String = Keychain.defaultService, synchronizable: Bool = false) {
        self.keychain = Keychain(service: service, synchronizable: synchronizable)
    }

    public var isSynchronizable: Bool { keychain.synchronizable }

    // MARK: - Single values

    public func value(scope: UUID, key: String) throws -> String? {
        try keychain.get(Keychain.account(environmentID: scope, key: key))
    }

    public func setValue(_ value: String, scope: UUID, key: String) throws {
        try keychain.set(value, for: Keychain.account(environmentID: scope, key: key))
    }

    public func delete(scope: UUID, key: String) throws {
        try keychain.delete(Keychain.account(environmentID: scope, key: key))
    }

    // MARK: - Whole variable lists

    /// Fills in the real values of the secret variables in `variables`.
    ///
    /// Anything the Keychain cannot supply comes back with an empty value rather than throwing:
    /// a locked Keychain, or a secret that was never set on this Mac, should leave the app usable
    /// and the variable visibly empty — not stop the workspace from loading.
    public func hydrate(_ variables: [Variable], scope: UUID) -> [Variable] {
        variables.map { variable in
            guard variable.isSecret, !variable.key.isEmpty else { return variable }
            var copy = variable
            copy.value = (try? value(scope: scope, key: variable.key)) ?? nil ?? ""
            return copy
        }
    }

    /// Writes the secret values and removes Keychain items for secrets that are gone.
    ///
    /// - Parameter previous: the variables as they were before the edit, so a renamed, deleted or
    ///   no-longer-secret variable does not leave its value behind in the Keychain.
    /// - Returns: how many values were actually written, which is how the skipping above is
    ///   tested without a Keychain to look into.
    @discardableResult
    public func persist(
        _ variables: [Variable], previous: [Variable], scope: UUID
    ) throws -> Int {
        let liveSecretKeys = Set(
            variables.filter { $0.isSecret && !$0.key.isEmpty }.map(\.key))

        for stale in previous where stale.isSecret && !stale.key.isEmpty {
            if !liveSecretKeys.contains(stale.key) {
                try? delete(scope: scope, key: stale.key)
            }
        }
        // Only what actually changed. Every Keychain write is a separate authorization, and on a
        // build without a stable signing identity that is a password prompt — so rewriting a
        // token that has not changed, because the environment was renamed or its base URL was
        // edited, costs the user a prompt and stores nothing new.
        //
        // The trade-off: if a write was refused earlier, an unrelated edit no longer silently
        // retries it. That failure is reported at the time (`secretsError`), and re-entering the
        // value writes it, which is a better bargain than a prompt on every edit.
        let alreadyStored = Dictionary(
            previous.filter { $0.isSecret && !$0.key.isEmpty }.map { ($0.key, $0.value) },
            uniquingKeysWith: { _, last in last })

        var written = 0
        for variable in variables where variable.isSecret && !variable.key.isEmpty {
            guard alreadyStored[variable.key] != variable.value else { continue }
            try setValue(variable.value, scope: scope, key: variable.key)
            written += 1
        }
        return written
    }

    /// Removes every secret belonging to one environment — used when the environment is deleted.
    public func deleteAll(in scope: UUID, keys: [String]) {
        for key in keys { try? delete(scope: scope, key: key) }
    }

    // MARK: - iCloud Keychain

    /// Moves every stored secret to (or from) iCloud Keychain.
    ///
    /// `kSecAttrSynchronizable` is part of an item's identity, so this is a copy-then-delete rather
    /// than an attribute change: read everything through the old store, write it through the new
    /// one, then remove the originals.
    ///
    /// - Parameter scopes: the environment ids (plus `globalsScope`) whose secrets should move,
    ///   with the keys held under each.
    /// - Returns: how many secrets were moved.
    @discardableResult
    public func setSynchronizable(_ enabled: Bool, scopes: [UUID: [String]]) throws -> Int {
        guard enabled != keychain.synchronizable else { return 0 }
        let source = keychain
        let destination = keychain.toggledSynchronizable()

        var moved = 0
        for (scope, keys) in scopes {
            for key in keys {
                let account = Keychain.account(environmentID: scope, key: key)
                guard let value = try? source.get(account) else { continue }
                try destination.set(value, for: account)
                try? source.delete(account)
                moved += 1
            }
        }
        keychain = destination
        return moved
    }

    /// Forgets everything under this service. Used by "reset all data" and by tests.
    public func deleteEverything() throws {
        try keychain.deleteAll()
        try keychain.toggledSynchronizable().deleteAll()
    }
}
