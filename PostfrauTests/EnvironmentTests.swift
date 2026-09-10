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
    ///
    /// Secrets are put back in the Keychain: that is what these tests are about, and since D57 it
    /// is no longer the default — the data folder is. A test that means to exercise the Keychain
    /// has to say so, the same as a user does.
    private func makeState(
        secretStorage: SecretStorage = .keychain
    ) -> (AppState, URL, SecretsStore) {
        let root = URL.temporaryDirectory.appending(path: "env-tests-\(UUID().uuidString)")
        let secrets = SecretsStore(service: "com.postfrau.tests.\(UUID().uuidString)")
        let state = AppState(
            store: WorkspaceStore(
                dataFolder: DataFolder(root: root, needsCoordination: false), localRoot: root),
            history: HistoryStore(root: root.appending(path: "history")),
            secretsStore: secrets)
        state.settings.secretStorage = secretStorage
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

    @Test("In data-folder mode the Keychain is not written to at all")
    func dataFolderModeLeavesTheKeychainAlone() async throws {
        let (state, _, secrets) = makeState(secretStorage: .dataFolder)
        var environment = state.newEnvironment(named: "Prod")
        environment.variables = [Variable(key: "token", value: "in the folder", isSecret: true)]
        state.update(environment)
        try await Task.sleep(for: .milliseconds(300))

        // The value is in the model, and that is where the workspace file will pick it up from.
        #expect(state.workspace.environments[0].variables[0].value == "in the folder")
        // And nowhere near the Keychain, which is the whole point of the setting.
        #expect(try await secrets.value(scope: environment.id, key: "token") == nil)
    }

    @Test("The toolbar button sets one secret in the active environment")
    func clipboardFillsTheTokenSecret() {
        let (state, _, _) = makeState()
        var environment = state.newEnvironment(named: "Staging")
        environment.variables = [Variable(key: "baseUrl", value: "https://example.com")]
        state.update(environment)
        state.workspace.activeEnvironmentID = environment.id

        #expect(state.setActiveEnvironmentSecret(named: "token", to: "  eyJhbGciOi.abc  \n"))
        let added = state.workspace.environments.first { $0.id == environment.id }?
            .variables.first { $0.key == "token" }
        #expect(added?.value == "eyJhbGciOi.abc", "the value should be trimmed")
        #expect(added?.isSecret == true)
        #expect(added?.enabled == true)
        #expect(state.workspace.environments.first { $0.id == environment.id }?.variables.count == 2,
                "baseUrl should still be there")

        // A second press replaces the value rather than adding a second `token`.
        #expect(state.setActiveEnvironmentSecret(named: "token", to: "second"))
        let variables = state.workspace.environments.first { $0.id == environment.id }?.variables
        #expect(variables?.filter { $0.key == "token" }.count == 1)
        #expect(variables?.first { $0.key == "token" }?.value == "second")
    }

    @Test("Nothing is written without an environment, or from a blank clipboard")
    func clipboardRefusesWhenThereIsNowhereToPutIt() {
        let (state, _, _) = makeState()
        // No active environment.
        #expect(state.setActiveEnvironmentSecret(named: "token", to: "abc") == false)

        let environment = state.newEnvironment(named: "Staging")
        state.workspace.activeEnvironmentID = environment.id
        // Whitespace only: a stray newline off the end of a copy is not a token.
        #expect(state.setActiveEnvironmentSecret(named: "token", to: "   \n ") == false)
        #expect(state.workspace.environments.first { $0.id == environment.id }?
            .variables.contains { $0.key == "token" } == false)
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
