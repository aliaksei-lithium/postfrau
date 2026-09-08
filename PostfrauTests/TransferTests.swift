import Foundation
import Testing
@testable import Postfrau
import PostfrauCore

/// Import and export as the user reaches them: one entry point that works out what a file is.
@MainActor
@Suite("Import and export")
struct AppTransferTests {
    private func makeState() -> (AppState, URL) {
        let root = URL.temporaryDirectory.appending(path: "transfer-\(UUID().uuidString)")
        let folder = DataFolder(root: root.appending(path: "Data"), needsCoordination: false)
        let state = AppState(
            store: WorkspaceStore(dataFolder: folder, localRoot: root),
            history: HistoryStore(root: root.appending(path: "history")))
        return (state, root)
    }

    private var collectionJSON: Data {
        Data("""
        {
          "info": { "name": "Imported API",
                    "schema": "https://schema.getpostman.com/json/collection/v2.1.0/collection.json" },
          "item": [
            { "name": "Ping",
              "request": { "method": "GET", "url": "https://api.test/ping" } },
            { "name": "Odd auth",
              "request": { "method": "GET", "url": "https://api.test/x",
                           "auth": { "type": "hawk", "hawk": [] } } }
          ]
        }
        """.utf8)
    }

    private var environmentJSON: Data {
        Data("""
        {
          "name": "Staging",
          "values": [
            { "key": "baseUrl", "value": "https://staging.test", "enabled": true, "type": "default" },
            { "key": "token", "value": "s3cret", "enabled": true, "type": "secret" }
          ]
        }
        """.utf8)
    }

    @Test func importsACollectionAndReportsWhatItCouldNotDo() async {
        let (state, scratch) = makeState()
        defer { try? FileManager.default.removeItem(at: scratch) }

        await state.importData(collectionJSON, named: "api.postman_collection.json")

        #expect(state.workspace.collections.map(\.name) == ["Imported API"])
        #expect(state.sidebarSection == .collections, "the import is shown, not just performed")
        let report = try? #require(state.importReport)
        #expect(report?.title.contains("Imported API") == true)
        #expect(report?.warnings.contains { $0.contains("hawk") } == true)
    }

    @Test func importsAnEnvironmentWithoutMistakingItForACollection() async {
        let (state, scratch) = makeState()
        defer { try? FileManager.default.removeItem(at: scratch) }
        // Importing an environment stores its secrets, which needs a keychain that answers.
        guard AppKeychainProbe.isKeychainUsable else {
            return withKnownIssue("Keychain is unavailable in this environment.",
                                  isIntermittent: true) { Issue.record("skipped") }
        }

        await state.importData(environmentJSON, named: "staging.postman_environment.json")

        #expect(state.workspace.collections.isEmpty)
        #expect(state.workspace.environments.map(\.name) == ["Staging"])
        #expect(state.importReport?.warnings.first?.contains("keychain") == true)
    }

    @Test func importsACurlCommandAsANewTab() async {
        let (state, scratch) = makeState()
        defer { try? FileManager.default.removeItem(at: scratch) }

        await state.importData(
            Data("curl -X POST https://api.test/users -d 'name=ada'".utf8), named: "req.sh")

        let tab = try? #require(state.selectedTab)
        #expect(tab?.draft.method == .post)
        #expect(tab?.draft.url == "https://api.test/users")
        #expect(state.importReport == nil, "a clean import says nothing")
    }

    @Test func importsAnOpenAPIDocument() async throws {
        let (state, scratch) = makeState()
        defer { try? FileManager.default.removeItem(at: scratch) }

        await state.importData(Data("""
        {"openapi":"3.0.3","info":{"title":"Acme Pets","version":"1.0"},
         "servers":[{"url":"https://api.acme.dev"}],
         "security":[{"bearerAuth":[]}],
         "paths":{"/pets/{petId}":{"get":{"tags":["Pets"],"summary":"Get a pet",
           "parameters":[{"name":"petId","in":"path","required":true,
                          "schema":{"type":"string"}}],"responses":{}}}},
         "components":{"securitySchemes":{"bearerAuth":{"type":"http","scheme":"bearer"}}}}
        """.utf8), named: "petstore.json")

        let collection = try #require(state.workspace.collections.first)
        #expect(collection.name == "Acme Pets")
        #expect(collection.auth == .bearer(token: "{{token}}"))
        #expect(collection.variables.first?.value == "https://api.acme.dev")

        let request = try #require(collection.allRequests().first?.request)
        #expect(request.name == "Get a pet")
        #expect(request.url == "{{baseUrl}}/pets/{{petId}}")

        // The sheet tells the user the path variable still needs a value.
        #expect(state.importReport?.warnings.contains { $0.contains("path variables") } == true)
    }

