import Foundation
import Testing
@testable import PostfrauCore

/// Loads a file from `Tests/.../Fixtures`.
func fixture(_ name: String) throws -> Data {
    let url = try #require(
        Bundle.module.url(forResource: "Fixtures/\(name)", withExtension: nil),
        "missing fixture \(name)")
    return try Data(contentsOf: url)
}

@Suite("Postman import")
struct PostmanImportTests {
    private func imported() throws -> PostmanV21Importer.Result {
        try PostmanV21Importer().import(fixture("acme-api.postman_collection.json"))
    }

    @Test func readsTheCollectionItself() throws {
        let result = try imported()
        #expect(result.collection.name == "Acme API")
        #expect(result.collection.description?.hasPrefix("The example collection") == true)
        #expect(result.collection.auth == .bearer(token: "{{apiToken}}"))
        #expect(result.collection.variables.map(\.key) == ["baseUrl", "apiToken"])
        #expect(result.collection.variables[1].isSecret)
    }

    @Test func keepsTheNesting() throws {
        let collection = try imported().collection
        #expect(collection.items.count == 4)
        guard case .folder(let users) = collection.items[0] else {
            Issue.record("first item should be the Users folder"); return
        }
        #expect(users.name == "Users")
        #expect(users.description == "Everything about users.")
        #expect(users.items.count == 2)
        #expect(collection.requestCount == 6)
    }

    @Test func readsAUrlObjectIntoTheUrlAndTheParamsTable() throws {
        let collection = try imported().collection
        let request = try #require(collection.allRequests().map(\.request).first { $0.name == "List users" })
        #expect(request.url.hasPrefix("{{baseUrl}}/v1/users"))
        #expect(request.params.map(\.key) == ["page", "per_page", "include"])
        #expect(request.params[1].description == "Max 100.")
        #expect(request.params[2].enabled == false, "a disabled query param stays disabled")
        #expect(request.url.contains("page=2"))
        #expect(!request.url.contains("include=roles"), "a disabled param is not in the URL")
    }

    @Test func readsHeadersIncludingDisabledOnes() throws {
        let collection = try imported().collection
        let request = try #require(collection.allRequests().map(\.request).first { $0.name == "List users" })
        #expect(request.headers.map(\.key) == ["Accept", "X-Debug"])
        #expect(request.headers[1].enabled == false)
    }

    @Test func readsEveryBodyMode() throws {
        let collection = try imported().collection

        let create = try #require(collection.allRequests().map(\.request).first { $0.name == "Create user" })
        guard case .raw(let text, let language) = create.body else {
            Issue.record("expected a raw body"); return
        }
        #expect(language == .json)
        #expect(text.contains("\"name\": \"Ada\""))

        let upload = try #require(collection.allRequests().map(\.request).first { $0.name == "Upload avatar" })
        guard case .formData(let fields) = upload.body else {
            Issue.record("expected form data"); return
        }
        #expect(fields.map(\.key) == ["caption", "file", "skipped"])
        #expect(fields[2].enabled == false)
        if case .file(let reference) = fields[1].value {
            #expect(reference.displayName == "me.png", "only the name survives, never the path")
            #expect(reference.bookmark == nil)
        } else {
            Issue.record("the file field should be a file")
        }

        let legacy = try #require(collection.allRequests().map(\.request).first { $0.name == "Legacy form post" })
        guard case .urlEncoded(let pairs) = legacy.body else {
            Issue.record("expected url-encoded"); return
        }
        #expect(pairs.map(\.key) == ["grant_type", "scope"])

        let blob = try #require(collection.allRequests().map(\.request).first { $0.name == "Raw binary" })
        guard case .binary(let reference) = blob.body else {
            Issue.record("expected a binary body"); return
        }
        #expect(reference.displayName == "payload.bin")
    }

