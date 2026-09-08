import Foundation
import Testing
@testable import PostfrauCore

@Suite("OpenAPI import")
struct OpenAPITests {
    private func imported() throws -> OpenAPIImporter.Result {
        try OpenAPIImporter().import(fixture("petstore.openapi.json"))
    }

    private func request(_ name: String) throws -> RequestItem {
        try #require(
            imported().collection.allRequests().map(\.request).first { $0.name == name },
            "no request called \(name)")
    }

    // MARK: - The document

    @Test func readsTheTitleAndDescription() throws {
        let collection = try imported().collection
        #expect(collection.name == "Acme Pets")
        #expect(collection.description?.contains("measure the importer against") == true)
        #expect(collection.description?.contains("API version 1.4.0") == true)
        #expect(collection.description?.contains("OpenAPI 3.0.3") == true)
    }

    @Test func fillsServerTemplatesFromTheirDefaults() throws {
        let result = try imported()
        // `https://{region}.api.acme.dev/{version}` with region=eu, version=v1.
        #expect(result.collection.variables.first?.key == "baseUrl")
        #expect(result.collection.variables.first?.value == "https://eu.api.acme.dev/v1")
        #expect(!result.warnings.contains { $0.contains("placeholders") })
    }

    @Test func aDocumentWithNoServerGetsAPlaceholderAndSaysSo() throws {
        let result = try OpenAPIImporter().import(Data("""
        {"openapi":"3.0.0","info":{"title":"X"},"paths":{}}
        """.utf8))
        #expect(result.collection.variables.first?.value == "https://example.com")
        #expect(result.warnings.contains { $0.contains("names no server") })
    }

    // MARK: - Structure

    @Test func tagsBecomeFoldersInTheOrderTheyAppear() throws {
        let collection = try imported().collection
        let folders = collection.items.compactMap { item -> Folder? in
            if case .folder(let folder) = item { return folder } else { return nil }
        }
        #expect(folders.map(\.name) == ["Pets", "Owners"])
        #expect(folders[0].items.count == 4, "four operations are tagged Pets")
    }

    @Test func anUntaggedOperationSitsAtTheRoot() throws {
        let collection = try imported().collection
        let loose = collection.items.compactMap { item -> RequestItem? in
            if case .request(let request) = item { return request } else { return nil }
        }
        #expect(loose.map(\.name) == ["Health"])
    }

    @Test func namesComeFromSummaryThenOperationIdThenTheRoute() throws {
        let names = try imported().collection.allRequests().map(\.request.name)
        #expect(names.contains("List pets"), "summary wins")
        #expect(names.contains("createPet"), "operationId when there is no summary")
    }

    @Test func everyOperationBecomesARequest() throws {
        // 4 under /pets and /pets/{petId}, 1 login, 1 health.
        #expect(try imported().collection.requestCount == 6)
    }

    // MARK: - URLs and parameters

    @Test func pathTemplatesBecomeVariablesYouCanFillIn() throws {
        let request = try request("Get a pet")
        #expect(request.url == "{{baseUrl}}/pets/{{petId}}")
        #expect(try imported().warnings.contains { $0.contains("path variables") })
    }

    @Test func queryParametersLandInTheParamsTable() throws {
        let request = try request("List pets")
        #expect(request.params.map(\.key) == ["limit", "status"])
        // A required parameter is on; an optional one is off, so the first send is the minimal one.
        #expect(request.params[0].enabled)
        #expect(!request.params[1].enabled)
        #expect(request.params[0].description == "How many to return.")
        // The URL carries only what is enabled.
        #expect(request.url.contains("limit="))
        #expect(!request.url.contains("status="))
    }

    @Test func schemaDefaultsAndEnumsSeedParameterValues() throws {
        let request = try request("List pets")
        #expect(request.params[0].value == "25", "the schema default")
        #expect(request.params[1].value == "available", "the first enum case")
    }

    @Test func parametersOnThePathItemApplyToEveryOperationUnderIt() throws {
        // `X-Request-Id` is declared once on /pets and belongs to both GET and POST.
        for name in ["List pets", "createPet"] {
            let request = try request(name)
            #expect(
                request.headers.contains { $0.key == "X-Request-Id" },
                "\(name) should inherit the path-level header")
        }
    }

    // MARK: - Bodies

    @Test func aJsonBodyIsBuiltFromItsSchema() throws {
        let request = try request("createPet")
        guard case .raw(let text, let language) = request.body else {
            Issue.record("expected a raw body, got \(request.body)"); return
        }
        #expect(language == .json)

        let decoded = try Postfrau.makeDecoder().decode(JSONValue.self, from: Data(text.utf8))
        let object = try #require(decoded.objectValue)
        #expect(object["name"]?.stringValue == "Rex", "the property's own example wins")
        #expect(object["age"] == .number("0"), "an integer with no example gets a usable zero")
        #expect(object["id"]?.stringValue == "00000000-0000-0000-0000-000000000000",
                "a uuid format gets a uuid-shaped placeholder")
        #expect(object["owner"]?["email"]?.stringValue == "name@example.com",
                "a $ref is followed")
        #expect(object["tags"]?.arrayValue?.count == 1, "an array gets one element")
    }

    @Test func aSelfReferentialSchemaStopsAtOneLevel() throws {
        // Pet.friend is a Pet. Unbounded this never ends; bounded only by depth it nests six
        // times and is useless to edit. One level is the readable answer.
        let request = try request("createPet")
        guard case .raw(let text, _) = request.body else {
            Issue.record("expected a raw body"); return
        }
        let decoded = try Postfrau.makeDecoder().decode(JSONValue.self, from: Data(text.utf8))
        let friend = try #require(decoded["friend"]?.objectValue)
        #expect(friend["name"]?.stringValue == "Rex", "the friend is expanded once")
        #expect(friend["friend"] == nil, "but its own friend is not")
    }

    @Test func onlyRealPathTemplatesAreCounted() throws {
        // Every URL contains {{baseUrl}}; only two carry an actual path variable.
        let warning = try #require(
            imported().warnings.first { $0.contains("path variables") })
        #expect(warning.hasPrefix("2 request(s)"), "got: \(warning)")
    }

    @Test func aFormBodyBecomesUrlEncodedFields() throws {
        let request = try request("Log in")
        guard case .urlEncoded(let fields) = request.body else {
            Issue.record("expected url-encoded, got \(request.body)"); return
        }
        #expect(fields.map(\.key) == ["password", "remember", "username"])
        // Required fields are on, the optional one is off.
        #expect(fields.first { $0.key == "username" }?.enabled == true)
        #expect(fields.first { $0.key == "remember" }?.enabled == false)
        #expect(request.headers.contains {
            $0.key == "Content-Type" && $0.value == "application/x-www-form-urlencoded"
        })
    }

    @Test func anExplicitExampleBeatsTheSchema() throws {
        let result = try OpenAPIImporter().import(Data("""
        {"openapi":"3.0.0","info":{"title":"X"},"paths":{"/a":{"post":{
          "summary":"A","requestBody":{"content":{"application/json":{
            "schema":{"type":"object","properties":{"n":{"type":"integer"}}},
            "example":{"n":42,"hand":"written"}}}},"responses":{}}}}}
        """.utf8))
        let request = try #require(result.collection.allRequests().first?.request)
        guard case .raw(let text, _) = request.body else {
            Issue.record("expected raw"); return
        }
        #expect(text.contains("42"))
        #expect(text.contains("hand"))
    }

    // MARK: - Security

    @Test func topLevelSecurityBecomesTheCollectionsAuth() throws {
        #expect(try imported().collection.auth == .bearer(token: "{{token}}"))
    }

    @Test func operationSecurityOverridesTheCollections() throws {
        #expect(try request("Delete a pet").auth
            == .apiKey(key: "X-Api-Key", value: "{{apiKey}}", location: .header))
        #expect(try request("Log in").auth == Auth.none, "`security: []` means none")
        #expect(try request("Get a pet").auth == .inherit, "no security means inherit")
    }

    @Test func anAuthSchemeItCannotModelIsReported() throws {
        let result = try OpenAPIImporter().import(Data("""
        {"openapi":"3.0.0","info":{"title":"X"},"paths":{},
         "security":[{"mtls":[]}],
         "components":{"securitySchemes":{"mtls":{"type":"mutualTLS"}}}}
        """.utf8))
        #expect(result.collection.auth == Auth.none)
        #expect(result.warnings.contains { $0.contains("mtls") })
    }

    // MARK: - Detection and refusal

    @Test func tellsAnOpenApiDocumentFromAPostmanOne() throws {
        let openAPI = try #require(
            try Postfrau.makeDecoder()
                .decode(JSONValue.self, from: fixture("petstore.openapi.json")).objectValue)
        let postman = try #require(
            try Postfrau.makeDecoder()
                .decode(JSONValue.self, from: fixture("acme-api.postman_collection.json")).objectValue)

        #expect(OpenAPIImporter.looksLikeOpenAPI(openAPI))
        #expect(!OpenAPIImporter.looksLikeOpenAPI(postman))
    }

    @Test func aYamlDocumentSaysWhatToDoAboutIt() {
        let yaml = Data("""
        openapi: 3.0.0
        info:
          title: Acme
        paths: {}
        """.utf8)
        #expect(OpenAPIImporter.looksLikeYAML(yaml))
        #expect(throws: OpenAPIImporter.ImportError.looksLikeYAML) {
            try OpenAPIImporter().import(yaml)
        }
    }

    @Test func swagger2IsRefusedByName() {
        #expect(throws: OpenAPIImporter.ImportError.swagger2) {
            try OpenAPIImporter().import(Data(#"{"swagger":"2.0","info":{"title":"X"}}"#.utf8))
        }
    }

    @Test func somethingElseEntirelyIsRefused() {
        #expect(throws: OpenAPIImporter.ImportError.notOpenAPI) {
            try OpenAPIImporter().import(Data(#"{"hello":"world"}"#.utf8))
        }
    }

    @Test func aDocumentWithNoOperationsStillImports() throws {
        let result = try OpenAPIImporter().import(Data("""
        {"openapi":"3.1.0","info":{"title":"Empty"},"paths":{}}
        """.utf8))
        #expect(result.collection.name == "Empty")
        #expect(result.warnings.contains { $0.contains("no operations") })
    }

    // MARK: - 3.1

    @Test func handlesTheThreeOneTypeArrayForm() throws {
        // 3.1 allows `"type": ["string", "null"]`, which 3.0 does not.
        let result = try OpenAPIImporter().import(Data("""
        {"openapi":"3.1.0","info":{"title":"X"},"paths":{"/a":{"post":{"summary":"A",
          "requestBody":{"content":{"application/json":{"schema":{"type":"object",
            "properties":{"note":{"type":["string","null"]}}}}}},"responses":{}}}}}
        """.utf8))
        let request = try #require(result.collection.allRequests().first?.request)
        guard case .raw(let text, _) = request.body else {
            Issue.record("expected raw"); return
        }
        #expect(text.contains("note"))
    }

    @Test func unmodelledFieldsAreKeptForTheRoundTrip() throws {
        let collection = try imported().collection
        #expect(collection.extras["tags"] != nil)
        let listPets = try request("List pets")
        #expect(listPets.extras["responses"] != nil, "responses survive as an extra")
    }
}
