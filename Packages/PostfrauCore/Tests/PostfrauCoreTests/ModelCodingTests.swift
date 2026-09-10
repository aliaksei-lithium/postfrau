import Foundation
import Testing
@testable import PostfrauCore

@Suite("Model coding")
struct ModelCodingTests {
    @Test("A secret's value is blanked unless the encoder asks for it")
    func secretValuesAreOptOut() throws {
        let secret = Variable(key: "token", value: "abc", isSecret: true)
        let plain = Variable(key: "baseUrl", value: "https://example.com")

        // The default, which is what exports and every other encoding path get.
        let blanked = try JSONSerialization.jsonObject(
            with: Postfrau.makeEncoder().encode([secret, plain])) as! [[String: Any]]
        #expect(blanked[0]["value"] as? String == "")
        #expect(blanked[0]["isSecret"] as? Bool == true, "it is still marked secret")
        #expect(blanked[1]["value"] as? String == "https://example.com")

        // Asked for: only the workspace store does this, and only when secrets live in the folder.
        let encoder = Postfrau.makeEncoder()
        encoder.userInfo[.includeSecretValues] = true
        let kept = try JSONSerialization.jsonObject(
            with: encoder.encode([secret, plain])) as! [[String: Any]]
        #expect(kept[0]["value"] as? String == "abc")
    }

