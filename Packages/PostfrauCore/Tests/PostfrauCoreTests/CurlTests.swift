import Foundation
import Testing
@testable import PostfrauCore

@Suite("Shell tokenizer")
struct CurlTokenizerTests {
    @Test func splitsOnWhitespace() {
        #expect(CurlTokenizer.tokenize("curl -X POST https://a.test")
            == ["curl", "-X", "POST", "https://a.test"])
    }

    @Test func singleQuotesAreLiteral() {
        #expect(CurlTokenizer.tokenize(#"curl -H 'Accept: application/json'"#)
            == ["curl", "-H", "Accept: application/json"])
        #expect(CurlTokenizer.tokenize(#"curl -d '{"a": "b\c"}'"#)
            == ["curl", "-d", #"{"a": "b\c"}"#], "a backslash inside single quotes is just a byte")
    }

    @Test func doubleQuotesHonourOnlyTheShellsOwnEscapes() {
        #expect(CurlTokenizer.tokenize(#"curl -d "{\"a\": 1}""#)
            == ["curl", "-d", #"{"a": 1}"#])
        #expect(CurlTokenizer.tokenize(#"curl -d "a\nb""#)
            == ["curl", "-d", #"a\nb"#], "\\n is not an escape the shell expands")
    }

    @Test func backslashAtEndOfLineContinues() {
        let command = """
            curl https://a.test \\
              -H 'Accept: text/plain' \\
              -d hello
            """
        #expect(CurlTokenizer.tokenize(command)
            == ["curl", "https://a.test", "-H", "Accept: text/plain", "-d", "hello"])
    }

    @Test func handlesAnsiCQuotingTheWayChromeCopiesIt() {
        #expect(CurlTokenizer.tokenize(#"curl -d $'line1\nline2\ttabbed'"#)
            == ["curl", "-d", "line1\nline2\ttabbed"])
    }

    @Test func anEmptyArgumentSurvives() {
        #expect(CurlTokenizer.tokenize("curl -d '' https://a.test")
            == ["curl", "-d", "", "https://a.test"])
    }

    @Test func anUnterminatedQuoteRunsToTheEndRatherThanFailing() {
        // Half a pasted command should still give back something usable.
        #expect(CurlTokenizer.tokenize("curl -H 'Accept: application/json")
            == ["curl", "-H", "Accept: application/json"])
    }
}

@Suite("curl import")
struct CurlParserTests {
    private func parse(_ command: String) throws -> RequestItem {
        try CurlParser().parse(command).request
    }

    @Test func theSimplestPossibleCommand() throws {
        let request = try parse("curl https://api.acme.dev/users")
        #expect(request.method == .get)
        #expect(request.url == "https://api.acme.dev/users")
        #expect(request.name == "users")
    }

    @Test func aSchemelessHostBecomesHttps() throws {
        // curl would assume http; every place people copy these from means https, and silently
        // downgrading a request is worse than making the user retype one.
        #expect(try parse("curl api.acme.dev/users").url == "https://api.acme.dev/users")
        #expect(try parse("curl http://localhost:8080/x").url == "http://localhost:8080/x")
    }

    @Test func explicitMethodWins() throws {
        #expect(try parse("curl -X DELETE https://a.test/1").method == .delete)
        #expect(try parse("curl --request PATCH https://a.test/1").method == .patch)
    }