    @Test func anOpenAPIDocumentIsNotMistakenForAPostmanCollection() async throws {
        // Both have an `info` block, and the Postman importer is lenient enough to accept one
        // and hand back a collection with nothing in it.
        let (state, scratch) = makeState()
        defer { try? FileManager.default.removeItem(at: scratch) }

        await state.importData(Data("""
        {"openapi":"3.0.0","info":{"title":"X","version":"1"},
         "paths":{"/a":{"get":{"summary":"A","responses":{}}}}}
        """.utf8), named: "spec.json")

        let collection = try #require(state.workspace.collections.first)
        #expect(collection.requestCount == 1, "the operation became a request")
    }

    @Test func aYamlSpecSaysHowToConvertIt() async {
        let (state, scratch) = makeState()
        defer { try? FileManager.default.removeItem(at: scratch) }

        await state.importData(Data("""
        openapi: 3.0.0
        info:
          title: Acme
        paths: {}
        """.utf8), named: "spec.yaml")

        #expect(state.workspace.collections.isEmpty)
        #expect(state.importReport?.detail.contains("yq") == true)
    }

    @Test func saysSoWhenAFileIsNeitherThing() async {
        let (state, scratch) = makeState()
        defer { try? FileManager.default.removeItem(at: scratch) }

        await state.importData(Data("just some prose".utf8), named: "notes.txt")

        #expect(state.workspace.collections.isEmpty)
        #expect(state.importReport?.title.contains("Could not import") == true)
    }

    @Test func pastingCurlIntoTheUrlBarFillsInTheWholeRequest() {
        let (state, scratch) = makeState()
        defer { try? FileManager.default.removeItem(at: scratch) }

        let tab = RequestTab(draft: RequestItem(name: "New Request"))
        state.tabs = [tab]
        let originalID = tab.draft.id

        let consumed = state.handlePastedCurl(
            "curl https://api.test/users -H 'Accept: application/json' -X PUT", into: tab)

        #expect(consumed)
        #expect(tab.draft.method == .put)
        #expect(tab.draft.url == "https://api.test/users")
        #expect(tab.draft.headers.map(\.key) == ["Accept"])
        #expect(tab.draft.id == originalID, "it is the same request, filled in")
    }

    @Test func pastingAPlainUrlIsNotTreatedAsCurl() {
        let (state, scratch) = makeState()
        defer { try? FileManager.default.removeItem(at: scratch) }

        let tab = RequestTab(draft: RequestItem())
        #expect(!state.handlePastedCurl("https://api.test/users", into: tab))
    }

    @Test func pastingCurlKeepsANameWorthKeeping() {
        let (state, scratch) = makeState()
        defer { try? FileManager.default.removeItem(at: scratch) }

        let tab = RequestTab(draft: RequestItem(name: "List users"))
        _ = state.handlePastedCurl("curl https://api.test/v2/people", into: tab)
        #expect(tab.draft.name == "List users")

        let scratchTab = RequestTab(draft: RequestItem(name: "New Request"))
        _ = state.handlePastedCurl("curl https://api.test/v2/people", into: scratchTab)
        #expect(scratchTab.draft.name == "people", "an unnamed tab takes the name from the URL")
    }

    @Test func copyAsCurlPutsAWorkingCommandOnTheClipboard() {
        let (state, scratch) = makeState()
        defer { try? FileManager.default.removeItem(at: scratch) }

        var request = RequestItem(name: "R", method: .post, url: "{{baseUrl}}/users")
        request.auth = .bearer(token: "tok")
        request.body = .raw(text: #"{"a":1}"#, language: .json)
        let tab = RequestTab(draft: request)
        state.tabs = [tab]
        state.selectedTabID = tab.id
        state.workspace.globals.variables = [Variable(key: "baseUrl", value: "https://api.test")]

        state.copyAsCurl(tab)
        let resolved = try? #require(Pasteboard.text)
        #expect(resolved?.contains("https://api.test/users") == true)
        #expect(resolved?.contains("Authorization: Bearer tok") == true)

        state.copyAsCurl(tab, handling: .raw)
        #expect(Pasteboard.text?.contains("{{baseUrl}}/users") == true)
    }

    @Test func exportPicksTheCollectionInFront() async {
        let (state, scratch) = makeState()
        defer { try? FileManager.default.removeItem(at: scratch) }

        await state.importData(collectionJSON, named: "api.json")
        let id = try? #require(state.workspace.collections.first?.id)

        // Nothing selected, one collection: that one.
        #expect(state.exportableCollectionID == id)

        // A tab on one of its requests names it too.
        let requestID = state.workspace.collections[0].allRequests().first?.request.id
        state.tabs = [RequestTab(requestID: requestID, collectionID: id, draft: RequestItem())]
        state.selectedTabID = state.tabs[0].id
        #expect(state.exportableCollectionID == id)
    }

    @Test func aFileNameSurvivesACollectionCalledAnything() {
        #expect(AppState.fileName(for: "GET /users") == "GET -users")
        #expect(AppState.fileName(for: "  ") == "Untitled")
        #expect(AppState.fileName(for: "Acme API") == "Acme API")
    }

    @Test func importThenExportThenImportKeepsTheSameRequests() async throws {
        let (state, scratch) = makeState()
        defer { try? FileManager.default.removeItem(at: scratch) }

        await state.importData(collectionJSON, named: "api.json")
        let original = try #require(state.workspace.collections.first)

        let exported = try PostmanV21Exporter().data(for: original)
        await state.importData(exported, named: "again.json")

        #expect(state.workspace.collections.count == 2)
        let again = try #require(state.workspace.collections.last)
        #expect(again.allRequests().map(\.request.url)
            == original.allRequests().map(\.request.url))
        #expect(again.allRequests().map(\.request.name)
            == original.allRequests().map(\.request.name))
    }
}

