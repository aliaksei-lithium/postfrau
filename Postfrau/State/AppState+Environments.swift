import Foundation
import PostfrauCore

/// Environments, globals and the secrets that ride along with them.
extension AppState {
    // MARK: - Editing

    @discardableResult
    func newEnvironment(named name: String = "New Environment") -> RequestEnvironment {
        let environment = RequestEnvironment(name: name)
        workspace.environments.append(environment)
        sortEnvironments()
        markDirty(environment: environment.id)
        return environment
    }

    @discardableResult
    func duplicateEnvironment(id: UUID) -> RequestEnvironment? {
        guard let original = workspace.environments.first(where: { $0.id == id })
        else { return nil }
        let copy = original.duplicated()
        workspace.environments.append(copy)
        sortEnvironments()
        markDirty(environment: copy.id)
        // The copy's secrets have to be written under its own id, or they would resolve to
        // nothing the moment the original is edited or deleted.
        persistSecrets(for: copy, previous: [])
        return copy
    }

    func deleteEnvironment(id: UUID) {
        guard let index = workspace.environments.firstIndex(where: { $0.id == id }) else { return }
        let removed = workspace.environments.remove(at: index)
        deletedEnvironmentIDs.insert(id)
        if workspace.activeEnvironmentID == id {
            workspace.activeEnvironmentID = nil
            markUIStateDirty()
        }

        // A deleted environment must not leave its secrets in the Keychain.
        let keys = removed.variables.filter(\.isSecret).map(\.key)
        let store = secretsStore
        Task.detached { await store.deleteAll(in: id, keys: keys) }
    }

    /// Writes an edited environment back, moving any secret values into the Keychain.
    func update(_ environment: RequestEnvironment) {
        guard let index = workspace.environments.firstIndex(where: { $0.id == environment.id })
        else { return }
        let previous = workspace.environments[index].variables
        workspace.environments[index] = environment
        markDirty(environment: environment.id)
        persistSecrets(for: environment, previous: previous)
    }

    func updateGlobals(_ globals: Globals) {
        let previous = workspace.globals.variables
        workspace.globals = globals
        markGlobalsDirty()
        persistSecrets(
            variables: globals.variables, previous: previous, scope: SecretsStore.globalsScope)
    }

    func setActiveEnvironment(_ id: UUID?) {
        workspace.activeEnvironmentID = id
        markUIStateDirty()
    }

    /// Sets one secret variable in the active environment, adding it if it is not there yet.
    ///
    /// The value is passed in rather than read from the clipboard here, so this is testable
    /// without one. Returns false when there is no active environment to put it in, or when the
    /// value is blank once trimmed — a stray newline off the end of a copied token should not
    /// count as a token, and neither should an empty clipboard.
    @discardableResult
    func setActiveEnvironmentSecret(named key: String, to value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let id = workspace.activeEnvironmentID,
              let index = workspace.environments.firstIndex(where: { $0.id == id })
        else { return false }

        var environment = workspace.environments[index]
        if let existing = environment.variables.firstIndex(where: { $0.key == key }) {
            environment.variables[existing].value = trimmed
            environment.variables[existing].isSecret = true
            environment.variables[existing].enabled = true
        } else {
            environment.variables.append(Variable(key: key, value: trimmed, isSecret: true))
        }
        // Goes through `update`, so the environment is marked dirty, every resolver is
        // invalidated, and the value reaches the Keychain like any other secret.
        update(environment)
        return true
    }

    private func sortEnvironments() {
        workspace.environments.sort {
            $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    // MARK: - Secrets

    func persistSecrets(for environment: RequestEnvironment, previous: [Variable] = []) {
        persistSecrets(
            variables: environment.variables, previous: previous, scope: environment.id)
    }

    /// Hands the secret values to the Keychain off the main actor.
    ///
    /// Failures are surfaced as a status message rather than thrown: a locked Keychain should not
    /// block editing, and the variable is still usable for the rest of the session.
    private func persistSecrets(variables: [Variable], previous: [Variable], scope: UUID) {
        guard variables.contains(where: \.isSecret) || previous.contains(where: \.isSecret)
        else { return }
        let store = secretsStore
        Task { [weak self] in
            do {
                try await store.persist(variables, previous: previous, scope: scope)
            } catch {
                self?.secretsError = AppState.message(for: error)
            }
        }
    }

    /// Fills in every secret value from the Keychain. Called once after the workspace loads.
    func loadSecrets() async {
        let store = secretsStore
        for index in workspace.environments.indices {
            let environment = workspace.environments[index]
            guard environment.variables.contains(where: \.isSecret) else { continue }
            workspace.environments[index].variables = await store.hydrate(
                environment.variables, scope: environment.id)
        }
        if workspace.globals.variables.contains(where: \.isSecret) {
            workspace.globals.variables = await store.hydrate(
                workspace.globals.variables, scope: SecretsStore.globalsScope)
        }
    }

    /// Moves every stored secret to or from iCloud Keychain.
    func setSecretsSyncEnabled(_ enabled: Bool) {
        settings.syncSecretsViaICloudKeychain = enabled
        markSettingsDirty()

        var scopes: [UUID: [String]] = [:]
        for environment in workspace.environments {
            let keys = environment.variables.filter(\.isSecret).map(\.key)
            if !keys.isEmpty { scopes[environment.id] = keys }
        }
        let globalKeys = workspace.globals.variables.filter(\.isSecret).map(\.key)
        if !globalKeys.isEmpty { scopes[SecretsStore.globalsScope] = globalKeys }

        let store = secretsStore
        Task { [weak self] in
            do {
                try await store.setSynchronizable(enabled, scopes: scopes)
                self?.secretsError = nil
            } catch {
                // The most likely failure is an unsigned build, which cannot use iCloud Keychain
                // at all; put the setting back so the UI does not claim something untrue.
                self?.settings.syncSecretsViaICloudKeychain = !enabled
                self?.markSettingsDirty()
                self?.secretsError = AppState.message(for: error)
            }
        }
    }
}
