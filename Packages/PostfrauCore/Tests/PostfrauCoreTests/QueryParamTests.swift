import Foundation
import Testing
@testable import PostfrauCore

/// The v3.6.2 report: `run --param` parsed and was dropped, array query params imported as one
/// JSON string, a dry run said nothing about three skipped params, `send --auth bearer` sent no
/// token, and history showed a `#fragment` the server never saw.
@Suite("Query params and one-off auth", .serialized)
struct QueryParamTests {
    private func resolver(_ variables: [String: String] = [:]) -> VariableResolver {
        VariableResolver(scope: VariableScope(layers: [
            VariableLayer(
                source: .environment(name: "test"),
                variables: variables.map { Variable(key: $0.key, value: $0.value) }),
        ]))
    }

    private func makeRunner(at root: URL) async throws -> CommandRunner {
        let folder = DataFolder(root: root.appending(path: "Data"), needsCoordination: false)
        try folder.prepare()
        let store = WorkspaceStore(dataFolder: folder, localRoot: root)
        try await store.save(collection: makeSampleCollection())
        return CommandRunner(
            store: store,
            history: HistoryStore(root: root.appending(path: "history")),
            executor: HTTPExecutor(protocolClasses: nil),
            secrets: SecretsStore(service: "com.postfrau.tests.\(UUID())"))
    }

    /// A request shaped like an imported one: a required param on, two optional ones off.
    private let interest = RequestItem(
        name: "Rollback", method: .post,
        url: "{{baseUrl}}/v2/materialization/rollback-daily-interest?date=2026-11-01",
        params: [
            KeyValue(key: "date", value: "2026-11-01"),
            KeyValue(key: "deposit_id", value: "OMA_example", enabled: false),
            KeyValue(key: "dry", value: "true", enabled: false),
        ])

    // MARK: - The patch

    @Test func aRepeatedParamIsSentOncePerValue() throws {
        let patch = RequestPatch(params: [
            .init(name: "deposit_id", value: "OMA_1"), .init(name: "deposit_id", value: "OMA_2"),
        ])
        let patched = try patch.applied(to: interest, resolver: resolver())
        #expect(patched.params.active.map(\.key) == ["date", "deposit_id", "deposit_id"])
        #expect(patched.params.active.map(\.value) == ["2026-11-01", "OMA_1", "OMA_2"])
        #expect(!patched.params.contains { $0.value == "OMA_example" }, "the disabled example goes")
        #expect(patch.paramsOrigin == "--param deposit_id ×2")
        #expect(interest.params.count == 3, "and nothing saved changes")
    }

    @Test func anEmptyValueRemovesTheParam() throws {
        let patched = try RequestPatch(params: [.init(name: "date", value: "")])
            .applied(to: interest, resolver: resolver())
        #expect(!patched.params.active.contains { $0.key == "date" })
        let built = try RequestBuilder().build(
            patched, resolver: resolver(["baseUrl": "https://bips.test"]), effectiveAuth: .none)
        #expect(!built.resolvedURL.contains("date="), "not even from the URL text")
    }

    /// The builder sends the URL text's own query when the table is empty; a `--param` must
    /// join that query, not replace it.
    @Test func aParamJoinsAQueryThatLivesOnlyInTheURL() throws {
        let bare = RequestItem(name: "x", url: "https://api.test/x?a=1&b=2")
        let patched = try RequestPatch(params: [.init(name: "b", value: "3")])
            .applied(to: bare, resolver: resolver())
        let built = try RequestBuilder().build(patched, resolver: resolver(), effectiveAuth: .none)
        #expect(built.resolvedURL == "https://api.test/x?a=1&b=3")
    }

    // MARK: - Dry run

    @Test func aDryRunListsTheParamsSentAndWarnsAboutTheOnesThatAreNot() async throws {
        let temp = TempDirectory()
        let runner = try await makeRunner(at: temp.url)
        try await runner.addRequest(interest, toFolderAt: "Acme API")

        let saved = try await runner.dryRun(requestAt: "Acme API/Rollback")
        #expect(saved.params.map(\.name) == ["date"])
        #expect(saved.paramsOrigin == nil)
        let warning = try #require(saved.warnings.first { $0.contains("disabled") })
        #expect(warning.contains("2 saved query params"))
        #expect(warning.contains("deposit_id, dry"))

        let patched = try await runner.dryRun(
            requestAt: "Acme API/Rollback",
            patch: RequestPatch(params: [
                .init(name: "deposit_id", value: "OMA_1"), .init(name: "deposit_id", value: "OMA_2"),
            ]))
        #expect(patched.params.map(\.value) == ["2026-11-01", "OMA_1", "OMA_2"])
        #expect(patched.paramsOrigin == "--param deposit_id ×2")
        #expect(patched.warnings.contains { $0.contains("1 saved query param is disabled") && $0.contains("dry") })
    }

