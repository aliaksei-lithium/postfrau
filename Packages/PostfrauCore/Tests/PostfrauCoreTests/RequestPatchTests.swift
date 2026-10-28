import Foundation
import Testing

@testable import PostfrauCore

/// `run --body`, `--field` and `-H`: changing a saved request for one send.
@Suite("Request patch")
struct RequestPatchTests {
    private func resolver(_ variables: [String: String] = [:]) -> VariableResolver {
        VariableResolver(scope: VariableScope(layers: [
            VariableLayer(
                source: .environment(name: "test"),
                variables: variables.map { Variable(key: $0.key, value: $0.value) }),
        ]))
    }

    private let saved = RequestItem(
        name: "Create", method: .post, url: "https://api.test/payments",
        headers: [KeyValue(key: "X-Trace", value: "1")],
        body: .raw(text: #"{"items":[{"id":1}],"partner_bank_id":0}"#, language: .json))

    private func json(_ request: RequestItem) throws -> JSONValue {
        guard case .raw(let text, _) = request.body else {
            Issue.record("not a raw body")
            return .null
        }
        return try JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))
    }

    @Test func anEmptyPatchChangesNothing() throws {
        #expect(try RequestPatch().applied(to: saved, resolver: resolver()) == saved)
        #expect(RequestPatch().bodyOrigin == nil)
    }

    /// The v3.4 bug: the flag was accepted and the saved `items` body went out regardless.
    @Test func aBodyReplacesTheSavedOne() throws {
        let patch = RequestPatch(body: #"{"partner_bank_id":7}"#)
        let patched = try patch.applied(to: saved, resolver: resolver())
        #expect(patched.body == .raw(text: #"{"partner_bank_id":7}"#, language: .json))
        #expect(patch.bodyOrigin == "--body")
    }

    @Test func fieldsAreSetAsJSONLiteralsOrStrings() throws {
        let patch = RequestPatch(fields: [
            .init(path: "partner_bank_id", value: "42"),
            .init(path: "$.note", value: "hello"),
            .init(path: "quoted", value: #""42""#),
            .init(path: "items[0].id", value: "9"),
            .init(path: "meta.source", value: "cli"),
        ])
        let root = try json(try patch.applied(to: saved, resolver: resolver()))
        #expect(root.objectValue?["partner_bank_id"] == .number("42"))
        #expect(root.objectValue?["note"] == .string("hello"))
        #expect(root.objectValue?["quoted"] == .string("42"))
        #expect(JSONPath.value(at: "items[0].id", in: root) == .number("9"))
        #expect(JSONPath.value(at: "meta.source", in: root) == .string("cli"), "missing objects are made")
        #expect(patch.bodyOrigin == "--field partner_bank_id, --field $.note, --field quoted, "
            + "--field items[0].id, --field meta.source")
    }

    @Test func fieldValuesResolveVariablesBeforeBeingRead() throws {
        let patch = RequestPatch(fields: [.init(path: "partner_bank_id", value: "{{bank}}")])
        let root = try json(try patch.applied(to: saved, resolver: resolver(["bank": "123"])))
        #expect(root.objectValue?["partner_bank_id"] == .number("123"))
    }

    /// `{"id": {{id}}}` is not JSON until it is resolved, and it is a perfectly normal saved body.
    @Test func aTemplatedSavedBodyCanStillTakeFields() throws {
        var request = saved
        request.body = .raw(text: #"{"id": {{id}}}"#, language: .json)
        let patch = RequestPatch(fields: [.init(path: "extra", value: "true")])
        let root = try json(try patch.applied(to: request, resolver: resolver(["id": "5"])))
        #expect(root == .object(["id": .number("5"), "extra": .bool(true)]))
    }

    @Test func fieldsApplyToAReplacementBody() throws {
        let patch = RequestPatch(
            body: #"{"a":1}"#, fields: [.init(path: "b", value: "2")])
        let root = try json(try patch.applied(to: saved, resolver: resolver()))
        #expect(root == .object(["a": .number("1"), "b": .number("2")]))
        #expect(patch.bodyOrigin == "--body, --field b")
    }

    @Test func aFieldCannotGoWhereThereIsNoJSON() {
        var form = saved
        form.body = .urlEncoded([KeyValue(key: "a", value: "1")])
        let patch = RequestPatch(fields: [.init(path: "a", value: "2")])
        #expect(throws: CommandRunner.CommandError.self) {
            try patch.applied(to: form, resolver: resolver())
        }

        var text = saved
        text.body = .raw(text: "not json", language: .text)
        #expect(throws: CommandRunner.CommandError.self) {
            try patch.applied(to: text, resolver: resolver())
        }

        let pastTheEnd = RequestPatch(fields: [.init(path: "items[5].id", value: "1")])
        #expect(throws: CommandRunner.CommandError.self) {
            try pastTheEnd.applied(to: saved, resolver: resolver())
        }
    }

    @Test func aHeaderReplacesOneOfTheSameNameInAnyCase() throws {
        let patch = RequestPatch(headers: [
            HeaderField(name: "x-trace", value: "2"),
            HeaderField(name: "X-Correlation-ID", value: "abc"),
        ])
        let patched = try patch.applied(to: saved, resolver: resolver())
        #expect(patched.headers.map(\.key) == ["x-trace", "X-Correlation-ID"])
        #expect(patched.headers.map(\.value) == ["2", "abc"])
        #expect(patched.body == saved.body, "headers alone leave the body as saved")
        #expect(patch.bodyOrigin == nil)
    }

    @Test func theLanguageOfAReplacementBodyIsGuessed() {
        #expect(RequestBody.raw(guessingLanguageOf: " [1]") == .raw(text: " [1]", language: .json))
        #expect(RequestBody.raw(guessingLanguageOf: "<a/>") == .raw(text: "<a/>", language: .xml))
        #expect(RequestBody.raw(guessingLanguageOf: "x=1") == .raw(text: "x=1", language: .text))
    }

    @Test func settingThroughAScalarFails() {
        #expect(JSONPath.setting(.null, at: "a.b", in: .object(["a": .string("x")])) == nil)
        #expect(JSONPath.setting(.null, at: "[0]", in: .object([:])) == nil)
        #expect(JSONPath.setting(.bool(true), at: "$", in: .null) == .bool(true))
        #expect(JSONPath.setting(.number("1"), at: "a[-1]", in: .object(["a": .array([.null, .null])]))
            == .object(["a": .array([.null, .number("1")])]))
    }
}