/// PLAN.md §6 Phase 10 acceptance: "import a real exported Postman collection, send a request
/// from it successfully".
///
/// Gated like the Core live tests, because it talks to httpbin.org:
///
///     POSTFRAU_LIVE_TESTS=1 make app-test
@MainActor
@Suite(
    "Imported collection over the wire",
    .serialized,
    .enabled(if: ProcessInfo.processInfo.environment["POSTFRAU_LIVE_TESTS"] == "1"))
struct ImportedCollectionLiveTests {
    private func makeState() -> (AppState, URL) {
        let root = URL.temporaryDirectory.appending(path: "live-\(UUID().uuidString)")
        let folder = DataFolder(root: root.appending(path: "Data"), needsCoordination: false)
        return (AppState(
            store: WorkspaceStore(dataFolder: folder, localRoot: root),
            history: HistoryStore(root: root.appending(path: "history"))), root)
    }

    /// The file a Postman export of two httpbin requests looks like.
    private var exportedCollection: Data {
        Data("""
        {
          "info": { "name": "httpbin (imported)",
                    "schema": "https://schema.getpostman.com/json/collection/v2.1.0/collection.json" },
          "variable": [{ "key": "baseUrl", "value": "https://httpbin.org", "type": "default" }],
          "item": [
            { "name": "Headers",
              "request": { "method": "GET",
                           "header": [{ "key": "X-Imported", "value": "yes" }],
                           "url": { "raw": "{{baseUrl}}/headers",
                                    "host": ["{{baseUrl}}"], "path": ["headers"] } } },
            { "name": "Post JSON",
              "request": { "method": "POST",
                           "header": [{ "key": "Content-Type", "value": "application/json" }],
                           "body": { "mode": "raw", "raw": "{\\"from\\": \\"Postfrau\\"}",
                                     "options": { "raw": { "language": "json" } } },
                           "url": { "raw": "{{baseUrl}}/post",
                                    "host": ["{{baseUrl}}"], "path": ["post"] } } }
          ]
        }
        """.utf8)
    }

    @Test(.timeLimit(.minutes(2)))
    func anImportedGetSendsAndComesBack() async throws {
        let (state, scratch) = makeState()
        defer { try? FileManager.default.removeItem(at: scratch) }

        await state.importData(exportedCollection, named: "httpbin.postman_collection.json")
        let collection = try #require(state.workspace.collections.first)
        let request = try #require(
            collection.allRequests().map(\.request).first { $0.name == "Headers" })

        let tab = state.openRequest(id: request.id)
        state.send(try #require(tab))
        await tab?.sendTask?.value

        let response = try #require(tab?.response)
        #expect(response.statusCode == 200)
        // httpbin echoes the headers it received, so this proves the imported header went out
        // and that `{{baseUrl}}` from the collection's own variables resolved.
        let body = String(decoding: try response.body.data(), as: UTF8.self)
        #expect(body.contains("X-Imported"))
        print("imported GET → \(response.statusLine), \(ByteCount.format(response.byteCount))")
    }

    @Test(.timeLimit(.minutes(2)))
    func anImportedPostSendsItsBody() async throws {
        let (state, scratch) = makeState()
        defer { try? FileManager.default.removeItem(at: scratch) }

        await state.importData(exportedCollection, named: "httpbin.postman_collection.json")
        let collection = try #require(state.workspace.collections.first)
        let request = try #require(
            collection.allRequests().map(\.request).first { $0.name == "Post JSON" })

        let tab = state.openRequest(id: request.id)
        state.send(try #require(tab))
        await tab?.sendTask?.value

        let response = try #require(tab?.response)
        #expect(response.statusCode == 200)
        let body = String(decoding: try response.body.data(), as: UTF8.self)
        #expect(body.contains("Postfrau"), "the imported JSON body reached the server")
        print("imported POST → \(response.statusLine)")
    }
}