    @Test("Secrets go to the data folder by default")
    func defaultStorageIsTheDataFolder() throws {
        #expect(AppSettings().secretStorage == .dataFolder)
        // An older settings file has no such key and must not be read as something else.
        let older = Data(#"{"editorFontSize": 13}"#.utf8)
        let decoded = try Postfrau.makeDecoder().decode(AppSettings.self, from: older)
        #expect(decoded.secretStorage == .dataFolder)
        #expect(decoded.editorFontSize == 13)
    }

    @Test func httpMethodRoundTripsIncludingCustomVerbs() throws {
        for method in HTTPMethod.allCases {
            #expect(try roundTrip(method) == method)
        }
        let custom = HTTPMethod(rawValue: "purge")
        #expect(custom == .custom("PURGE"))
        #expect(try roundTrip(custom) == custom)
    }

    @Test func authRoundTripsEveryCase() throws {
        let cases: [Auth] = [
            .inherit, .none,
            .basic(username: "ada", password: "s3cret"),
            .bearer(token: "{{token}}"),
            .apiKey(key: "X-Key", value: "abc", location: .query),
        ]
        for auth in cases {
            #expect(try roundTrip(auth) == auth)
        }
    }

    @Test func authEncodesATypeDiscriminator() throws {
        let data = try Postfrau.makeEncoder().encode(Auth.bearer(token: "t"))
        let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(json["type"] as? String == "bearer")
        #expect(json["token"] as? String == "t")
    }

    @Test func bodyRoundTripsEveryMode() throws {
        let cases: [RequestBody] = [
            .none,
            .raw(text: "{\"a\":1}", language: .json),
            .formData([
                FormField(key: "file", value: .file(FileReference(bookmark: Data([1, 2]), displayName: "a.png"))),
                FormField(key: "note", value: .text("hi")),
            ]),
            .urlEncoded([KeyValue(key: "a", value: "1")]),
            .binary(FileReference(bookmark: Data([9]), displayName: "blob.bin")),
        ]
        for body in cases {
            #expect(try roundTrip(body) == body)
        }
    }

    @Test func collectionItemUsesATypeDiscriminator() throws {
        let item = CollectionItem.folder(Folder(name: "F"))
        let data = try Postfrau.makeEncoder().encode(item)
        let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(json["type"] as? String == "folder")
        #expect(json["folder"] != nil)
        #expect(try roundTrip(item) == item)
    }

    @Test func collectionItemRejectsAnUnknownType() throws {
        let data = Data(#"{"type":"widget"}"#.utf8)
        #expect(throws: (any Error).self) {
            try Postfrau.makeDecoder().decode(CollectionItem.self, from: data)
        }
    }

    @Test func nestedCollectionRoundTripsIdentically() throws {
        let collection = makeSampleCollection()
        let decoded = try roundTrip(collection)
        #expect(decoded == collection)
        #expect(decoded.requestCount == 3)
    }

    @Test func collectionWritesItsSchemaVersion() throws {
        let data = try Postfrau.makeEncoder().encode(RequestCollection(name: "X"))
        let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(json["schemaVersion"] as? Int == Postfrau.schemaVersion)
    }

    @Test func collectionRootNormalizesInheritToNone() throws {
        let data = Data(#"{"name":"C","auth":{"type":"inherit"}}"#.utf8)
        let decoded = try Postfrau.makeDecoder().decode(RequestCollection.self, from: data)
        #expect(decoded.auth == .none)
    }

    @Test func decodingToleratesUnknownKeysAndMissingFields() throws {
        let data = Data(#"{"name":"Sparse","somethingNew":{"a":1}}"#.utf8)
        let request = try Postfrau.makeDecoder().decode(RequestItem.self, from: data)
        #expect(request.name == "Sparse")
        #expect(request.method == .get)
        #expect(request.settings.timeoutSeconds == 30)
        #expect(request.auth == .inherit)
    }

    @Test func secretVariableValueIsNeverWrittenToDisk() throws {
        let secret = Variable(key: "token", value: "hunter2", isSecret: true)
        let data = try Postfrau.makeEncoder().encode(secret)
        let text = String(decoding: data, as: UTF8.self)
        #expect(!text.contains("hunter2"))
        let decoded = try Postfrau.makeDecoder().decode(Variable.self, from: data)
        #expect(decoded.value.isEmpty)
        #expect(decoded.isSecret)
        #expect(decoded.key == "token")
    }

    @Test func nonSecretVariableKeepsItsValue() throws {
        let plain = Variable(key: "baseUrl", value: "https://x.test")
        #expect(try roundTrip(plain) == plain)
    }

    @Test func extrasSurviveARoundTrip() throws {
        let extras: [String: JSONValue] = [
            "event": .array([.object(["listen": .string("test")])]),
            "protocolProfileBehavior": .object(["disableBodyPruning": .bool(true)]),
        ]
        let request = RequestItem(name: "R", extras: extras)
        #expect(try roundTrip(request).extras == extras)
    }

    @Test func jsonValuePreservesLargeIntegerPrecision() throws {
        let big = JSONValue.number("9007199254740993")
        let decoded = try roundTrip(big)
        #expect(decoded == big)
    }

    @Test func jsonValueRoundTripsEveryShape() throws {
        let value = JSONValue.object([
            "n": .null,
            "b": .bool(false),
            "i": .number("42"),
            "d": .number("1.5"),
            "s": .string("text"),
            "a": .array([.number("1"), .string("two")]),
        ])
        #expect(try roundTrip(value) == value)
    }

    @Test func requestSettingsFallBackToDefaultsForMissingKeys() throws {
        let data = Data(#"{"timeoutSeconds":5}"#.utf8)
        let settings = try Postfrau.makeDecoder().decode(RequestSettings.self, from: data)
        #expect(settings.timeoutSeconds == 5)
        #expect(settings.followRedirects)
        #expect(settings.maxRedirects == 10)
        #expect(settings.encodeURL)
    }

    @Test func historyEntryDerivesItsDisplayPath() {
        let entry = HistoryEntry(resolvedURL: "https://api.example.com/v1/users?limit=10")
        #expect(entry.displayPath == "/v1/users?limit=10")
        #expect(entry.host == "api.example.com")
        #expect(HistoryEntry(resolvedURL: "https://x.test").displayPath == "/")
    }

    @Test func activeRowsDropDisabledAndUnnamed() {
        let rows = [
            KeyValue(key: "a", value: "1"),
            KeyValue(key: "b", value: "2", enabled: false),
            KeyValue(key: "", value: "3"),
        ]
        #expect(rows.active.map(\.key) == ["a"])
    }

    @Test func appSettingsAndUIStateRoundTrip() throws {
        let settings = AppSettings(
            dataFolderPath: "/tmp/x", syncSecretsViaICloudKeychain: true, appearance: .dark,
            editorFontSize: 14, responseLayout: .horizontal, maxHistoryEntries: 250)
        #expect(try roundTrip(settings) == settings)

        let state = UIState(
            tabs: [TabState(draft: RequestItem(name: "T"), isDirty: true)],
            sidebarWidth: 300, requestPaneFraction: 0.6, windowFrame: "0 0 100 100")
        #expect(try roundTrip(state) == state)
    }

    /// A `settings.json` written before the theme setting existed must still open, following the
    /// system rather than forcing anyone into a theme they never chose.
    @Test func settingsWrittenBeforeTheThemeSettingStillOpen() throws {
        let json = Data(#"{"schemaVersion":1,"editorFontSize":14}"#.utf8)
        let settings = try JSONDecoder().decode(AppSettings.self, from: json)
        #expect(settings.appearance == .system)
        #expect(settings.editorFontSize == 14)
    }
}
