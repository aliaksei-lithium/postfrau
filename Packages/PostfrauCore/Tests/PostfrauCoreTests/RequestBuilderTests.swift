import Foundation
import Testing
@testable import PostfrauCore

@Suite("Request builder")
struct RequestBuilderTests {
    private let builder = RequestBuilder()

    private func build(
        _ request: RequestItem,
        values: [String: String] = [:],
        auth: Auth = .none
    ) throws -> BuiltRequest {
        try builder.build(
            request,
            resolver: VariableResolver(
                values: values, dynamics: FixedDynamicVariables(values: [:])),
            effectiveAuth: auth)
    }

    // MARK: - URL

    @Test func resolvesVariablesInTheURL() throws {
        let built = try build(
            RequestItem(url: "{{baseUrl}}/users/{{id}}"),
            values: ["baseUrl": "https://api.test", "id": "42"])
        #expect(built.resolvedURL == "https://api.test/users/42")
    }

    @Test func rejectsAnEmptyURL() {
        #expect(throws: RequestBuilder.BuildError.emptyURL) {
            try build(RequestItem(url: "   "))
        }
    }

    @Test func assumesHTTPSWhenNoSchemeIsGiven() throws {
        #expect(try build(RequestItem(url: "example.com/x")).resolvedURL
            == "https://example.com/x")
        #expect(try build(RequestItem(url: "http://example.com/x")).resolvedURL
            == "http://example.com/x")
    }

    @Test func percentEncodesAURLThatIsNotStrictlyValid() throws {
        let built = try build(RequestItem(url: "https://example.com/a b/ç"))
        #expect(built.resolvedURL.contains("%20"))
        #expect(!built.resolvedURL.contains(" "))
    }

    @Test func theParamsTableOwnsTheQuery() throws {
        let built = try build(RequestItem(
            url: "https://api.test/users?stale=yes",
            params: [KeyValue(key: "limit", value: "10"), KeyValue(key: "q", value: "a b")]))
        #expect(built.resolvedURL == "https://api.test/users?limit=10&q=a%20b")
        #expect(!built.resolvedURL.contains("stale"))
    }

    @Test func anEmptyParamsTableLeavesTheURLsOwnQueryAlone() throws {
        let built = try build(RequestItem(url: "https://api.test/users?a=1&b=2"))
        #expect(built.resolvedURL == "https://api.test/users?a=1&b=2")
    }

    @Test func disabledParamsAreDropped() throws {
        let built = try build(RequestItem(
            url: "https://api.test/u",
            params: [
                KeyValue(key: "a", value: "1"),
                KeyValue(key: "b", value: "2", enabled: false),
            ]))
        #expect(built.resolvedURL == "https://api.test/u?a=1")
    }

    @Test func encodeURLOffSendsTheQueryVerbatim() throws {
        var request = RequestItem(
            url: "https://api.test/u", params: [KeyValue(key: "filter", value: "a=b,c")])
        request.settings.encodeURL = false
        #expect(try build(request).resolvedURL == "https://api.test/u?filter=a=b,c")
    }

    // MARK: - Headers

    @Test func addsTheDefaultHeaders() throws {
        let built = try build(RequestItem(url: "https://api.test"))
        let headers = built.urlRequest.allHTTPHeaderFields ?? [:]
        #expect(headers["User-Agent"] == Postfrau.userAgent)
        #expect(headers["Accept"] == "*/*")
        #expect(built.automaticHeaders.contains { $0.name == "User-Agent" })
    }

    @Test func theUsersHeadersWinOverTheDefaults() throws {
        let built = try build(RequestItem(
            url: "https://api.test",
            headers: [
                KeyValue(key: "User-Agent", value: "MyClient/9"),
                KeyValue(key: "Accept", value: "application/json"),
            ]))
        let headers = built.urlRequest.allHTTPHeaderFields ?? [:]
        #expect(headers["User-Agent"] == "MyClient/9")
        #expect(headers["Accept"] == "application/json")
        #expect(!built.automaticHeaders.contains { $0.name == "User-Agent" })
    }

    @Test func resolvesVariablesInHeaders() throws {
        let built = try build(
            RequestItem(url: "https://api.test", headers: [KeyValue(key: "X-Env", value: "{{env}}")]),
            values: ["env": "staging"])
        #expect(built.urlRequest.value(forHTTPHeaderField: "X-Env") == "staging")
    }

    @Test func disabledHeadersAreNotSent() throws {
        let built = try build(RequestItem(
            url: "https://api.test",
            headers: [KeyValue(key: "X-Off", value: "1", enabled: false)]))
        #expect(built.urlRequest.value(forHTTPHeaderField: "X-Off") == nil)
    }

    // MARK: - Auth

    @Test func appliesBearerAuthAsAnAutomaticHeader() throws {
        let built = try build(
            RequestItem(url: "https://api.test"),
            values: ["t": "abc"], auth: .bearer(token: "{{t}}"))
        #expect(built.urlRequest.value(forHTTPHeaderField: "Authorization") == "Bearer abc")
        #expect(built.automaticHeaders.contains { $0.name == "Authorization" })
    }

    @Test func aUserAuthorizationHeaderBeatsTheAuthHelperAndWarns() throws {
        let built = try build(
            RequestItem(
                url: "https://api.test",
                headers: [KeyValue(key: "Authorization", value: "Custom xyz")]),
            auth: .bearer(token: "abc"))
        #expect(built.urlRequest.value(forHTTPHeaderField: "Authorization") == "Custom xyz")
        #expect(built.warnings.contains { $0.contains("overrides") })
    }

    @Test func appliesAnAPIKeyInTheQuery() throws {
        let built = try build(
            RequestItem(url: "https://api.test/u", params: [KeyValue(key: "a", value: "1")]),
            auth: .apiKey(key: "api_key", value: "k", location: .query))
        #expect(built.resolvedURL == "https://api.test/u?a=1&api_key=k")
    }

    @Test func appliesBasicAuth() throws {
        let built = try build(
            RequestItem(url: "https://api.test"),
            auth: .basic(username: "ada", password: "s3cret"))
        #expect(built.urlRequest.value(forHTTPHeaderField: "Authorization")
            == "Basic YWRhOnMzY3JldA==")
    }

    // MARK: - Bodies

    @Test func rawJSONGetsTheRightContentTypeAndLength() throws {
        let json = #"{"name":"ada"}"#
        let built = try build(RequestItem(
            method: .post, url: "https://api.test",
            body: .raw(text: json, language: .json)))

        #expect(built.urlRequest.value(forHTTPHeaderField: "Content-Type") == "application/json")
        #expect(built.urlRequest.value(forHTTPHeaderField: "Content-Length") == String(json.utf8.count))
        #expect(built.urlRequest.httpBody == Data(json.utf8))
    }

    @Test func rawBodyResolvesVariables() throws {
        let built = try build(
            RequestItem(method: .post, url: "https://api.test",
                        body: .raw(text: #"{"id":"{{id}}"}"#, language: .json)),
            values: ["id": "42"])
        #expect(built.urlRequest.httpBody == Data(#"{"id":"42"}"#.utf8))
    }

    @Test func eachRawLanguageHasItsOwnContentType() throws {
        let expected: [RawLanguage: String] = [
            .json: "application/json", .text: "text/plain", .xml: "application/xml",
            .html: "text/html", .javascript: "application/javascript",
        ]
        for (language, contentType) in expected {
            let built = try build(RequestItem(
                method: .post, url: "https://api.test",
                body: .raw(text: "x", language: language)))
            #expect(built.urlRequest.value(forHTTPHeaderField: "Content-Type") == contentType)
        }
    }

    @Test func aUserContentTypeBeatsTheBodysDefault() throws {
        let built = try build(RequestItem(
            method: .post, url: "https://api.test",
            headers: [KeyValue(key: "Content-Type", value: "application/vnd.api+json")],
            body: .raw(text: "{}", language: .json)))
        #expect(built.urlRequest.value(forHTTPHeaderField: "Content-Type")
            == "application/vnd.api+json")
    }

    @Test func anEmptyRawBodySendsNothing() throws {
        let built = try build(RequestItem(
            method: .post, url: "https://api.test", body: .raw(text: "", language: .json)))
        #expect(built.urlRequest.httpBody == nil)
        #expect(built.urlRequest.value(forHTTPHeaderField: "Content-Type") == nil)
    }

    @Test func urlEncodedBodyUsesFormEscaping() throws {
        let built = try build(RequestItem(
            method: .post, url: "https://api.test",
            body: .urlEncoded([
                KeyValue(key: "name", value: "ada lovelace"),
                KeyValue(key: "note", value: "a&b=c"),
                KeyValue(key: "skip", value: "x", enabled: false),
            ])))

        #expect(built.urlRequest.value(forHTTPHeaderField: "Content-Type")
            == "application/x-www-form-urlencoded")
        let body = String(decoding: built.urlRequest.httpBody ?? Data(), as: UTF8.self)
        #expect(body == "name=ada+lovelace&note=a%26b%3Dc")
    }

    @Test func multipartWithOnlyTextPartsIsBuiltInMemory() throws {
        let built = try build(RequestItem(
            method: .post, url: "https://api.test",
            body: .formData([
                FormField(key: "name", value: .text("ada")),
                FormField(key: "role", value: .text("engineer")),
                FormField(key: "off", enabled: false, value: .text("no")),
            ])))

        let contentType = try #require(built.urlRequest.value(forHTTPHeaderField: "Content-Type"))
        #expect(contentType.hasPrefix("multipart/form-data; boundary=----PostfrauBoundary"))
        let boundary = String(contentType.split(separator: "boundary=").last!)

        let body = String(decoding: built.urlRequest.httpBody ?? Data(), as: UTF8.self)
        #expect(body.contains("Content-Disposition: form-data; name=\"name\"\r\n\r\nada\r\n"))
        #expect(body.contains("name=\"role\""))
        #expect(!body.contains("name=\"off\""))
        #expect(body.hasSuffix("--\(boundary)--\r\n"))
        #expect(body.hasPrefix("--\(boundary)\r\n"))
    }

    @Test func multipartWithAFilePartIsStreamedFromDisk() throws {
        let temp = TempDirectory()
        let file = temp.url.appending(path: "avatar.png")
        try Data(repeating: 0xAB, count: 4096).write(to: file)
        let bookmark = try file.bookmarkData(options: [.withSecurityScope])

        let built = try build(RequestItem(
            method: .post, url: "https://api.test",
            body: .formData([
                FormField(key: "caption", value: .text("hi")),
                FormField(
                    key: "file",
                    value: .file(FileReference(bookmark: bookmark, displayName: "avatar.png"))),
            ])))

        guard case .file(let payloadURL) = built.payload else {
            Issue.record("expected a streamed payload"); return
        }
        defer { try? FileManager.default.removeItem(at: payloadURL) }

        let bytes = try Data(contentsOf: payloadURL)
        let text = String(decoding: bytes.prefix(600), as: UTF8.self)
        #expect(text.contains("name=\"caption\""))
        #expect(text.contains("name=\"file\"; filename=\"avatar.png\""))
        #expect(text.contains("Content-Type: image/png"))
        #expect(bytes.count > 4096)
        #expect(built.urlRequest.value(forHTTPHeaderField: "Content-Length") == String(bytes.count))
        SecurityScopedFile.stopAccessing(built.accessedURLs)
    }

    @Test func aFormFieldWithNoAttachedFileWarnsInsteadOfFailing() throws {
        let built = try build(RequestItem(
            method: .post, url: "https://api.test",
            body: .formData([
                FormField(key: "text", value: .text("ok")),
                FormField(key: "file", value: .file(FileReference(displayName: "gone.png"))),
            ])))
        #expect(built.warnings.contains { $0.contains("gone.png") })
        #expect(built.payload.byteCount ?? 0 > 0)
    }

    @Test func binaryBodyStreamsTheFileAndSniffsItsType() throws {
        let temp = TempDirectory()
        let file = temp.url.appending(path: "doc.pdf")
        try Data(repeating: 0x25, count: 2048).write(to: file)
        let bookmark = try file.bookmarkData(options: [.withSecurityScope])

        let built = try build(RequestItem(
            method: .post, url: "https://api.test",
            body: .binary(FileReference(bookmark: bookmark, displayName: "doc.pdf"))))

        #expect(built.urlRequest.value(forHTTPHeaderField: "Content-Type") == "application/pdf")
        #expect(built.urlRequest.value(forHTTPHeaderField: "Content-Length") == "2048")
        guard case .file = built.payload else {
            Issue.record("expected a streamed payload"); return
        }
        SecurityScopedFile.stopAccessing(built.accessedURLs)
    }

    @Test func aBinaryBodyWithNoFileSendsNothing() throws {
        let built = try build(RequestItem(
            method: .post, url: "https://api.test", body: .binary(FileReference())))
        #expect(built.payload.byteCount == 0)
    }

    @Test func aStaleBookmarkGivesAnActionableError() throws {
        let temp = TempDirectory()
        let file = temp.url.appending(path: "gone.bin")
        try Data([1, 2, 3]).write(to: file)
        let bookmark = try file.bookmarkData(options: [.withSecurityScope])
        try FileManager.default.removeItem(at: file)

        #expect(throws: RequestBuilder.BuildError.self) {
            try build(RequestItem(
                method: .post, url: "https://api.test",
                body: .binary(FileReference(bookmark: bookmark, displayName: "gone.bin"))))
        }
        #expect(RequestBuilder.BuildError.unreadableFile("gone.bin").errorDescription?
            .contains("Pick the file again") == true)
    }

    // MARK: - Settings and warnings

    @Test func carriesTheTimeoutAndCookiePolicy() throws {
        var request = RequestItem(url: "https://api.test")
        request.settings.timeoutSeconds = 7
        request.settings.sendCookies = false
        let built = try build(request)
        #expect(built.urlRequest.timeoutInterval == 7)
        #expect(!built.urlRequest.httpShouldHandleCookies)
    }

    @Test func warnsAboutEveryUnresolvedVariable() throws {
        let built = try build(RequestItem(
            method: .post, url: "{{host}}/x",
            params: [KeyValue(key: "p", value: "{{missingParam}}")],
            headers: [KeyValue(key: "X", value: "{{missingHeader}}")],
            body: .raw(text: "{{missingBody}}", language: .json)),
            values: ["host": "https://api.test"])

        let warning = try #require(built.warnings.first { $0.hasPrefix("Unresolved") })
        for name in ["missingParam", "missingHeader", "missingBody"] {
            #expect(warning.contains(name))
        }
    }

    @Test func aFullyResolvedRequestHasNoWarnings() throws {
        let built = try build(
            RequestItem(url: "{{host}}/x"), values: ["host": "https://api.test"])
        #expect(built.warnings.isEmpty)
    }

    @Test func allHeadersIsSortedAndComplete() throws {
        let built = try build(RequestItem(
            url: "https://api.test",
            headers: [KeyValue(key: "Z-Last", value: "1"), KeyValue(key: "A-First", value: "2")]))
        let names = built.allHeaders.map(\.name)
        #expect(names == names.sorted { $0.lowercased() < $1.lowercased() })
        #expect(names.contains("A-First"))
        #expect(names.contains("User-Agent"))
    }
}