    @Test func readsEveryAuthSchemeItSupports() throws {
        let collection = try imported().collection
        #expect(try #require(collection.allRequests().map(\.request).first { $0.name == "Create user" }).auth
            == .basic(username: "ada", password: "lovelace"))
        #expect(try #require(collection.allRequests().map(\.request).first { $0.name == "Legacy form post" }).auth
            == Auth.none)
        #expect(try #require(collection.allRequests().map(\.request).first { $0.name == "List users" }).auth
            == .inherit, "no auth block means inherit")
    }

    @Test func warnsAboutWhatItCannotDo() throws {
        let result = try imported()
        let joined = result.warnings.joined(separator: "\n")
        #expect(joined.contains("oauth2"), "an unsupported scheme is called out by name")
        #expect(joined.contains("Health"), "and so is the request it belongs to")
        #expect(joined.contains("scripts"))
        #expect(joined.contains("me.png") || joined.contains("file"))
    }

    @Test func aBareUrlStringIsAValidRequest() throws {
        let collection = try imported().collection
        let health = try #require(collection.allRequests().map(\.request).first { $0.name == "Health" })
        #expect(health.url == "https://api.acme.dev/health")
        #expect(health.method == .get)
    }

    @Test func keepsFieldsItDoesNotUnderstand() throws {
        let result = try imported()
        #expect(result.collection.extras["protocolProfileBehavior"] != nil)
        #expect(result.collection.extras["event"] == nil, "event is read, so it is not an extra")
        let list = try #require(result.collection.allRequests().map(\.request).first { $0.name == "List users" })
        #expect(list.extras["response"] != nil, "saved examples survive for the round trip")
    }

    @Test func refusesWhatIsNotACollection() {
        #expect(throws: PostmanV21Importer.ImportError.notJSON) {
            try PostmanV21Importer().import(Data("nonsense".utf8))
        }
        #expect(throws: PostmanV21Importer.ImportError.notACollection) {
            try PostmanV21Importer().import(Data(#"{"values":[]}"#.utf8))
        }
    }
}

@Suite("Postman export")
struct PostmanExportTests {
    /// Compares two collections ignoring the identifiers and timestamps a round trip must change.
    private func normalized(_ collection: RequestCollection) -> String {
        var copy = collection
        copy.id = UUID(uuidString: "00000000-0000-0000-0000-000000000000")!
        copy.createdAt = fixedDate
        copy.updatedAt = fixedDate
        copy.revision = 1
        copy.variables = copy.variables.map { var v = $0; v.id = copy.id; return v }
        copy.items = Self.stripIDs(copy.items)
        return String(decoding: try! Postfrau.makeEncoder(pretty: true).encode(copy), as: UTF8.self)
    }

    private static func stripIDs(_ items: [CollectionItem]) -> [CollectionItem] {
        let zero = UUID(uuidString: "00000000-0000-0000-0000-000000000000")!
        return items.map { item in
            switch item {
            case .request(var request):
                request.id = zero
                request.params = request.params.map { var p = $0; p.id = zero; return p }
                request.headers = request.headers.map { var h = $0; h.id = zero; return h }
                request.body = stripIDs(request.body)
                return .request(request)
            case .folder(var folder):
                folder.id = zero
                folder.variables = folder.variables.map { var v = $0; v.id = zero; return v }
                folder.items = stripIDs(folder.items)
                return .folder(folder)
            }
        }
    }

    private static func stripIDs(_ body: RequestBody) -> RequestBody {
        let zero = UUID(uuidString: "00000000-0000-0000-0000-000000000000")!
        switch body {
        case .urlEncoded(let pairs):
            return .urlEncoded(pairs.map { var p = $0; p.id = zero; return p })
        case .formData(let fields):
            return .formData(fields.map { var f = $0; f.id = zero; return f })
        default:
            return body
        }
    }

    @Test func exportThenImportGivesBackTheSameModel() throws {
        // PLAN.md §6 Phase 10 acceptance: "export → re-import yields an identical model
        // (modulo ids/timestamps)".
        let original = try PostmanV21Importer().import(
            fixture("acme-api.postman_collection.json")).collection

        let exported = try PostmanV21Exporter().data(for: original)
        let reimported = try PostmanV21Importer().import(exported).collection

        #expect(normalized(reimported) == normalized(original))
    }

