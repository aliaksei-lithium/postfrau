import Foundation
import Testing
import PostfrauCore
@testable import Postfrau

/// Phase 7's acceptance criteria, at the level where they can be checked deterministically:
/// switching environments changes where a request goes, and a secret is sent correctly while
/// never reaching the data folder.
@Suite("Environments and secrets", .serialized)
@MainActor
struct EnvironmentTests {
    /// An `AppState` on a temporary data folder with a throwaway Keychain service.
    private func makeState() -> (AppState, URL, SecretsStore) {
        let root = URL.temporaryDirectory.appending(path: "env-tests-\(UUID().uuidString)")
        let secrets = SecretsStore(service: "com.postfrau.tests.\(UUID().uuidString)")
        let state = AppState(
            store: WorkspaceStore(
                dataFolder: DataFolder(root: root, needsCoordination: false), localRoot: root),
            history: HistoryStore(root: root.appending(path: "history")),
            secretsStore: secrets)
        return (state, root, secrets)
    }

    /// True when this machine's Keychain will actually take an item.
    ///
    /// It will not on a Mac whose login keychain is locked or needs an authorization nobody is
    /// there to give — a headless session, a CI runner. The tests that need it say so and skip,
    /// the same way the Core Keychain tests do, rather than reporting a machine's state as a
    /// defect in the app.
    private func keychainIsUsable(_ secrets: SecretsStore) async -> Bool {
        AppKeychainProbe.isKeychainUsable
    }

    private func skipUnavailableKeychain() {
        withKnownIssue("Keychain is unavailable in this environment.", isIntermittent: true) {
            Issue.record("skipped")
        }
    }

    private func makeTab(_ state: AppState, url: String) -> RequestTab {
        let tab = RequestTab(draft: RequestItem(name: "R", url: url))
        state.tabs = [tab]
        state.selectedTabID = tab.id
        return tab
    }

