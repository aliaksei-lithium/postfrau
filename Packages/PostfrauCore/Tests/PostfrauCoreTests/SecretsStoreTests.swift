import Foundation
import Security
import Testing
@testable import PostfrauCore

/// Runs against a throwaway Keychain service and cleans up after itself. When the Keychain is
/// unavailable — a locked login keychain, a headless account — each test records a known issue and
/// returns rather than failing.
@Suite("Secrets store", .serialized)
struct SecretsStoreTests {
    private func makeStore() -> SecretsStore {
        SecretsStore(service: "com.postfrau.tests.\(UUID().uuidString)")
    }

    /// True when this machine lets us write to the Keychain at all.
    private func isUsable(_ store: SecretsStore) async -> Bool {
        do {
            try await store.setValue("probe", scope: UUID(), key: "probe")
            try await store.deleteEverything()
            return true
        } catch {
            return false
        }
    }

    private func skipUnavailable() {
        withKnownIssue("Keychain is unavailable in this environment.", isIntermittent: true) {
            Issue.record("skipped")
        }
    }

    @Test func storesAndReadsBackASecret() async throws {
        let store = makeStore()
        guard await isUsable(store) else { return skipUnavailable() }
        defer { Task { try? await store.deleteEverything() } }

        let environment = UUID()
        #expect(try await store.value(scope: environment, key: "token") == nil)
        try await store.setValue("s3cret", scope: environment, key: "token")
        #expect(try await store.value(scope: environment, key: "token") == "s3cret")

        try await store.delete(scope: environment, key: "token")
        #expect(try await store.value(scope: environment, key: "token") == nil)
    }

    @Test func hydrateFillsInSecretValuesAndLeavesPlainOnesAlone() async throws {
        let store = makeStore()
        guard await isUsable(store) else { return skipUnavailable() }
        defer { Task { try? await store.deleteEverything() } }

        let environment = UUID()
        try await store.setValue("abc123", scope: environment, key: "apiKey")

        let onDisk = [
            Variable(key: "baseUrl", value: "https://api.test"),
            Variable(key: "apiKey", value: "", isSecret: true),
            Variable(key: "missing", value: "", isSecret: true),
        ]
        let hydrated = await store.hydrate(onDisk, scope: environment)

        #expect(hydrated[0].value == "https://api.test", "a plain variable is untouched")
        #expect(hydrated[1].value == "abc123")
        #expect(hydrated[2].value == "", "a secret with nothing stored comes back empty")
    }