@Suite("URL query")
struct URLQueryTests {
    @Test func parsesAQueryIntoRows() {
        let (base, params) = URLQuery.parse("https://api.test/u?limit=10&q=a%20b&flag")
        #expect(base == "https://api.test/u")
        #expect(params.map(\.key) == ["limit", "q", "flag"])
        #expect(params.map(\.value) == ["10", "a b", ""])
    }

    @Test func aURLWithNoQueryParsesToNoRows() {
        let (base, params) = URLQuery.parse("https://api.test/u")
        #expect(base == "https://api.test/u")
        #expect(params.isEmpty)
    }

    @Test func keepsTheFragmentAttachedToTheBase() {
        let (base, params) = URLQuery.parse("https://api.test/u?a=1#section")
        #expect(base == "https://api.test/u#section")
        #expect(params.map(\.key) == ["a"])
        #expect(URLQuery.compose(base: base, params: params) == "https://api.test/u?a=1#section")
    }

    @Test func composesAndRoundTrips() {
        let original = "https://api.test/u?limit=10&q=hello"
        let (base, params) = URLQuery.parse(original)
        #expect(URLQuery.compose(base: base, params: params) == original)
    }

    @Test func composeReplacesAnExistingQuery() {
        let composed = URLQuery.compose(
            base: "https://api.test/u?old=1", params: [KeyValue(key: "new", value: "2")])
        #expect(composed == "https://api.test/u?new=2")
    }

