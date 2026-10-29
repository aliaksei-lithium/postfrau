import Foundation
import Testing
@testable import PostfrauCore

@Suite("OpenAPI update")
struct OpenAPISyncTests {
    // MARK: - Specs

    /// A small deposits API; each argument changes one thing about it.
    private func spec(
        server: String = "https://api.example.com",
        listSummary: String = "List deposits",
        listParams: String = #"[{"name":"customer_id","in":"query","required":true,"schema":{"type":"string"}}]"#,
        getPath: String = "/deposits/{depositId}",
        createExample: String = #"{"amount": 100}"#,
        extraPaths: String = "",
        includeDelete: Bool = true
    ) -> Data {
        let delete = includeDelete ? #""delete":{"tags":["Deposits"],"summary":"Close deposit","responses":{}},"# : ""
        return Data("""
        {
          "openapi": "3.0.3",
          "info": {"title": "Deposits API", "version": "1"},
          "servers": [{"url": "\(server)"}],
          "tags": [{"name": "Deposits"}, {"name": "Transactions"}],
          "paths": {
            "/deposits": {
              "get": {"tags": ["Deposits"], "summary": "\(listSummary)",
                      "parameters": \(listParams), "responses": {}},
              "post": {"tags": ["Deposits"], "summary": "Open deposit",
                       "requestBody": {"content": {"application/json": {"example": \(createExample)}}},
                       "responses": {}}
            },
            "\(getPath)": {
              "get": {"tags": ["Deposits"], "summary": "Get deposit", "responses": {}},
              \(delete)
              "parameters": []
            },
            "/transactions": {
              "get": {"tags": ["Transactions"], "summary": "List transactions", "responses": {}}
            }
            \(extraPaths)
          }
        }
        """.utf8)
    }

    private func imported(_ data: Data) throws -> RequestCollection {
        try OpenAPIImporter().import(data).collection
    }

