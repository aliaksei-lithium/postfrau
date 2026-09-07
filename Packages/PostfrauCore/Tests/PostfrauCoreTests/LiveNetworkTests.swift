import Foundation
import Testing
@testable import PostfrauCore

/// Real network calls. Off by default; run them with:
///
///     POSTFRAU_LIVE_TESTS=1 swift test --filter Live
///
/// They exist to catch the things a `URLProtocol` mock cannot: real TLS, real redirects, and
/// whether `URLSessionTaskMetrics` actually gives us a timing breakdown.
@Suite("Live network", .serialized, .enabled(if: ProcessInfo.processInfo.environment["POSTFRAU_LIVE_TESTS"] == "1"))
struct LiveNetworkTests {
    private func send(_ request: RequestItem) async throws -> HTTPResponse {
        let built = try RequestBuilder().build(
            request, resolver: VariableResolver(values: [:]), effectiveAuth: .none)
        return try await HTTPExecutor().send(built, settings: request.settings)
    }

    @Test func getsARealPageOverTLS() async throws {
        let response = try await send(RequestItem(url: "https://example.com"))
        #expect(response.statusCode == 200)
        #expect(response.byteCount > 0)
        #expect(response.timing.total > 0)
        // A fresh TLS connection should report the handshake phases.
        #expect(response.timing.dns != nil)
        #expect(response.timing.tls != nil)

        // Printed so a live run leaves an auditable record of what came back.
        print("""
            \(response.statusLine)  \(ByteCount.format(response.byteCount))  \
            \(ByteCount.formatDuration(milliseconds: response.timing.totalMilliseconds))
            final URL: \(response.finalURL)
            phases: \(response.timing.breakdown
                .map { "\($0.label) \(Int($0.seconds * 1000)) ms" }
                .joined(separator: " · "))
            """)
    }

    @Test func echoesAPostedJSONBody() async throws {
        let response = try await send(RequestItem(
            method: .post,
            url: "https://httpbin.org/anything",
            headers: [KeyValue(key: "X-Postfrau-Test", value: "1")],
            body: .raw(text: #"{"hello":"world"}"#, language: .json)))

        #expect(response.statusCode == 200)
        let json = try #require(
            try JSONSerialization.jsonObject(with: response.body.data()) as? [String: Any])
        #expect((json["json"] as? [String: Any])?["hello"] as? String == "world")
        #expect((json["headers"] as? [String: Any])?["X-Postfrau-Test"] as? String == "1")
    }

    @Test func followsARealRedirect() async throws {
        let response = try await send(
            RequestItem(url: "https://httpbin.org/redirect-to?url=https%3A%2F%2Fexample.com"))
        #expect(response.statusCode == 200)
        #expect(!response.redirects.isEmpty)
        #expect(response.finalURL.contains("example.com"))
    }
}
