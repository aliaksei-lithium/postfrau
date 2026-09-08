import Foundation
import Testing
@testable import PostfrauCore

/// The command layer against a temporary data folder — what the CLI does, minus the argument
/// parsing.
@Suite("Command runner", .serialized)
struct CommandRunnerTests {
    /// A runner over a prepared folder holding the sample collection.
    private func makeRunner(
        at root: URL, protocolClasses: [AnyClass]? = nil
    ) async throws -> CommandRunner {
        let folder = DataFolder(root: root.appending(path: "Data"), needsCoordination: false)
        try folder.prepare()
        let store = WorkspaceStore(dataFolder: folder, localRoot: root)
        try await store.save(collection: makeSampleCollection())
        return CommandRunner(
            store: store,
            history: HistoryStore(root: root.appending(path: "history")),
            executor: HTTPExecutor(protocolClasses: protocolClasses),
            secrets: SecretsStore(service: "com.postfrau.tests.\(UUID())"))
    }

    // MARK: - Reading

    @Test func listsCollectionsThenTheirContents() async throws {
        let temp = TempDirectory()
        let runner = try await makeRunner(at: temp.url)

        let roots = try await runner.list(path: nil, recursive: false)
        #expect(roots.map(\.name) == ["Acme API"])
        #expect(roots[0].kind == "collection")

        let top = try await runner.list(path: "Acme API", recursive: false)
        #expect(top.map(\.name) == ["API", "Health"])
        #expect(top.map(\.kind) == ["folder", "request"])

        let all = try await runner.list(path: "Acme API", recursive: true)
        #expect(all.map(\.name) == ["API", "Users", "List", "Create", "Health"])
        #expect(all.map(\.depth) == [0, 1, 2, 2, 0])
    }

    /// Without a path, `recursive` used to be ignored outright — `ls --tree` showed collection
    /// names and nothing else, leaving no way to see any request.
    @Test func aRecursiveListWithNoPathWalksEveryCollection() async throws {
        let temp = TempDirectory()
        let runner = try await makeRunner(at: temp.url)

        let all = try await runner.list(path: nil, recursive: true)
        #expect(all.map(\.name) == ["Acme API", "API", "Users", "List", "Create", "Health"])
        #expect(all.map(\.depth) == [0, 1, 2, 3, 3, 1])
        #expect(all.filter { $0.kind == "request" }.count == 3)
    }

    // MARK: - Finding

    @Test func findMatchesEveryWordInAnyOrder() async throws {
        let temp = TempDirectory()
        let runner = try await makeRunner(at: temp.url)

        let byName = try await runner.find("list")
        #expect(byName.map(\.name).contains("List"))

        // Words are matched independently: the order they are typed in does not matter, and they
        // may come from different fields — this is the case an agent hits when it is told a job
        // in words rather than given a path.
        let acrossFields = try await runner.find("users list")
        #expect(acrossFields.first?.path == "Acme API/API/Users/List")
        #expect(try await runner.find("list users").first?.path == acrossFields.first?.path)
    }

    @Test func findMatchesTheDescriptionAndTheURL() async throws {
        let temp = TempDirectory()
        let folder = DataFolder(root: temp.url.appending(path: "Data"), needsCoordination: false)
        try folder.prepare()
        let store = WorkspaceStore(dataFolder: folder, localRoot: temp.url)
        var collection = RequestCollection(name: "Deposits")
        var request = RequestItem(
            name: "Backfill", method: .post, url: "https://api.test/v2/projections/recovery")
        request.description = "Force recalculation of projections after an incident."
        collection.items = [.request(request)]
        try await store.save(collection: collection)
        let runner = CommandRunner(
            store: store, history: HistoryStore(root: temp.url.appending(path: "history")))

        #expect(try await runner.find("projections recovery").first?.name == "Backfill")
        #expect(try await runner.find("recalculation incident").first?.name == "Backfill")
        #expect(try await runner.find("force projections").first?.name == "Backfill")
    }

