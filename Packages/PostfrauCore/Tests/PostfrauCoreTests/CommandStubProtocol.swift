import Foundation
import Synchronization
@testable import PostfrauCore

/// A stub transport owned by the command tests alone.
///
/// `MockURLProtocol` has a global routing table, and suites run in parallel, so two suites sharing
/// it end up reading each other's routes — which is how a command test came back holding a nine
/// megabyte body from the executor tests. This one is used by a single `.serialized` suite.
final class CommandStubProtocol: URLProtocol, @unchecked Sendable {
    // Foundation owns the lifetime and instantiates these on its own threads; the one piece of
    // shared state is `Mutex`-protected.
    struct Reply: Sendable {
        var statusCode: Int = 200
        var headers: [String: String] = ["Content-Type": "application/json"]
        var body: Data = Data("{}".utf8)
        var error: URLError?
    }

    private static let reply = Mutex(Reply())
    private static let requestCount = Mutex(0)

    static func stub(_ newReply: Reply) {
        reply.withLock { $0 = newReply }
        requestCount.withLock { $0 = 0 }
    }

    static var count: Int { requestCount.withLock { $0 } }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.requestCount.withLock { $0 += 1 }
        let reply = Self.reply.withLock { $0 }

        if let error = reply.error {
            client?.urlProtocol(self, didFailWithError: error)
            return
        }
        let response = HTTPURLResponse(
            url: request.url ?? URL(filePath: "/"),
            statusCode: reply.statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: reply.headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: reply.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
