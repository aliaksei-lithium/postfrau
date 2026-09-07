import Foundation
import Testing
@testable import PostfrauCore

/// Every test here runs against `MockURLProtocol`, so nothing touches the network.
/// `.serialized` because the mock's routing table is process-wide.
@Suite("HTTP executor", .serialized)
struct HTTPExecutorTests {
    private func makeExecutor() -> HTTPExecutor {
        MockURLProtocol.reset()
        return HTTPExecutor(protocolClasses: [MockURLProtocol.self])
    }

    private func send(
        _ executor: HTTPExecutor,
        _ request: RequestItem,
        values: [String: String] = [:],
        auth: Auth = .none
    ) async throws -> HTTPResponse {
        let built = try RequestBuilder().build(
            request, resolver: VariableResolver(values: values), effectiveAuth: auth)
        return try await executor.send(built, settings: request.settings)
    }

    // MARK: - Happy path

    @Test func returnsStatusHeadersAndBody() async throws {
        let executor = makeExecutor()
        MockURLProtocol.routeAll(MockRoute(
            statusCode: 201,
            headers: ["Content-Type": "application/json", "X-Trace": "abc"],
            body: Data(#"{"ok":true}"#.utf8)))

        let response = try await send(executor, RequestItem(url: "https://api.test/things"))

        #expect(response.statusCode == 201)
        #expect(response.reasonPhrase == "Created")
        #expect(response.statusLine == "201 Created")
        #expect(response.isSuccess)
        #expect(response.headers.value(for: "x-trace") == "abc")
        #expect(response.mimeType == "application/json")
        #expect(try response.body.data() == Data(#"{"ok":true}"#.utf8))
        #expect(response.byteCount == 11)
        #expect(!response.body.isOnDisk)
    }

    @Test func putsTheRequestOnTheWireAsBuilt() async throws {
        let executor = makeExecutor()
        MockURLProtocol.routeAll(MockRoute(body: Data("{}".utf8)))

        _ = try await send(executor, RequestItem(
            method: .post,
            url: "https://api.test/users",
            params: [KeyValue(key: "dry", value: "1")],
            headers: [KeyValue(key: "X-Client", value: "postfrau")],
            body: .raw(text: #"{"a":1}"#, language: .json)),
            auth: .bearer(token: "tok"))

        let sent = try #require(MockURLProtocol.lastRequest)
        #expect(sent.method == "POST")
        #expect(sent.url == "https://api.test/users?dry=1")
        #expect(sent.headers["X-Client"] == "postfrau")
        #expect(sent.headers["Authorization"] == "Bearer tok")
        #expect(sent.headers["Content-Type"] == "application/json")
        #expect(sent.body == Data(#"{"a":1}"#.utf8))
    }

    @Test func streamsAFileBodyToTheServer() async throws {
        let executor = makeExecutor()
        MockURLProtocol.routeAll(MockRoute(body: Data("ok".utf8)))

        let temp = TempDirectory()
        let file = temp.url.appending(path: "payload.bin")
        let contents = Data(repeating: 0x7F, count: 5000)
        try contents.write(to: file)

        _ = try await send(executor, RequestItem(
            method: .put,
            url: "https://api.test/upload",
            body: .binary(FileReference(
                bookmark: try file.bookmarkData(options: [.withSecurityScope]),
                displayName: "payload.bin"))))

        let sent = try #require(MockURLProtocol.lastRequest)
        #expect(sent.body == contents)
        #expect(sent.headers["Content-Length"] == "5000")
    }

    @Test func recordsTheHeadersItActuallySent() async throws {
        let executor = makeExecutor()
        MockURLProtocol.routeAll(MockRoute())
        let response = try await send(executor, RequestItem(url: "https://api.test"))
        #expect(response.sentHeaders.contains { $0.name == "User-Agent" })
        #expect(response.sentHeaders.contains { $0.name == "Accept" })
    }

    @Test func reportsTiming() async throws {
        let executor = makeExecutor()
        MockURLProtocol.routeAll(MockRoute(body: Data("x".utf8), delay: .milliseconds(40)))
        let response = try await send(executor, RequestItem(url: "https://api.test"))
        #expect(response.timing.total > 0.03)
        #expect(response.timing.totalMilliseconds > 30)
    }

    // MARK: - Status handling

    @Test func namesEveryCommonStatusCode() async throws {
        let executor = makeExecutor()
        for (code, phrase) in [(200, "OK"), (204, "No Content"), (404, "Not Found"),
                               (429, "Too Many Requests"), (500, "Internal Server Error")] {
            MockURLProtocol.routeAll(MockRoute(statusCode: code))
            let response = try await send(executor, RequestItem(url: "https://api.test"))
            #expect(response.reasonPhrase == phrase)
        }
        #expect(ReasonPhrase.forStatus(599) == "Server Error")
        #expect(ReasonPhrase.forStatus(299) == "Success")
        #expect(ReasonPhrase.forStatus(42).isEmpty)
    }

    @Test func aFourHundredIsAResponseNotAnError() async throws {
        let executor = makeExecutor()
        MockURLProtocol.routeAll(MockRoute(statusCode: 422, body: Data(#"{"error":"nope"}"#.utf8)))
        let response = try await send(executor, RequestItem(url: "https://api.test"))
        #expect(response.statusCode == 422)
        #expect(!response.isSuccess)
        #expect(try response.body.data().count == 16)
    }

    // MARK: - Redirects

    @Test func followsAndRecordsRedirects() async throws {
        let executor = makeExecutor()
        MockURLProtocol.route("/final", MockRoute(body: Data("arrived".utf8)))
        MockURLProtocol.route("/start", MockRoute(
            statusCode: 302, redirectTo: "https://api.test/final"))

        let response = try await send(executor, RequestItem(url: "https://api.test/start"))

        #expect(response.statusCode == 200)
        #expect(try response.body.data() == Data("arrived".utf8))
        #expect(response.redirects.count == 1)
        #expect(response.redirects[0].statusCode == 302)
        #expect(response.redirects[0].location == "https://api.test/final")
        #expect(response.finalURL == "https://api.test/final")
    }

    @Test func stopsAtTheRedirectWhenFollowingIsOff() async throws {
        let executor = makeExecutor()
        MockURLProtocol.route("/final", MockRoute(body: Data("arrived".utf8)))
        MockURLProtocol.route("/start", MockRoute(
            statusCode: 302, redirectTo: "https://api.test/final"))

        var request = RequestItem(url: "https://api.test/start")
        request.settings.followRedirects = false
        let response = try await send(executor, request)

        #expect(response.statusCode == 302)
        #expect(response.headers.value(for: "Location") == "https://api.test/final")
        #expect(response.redirects.count == 1)
    }

    @Test func honoursTheRedirectLimit() async throws {
        let executor = makeExecutor()
        // A loop: every hop redirects to the next one.
        MockURLProtocol.routeAll(MockRoute(statusCode: 302, redirectTo: "https://api.test/loop"))

        var request = RequestItem(url: "https://api.test/loop")
        request.settings.maxRedirects = 3
        let response = try await send(executor, request)

        #expect(response.statusCode == 302)
        #expect(response.redirects.count == 4)
    }

    // MARK: - Errors and cancellation

    @Test func mapsTransportErrorsToReadableMessages() async throws {
        let executor = makeExecutor()
        MockURLProtocol.routeAll(MockRoute(error: URLError(.cannotFindHost)))

        await #expect(throws: HTTPExecutor.ExecutorError.self) {
            try await send(executor, RequestItem(url: "https://nope.test"))
        }

        let cases: [(URLError.Code, String)] = [
            (.notConnectedToInternet, "No internet connection."),
            (.timedOut, "The request timed out."),
            (.cannotFindHost, "Could not find that host. Check the URL."),
            (.serverCertificateUntrusted, "Verify TLS certificates"),
        ]
        for (code, fragment) in cases {
            let message = HTTPExecutor.ExecutorError.transport(URLError(code)).errorDescription ?? ""
            #expect(message.contains(fragment))
        }
    }

    @Test func aTimeoutSurfacesAsATimeoutError() async throws {
        let executor = makeExecutor()
        MockURLProtocol.routeAll(MockRoute(error: URLError(.timedOut)))
        var request = RequestItem(url: "https://slow.test")
        request.settings.timeoutSeconds = 0.2

        do {
            _ = try await send(executor, request)
            Issue.record("expected the send to fail")
        } catch let error as HTTPExecutor.ExecutorError {
            #expect(error.errorDescription?.contains("timed out") == true)
        }
    }

    @Test func cancellingTheTaskCancelsTheTransfer() async throws {
        let executor = makeExecutor()
        MockURLProtocol.routeAll(MockRoute(body: Data("late".utf8), delay: .seconds(5)))

        let built = try RequestBuilder().build(
            RequestItem(url: "https://slow.test"),
            resolver: VariableResolver(values: [:]), effectiveAuth: .none)

        let started = ContinuousClock.now
        let task = Task { try await executor.send(built, settings: RequestSettings()) }
        try await Task.sleep(for: .milliseconds(120))
        task.cancel()

        let result = await task.result
        let elapsed = started.duration(to: .now)
        #expect(elapsed < .seconds(3), "cancel should not wait for the response")

        switch result {
        case .success:
            Issue.record("expected the send to be cancelled")
        case .failure(let error):
            let executorError = try #require(error as? HTTPExecutor.ExecutorError)
            if case .cancelled = executorError {} else {
                Issue.record("expected .cancelled, got \(executorError)")
            }
        }
    }

    // MARK: - Body size

    @Test func aBodyOverTheSpillThresholdLandsOnDisk() async throws {
        let executor = makeExecutor()
        let size = HTTPExecutor.spillThreshold + 1024
        MockURLProtocol.routeAll(MockRoute(body: Data(repeating: 0x41, count: size)))

        let response = try await send(executor, RequestItem(url: "https://api.test/big"))
        defer { response.body.discardTemporaryFile() }

        #expect(response.body.isOnDisk)
        #expect(response.byteCount == size)
        // The viewer reads a window into the file rather than the whole thing.
        #expect(try response.body.prefix(16).count == 16)
        #expect(try response.body.data().count == size)
    }

    @Test func aBodyUnderTheThresholdStaysInMemory() async throws {
        let executor = makeExecutor()
        MockURLProtocol.routeAll(MockRoute(body: Data(repeating: 0x41, count: 3 * 1024 * 1024)))
        let response = try await send(executor, RequestItem(url: "https://api.test/medium"))
        #expect(!response.body.isOnDisk)
        #expect(response.byteCount == 3 * 1024 * 1024)
    }

    @Test func discardingARemovesTheSpillFile() async throws {
        let executor = makeExecutor()
        MockURLProtocol.routeAll(MockRoute(
            body: Data(repeating: 0x41, count: HTTPExecutor.spillThreshold + 64)))
        let response = try await send(executor, RequestItem(url: "https://api.test/big"))

        guard case .onDisk(let url, _) = response.body else {
            Issue.record("expected an on-disk body"); return
        }
        #expect(FileManager.default.fileExists(atPath: url.path))
        response.body.discardTemporaryFile()
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    @Test func theHardCapIsReported() {
        let message = HTTPExecutor.ExecutorError.tooLarge(limit: HTTPExecutor.hardCap)
            .errorDescription ?? ""
        #expect(message.contains("200"))
        #expect(HTTPExecutor.hardCap == 200 * 1024 * 1024)
        #expect(HTTPExecutor.spillThreshold == 20 * 1024 * 1024)
    }

    // MARK: - Cookies

    @Test func parsesSetCookieHeadersFromTheResponse() async throws {
        let executor = makeExecutor()
        MockURLProtocol.routeAll(MockRoute(headers: [
            "Set-Cookie": "session=abc123; Path=/; Domain=api.test; Secure; HttpOnly; SameSite=Lax",
        ]))

        let response = try await send(executor, RequestItem(url: "https://api.test"))
        let cookie = try #require(response.cookies.first)
        #expect(cookie.name == "session")
        #expect(cookie.value == "abc123")
        #expect(cookie.path == "/")
        #expect(cookie.domain == "api.test")
        #expect(cookie.isSecure)
        #expect(cookie.isHTTPOnly)
        #expect(cookie.sameSite == "Lax")
    }

    // MARK: - Sessions

    @Test func reusesOneSessionPerProfile() async throws {
        let executor = makeExecutor()
        MockURLProtocol.routeAll(MockRoute(body: Data("x".utf8)))

        var strict = RequestItem(url: "https://api.test/a")
        var lax = RequestItem(url: "https://api.test/b")
        lax.settings.verifyTLS = false

        for _ in 0..<3 {
            _ = try await send(executor, strict)
            _ = try await send(executor, lax)
        }
        #expect(MockURLProtocol.recorded.count == 6)

        strict.settings.timeoutSeconds = 99  // does not change the profile
        _ = try await send(executor, strict)
        await executor.invalidateSessions()
        _ = try await send(executor, strict)
        #expect(MockURLProtocol.recorded.count == 8)
    }
}

@Suite("Cookie parser")
struct CookieParserTests {
    @Test func parsesTheSimplestForm() throws {
        let cookie = try #require(CookieParser.parse(setCookie: "id=42"))
        #expect(cookie.name == "id")
        #expect(cookie.value == "42")
        #expect(!cookie.isSecure)
        #expect(cookie.path == nil)
    }

    @Test func parsesEveryAttribute() throws {
        let header = "sid=x.y.z; Expires=Wed, 09 Sep 2026 10:18:14 GMT; Max-Age=3600; "
            + "Domain=.example.com; Path=/api; Secure; HttpOnly; SameSite=Strict"
        let cookie = try #require(CookieParser.parse(setCookie: header))
        #expect(cookie.value == "x.y.z")
        #expect(cookie.expires == "Wed, 09 Sep 2026 10:18:14 GMT")
        #expect(cookie.maxAge == 3600)
        #expect(cookie.domain == ".example.com")
        #expect(cookie.path == "/api")
        #expect(cookie.isSecure)
        #expect(cookie.isHTTPOnly)
        #expect(cookie.sameSite == "Strict")
    }

    @Test func keepsAnEmptyValue() throws {
        let cookie = try #require(CookieParser.parse(setCookie: "cleared=; Max-Age=0"))
        #expect(cookie.value.isEmpty)
        #expect(cookie.maxAge == 0)
    }

    @Test func keepsEqualsSignsInsideTheValue() throws {
        let cookie = try #require(CookieParser.parse(setCookie: "token=YWJjPT0=; Path=/"))
        #expect(cookie.value == "YWJjPT0=")
    }

    @Test func rejectsHeadersWithNoNameValuePair() {
        #expect(CookieParser.parse(setCookie: "") == nil)
        #expect(CookieParser.parse(setCookie: "Secure; HttpOnly") == nil)
        #expect(CookieParser.parse(setCookie: "=novalue") == nil)
    }

    @Test func ignoresUnknownAttributes() throws {
        let cookie = try #require(CookieParser.parse(setCookie: "a=1; Priority=High; Partitioned"))
        #expect(cookie.name == "a")
    }

    @Test func collectsEveryCookieFromAResponsesHeaders() {
        let headers = [
            HeaderField(name: "Set-Cookie", value: "a=1"),
            HeaderField(name: "Content-Type", value: "text/plain"),
            HeaderField(name: "set-cookie", value: "b=2; Secure"),
        ]
        let cookies = CookieParser.parse(headers: headers)
        #expect(cookies.map(\.name) == ["a", "b"])
        #expect(cookies[1].isSecure)
    }
}

@Suite("Byte count")
struct ByteCountTests {
    @Test func formatsSizes() {
        #expect(ByteCount.format(0) == "0 B")
        #expect(ByteCount.format(842) == "842 B")
        #expect(ByteCount.format(2048) == "2.0 KB")
        #expect(ByteCount.format(1024 * 1024 * 3 / 2) == "1.5 MB")
        #expect(ByteCount.format(200 * 1024 * 1024) == "200 MB")
    }

    @Test func formatsDurations() {
        #expect(ByteCount.formatDuration(milliseconds: 142) == "142 ms")
        #expect(ByteCount.formatDuration(milliseconds: 1420) == "1.42 s")
        #expect(ByteCount.formatDuration(milliseconds: 67_000) == "1 m 07 s")
    }
}

@Suite("Timing")
struct TimingTests {
    @Test func breakdownSkipsPhasesThatWereNotMeasured() {
        let timing = Timing(total: 1, dns: 0.01, connect: nil, tls: 0.02, ttfb: 0.5)
        #expect(timing.breakdown.map(\.label) == ["DNS", "TLS", "Waiting"])
    }

    @Test func anEmptyBreakdownIsFine() {
        #expect(Timing(total: 0.1).breakdown.isEmpty)
        #expect(Timing(total: 0.1).totalMilliseconds == 100)
    }
}