    @Test func aQueryInTheURLThatTheTableDropsIsCalledOut() async throws {
        let temp = TempDirectory()
        let runner = try await makeRunner(at: temp.url)
        var drifted = interest
        drifted.name = "Drifted"
        drifted.url += "&page=2"
        try await runner.addRequest(drifted, toFolderAt: "Acme API")

        let dry = try await runner.dryRun(requestAt: "Acme API/Drifted")
        #expect(!dry.url.contains("page="))
        #expect(dry.warnings.contains { $0.contains("page") && $0.contains("omitted") })
    }

    // MARK: - Auth

    @Test func bearerFromTheEnvironmentReachesAnAdHocSend() async throws {
        let temp = TempDirectory()
        let runner = try await makeRunner(at: temp.url)
        _ = try await runner.addEnvironment(named: "BIPS Production DEU")
        _ = try await runner.setVariable(
            "token", to: "abc", inEnvironmentNamed: "BIPS Production DEU", isSecret: false)
        try await runner.selectEnvironment(named: "BIPS Production DEU")

        let request = RequestItem(name: "", method: .get, url: "https://bips.test/v2/x")
        let dry = try await runner.dryRun(
            request, patch: RequestPatch(auth: .bearer(token: "{{token}}")))
        #expect(dry.headers.contains { $0.name.lowercased() == "authorization" })
    }