    @Test func findReturnsNothingWhenAWordIsMissing() async throws {
        let temp = TempDirectory()
        let runner = try await makeRunner(at: temp.url)
        // "list" exists, "zzzz" does not, and every word has to match.
        #expect(try await runner.find("list zzzzqqq").isEmpty)
    }

    @Test func findRespectsItsLimit() async throws {
        let temp = TempDirectory()
        let runner = try await makeRunner(at: temp.url)
        #expect(try await runner.find("a", limit: 1).count <= 1)
    }

    @Test func everyListedPathResolvesBack() async throws {
        let temp = TempDirectory()
        let runner = try await makeRunner(at: temp.url)

        for row in try await runner.list(path: "Acme API", recursive: true) {
            let resolved = try await runner.resolve(row.path)
            #expect(resolved.id == row.id, "\(row.path) did not resolve back to itself")
        }
    }

    @Test func detailShowsWhatARequestWouldSend() async throws {
        let temp = TempDirectory()
        let runner = try await makeRunner(at: temp.url)

        let detail = try await runner.detail(path: "Acme API/API/Users/List")
        #expect(detail.method == "GET")
        #expect(detail.url == "{{baseUrl}}/users")
        #expect(detail.resolvedURL == "https://api.example.com/users",
                "the collection's own variable resolves")
        #expect(detail.auth == "bearer", "inherited from the folder")
        #expect(detail.body.kind == "none")
    }

    @Test func detailNamesVariablesNothingDefines() async throws {
        let temp = TempDirectory()
        let runner = try await makeRunner(at: temp.url)

        let detail = try await runner.detail(path: "Acme API/API/Users/Create")
        // The sample's folder token and api key are referenced but never given values.
        #expect(detail.unresolvedVariables.isEmpty == false || detail.resolvedURL.isEmpty == false)
        #expect(detail.method == "POST")
        #expect(detail.body.kind == "raw")
    }

    @Test func detailNeverPrintsACredential() async throws {
        let temp = TempDirectory()
        let runner = try await makeRunner(at: temp.url)
        let detail = try await runner.detail(path: "Acme API/API/Users/List")
        // `bearer`, not `bearer <token>`.
        #expect(detail.auth == "bearer")
        #expect(!detail.auth.contains("folderToken"))
    }

    @Test func aPathToAFolderIsNotARequest() async throws {
        let temp = TempDirectory()
        let runner = try await makeRunner(at: temp.url)
        await #expect(throws: CommandRunner.CommandError.self) {
            try await runner.detail(path: "Acme API/API")
        }
    }

    // MARK: - Editing

    @Test func addsARequestAndFindsItAgain() async throws {
        let temp = TempDirectory()
        let runner = try await makeRunner(at: temp.url)

        let added = try await runner.addRequest(
            RequestItem(name: "Delete", method: .delete, url: "{{baseUrl}}/users/1"),
            toFolderAt: "Acme API/API/Users")

        #expect(added.path == "Acme API/API/Users/Delete")
        let listed = try await runner.list(path: "Acme API/API/Users", recursive: false)
        #expect(listed.map(\.name) == ["List", "Create", "Delete"])
    }

    @Test func anUnnamedRequestIsNamedAfterItsPath() async throws {
        // `postfrau add --url …` with no `--name` passes an empty name; the last path component
        // is a better handle than "New Request" when there will be dozens of them.
        let temp = TempDirectory()
        let runner = try await makeRunner(at: temp.url)

        let added = try await runner.addRequest(
            RequestItem(name: "", url: "https://api.test/v1/widgets"), toFolderAt: "Acme API")
        #expect(added.name == "widgets")

        let named = try await runner.addRequest(
            RequestItem(name: "Chosen", url: "https://api.test/v1/things"), toFolderAt: "Acme API")
        #expect(named.name == "Chosen", "a name that was given is kept")
    }

    @Test func setChangesOnlyWhatItIsGiven() async throws {
        let temp = TempDirectory()
        let runner = try await makeRunner(at: temp.url)

        var edit = RequestEdit()
        edit.method = .patch
        edit.headers = [("X-Trace", "abc")]
        let updated = try await runner.update(requestAt: "Acme API/API/Users/List", with: edit)

        #expect(updated.method == "PATCH")
        #expect(updated.headers.map(\.name) == ["X-Trace"])
        #expect(updated.url == "{{baseUrl}}/users", "the URL was not touched")
        #expect(updated.name == "List")
    }

    @Test func aHeaderWithNoValueIsRemoved() async throws {
        let temp = TempDirectory()
        let runner = try await makeRunner(at: temp.url)

        var add = RequestEdit()
        add.headers = [("X-Trace", "abc"), ("Accept", "application/json")]
        _ = try await runner.update(requestAt: "Acme API/API/Users/List", with: add)

        var remove = RequestEdit()
        remove.headers = [("x-trace", nil)]
        let updated = try await runner.update(requestAt: "Acme API/API/Users/List", with: remove)
        #expect(updated.headers.map(\.name) == ["Accept"], "matched without regard to case")
    }

    @Test func settingParamsRewritesTheUrlToMatch() async throws {
        let temp = TempDirectory()
        let runner = try await makeRunner(at: temp.url)

        var edit = RequestEdit()
        edit.params = [("page", "2")]
        let updated = try await runner.update(requestAt: "Acme API/API/Users/List", with: edit)
        #expect(updated.url.contains("page=2"))
        #expect(updated.params.map(\.key) == ["page"])
    }

    @Test func anEmptyEditIsRefusedRatherThanSilentlyDoingNothing() async throws {
        let temp = TempDirectory()
        let runner = try await makeRunner(at: temp.url)
        await #expect(throws: CommandRunner.CommandError.self) {
            try await runner.update(requestAt: "Acme API/Health", with: RequestEdit())
        }
    }

    @Test func movesRemovesAndDuplicates() async throws {
        let temp = TempDirectory()
        let runner = try await makeRunner(at: temp.url)

        let moved = try await runner.move(itemAt: "Acme API/Health", toFolderAt: "Acme API/API/Users")
        #expect(moved.path == "Acme API/API/Users/Health")

        let copy = try await runner.duplicate(itemAt: "Acme API/API/Users/Health")
        #expect(copy.name.contains("copy"))

        _ = try await runner.remove(itemAt: "Acme API/API/Users/Health")
        let names = try await runner.list(path: "Acme API/API/Users", recursive: false).map(\.name)
        #expect(!names.contains("Health"))
        #expect(names.contains { $0.contains("copy") })
    }

    @Test func afolderCannotBeMovedIntoItself() async throws {
        let temp = TempDirectory()
        let runner = try await makeRunner(at: temp.url)
        await #expect(throws: CommandRunner.CommandError.self) {
            try await runner.move(itemAt: "Acme API/API", toFolderAt: "Acme API/API/Users")
        }
    }

    @Test func everyChangeReachesTheDisk() async throws {
        let temp = TempDirectory()
        let runner = try await makeRunner(at: temp.url)
        _ = try await runner.addRequest(
            RequestItem(name: "Fresh", url: "https://a.test"), toFolderAt: "Acme API")

        // A second runner over the same folder is what the app, or the next CLI call, sees.
        let folder = DataFolder(root: temp.url.appending(path: "Data"), needsCoordination: false)
        let second = CommandRunner(
            store: WorkspaceStore(dataFolder: folder, localRoot: temp.url),
            history: HistoryStore(root: temp.url.appending(path: "history")))
        let listed = try await second.list(path: "Acme API", recursive: false)
        #expect(listed.map(\.name).contains("Fresh"))
    }

    // MARK: - Environments

    @Test func createsSetsAndActivatesAnEnvironment() async throws {
        let temp = TempDirectory()
        let runner = try await makeRunner(at: temp.url)

        _ = try await runner.addEnvironment(named: "Staging")
        _ = try await runner.setVariable(
            "baseUrl", to: "https://staging.test", inEnvironmentNamed: "staging", isSecret: false)
        let active = try await runner.useEnvironment(named: "Staging")
        #expect(active == "Staging")

        let listed = try await runner.listEnvironments()
        #expect(listed.map(\.name) == ["Staging"])
        #expect(listed[0].isActive)

        // The active environment now wins over the collection's own value.
        let detail = try await runner.detail(path: "Acme API/API/Users/List")
        #expect(detail.resolvedURL == "https://staging.test/users")
    }

    @Test func unsettingAVariableThatIsNotThereSaysSo() async throws {
        let temp = TempDirectory()
        let runner = try await makeRunner(at: temp.url)
        _ = try await runner.addEnvironment(named: "Staging")
        await #expect(throws: CommandRunner.CommandError.self) {
            try await runner.unsetVariable("nope", inEnvironmentNamed: "Staging")
        }
    }

    @Test func choosingNoEnvironmentIsAllowed() async throws {
        let temp = TempDirectory()
        let runner = try await makeRunner(at: temp.url)
        _ = try await runner.addEnvironment(named: "Staging")
        _ = try await runner.useEnvironment(named: "Staging")
        #expect(try await runner.useEnvironment(named: "none") == "none")
        #expect(try await runner.listEnvironments()[0].isActive == false)
    }

    // MARK: - Running

    @Test func aDryRunBuildsWithoutSendingOrRecording() async throws {
        let temp = TempDirectory()
        let runner = try await makeRunner(at: temp.url)

        let dry = try await runner.dryRun(requestAt: "Acme API/API/Users/List")
        #expect(dry.method == "GET")
        #expect(dry.url == "https://api.example.com/users")
        #expect(await runner.history.count() == 0, "a dry run writes no history")
    }

    @Test func aDryRunRedactsTheAuthorizationItWouldSend() async throws {
        let temp = TempDirectory()
        let runner = try await makeRunner(at: temp.url)

        var edit = RequestEdit()
        edit.auth = .bearer(token: "tok-123")
        _ = try await runner.update(requestAt: "Acme API/Health", with: edit)

        let dry = try await runner.dryRun(requestAt: "Acme API/Health")
        let authorization = dry.headers.first { $0.name.lowercased() == "authorization" }
        #expect(authorization?.value == HistoryRedactor.placeholder)
    }

    @Test func commandLineVariablesBeatEverythingElse() async throws {
        let temp = TempDirectory()
        let runner = try await makeRunner(at: temp.url)

        let dry = try await runner.dryRun(
            requestAt: "Acme API/API/Users/List", overrides: ["baseUrl": "https://override.test"])
        #expect(dry.url == "https://override.test/users")
    }

    @Test func runSendsAndRecordsWithAttribution() async throws {
        let temp = TempDirectory()
                CommandStubProtocol.stub(.init(body: Data(#"{"ok":true}"#.utf8)))
        let runner = try await makeRunner(at: temp.url, protocolClasses: [CommandStubProtocol.self])
        await runner.setSource(.agent(name: "claude"))

        let result = try await runner.run(requestAt: "Acme API/API/Users/List")
        #expect(result.status == 200)
        #expect(result.isSuccess)
        #expect(result.body == #"{"ok":true}"#)
        #expect(result.path == "Acme API/API/Users/List")

        let entry = try #require(await runner.history.load().first)
        #expect(entry.source == .agent(name: "claude"))
        #expect(entry.statusCode == 200)
    }

    @Test func aTransportFailureIsAResultNotAThrow() async throws {
        let temp = TempDirectory()
                CommandStubProtocol.stub(.init(error: URLError(.cannotConnectToHost)))
        let runner = try await makeRunner(at: temp.url, protocolClasses: [CommandStubProtocol.self])

        let result = try await runner.run(requestAt: "Acme API/API/Users/List")
        #expect(result.status == nil)
        #expect(!result.isSuccess)
        #expect(result.error?.isEmpty == false)
        #expect(await runner.history.count() == 1, "a failed send is still history")
    }

    @Test func runAllWalksAFolderInOrder() async throws {
        let temp = TempDirectory()
                CommandStubProtocol.stub(.init())
        let runner = try await makeRunner(at: temp.url, protocolClasses: [CommandStubProtocol.self])

        let results = try await runner.runAll(under: "Acme API/API/Users")
        #expect(results.map(\.name) == ["List", "Create"])
        #expect(results.allSatisfy { $0.isSuccess })
    }

    @Test func runAllCanStopAtTheFirstFailure() async throws {
        let temp = TempDirectory()
                CommandStubProtocol.stub(.init(statusCode: 500))
        let runner = try await makeRunner(at: temp.url, protocolClasses: [CommandStubProtocol.self])

        let stopping = try await runner.runAll(under: "Acme API/API/Users", stopOnError: true)
        #expect(stopping.count == 1)

        let carryingOn = try await runner.runAll(under: "Acme API/API/Users")
        #expect(carryingOn.count == 2, "by default you get to see everything that is broken")
    }

    @Test func captureStoresAValueInTheActiveEnvironment() async throws {
        let temp = TempDirectory()
                CommandStubProtocol.stub(.init(body: Data(#"{"data":{"token":"abc123","id":7}}"#.utf8)))
        let runner = try await makeRunner(at: temp.url, protocolClasses: [CommandStubProtocol.self])
        _ = try await runner.addEnvironment(named: "Staging")
        _ = try await runner.useEnvironment(named: "Staging")

        let result = try await runner.run(
            requestAt: "Acme API/Health",
            captures: ["token": "$.data.token", "userID": "$.data.id"])

        #expect(result.captured == ["token": "abc123", "userID": "7"])
        let environment = try await runner.environment(named: "Staging")
        #expect(environment.variables.first { $0.key == "token" }?.value == "abc123")
    }

    @Test func aCaptureThatMatchesNothingIsAnError() async throws {
        let temp = TempDirectory()
                CommandStubProtocol.stub(.init(body: Data(#"{"a":1}"#.utf8)))
        let runner = try await makeRunner(at: temp.url, protocolClasses: [CommandStubProtocol.self])

        await #expect(throws: CommandRunner.CommandError.self) {
            try await runner.run(requestAt: "Acme API/Health", captures: ["t": "$.nope"])
        }
    }

    @Test func recordingCanBeTurnedOffForOneRun() async throws {
        let temp = TempDirectory()
                CommandStubProtocol.stub(.init())
        let runner = try await makeRunner(at: temp.url, protocolClasses: [CommandStubProtocol.self])
        await runner.setRecordLevel(.off)

        _ = try await runner.run(requestAt: "Acme API/Health")
        #expect(await runner.history.count() == 0)
    }

    @Test func historyRecordsTheRedactedRequest() async throws {
        let temp = TempDirectory()
                CommandStubProtocol.stub(.init())
        let runner = try await makeRunner(at: temp.url, protocolClasses: [CommandStubProtocol.self])
        await runner.setRecordLevel(.full)

        var edit = RequestEdit()
        edit.auth = .bearer(token: "super-secret-token")
        _ = try await runner.update(requestAt: "Acme API/Health", with: edit)
        _ = try await runner.run(requestAt: "Acme API/Health")

        let entry = try #require(await runner.history.load().first)
        let encoded = String(
            decoding: try Postfrau.makeEncoder().encode(entry), as: UTF8.self)
        #expect(!encoded.contains("super-secret-token"))
        #expect(encoded.contains(HistoryRedactor.placeholder))
    }
}