    @Test func persistWritesSecretsAndSkipsPlainVariables() async throws {
        let store = makeStore()
        guard await isUsable(store) else { return skipUnavailable() }
        defer { Task { try? await store.deleteEverything() } }

        let environment = UUID()
        try await store.persist(
            [
                Variable(key: "baseUrl", value: "https://api.test"),
                Variable(key: "token", value: "t0ken", isSecret: true),
            ],
            previous: [], scope: environment)

        #expect(try await store.value(scope: environment, key: "token") == "t0ken")
        #expect(try await store.value(scope: environment, key: "baseUrl") == nil,
                "a plain variable has no business in the Keychain")
    }

    @Test func persistRemovesSecretsThatWereDeletedOrRenamed() async throws {
        let store = makeStore()
        guard await isUsable(store) else { return skipUnavailable() }
        defer { Task { try? await store.deleteEverything() } }

        let environment = UUID()
        let before = [
            Variable(key: "old", value: "value", isSecret: true),
            Variable(key: "kept", value: "still here", isSecret: true),
        ]
        try await store.persist(before, previous: [], scope: environment)

        // "old" is renamed to "new"; "kept" stays.
        let after = [
            Variable(key: "new", value: "value", isSecret: true),
            Variable(key: "kept", value: "still here", isSecret: true),
        ]
        try await store.persist(after, previous: before, scope: environment)

        #expect(try await store.value(scope: environment, key: "old") == nil,
                "the renamed secret must not be left behind")
        #expect(try await store.value(scope: environment, key: "new") == "value")
        #expect(try await store.value(scope: environment, key: "kept") == "still here")
    }

    @Test func persistRemovesASecretThatIsNoLongerSecret() async throws {
        let store = makeStore()
        guard await isUsable(store) else { return skipUnavailable() }
        defer { Task { try? await store.deleteEverything() } }

        let environment = UUID()
        let before = [Variable(key: "token", value: "t", isSecret: true)]
        try await store.persist(before, previous: [], scope: environment)

        let after = [Variable(key: "token", value: "t", isSecret: false)]
        try await store.persist(after, previous: before, scope: environment)

        #expect(try await store.value(scope: environment, key: "token") == nil)
    }

    @Test func environmentsDoNotSeeEachOthersSecrets() async throws {
        let store = makeStore()
        guard await isUsable(store) else { return skipUnavailable() }
        defer { Task { try? await store.deleteEverything() } }

        let staging = UUID()
        let production = UUID()
        try await store.setValue("staging-token", scope: staging, key: "token")
        try await store.setValue("prod-token", scope: production, key: "token")

        #expect(try await store.value(scope: staging, key: "token") == "staging-token")
        #expect(try await store.value(scope: production, key: "token") == "prod-token")
    }

    @Test func deletingAnEnvironmentTakesItsSecretsWithIt() async throws {
        let store = makeStore()
        guard await isUsable(store) else { return skipUnavailable() }
        defer { Task { try? await store.deleteEverything() } }

        let environment = UUID()
        try await store.setValue("a", scope: environment, key: "one")
        try await store.setValue("b", scope: environment, key: "two")

        await store.deleteAll(in: environment, keys: ["one", "two"])
        #expect(try await store.value(scope: environment, key: "one") == nil)
        #expect(try await store.value(scope: environment, key: "two") == nil)
    }

    @Test func globalsHaveTheirOwnScope() async throws {
        let store = makeStore()
        guard await isUsable(store) else { return skipUnavailable() }
        defer { Task { try? await store.deleteEverything() } }

        try await store.setValue("global", scope: SecretsStore.globalsScope, key: "shared")
        #expect(try await store.value(scope: SecretsStore.globalsScope, key: "shared") == "global")
        #expect(try await store.value(scope: UUID(), key: "shared") == nil)
    }

    @Test func togglingICloudSyncMovesEverySecret() async throws {
        let store = makeStore()
        guard await isUsable(store) else { return skipUnavailable() }
        defer { Task { try? await store.deleteEverything() } }

        let environment = UUID()
        try await store.setValue("t0ken", scope: environment, key: "token")
        #expect(await store.isSynchronizable == false)

        // iCloud Keychain items need a signed build with a Keychain access group; an ad-hoc
        // build gets `errSecMissingEntitlement`. That is a fact about the build, not a bug, so
        // the test asserts the error is the actionable one and stops there.
        // See `docs/decisions.md` D26.
        let moved: Int
        do {
            moved = try await store.setSynchronizable(true, scopes: [environment: ["token"]])
        } catch Keychain.KeychainError.missingEntitlement {
            #expect(await store.isSynchronizable == false, "a refused move must not flip the flag")
            #expect(try await store.value(scope: environment, key: "token") == "t0ken",
                    "and must not lose the secret")
            return
        }
        #expect(moved == 1)
        #expect(await store.isSynchronizable)
        // Readable through the new (synchronizable) store...
        #expect(try await store.value(scope: environment, key: "token") == "t0ken")

        // ...and moving back returns it.
        let movedBack = try await store.setSynchronizable(false, scopes: [environment: ["token"]])
        #expect(movedBack == 1)
        #expect(try await store.value(scope: environment, key: "token") == "t0ken")
    }

    @Test func togglingToTheSameStateDoesNothing() async throws {
        let store = makeStore()
        guard await isUsable(store) else { return skipUnavailable() }
        #expect(try await store.setSynchronizable(false, scopes: [:]) == 0)
    }

    @Test func aSecretsValueNeverReachesTheEncodedDocument() throws {
        // The store's whole reason for existing: disk holds a blank.
        let environment = RequestEnvironment(
            name: "Prod", variables: [Variable(key: "token", value: "s3cret", isSecret: true)])
        let text = String(decoding: try Postfrau.makeEncoder().encode(environment), as: UTF8.self)
        #expect(!text.contains("s3cret"))
        #expect(text.contains("\"isSecret\" : true"))
    }
}