    @Test func anAuthThatDoesNotResolveIsRefusedRatherThanDropped() async throws {
        let temp = TempDirectory()
        let runner = try await makeRunner(at: temp.url)
        let request = RequestItem(name: "", method: .get, url: "https://bips.test/v2/x")
        let error = await #expect(throws: CommandRunner.CommandError.self) {
            _ = try await runner.dryRun(
                request, patch: RequestPatch(auth: .bearer(token: "{{token}}")))
        }
        #expect(error.map { CommandRunner.message(for: $0) }?.contains("{{token}}") == true)
        await #expect(throws: CommandRunner.CommandError.self) {
            _ = try await runner.dryRun(request, patch: RequestPatch(auth: .inherit))
        }
    }

    @Test func runAuthOverridesTheInheritedChain() async throws {
        let temp = TempDirectory()
        let runner = try await makeRunner(at: temp.url)
        // `Users/List` inherits the folder's bearer; `--auth none` takes it off for one send.
        let none = try await runner.dryRun(
            requestAt: "Acme API/API/Users/List", overrides: ["folderToken": "f"],
            patch: RequestPatch(auth: Auth.none))
        #expect(!none.headers.contains { $0.name.lowercased() == "authorization" })

        let inherited = try await runner.dryRun(
            requestAt: "Acme API/API/Users/List", overrides: ["folderToken": "f"])
        #expect(inherited.headers.contains { $0.name.lowercased() == "authorization" })
    }

    // MARK: - The URL the server sees

    @Test func aFragmentIsNotPartOfTheRecordedURLAndIsCalledOut() throws {
        let request = RequestItem(
            name: "", url: "https://bips.test/swagger/index.html#/v2/materialization/rollback")
        let built = try RequestBuilder().build(request, resolver: resolver(), effectiveAuth: .none)
        #expect(built.resolvedURL == "https://bips.test/swagger/index.html")
        let warning = try #require(built.warnings.first { $0.contains("never sent") })
        #expect(warning.contains("/swagger/index.html"))
        #expect(warning.contains("#/v2/materialization/rollback"))
    }

    // MARK: - OpenAPI

    private func importing(_ parameter: String) throws -> RequestItem {
        let spec = """
        {"openapi":"3.0.3","info":{"title":"Deposits","version":"1"},
         "servers":[{"url":"https://bips.test"}],
         "paths":{"/v2/materialization/rollback-daily-interest":{"post":{
           "summary":"Rollback","parameters":[\(parameter)],"responses":{}}}}}
        """
        let collection = try OpenAPIImporter().import(Data(spec.utf8)).collection
        return try #require(collection.allRequests().first?.request)
    }

    @Test func aFormExplodedArrayBecomesRepeatedDisabledRows() throws {
        let request = try importing("""
        {"name":"deposit_id","in":"query","required":true,
         "schema":{"type":"array","items":{"type":"string"}},
         "example":["OMA_1","OMA_2"]}
        """)
        #expect(request.params.map(\.key) == ["deposit_id", "deposit_id"])
        #expect(request.params.map(\.value) == ["OMA_1", "OMA_2"])
        #expect(request.params.allSatisfy { !$0.enabled }, "the spec's ids are an example")
        #expect(!request.url.contains("?"), "and stay out of the URL")
        #expect(!request.params.contains { $0.value.contains("[") }, "never one JSON string")
        #expect(request.params[0].description?.contains("required") == true)
    }

    @Test func aNonExplodedArrayIsOneJoinedRow() throws {
        let request = try importing("""
        {"name":"ids","in":"query","explode":false,
         "schema":{"type":"array","items":{"type":"integer","example":7}}}
        """)
        #expect(request.params.count == 1)
        #expect(request.params[0].value == "7")

        let piped = try importing("""
        {"name":"ids","in":"query","style":"pipeDelimited","explode":false,
         "schema":{"type":"array"},"example":["a","b"]}
        """)
        #expect(piped.params[0].value == "a|b")
    }

    @Test func aScalarParamIsUnchanged() throws {
        let request = try importing("""
        {"name":"date","in":"query","required":true,"schema":{"type":"string"},"example":"2026-11-01"}
        """)
        #expect(request.params.map(\.value) == ["2026-11-01"])
        #expect(request.params[0].enabled)
        #expect(request.url.hasSuffix("?date=2026-11-01"))
    }

    @Test func anUpdateFromTheSpecKeepsRepeatedRowsTogether() throws {
        let parameter = """
        {"name":"deposit_id","in":"query","schema":{"type":"array","items":{"type":"string"}},
         "example":["OMA_1","OMA_2"]}
        """
        let spec = { (extra: String) in
            Data("""
            {"openapi":"3.0.3","info":{"title":"Deposits","version":"1"},
             "servers":[{"url":"https://bips.test"}],
             "paths":{"/v2/r":{"post":{"summary":"Rollback",
               "parameters":[\(parameter)\(extra)],"responses":{}}}}}
            """.utf8)
        }
        let existing = try OpenAPIImporter().import(spec("")).collection
        let newer = try OpenAPIImporter().import(
            spec(#",{"name":"page","in":"query","schema":{"type":"integer"}}"#)).collection
        let (updated, _) = OpenAPISync.update(existing, from: newer)
        let request = try #require(updated.allRequests().first?.request)
        #expect(request.params.map(\.key) == ["deposit_id", "deposit_id", "page"])
        #expect(request.params.map(\.value).prefix(2) == ["OMA_1", "OMA_2"])
    }

    // MARK: - Local API

    @Test func theAppRefusesAFieldItDoesNotKnow() throws {
        let body = Data(#"{"path":"A/B","params":[{"name":"x","value":"1"}]}"#.utf8)
        #expect(throws: LocalAPI.BodyError.self) {
            _ = try LocalAPI.decodeStrictly(LocalAPI.RunBody.self, from: body)
        }
        let nested = Data(#"{"path":"A/B","patch":{"body":"{}","colour":"red"}}"#.utf8)
        let error = #expect(throws: LocalAPI.BodyError.self) {
            _ = try LocalAPI.decodeStrictly(LocalAPI.RunBody.self, from: nested)
        }
        #expect(error.map { CommandRunner.message(for: $0) }?.contains("patch.colour") == true)
    }

    @Test func everyFieldTheToolSendsIsOneTheAppKnows() throws {
        let run = LocalAPI.RunBody(
            path: "A/B", environment: "E", variables: ["a": "1"], captures: ["t": "$.t"],
            bodyCap: 1, dryRun: true,
            patch: RequestPatch(
                body: "{}", fields: [.init(path: "a", value: "1")],
                headers: [HeaderField(name: "X", value: "1")],
                params: [.init(name: "id", value: "1")], auth: .bearer(token: "{{token}}")),
            captureAsSecret: true, agent: "claude", record: "full")
        let decoded = try LocalAPI.decodeStrictly(
            LocalAPI.RunBody.self, from: try JSONEncoder().encode(run))
        #expect(decoded.patch?.params == [.init(name: "id", value: "1")])
        #expect(decoded.patch?.auth == .bearer(token: "{{token}}"))
        #expect(decoded.agent == "claude")

        let send = LocalAPI.SendBody(
            method: "GET", url: "https://x.test", headers: [], body: "", environment: "E",
            variables: [:], captures: [:], bodyCap: 1, dryRun: false,
            params: [.init(name: "id", value: "1"), .init(name: "id", value: "2")],
            auth: .bearer(token: "{{token}}"), verifyTLS: false, followRedirects: false,
            captureAsSecret: true, agent: "claude", record: "off")
        let sent = try LocalAPI.decodeStrictly(
            LocalAPI.SendBody.self, from: try JSONEncoder().encode(send))
        #expect(sent.params?.count == 2)
        #expect(sent.verifyTLS == false)
    }

    @Test func pingAdvertisesTheNewCapabilities() {
        #expect(LocalAPI.capabilities.contains(LocalAPI.Capability.requestParams))
        #expect(LocalAPI.capabilities.contains(LocalAPI.Capability.strictFields))
    }
}