    @Test func theExportIsAValidPostmanFile() throws {
        let original = try PostmanV21Importer().import(
            fixture("acme-api.postman_collection.json")).collection
        let value = PostmanV21Exporter().export(original)

        #expect(value["info"]?["schema"]?.stringValue == PostmanV21.schemaURL)
        #expect(value["info"]?["name"]?.stringValue == "Acme API")
        #expect(value["item"]?.arrayValue?.count == 4)
        #expect(value["auth"]?["type"]?.stringValue == "bearer")
        #expect(value["protocolProfileBehavior"] != nil, "unknown fields are put back")
    }

    @Test func writesBothTheRawUrlAndItsParts() throws {
        var request = RequestItem(name: "R", url: "https://api.acme.dev:8443/v1/users")
        request.params = [KeyValue(key: "page", value: "2")]

        let url = PostmanV21Exporter().url(from: request)
        #expect(url["raw"]?.stringValue?.hasPrefix("https://api.acme.dev:8443/v1/users") == true)
        #expect(url["protocol"]?.stringValue == "https")
        #expect(url["host"]?.arrayValue?.compactMap(\.stringValue) == ["api", "acme", "dev"])
        #expect(url["port"]?.stringValue == "8443")
        #expect(url["path"]?.arrayValue?.compactMap(\.stringValue) == ["v1", "users"])
        #expect(url["query"]?.arrayValue?.count == 1)
    }

    @Test func neverWritesASecretsValue() throws {
        var collection = RequestCollection(name: "C")
        collection.variables = [Variable(key: "token", value: "hunter2", isSecret: true)]

        let text = String(decoding: try PostmanV21Exporter().data(for: collection), as: UTF8.self)
        #expect(!text.contains("hunter2"), "a shared export must not carry the secret")
        #expect(text.contains("\"secret\""), "but it stays marked as one")
    }

    @Test func inheritIsTheAbsenceOfAnAuthBlock() {
        let exporter = PostmanV21Exporter()
        #expect(exporter.auth(from: .inherit) == nil)
        #expect(exporter.auth(from: Auth.none)?["type"]?.stringValue == "noauth")
        #expect(exporter.auth(from: .apiKey(key: "K", value: "v", location: .query))?["type"]?
            .stringValue == "apikey")
    }
}

@Suite("Postman environments")
struct PostmanEnvironmentTests {
    @Test func importsValuesFlagsAndSecrets() throws {
        let environment = try PostmanEnvironment.import(
            fixture("acme.postman_environment.json"))
        #expect(environment.name == "Acme production")
        #expect(environment.variables.map(\.key) == ["baseUrl", "apiToken", "unused"])
        #expect(environment.variables[1].isSecret)
        #expect(environment.variables[1].value == "super-secret")
        #expect(environment.variables[2].enabled == false)
    }

    @Test func roundTripsThroughExport() throws {
        let original = try PostmanEnvironment.import(fixture("acme.postman_environment.json"))
        let again = try PostmanEnvironment.import(PostmanEnvironment.data(for: original))

        #expect(again.name == original.name)
        #expect(again.variables.map(\.key) == original.variables.map(\.key))
        #expect(again.variables.map(\.enabled) == original.variables.map(\.enabled))
        #expect(again.variables.map(\.isSecret) == original.variables.map(\.isSecret))
        #expect(again.variables[1].value.isEmpty, "the secret is not carried through a file")
    }

    @Test func tellsAnEnvironmentFromACollection() throws {
        let environment = try #require(
            try Postfrau.makeDecoder()
                .decode(JSONValue.self, from: fixture("acme.postman_environment.json"))
                .objectValue)
        let collection = try #require(
            try Postfrau.makeDecoder()
                .decode(JSONValue.self, from: fixture("acme-api.postman_collection.json"))
                .objectValue)

        #expect(PostmanEnvironment.looksLikeEnvironment(environment))
        #expect(!PostmanEnvironment.looksLikeEnvironment(collection))
    }

    @Test func refusesSomethingThatIsNotAnEnvironment() {
        #expect(throws: PostmanEnvironment.ImportError.notAnEnvironment) {
            try PostmanEnvironment.import(Data(#"{"name":"x"}"#.utf8))
        }
    }
}
