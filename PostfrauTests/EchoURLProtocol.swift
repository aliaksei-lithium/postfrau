import Foundation
import Synchronization

/// A `URLProtocol` that echoes the request back as JSON, exactly as httpbin would.
///
/// The app is sandboxed as a network *client*; it cannot bind a listening socket, so an
/// in-process HTTP server is not available to these tests. Intercepting at the protocol layer
/// leaves the whole of Postfrau in the path — request building, auth, the executor, the
/// recording — and replaces only the wire.
nonisolated final class EchoURLProtocol: URLProtocol, @unchecked Sendable {
    // Foundation owns this object's lifetime and instantiates it on its own threads; the shared
    // counter below is the only cross-thread state and it is `Mutex`-protected.
    private static let exchanges = Mutex(0)

    /// How many requests have been answered since `reset()`.
    static var exchangeCount: Int { exchanges.withLock { $0 } }

    static func reset() { exchanges.withLock { $0 = 0 } }

    /// A URL containing this fails with a transport error instead of answering.
    static let failingPathMarker = "/unreachable"

    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.exchanges.withLock { $0 += 1 }
        guard let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        guard !url.absoluteString.contains(Self.failingPathMarker) else {
            client?.urlProtocol(self, didFailWithError: URLError(.cannotConnectToHost))
            return
        }

        let echo: [String: Any] = [
            "method": request.httpMethod ?? "GET",
            "path": url.path,
            "headers": request.allHTTPHeaderFields ?? [:],
            "body": String(decoding: Self.body(of: request), as: UTF8.self),
        ]
        let payload = (try? JSONSerialization.data(
            withJSONObject: echo, options: [.prettyPrinted, .sortedKeys])) ?? Data("{}".utf8)

        let response = HTTPURLResponse(
            url: url,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: [
                "Content-Type": "application/json",
                "Content-Length": "\(payload.count)",
                "X-Echo": "postfrau-test",
                // A sensitive response header, to prove recording redacts both directions.
                "Set-Cookie": "session=server-side-secret; Path=/",
            ])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: payload)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    /// `URLRequest.httpBody` is nil for a stream-backed body, which is what the builder produces
    /// for anything that came from a file; read the stream in that case.
    private static func body(of request: URLRequest) -> Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let read = stream.read(&buffer, maxLength: buffer.count)
            if read <= 0 { break }
            data.append(buffer, count: read)
        }
        return data
    }
}
