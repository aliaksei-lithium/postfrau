import Foundation
import Security

/// Storage for secret variable values.
///
/// Items are generic passwords under the service `com.postfrau.secrets`, keyed
/// `"<environmentID>.<variableKey>"`. Accessibility is `AfterFirstUnlock` so a request can be
/// sent without an interactive unlock, and `kSecAttrSynchronizable` follows the user's
/// "Sync secrets via iCloud Keychain" setting — that flag is part of an item's identity, so
/// changing it means rewriting every item (see `WorkspaceStore.resyncSecrets`).
public struct Keychain: Sendable {
    public static let defaultService = "com.postfrau.secrets"

    public let service: String
    /// When true, items are written with `kSecAttrSynchronizable` and ride iCloud Keychain.
    public let synchronizable: Bool

    public init(service: String = Keychain.defaultService, synchronizable: Bool = false) {
        self.service = service
        self.synchronizable = synchronizable
    }

    public enum KeychainError: Error, LocalizedError, Equatable {
        case unexpectedStatus(OSStatus)
        case interactionNotAllowed
        /// The system refused the item because the build is not signed for it. iCloud Keychain
        /// (`kSecAttrSynchronizable`) needs a real signing identity; an ad-hoc build cannot store
        /// synchronizable items at all.
        case missingEntitlement

        public var errorDescription: String? {
            switch self {
            case .interactionNotAllowed:
                "The keychain is locked."
            case .missingEntitlement:
                "This build cannot use iCloud Keychain. Syncing secrets needs a signed build "
                    + "with a Keychain access group; secrets stay on this Mac."
            case .unexpectedStatus(let status):
                SecCopyErrorMessageString(status, nil) as String?
                    ?? "Keychain error \(status)."
            }
        }

        /// Maps an `OSStatus` to the case that says the most about it.
        static func from(_ status: OSStatus) -> KeychainError {
            switch status {
            case errSecInteractionNotAllowed: .interactionNotAllowed
            case errSecMissingEntitlement: .missingEntitlement
            default: .unexpectedStatus(status)
            }
        }
    }

    /// The account string for a secret variable.
    public static func account(environmentID: UUID, key: String) -> String {
        "\(environmentID.uuidString).\(key)"
    }

    /// The account string for a secret variable that belongs to globals rather than an environment.
    public static let globalsScope = UUID(uuidString: "00000000-0000-0000-0000-0000000067CB")!

    public func get(_ account: String) throws -> String? {
        var query = baseQuery(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            guard let data = result as? Data else { return nil }
            return String(data: data, encoding: .utf8)
        case errSecItemNotFound:
            return nil
        default:
            throw KeychainError.from(status)
        }
    }

    public func set(_ value: String, for account: String) throws {
        let data = Data(value.utf8)
        let query = baseQuery(account: account)

        let updateStatus = SecItemUpdate(
            query as CFDictionary,
            [kSecValueData as String: data] as CFDictionary)
        if updateStatus == errSecSuccess { return }
        if updateStatus != errSecItemNotFound { throw KeychainError.from(updateStatus) }

        var insert = query
        insert[kSecValueData as String] = data
        insert[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        let addStatus = SecItemAdd(insert as CFDictionary, nil)
        guard addStatus == errSecSuccess else { throw KeychainError.from(addStatus) }
    }

    public func delete(_ account: String) throws {
        let status = SecItemDelete(baseQuery(account: account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.unexpectedStatus(status)
        }
    }

    /// Removes every item under this service. Used by tests and by "reset all data".
    ///
    /// macOS's file-based keychain removes only **one** matching item per `SecItemDelete`, and it
    /// rejects `kSecMatchLimit` on a delete, so the call is repeated until nothing matches.
    public func deleteAll() throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrSynchronizable as String: kSecAttrSynchronizableAny,
        ]
        // Bounded so a keychain that keeps reporting success can never spin forever.
        for _ in 0..<10_000 {
            let status = SecItemDelete(query as CFDictionary)
            if status == errSecItemNotFound { return }
            guard status == errSecSuccess else { throw KeychainError.unexpectedStatus(status) }
        }
        throw KeychainError.unexpectedStatus(errSecInternalError)
    }

    /// Every account name stored under this service.
    public func allAccounts() throws -> [String] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll,
        ]
        query[kSecAttrSynchronizable as String] = kSecAttrSynchronizableAny

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return [] }
        guard status == errSecSuccess else { throw KeychainError.unexpectedStatus(status) }
        let items = result as? [[String: Any]] ?? []
        return items.compactMap { $0[kSecAttrAccount as String] as? String }
    }

    /// The same store with the opposite iCloud-sync flag, for migrating items between the two.
    public func toggledSynchronizable() -> Keychain {
        Keychain(service: service, synchronizable: !synchronizable)
    }

    private func baseQuery(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: synchronizable,
        ]
    }
}
