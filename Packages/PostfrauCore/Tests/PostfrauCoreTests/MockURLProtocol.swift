import Foundation
import Synchronization
@testable import PostfrauCore

/// What a mocked exchange should do.
struct MockRoute: Sendable {
    var statusCode: Int = 200
    var headers: [String: String] = [:]
    var body: Data = Data()
    /// Set to make the request fail with a transport error instead of returning a response.
    var error: URLError?
    /// Artificial latency, for cancellation and timeout tests.
    var delay: Duration = .zero
    /// When set, the response is a redirect to this URL.
    var redirectTo: String?
}

/// A `URLProtocol` that answers from a routing table and records what it was asked for.
///
/// Registered per `URLSession` via `URLSessionConfiguration.protocolClasses`, so tests never touch
/// the network. `URLProtocol` subclasses are instantiated by Foundation on arbitrary threads and
/// the routing table is global by necessity, so it lives behind a `Mutex`.
final class MockURLProtocol: URLProtocol, @unchecked Sendable {
    // `URLProtocol` requires overriding non-Sendable-friendly class methods and Foundation owns
    // this object's lifetime, so the class is `@unchecked Sendable`; every piece of shared state
    // below is `Mutex`-protected and instance state is only touched on Foundation's own thread.
    struct RecordedRequest: Sendable {
        var method: String
        var url: String
        var headers: [String: String]
        var body: Data
    }

    private struct Registry {
        /// Matched by "does the URL contain this string", newest first.
        var routes: [(match: String, route: MockRoute)] = []
        var fallback = MockRoute()
        var recorded: [RecordedRequest] = []
    }

    private static let registry = Mutex(Registry())

    static func reset() {
        registry.withLock { $0 = Registry() }
    }

    /// Routes every request whose URL contains `match`.
    static func route(_ match: String, _ route: MockRoute) {
        registry.withLock { $0.routes.insert((match, route), at: 0) }
    }

    static func routeAll(_ route: MockRoute) {
        registry.withLock { $0.fallback = route }
    }

    static var recorded: [RecordedRequest] {
        registry.withLock { $0.recorded }
    }

    static var lastRequest: RecordedRequest? {
        registry.withLock { $0.recorded.last }
    }

    private static func route(for url: String) -> MockRoute {
        registry.withLock { registry in
            registry.routes.first { url.contains($0.match) }?.route ?? registry.fallback
        }
    }

    private static func record(_ request: RecordedRequest) {
        registry.withLock { $0.recorded.append(request) }
    }

    // MARK: - URLProtocol

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let url = request.url?.absoluteString ?? ""
        Self.record(RecordedRequest(
            method: request.httpMethod ?? "GET",
            url: url,
            headers: request.allHTTPHeaderFields ?? [:],
            // `httpBodyStream` is how a streamed (file) body arrives; read it back so tests can
            // assert on the exact bytes Postfrau put on the wire.
            body: request.httpBody ?? Self.drain(request.httpBodyStream)))

        let route = Self.route(for: url)

        // Foundation calls `startLoading` on its own loading thread, so the delay is a plain
        // sleep rather than a `Task`: no hop, no captures to make `Sendable`, and `stopLoading`
        // still interrupts it because the wait is polled.
        if route.delay > .zero, !sleepInterruptibly(route.delay) { return }
        guard !isStopped else { return }

        if let error = route.error {
            client?.urlProtocol(self, didFailWithError: error)
            return
        }

        if let destination = route.redirectTo, let requestURL = request.url {
            var headers = route.headers
            headers["Location"] = destination
            let response = HTTPURLResponse(
                url: requestURL, statusCode: route.statusCode == 200 ? 302 : route.statusCode,
                httpVersion: "HTTP/1.1", headerFields: headers)!
            var followUp = request
            followUp.url = URL(string: destination)
            client?.urlProtocol(self, wasRedirectedTo: followUp, redirectResponse: response)
            // The load must still complete: if the delegate declines the redirect, the loading
            // system delivers this 3xx as the final response instead of issuing a new request.
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocolDidFinishLoading(self)
            return
        }

        var headers = route.headers
        if headers["Content-Length"] == nil {
            headers["Content-Length"] = String(route.body.count)
        }
        let response = HTTPURLResponse(
            url: request.url!, statusCode: route.statusCode,
            httpVersion: "HTTP/1.1", headerFields: headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if !route.body.isEmpty {
            // Delivered in chunks so a cancel mid-body behaves like a real transfer.
            for chunk in route.body.chunked(into: 1 << 18) {
                guard !isStopped else { return }
                client?.urlProtocol(self, didLoad: chunk)
            }
        }
        client?.urlProtocolDidFinishLoading(self)
    }

    /// Sleeps in small slices so `stopLoading` takes effect promptly.
    /// Returns false when the load was cancelled while waiting.
    private func sleepInterruptibly(_ duration: Duration) -> Bool {
        let deadline = ContinuousClock.now.advanced(by: duration)
        while ContinuousClock.now < deadline {
            if isStopped { return false }
            Thread.sleep(forTimeInterval: 0.01)
        }
        return !isStopped
    }

    override func stopLoading() {
        stopped.withLock { $0 = true }
    }

    private let stopped = Mutex(false)
    private var isStopped: Bool { stopped.withLock { $0 } }

    private static func drain(_ stream: InputStream?) -> Data {
        guard let stream else { return Data() }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while stream.hasBytesAvailable {
            let read = stream.read(&buffer, maxLength: buffer.count)
            if read <= 0 { break }
            data.append(contentsOf: buffer[0..<read])
        }
        return data
    }
}

extension Data {
    /// Splits the bytes into chunks of at most `size`.
    func chunked(into size: Int) -> [Data] {
        guard count > size else { return [self] }
        return stride(from: 0, to: count, by: size).map {
            subdata(in: $0..<Swift.min($0 + size, count))
        }
    }
}