    private func request(_ name: String, in collection: RequestCollection) throws -> RequestItem {
        try #require(collection.allRequests().map(\.request).first { $0.name == name },
                     "no request called \(name)")
    }

    private func folderName(of name: String, in collection: RequestCollection) throws -> String? {
        let id = try request(name, in: collection).id
        return collection.folderChain(to: id)?.last.flatMap { collection.folder(withID: $0)?.name }
    }

    // MARK: - Keys

    @Test func importStampsEachRequestWithItsOperation() throws {
        let collection = try imported(spec())
        let get = try request("Get deposit", in: collection)
        #expect(OpenAPISync.stampedKey(of: get) == "GET /deposits/{}")
        #expect(collection.extras[OpenAPISync.metadataKey] != nil)
    }

    @Test func keysIgnoreParameterNames() {
        #expect(OpenAPISync.operationKey(method: "get", path: "/a/{id}/b/{x}")
            == OpenAPISync.operationKey(method: "GET", path: "/a/{other}/b/{y}"))
        let legacy = RequestItem(method: .get, url: "{{baseUrl}}/a/{{id}}/b/{{x}}?q=1")
        #expect(OpenAPISync.derivedKey(of: legacy) == "GET /a/{}/b/{}")
    }

    // MARK: - Updating

    @Test func theSameSpecChangesNothing() throws {
        let existing = try imported(spec())
        let (updated, report) = OpenAPISync.update(existing, from: try imported(spec()))
        #expect(report.added.isEmpty && report.updated.isEmpty && report.flagged.isEmpty)
        #expect(report.unchanged == existing.requestCount)
        #expect(updated.allRequests().map(\.request.id) == existing.allRequests().map(\.request.id),
                "requests keep their ids, so open tabs and history still point at them")
    }

    @Test func untouchedFieldsTakeTheSpecsChanges() throws {
        let existing = try imported(spec())
        let (updated, report) = OpenAPISync.update(
            existing, from: try imported(spec(listSummary: "Find deposits", createExample: #"{"amount": 5, "currency": "EUR"}"#)))
        let list = try request("Find deposits", in: updated)
        #expect(list.id == (try request("List deposits", in: existing)).id)
        let create = try request("Open deposit", in: updated)
        #expect(create.body.rawText?.contains("currency") == true)
        #expect(Set(report.updated) == ["Find deposits", "Open deposit"])
        #expect(report.keptEdits.isEmpty)
    }

    @Test func theUsersEditsWinAndAreReportedWhenTheSpecChangedThemToo() throws {
        var existing = try imported(spec())
        var create = try request("Open deposit", in: existing)
        create.body = .raw(text: #"{"amount": 42}"#, language: .json)
        existing.replace(.request(create))

        // The spec leaves the body alone: the edit stays, silently.
        let (same, quiet) = OpenAPISync.update(existing, from: try imported(spec()))
        #expect(try request("Open deposit", in: same).body == create.body)
        #expect(quiet.keptEdits.isEmpty)

        // The spec changes it too: the edit still stays, and the report says so.
        let (changed, loud) = OpenAPISync.update(
            existing, from: try imported(spec(createExample: #"{"amount": 1, "term": 12}"#)))
        #expect(try request("Open deposit", in: changed).body == create.body)
        #expect(loud.keptEdits.count == 1)
        #expect(loud.keptEdits.first?.contains("body") == true)
    }

    @Test func aNewParamArrivesBesideOnesTheUserFilledIn() throws {
        var existing = try imported(spec())
        var list = try request("List deposits", in: existing)
        list.params[0].value = "BAC_111"
        list.url = URLQuery.compose(base: URLQuery.stripQuery(from: list.url), params: list.params, encode: false)
        existing.replace(.request(list))

        let params = #"[{"name":"customer_id","in":"query","required":true,"schema":{"type":"string"}},{"name":"status","in":"query","required":true,"schema":{"type":"string","example":"open"}}]"#
        let (updated, _) = OpenAPISync.update(existing, from: try imported(spec(listParams: params)))
        let merged = try request("List deposits", in: updated)
        #expect(merged.params.map(\.key) == ["customer_id", "status"])
        #expect(merged.params[0].value == "BAC_111")
        #expect(merged.url == "{{baseUrl}}/deposits?customer_id=BAC_111&status=open")
    }

    @Test func aRowTheUserDeletedStaysDeleted() throws {
        var existing = try imported(spec())
        var list = try request("List deposits", in: existing)
        list.params = []
        list.url = URLQuery.stripQuery(from: list.url)
        existing.replace(.request(list))

        let (updated, _) = OpenAPISync.update(existing, from: try imported(spec()))
        #expect(try request("List deposits", in: updated).params.isEmpty)
    }

    @Test func aRenamedPathParameterStillMatches() throws {
        let existing = try imported(spec())
        let (updated, report) = OpenAPISync.update(
            existing, from: try imported(spec(getPath: "/deposits/{id}")))
        #expect(report.added.isEmpty && report.flagged.isEmpty)
        #expect(try request("Get deposit", in: updated).url == "{{baseUrl}}/deposits/{{id}}")
    }

    @Test func newOperationsGoBesideTheirSiblingsWhereverTheUserPutThem() throws {
        var existing = try imported(spec())
        // The user renamed the Deposits folder.
        let index = try #require(existing.items.firstIndex { $0.asFolder?.name == "Deposits" })
        var folder = try #require(existing.items[index].asFolder)
        folder.name = "Savings"
        existing.items[index] = .folder(folder)

        let extra = #", "/deposits/{id}/statement": {"get": {"tags": ["Deposits"], "summary": "Statement", "responses": {}}}, "/fx": {"get": {"tags": ["FX"], "summary": "Rates", "responses": {}}}"#
        let (updated, report) = OpenAPISync.update(existing, from: try imported(spec(extraPaths: extra)))
        #expect(Set(report.added) == ["Statement", "Rates"])
        #expect(try folderName(of: "Statement", in: updated) == "Savings")
        #expect(try folderName(of: "Rates", in: updated) == "FX")
    }

    @Test func droppedOperationsAreFlaggedOrRemoved() throws {
        let existing = try imported(spec())
        let newer = try imported(spec(includeDelete: false))

        let (flagged, flagReport) = OpenAPISync.update(existing, from: newer)
        #expect(flagReport.flagged == ["Close deposit"])
        #expect(try folderName(of: "Close deposit", in: flagged) == OpenAPISync.removedFolderName)

        let (removed, removeReport) = OpenAPISync.update(existing, from: newer, dropped: .remove)
        #expect(removeReport.removed == ["Close deposit"])
        #expect(!removed.allRequests().contains { $0.request.name == "Close deposit" })

        // Back in a later version: out of the removed folder, beside its siblings.
        let (back, _) = OpenAPISync.update(flagged, from: try imported(spec()))
        #expect(try folderName(of: "Close deposit", in: back) == "Deposits")
        #expect(!back.items.contains { $0.asFolder?.name == OpenAPISync.removedFolderName },
                "the folder the update emptied goes")
    }

    @Test func aFolderTheUpdateEmptiesGoesButOneTheUserMadeEmptyStays() throws {
        var existing = try imported(spec())
        existing.items.append(.folder(Folder(name: "Scratch")))
        let newer = try imported(spec()).replacingTransactions()

        let (updated, _) = OpenAPISync.update(existing, from: newer, dropped: .remove)
        #expect(!updated.items.contains { $0.asFolder?.name == "Transactions" })
        #expect(updated.items.contains { $0.asFolder?.name == "Scratch" })
    }

    @Test func requestsTheUserAddedAreLeftAlone() throws {
        var existing = try imported(spec())
        let mine = RequestItem(name: "My probe", method: .get, url: "{{baseUrl}}/internal/ping")
        _ = existing.insert(.request(mine), into: nil)

        let (updated, report) = OpenAPISync.update(existing, from: try imported(spec()), dropped: .remove)
        #expect(updated.request(withID: mine.id) == mine)
        #expect(report.flagged.isEmpty && report.removed.isEmpty)
    }

    @Test func theBaseURLFollowsTheSpecUnlessTheUserChangedIt() throws {
        let existing = try imported(spec())
        let (followed, _) = OpenAPISync.update(
            existing, from: try imported(spec(server: "https://v2.example.com")))
        #expect(OpenAPISync.baseURL(of: followed) == "https://v2.example.com")

        var edited = existing
        edited.variables[0].value = "http://localhost:8080"
        let (kept, _) = OpenAPISync.update(
            edited, from: try imported(spec(server: "https://v2.example.com")))
        #expect(OpenAPISync.baseURL(of: kept) == "http://localhost:8080")
    }

    @Test func aCollectionImportedBeforeStampingMatchesByURL() throws {
        // What an older Postfrau wrote: no stamps anywhere.
        var existing = try imported(spec())
        existing.extras[OpenAPISync.metadataKey] = nil
        for (request, _) in existing.allRequests() {
            var bare = request
            bare.extras[OpenAPISync.metadataKey] = nil
            if bare.name == "Open deposit" { bare.body = .raw(text: "{}", language: .json) }
            existing.replace(.request(bare))
        }

        let params = #"[{"name":"customer_id","in":"query","required":true,"schema":{"type":"string"}},{"name":"page","in":"query","required":false,"schema":{"type":"integer"}}]"#
        let (updated, report) = OpenAPISync.update(
            existing, from: try imported(spec(listParams: params, createExample: #"{"amount": 7}"#)))
        #expect(report.added.isEmpty && report.flagged.isEmpty)
        #expect(!report.warnings.isEmpty, "the user is told what a first update could not know")
        #expect(try request("Open deposit", in: updated).body == .raw(text: "{}", language: .json),
                "with no record of the import, the user's body is kept")
        #expect(try request("List deposits", in: updated).params.map(\.key) == ["customer_id", "page"])
        // And from now on the collection is stamped.
        #expect(updated.allRequests().allSatisfy { OpenAPISync.stampedKey(of: $0.request) != nil })
    }

    @Test func theYamlFormUpdatesTheJSONImport() throws {
        let existing = try OpenAPIImporter().import(fixture("petstore.openapi.json")).collection
        let yaml = try OpenAPIImporter().import(fixture("petstore.openapi.yaml")).collection
        let (_, report) = OpenAPISync.update(existing, from: yaml)
        #expect(report.added.isEmpty && report.updated.isEmpty && report.flagged.isEmpty)
        #expect(report.unchanged == existing.requestCount)
    }
}

private extension RequestCollection {
    /// The same collection without its Transactions operations, as if the spec dropped them.
    func replacingTransactions() -> RequestCollection {
        var copy = self
        copy.items.removeAll { $0.asFolder?.name == "Transactions" }
        return copy
    }
}

private extension RequestBody {
    var rawText: String? {
        if case .raw(let text, _) = self { return text }
        return nil
    }
}