    @Test func composeDropsDisabledAndEmptyRows() {
        let composed = URLQuery.compose(base: "https://api.test/u", params: [
            KeyValue(key: "a", value: "1"),
            KeyValue(key: "b", value: "2", enabled: false),
            KeyValue(key: "", value: ""),
        ])
        #expect(composed == "https://api.test/u?a=1")
    }

    @Test func composeWithNoRowsLeavesABareURL() {
        #expect(URLQuery.compose(base: "https://api.test/u?a=1", params: []) == "https://api.test/u")
    }

    @Test func variablesSurviveComposition() {
        let composed = URLQuery.compose(
            base: "{{baseUrl}}/u", params: [KeyValue(key: "id", value: "{{userId}}")])
        #expect(composed == "{{baseUrl}}/u?id={{userId}}")
    }

    @Test func mergeKeepsRowIdentityForUnchangedKeys() {
        let existing = [
            KeyValue(key: "limit", value: "10", description: "page size"),
            KeyValue(key: "debug", value: "1", enabled: false),
        ]
        let (base, merged) = URLQuery.merge(urlText: "https://api.test/u?limit=25", into: existing)

        #expect(base == "https://api.test/u")
        #expect(merged.count == 2)
        #expect(merged[0].id == existing[0].id)
        #expect(merged[0].value == "25")
        #expect(merged[0].description == "page size")
        // The disabled row is not in the URL but must not be lost.
        #expect(merged[1].key == "debug")
        #expect(!merged[1].enabled)
    }

    @Test func mergeAddsNewRowsAndDropsRemovedOnes() {
        let existing = [KeyValue(key: "a", value: "1"), KeyValue(key: "gone", value: "x")]
        let (_, merged) = URLQuery.merge(urlText: "https://api.test/u?a=1&b=2", into: existing)
        #expect(merged.map(\.key) == ["a", "b"])
    }

    @Test func stripQueryKeepsTheFragment() {
        #expect(URLQuery.stripQuery(from: "https://x.test/p?a=1#f") == "https://x.test/p#f")
        #expect(URLQuery.stripQuery(from: "https://x.test/p") == "https://x.test/p")
    }
}
