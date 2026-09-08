import Foundation
import Security
import Testing
@testable import PostfrauCore

/// These run against a throwaway service name and clean up after themselves. When the keychain is
/// unavailable — a locked login keychain, or a headless CI account — the test records a known
/// issue and returns instead of failing.
@Suite("Keychain")
struct KeychainTests {
    private func makeStore() -> Keychain {
        Keychain(service: "com.postfrau.tests.\(UUID().uuidString)")
    }

    /// True when this machine lets us write to the keychain at all.
    ///
    /// Answered by `KeychainProbe`, which puts a deadline on the question: a keychain that needs
    /// an authorization nobody can give blocks in `SecItemAdd` rather than failing.
    private func isUsable(_ store: Keychain) -> Bool { KeychainProbe.isKeychainUsable }

    /// Marks a test as skipped-because-the-environment-cannot-run-it, without failing the suite.
    private func skipUnavailable() {
        withKnownIssue("Keychain is unavailable in this environment.", isIntermittent: true) {
            Issue.record("skipped")
        }
    }

    @Test func storesUpdatesAndDeletesASecret() throws {
        let store = makeStore()
        guard isUsable(store) else { return skipUnavailable() }
        defer { try? store.deleteAll() }

        let account = Keychain.account(environmentID: UUID(), key: "token")
        #expect(try store.get(account) == nil)

        try store.set("first", for: account)
        #expect(try store.get(account) == "first")

        try store.set("second", for: account)
        #expect(try store.get(account) == "second")

        try store.delete(account)
        #expect(try store.get(account) == nil)

        // Deleting twice is not an error.
        try store.delete(account)
    }

    @Test func keepsSecretsFromDifferentEnvironmentsApart() throws {
        let store = makeStore()
        guard isUsable(store) else { return skipUnavailable() }
        defer { try? store.deleteAll() }

        let staging = UUID()
        let production = UUID()
        try store.set("s", for: Keychain.account(environmentID: staging, key: "token"))
        try store.set("p", for: Keychain.account(environmentID: production, key: "token"))

        #expect(try store.get(Keychain.account(environmentID: staging, key: "token")) == "s")
        #expect(try store.get(Keychain.account(environmentID: production, key: "token")) == "p")
        #expect(try store.allAccounts().count == 2)
    }

    @Test func deleteAllEmptiesTheService() throws {
        let store = makeStore()
        guard isUsable(store) else { return skipUnavailable() }

        for index in 0..<5 { try store.set("v\(index)", for: "account-\(index)") }
        #expect(try store.allAccounts().count == 5)

        try store.deleteAll()
        #expect(try store.allAccounts().isEmpty)

        // Emptying an already-empty service is not an error.
        try store.deleteAll()
    }

    @Test func handlesUnicodeAndEmptyValues() throws {
        let store = makeStore()
        guard isUsable(store) else { return skipUnavailable() }
        defer { try? store.deleteAll() }

        try store.set("pässwörd — 🔐", for: "unicode")
        #expect(try store.get("unicode") == "pässwörd — 🔐")

        try store.set("", for: "empty")
        #expect(try store.get("empty") == "")
    }

    @Test func synchronizableItemsAreSeparateFromLocalOnes() throws {
        let service = "com.postfrau.tests.\(UUID().uuidString)"
        let local = Keychain(service: service, synchronizable: false)
        let synced = Keychain(service: service, synchronizable: true)
        guard isUsable(local) else { return skipUnavailable() }
        defer { try? local.deleteAll() }

        try local.set("local-value", for: "token")
        // `kSecAttrSynchronizable` is part of an item's identity: the synced store sees nothing.
        #expect(try synced.get("token") == nil)
        #expect(try local.get("token") == "local-value")

        // Both stores are visible to a service-wide enumeration.
        try? synced.set("synced-value", for: "token")
        #expect(try local.allAccounts().contains("token"))
    }

    @Test func accountNamesAreDerivedFromTheEnvironmentAndKey() {
        let id = UUID()
        #expect(Keychain.account(environmentID: id, key: "apiKey") == "\(id.uuidString).apiKey")
        #expect(Keychain.globalsScope.uuidString.hasPrefix("00000000-"))
    }

    @Test func togglingSynchronizableGivesADistinctStore() {
        let store = Keychain(service: "s", synchronizable: false)
        let synced = store.toggledSynchronizable()
        #expect(synced.synchronizable)
        #expect(synced.service == store.service)
        #expect(synced.toggledSynchronizable().synchronizable == false)
    }

    @Test func errorsCarryAReadableDescription() {
        #expect(Keychain.KeychainError.interactionNotAllowed.errorDescription
            == "The keychain is locked.")
        #expect(Keychain.KeychainError.unexpectedStatus(errSecItemNotFound)
            .errorDescription?.isEmpty == false)
    }
}