    @Test func dataWithoutAMethodIsAPost() throws {
        let request = try parse(#"curl https://a.test -d '{"a":1}'"#)
        #expect(request.method == .post)
        guard case .raw(let text, let language) = request.body else {
            Issue.record("expected raw"); return
        }
        #expect(text == #"{"a":1}"#)
        #expect(language == .json, "a body that starts with { is JSON even with no header")
    }

    @Test func repeatedDataIsJoinedWithAmpersandsIntoAForm() throws {
        let request = try parse("curl https://a.test -d name=ada -d role=admin")
        guard case .urlEncoded(let pairs) = request.body else {
            Issue.record("expected url-encoded"); return
        }
        #expect(pairs.map(\.key) == ["name", "role"])
        #expect(pairs.map(\.value) == ["ada", "admin"])
    }

    @Test func headersBecomeHeaders() throws {
        let request = try parse(
            #"curl https://a.test -H 'Accept: application/json' -H "X-Trace: abc""#)
        #expect(request.headers.map(\.key) == ["Accept", "X-Trace"])
        #expect(request.headers.map(\.value) == ["application/json", "abc"])
    }

    @Test func anEmptyHeaderUsesCurlsSemicolonForm() throws {
        let request = try parse(#"curl https://a.test -H "X-Empty;""#)
        #expect(request.headers == [KeyValue(id: request.headers[0].id, key: "X-Empty", value: "")])
    }

    @Test func aBearerHeaderBecomesAuthRatherThanAHeader() throws {
        let request = try parse(
            #"curl https://a.test -H 'Authorization: Bearer abc123'"#)
        #expect(request.auth == .bearer(token: "abc123"))
        #expect(request.headers.isEmpty, "it moved to the auth tab, where it can be edited")
    }

    @Test func aBasicHeaderIsDecodedIntoItsParts() throws {
        let encoded = Data("ada:lovelace".utf8).base64EncodedString()
        let request = try parse("curl https://a.test -H 'Authorization: Basic \(encoded)'")
        #expect(request.auth == .basic(username: "ada", password: "lovelace"))
    }

    @Test func anAuthSchemeItCannotModelStaysAHeader() throws {
        let request = try parse(#"curl https://a.test -H 'Authorization: AWS4-HMAC-SHA256 x'"#)
        #expect(request.headers.count == 1)
        #expect(request.auth == .inherit)
    }

    @Test func userFlagBecomesBasicAuth() throws {
        #expect(try parse("curl -u ada:lovelace https://a.test").auth
            == .basic(username: "ada", password: "lovelace"))
        #expect(try parse("curl -u ada https://a.test").auth
            == .basic(username: "ada", password: ""))
    }

    @Test func formFlagsBecomeMultipart() throws {
        let request = try parse(
            "curl https://a.test -F caption=hello -F 'file=@/tmp/me.png' -F 'doc=@a.pdf;type=application/pdf'")
        guard case .formData(let fields) = request.body else {
            Issue.record("expected multipart"); return
        }
        #expect(fields.map(\.key) == ["caption", "file", "doc"])
        if case .file(let reference) = fields[1].value {
            #expect(reference.displayName == "me.png")
        } else {
            Issue.record("the second field should be a file")
        }
        if case .file(let reference) = fields[2].value {
            #expect(reference.displayName == "a.pdf", "the ;type= suffix is not part of the path")
        } else {
            Issue.record("the third field should be a file")
        }
    }

    @Test func settingsFlagsReachTheRequestSettings() throws {
        let request = try parse("curl -L -k --max-time 5 https://a.test")
        #expect(request.settings.followRedirects)
        #expect(!request.settings.verifyTLS)
        #expect(request.settings.timeoutSeconds == 5)
    }

    @Test func getFlagMovesDataIntoTheQuery() throws {
        let request = try parse("curl -G https://a.test/search -d q=swift -d page=2")
        #expect(request.method == .get)
        #expect(request.url.contains("q=swift"))
        #expect(request.url.contains("page=2"))
        #expect(request.params.map(\.key).contains("q"))
        if case .none = request.body {} else { Issue.record("a -G request has no body") }
    }

    @Test func cookieAndUserAgentBecomeHeaders() throws {
        let request = try parse(
            "curl https://a.test -b 'session=abc' -A 'Mozilla/5.0' -e https://ref.test")
        #expect(request.headers.map(\.key).sorted() == ["Cookie", "Referer", "User-Agent"])
    }

    @Test func flagsAboutCurlItselfAreIgnoredSilently() throws {
        let result = try CurlParser().parse(
            "curl -sS --compressed -f https://a.test")
        #expect(result.warnings.isEmpty, "these say nothing about the request")
        #expect(result.request.url == "https://a.test")
    }

    @Test func aFlagWithAValueItIgnoresDoesNotSwallowTheUrl() throws {
        // The bug this guards: `-o out.json` consuming `out.json`, then the URL landing in it.
        let result = try CurlParser().parse("curl -o out.json https://a.test/users")
        #expect(result.request.url == "https://a.test/users")
        #expect(result.warnings.count == 1)
    }

    @Test func anUnknownFlagIsReportedNotFatal() throws {
        let result = try CurlParser().parse("curl --frobnicate https://a.test")
        #expect(result.request.url == "https://a.test")
        #expect(result.warnings.contains { $0.contains("--frobnicate") })
    }

    @Test func shortFlagsCanCarryTheirValue() throws {
        let request = try parse(#"curl -H'Accept: text/csv' -XPUT https://a.test"#)
        #expect(request.method == .put)
        #expect(request.headers.first?.value == "text/csv")
    }

    @Test func longFlagsCanUseEquals() throws {
        let request = try parse("curl --request=PUT --header='Accept: text/csv' https://a.test")
        #expect(request.method == .put)
        #expect(request.headers.first?.value == "text/csv")
    }

    @Test func theUrlFlagIsHonoured() throws {
        #expect(try parse("curl --url https://a.test/x").url == "https://a.test/x")
    }

    @Test func aQueryStringInTheUrlFillsTheParamsTable() throws {
        let request = try parse("curl 'https://a.test/search?q=swift&page=2'")
        #expect(request.params.map(\.key) == ["q", "page"])
    }

    @Test func aChromeCopyAsCurlWorksEndToEnd() throws {
        // The shape Chrome actually produces, $'…' body and all.
        let command = #"""
        curl 'https://api.acme.dev/v1/users?page=2' \
          -H 'accept: application/json' \
          -H 'authorization: Bearer eyJhbGciOi.J9.sig' \
          -H 'content-type: application/json' \
          --data-raw $'{\n  "name": "Ada"\n}' \
          --compressed
        """#
        let result = try CurlParser().parse(command)
        #expect(result.request.method == .post)
        #expect(result.request.url.hasPrefix("https://api.acme.dev/v1/users"))
        #expect(result.request.params.first?.key == "page")
        #expect(result.request.auth == .bearer(token: "eyJhbGciOi.J9.sig"))
        guard case .raw(let text, let language) = result.request.body else {
            Issue.record("expected raw"); return
        }
        #expect(text == "{\n  \"name\": \"Ada\"\n}")
        #expect(language == .json)
        #expect(result.warnings.isEmpty)
    }

    @Test func multipleUrlsTakeTheFirstAndSaySo() throws {
        let result = try CurlParser().parse("curl https://a.test https://b.test")
        #expect(result.request.url == "https://a.test")
        #expect(result.warnings.contains { $0.contains("2 URLs") })
    }

    @Test func refusesWhatIsNotCurl() {
        #expect(throws: CurlParser.ParseError.notCurl) {
            try CurlParser().parse("wget https://a.test")
        }
        #expect(throws: CurlParser.ParseError.noURL) {
            try CurlParser().parse("curl -X POST")
        }
    }

    @Test func recognisesCurlTextForThePasteHandler() {
        #expect(CurlParser.looksLikeCurl("curl https://a.test"))
        #expect(CurlParser.looksLikeCurl("  curl -X POST https://a.test  "))
        #expect(!CurlParser.looksLikeCurl("https://a.test"))
        #expect(!CurlParser.looksLikeCurl("curling is a sport"))
    }
}

@Suite("curl export")
struct CurlFormatterTests {
    private let formatter = CurlFormatter()

    @Test func writesAReadableMultiLineCommand() {
        var request = RequestItem(name: "R", method: .post, url: "https://a.test/users")
        request.headers = [KeyValue(key: "Accept", value: "application/json")]
        request.body = .raw(text: #"{"name":"Ada"}"#, language: .json)

        let command = formatter.format(request)
        #expect(command.hasPrefix("curl 'https://a.test/users'"))
        #expect(command.contains("--request POST"))
        #expect(command.contains("--header 'Accept: application/json'"))
        #expect(command.contains(#"--data-raw '{"name":"Ada"}'"#))
        #expect(command.contains(" \\\n    "), "continuations are aligned for reading")
    }

    @Test func aGetHasNoRequestFlag() {
        let command = formatter.format(RequestItem(url: "https://a.test"))
        #expect(!command.contains("--request"))
    }

    @Test func authBecomesTheHeaderItWouldSend() {
        let command = formatter.format(
            RequestItem(url: "https://a.test"), effectiveAuth: .bearer(token: "abc"))
        #expect(command.contains("--header 'Authorization: Bearer abc'"))

        let basic = formatter.format(
            RequestItem(url: "https://a.test"),
            effectiveAuth: .basic(username: "ada", password: "lovelace"))
        let encoded = Data("ada:lovelace".utf8).base64EncodedString()
        #expect(basic.contains("Basic \(encoded)"))
    }

    @Test func aQueryApiKeyIsAlreadyInTheUrlAndIsNotRepeated() {
        let command = formatter.format(
            RequestItem(url: "https://a.test?key=v"),
            effectiveAuth: .apiKey(key: "key", value: "v", location: .query))
        #expect(!command.contains("--header 'key: v'"))
    }

    @Test func variablesAreKeptOrFilledInAsAsked() {
        var request = RequestItem(url: "{{baseUrl}}/users")
        request.headers = [KeyValue(key: "X-Env", value: "{{env}}")]
        let resolver = VariableResolver(scope: .test([
            (.globals, ["baseUrl": "https://a.test", "env": "prod"]),
        ]))

        let raw = formatter.format(request, resolver: resolver, handling: .raw)
        #expect(raw.contains("{{baseUrl}}/users"))

        let resolved = formatter.format(request, resolver: resolver, handling: .resolved)
        #expect(resolved.contains("https://a.test/users"))
        #expect(resolved.contains("X-Env: prod"))
    }

    @Test func quotesTheWayTheShellNeeds() {
        #expect(CurlFormatter.quote("plain") == "'plain'")
        #expect(CurlFormatter.quote("") == "''")
        #expect(CurlFormatter.quote(#"{"a":"b"}"#) == #"'{"a":"b"}'"#)
        // Single quotes make everything inside them literal, so `$` and `"`
        // need no escaping there.
        #expect(CurlFormatter.quote(#"a"b$c"#) == #"'a"b$c'"#)
        // A value containing a single quote cannot be single-quoted at all,
        // and then the characters the shell still reads have to be escaped.
        #expect(CurlFormatter.quote("it's") == #""it's""#)
    }

    @Test func everyBodyModeHasAForm() {
        var request = RequestItem(url: "https://a.test")

        request.body = .urlEncoded([KeyValue(key: "a", value: "1")])
        #expect(formatter.format(request).contains("--data-urlencode 'a=1'"))

        request.body = .formData([
            FormField(key: "caption", value: .text("hi")),
            FormField(key: "file", value: .file(FileReference(displayName: "me.png"))),
        ])
        let form = formatter.format(request)
        #expect(form.contains("--form 'caption=hi'"))
        #expect(form.contains("--form 'file=@me.png'"))

        request.body = .binary(FileReference(displayName: "payload.bin"))
        #expect(formatter.format(request).contains("--data-binary '@payload.bin'"))
    }

    @Test func settingsThatDifferFromCurlsDefaultsAreWritten() {
        var request = RequestItem(url: "https://a.test")
        request.settings.verifyTLS = false
        request.settings.followRedirects = true

        let command = formatter.format(request)
        #expect(command.contains("--insecure"))
        #expect(command.contains("--location"))
    }
}

@Suite("curl round trip")
struct CurlRoundTripTests {
    @Test func formatThenParseGivesBackTheSameRequest() throws {
        var original = RequestItem(name: "Create user", method: .post, url: "https://a.test/users")
        original.params = [KeyValue(key: "dry_run", value: "true")]
        original.headers = [
            KeyValue(key: "Accept", value: "application/json"),
            KeyValue(key: "X-Trace", value: "abc"),
        ]
        original.auth = .bearer(token: "tok123")
        original.body = .raw(text: #"{"name":"Ada"}"#, language: .json)
        original.settings.verifyTLS = false

        let command = CurlFormatter().format(original, effectiveAuth: original.auth)
        let parsed = try CurlParser().parse(command).request

        #expect(parsed.method == original.method)
        #expect(parsed.url == "https://a.test/users?dry_run=true")
        #expect(parsed.auth == original.auth)
        #expect(parsed.headers.map(\.key) == ["Accept", "X-Trace"])
        #expect(parsed.body == original.body)
        #expect(parsed.settings.verifyTLS == false)
    }

    @Test func aFormPostSurvivesTheRoundTrip() throws {
        var original = RequestItem(method: .post, url: "https://a.test/token")
        original.body = .urlEncoded([
            KeyValue(key: "grant_type", value: "client_credentials"),
            KeyValue(key: "scope", value: "read write"),
        ])

        let command = CurlFormatter().format(original)
        let parsed = try CurlParser().parse(command).request

        guard case .urlEncoded(let pairs) = parsed.body else {
            Issue.record("expected url-encoded, got \(parsed.body)"); return
        }
        #expect(pairs.map(\.key) == ["grant_type", "scope"])
        #expect(pairs.map(\.value) == ["client_credentials", "read write"])
    }
}