    @Test func switchingEnvironmentChangesWhereARequestGoes() throws {
        let (state, root, _) = makeState()
        defer { try? FileManager.default.removeItem(at: root) }

        let staging = state.newEnvironment(named: "Staging")
        state.update({
            var updated = staging
            updated.variables = [Variable(key: "baseUrl", value: "https://staging.test")]
            return updated
        }())
        let production = state.newEnvironment(named: "Production")
        state.update({
            var updated = production
            updated.variables = [Variable(key: "baseUrl", value: "https://api.test")]
            return updated
        }())

        let tab = makeTab(state, url: "{{baseUrl}}/users")

        state.setActiveEnvironment(staging.id)
        #expect(state.resolver(for: tab).resolved(tab.draft.url) == "https://staging.test/users")

        state.setActiveEnvironment(production.id)
        #expect(state.resolver(for: tab).resolved(tab.draft.url) == "https://api.test/users")

        state.setActiveEnvironment(nil)
        #expect(
            state.resolver(for: tab).resolve(tab.draft.url).unresolved == ["baseUrl"],
            "with no environment the variable is unresolved, and says so")
    }

    @Test func aSecretIsSentCorrectlyButNeverWrittenToTheDataFolder() async throws {
        let (state, root, secrets) = makeState()
        guard await keychainIsUsable(secrets) else { return skipUnavailableKeychain() }
        defer {
            try? FileManager.default.removeItem(at: root)
            Task { try? await secrets.deleteEverything() }
        }

        let environment = state.newEnvironment(named: "Prod")
        var updated = environment
        updated.variables = [Variable(key: "apiToken", value: "s3cret-value", isSecret: true)]
        state.update(updated)
        state.setActiveEnvironment(environment.id)

        // Give the detached Keychain write a moment to land.
        try await Task.sleep(for: .milliseconds(300))

        // Sent correctly: the auth helper resolves the secret.
        let tab = makeTab(state, url: "https://api.test/me")
        tab.draft.auth = .bearer(token: "{{apiToken}}")
        let wire = try #require(AuthResolver.wireValue(
            for: tab.draft.auth, resolver: state.resolver(for: tab)))
        #expect(wire == .header(name: "Authorization", value: "Bearer s3cret-value"))

        // Never written: the document on disk holds a blank.
        _ = try await state.store.save(environment: state.workspace.environments[0])
        let file = await state.store.folder.environmentFile(environment.id)
        let text = try String(contentsOf: file, encoding: .utf8)
        #expect(!text.contains("s3cret-value"))
        #expect(text.contains("\"isSecret\" : true"))
    }

    @Test func secretsComeBackFromTheKeychainOnALaterLaunch() async throws {
        let (state, root, secrets) = makeState()
        guard await keychainIsUsable(secrets) else { return skipUnavailableKeychain() }
        defer {
            try? FileManager.default.removeItem(at: root)
            Task { try? await secrets.deleteEverything() }
        }

        let environment = state.newEnvironment(named: "Prod")
        var updated = environment
        updated.variables = [Variable(key: "apiToken", value: "kept", isSecret: true)]
        state.update(updated)
        try await Task.sleep(for: .milliseconds(300))

        // Simulate a relaunch: the model comes back from disk with a blank secret…
        state.workspace.environments[0].variables[0].value = ""
        #expect(state.workspace.environments[0].variables[0].value.isEmpty)

        // …and `loadSecrets` fills it in again.
        await state.loadSecrets()
        #expect(state.workspace.environments[0].variables[0].value == "kept")
    }

    @Test func deletingAnEnvironmentRemovesItsSecrets() async throws {
        let (state, root, secrets) = makeState()
        guard await keychainIsUsable(secrets) else { return skipUnavailableKeychain() }
        defer {
            try? FileManager.default.removeItem(at: root)
            Task { try? await secrets.deleteEverything() }
        }

        let environment = state.newEnvironment(named: "Doomed")
        var updated = environment
        updated.variables = [Variable(key: "token", value: "gone soon", isSecret: true)]
        state.update(updated)
        try await Task.sleep(for: .milliseconds(300))
        #expect(try await secrets.value(scope: environment.id, key: "token") == "gone soon")

        state.deleteEnvironment(id: environment.id)
        try await Task.sleep(for: .milliseconds(300))
        #expect(try await secrets.value(scope: environment.id, key: "token") == nil)
        #expect(state.workspace.environments.isEmpty)
    }

    @Test func deletingTheActiveEnvironmentClearsTheSelection() {
        let (state, root, _) = makeState()
        defer { try? FileManager.default.removeItem(at: root) }

        let environment = state.newEnvironment(named: "Active")
        state.setActiveEnvironment(environment.id)
        state.deleteEnvironment(id: environment.id)
        #expect(state.workspace.activeEnvironmentID == nil)
    }

    @Test func duplicatingAnEnvironmentCopiesItsSecretsUnderTheNewID() async throws {
        let (state, root, secrets) = makeState()
        guard await keychainIsUsable(secrets) else { return skipUnavailableKeychain() }
        defer {
            try? FileManager.default.removeItem(at: root)
            Task { try? await secrets.deleteEverything() }
        }

        let original = state.newEnvironment(named: "Prod")
        var updated = original
        updated.variables = [Variable(key: "token", value: "shared", isSecret: true)]
        state.update(updated)
        try await Task.sleep(for: .milliseconds(300))

        let copy = try #require(state.duplicateEnvironment(id: original.id))
        try await Task.sleep(for: .milliseconds(300))

        #expect(copy.id != original.id)
        #expect(try await secrets.value(scope: copy.id, key: "token") == "shared",
                "the copy's secrets must be stored under its own id")
        #expect(try await secrets.value(scope: original.id, key: "token") == "shared")
    }

    @Test func globalsResolveEverywhereAndAreShadowedByAnEnvironment() throws {
        let (state, root, _) = makeState()
        defer { try? FileManager.default.removeItem(at: root) }

        state.updateGlobals(Globals(variables: [
            Variable(key: "ua", value: "postfrau"),
            Variable(key: "baseUrl", value: "https://global.test"),
        ]))
        let tab = makeTab(state, url: "{{baseUrl}}/x")
        #expect(state.resolver(for: tab).resolved("{{ua}}") == "postfrau")
        #expect(state.resolver(for: tab).resolved(tab.draft.url) == "https://global.test/x")

        let environment = state.newEnvironment(named: "Staging")
        var updated = environment
        updated.variables = [Variable(key: "baseUrl", value: "https://staging.test")]
        state.update(updated)
        state.setActiveEnvironment(environment.id)

        #expect(state.resolver(for: tab).resolved(tab.draft.url) == "https://staging.test/x",
                "the environment wins over globals")
        #expect(state.resolver(for: tab).resolved("{{ua}}") == "postfrau",
                "and globals still supply what the environment does not")
    }

    @Test func unresolvedVariablesAreCountedPerSection() {
        let (state, root, _) = makeState()
        defer { try? FileManager.default.removeItem(at: root) }

        let tab = makeTab(state, url: "{{host}}/x")
        tab.draft.params = [KeyValue(key: "a", value: "{{missingParam}}")]
        tab.draft.headers = [KeyValue(key: "X", value: "{{missingHeader}}")]
        tab.draft.body = .raw(text: "{{missingBody}}", language: .json)

        let counts = state.unresolvedCounts(for: tab)
        #expect(counts.url == 1)
        #expect(counts.params == 1)
        #expect(counts.headers == 1)
        #expect(counts.body == 1)
        #expect(counts.total == 4)

        state.updateGlobals(Globals(variables: [Variable(key: "host", value: "https://x.test")]))
        #expect(state.unresolvedCounts(for: tab).url == 0)
    }
}
