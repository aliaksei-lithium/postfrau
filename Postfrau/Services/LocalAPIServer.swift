import Foundation
import Network
import PostfrauCore

/// Answers `postfrau` over a loopback socket, so an agent that cannot reach the workspace on disk
/// can still list, find and send.
///
/// The app is the process holding the security-scoped bookmark to the data folder. A CLI running
/// under a sandbox that denies `~/Library/Containers` — or denies the user's chosen folder —
/// cannot read any of it, and no amount of `--data-dir` fixes that. So the app does the file
/// access and hands back the answers. See `docs/decisions.md` D48.
///
/// Everything here is deliberately small: four routes, no keep-alive, no chunked encoding. It is
/// not a web server, it is a hatch in the side of the app.
actor LocalAPIServer {
    /// What the socket is allowed to do, and to whom.
    private enum Limits {
        /// Bodies larger than this are refused outright rather than buffered.
        static let maximumRequestBytes = 1 << 20
        /// A client that opens a connection and says nothing does not get to hold one forever.
        static let readTimeout: Duration = .seconds(10)
    }

    private let port: UInt16
    private let token: String
    private let runner: CommandRunner
    private let dataFolderPath: String
    private var listener: NWListener?

    /// The queue Network hands us callbacks on. Everything they touch is hopped into the actor.
    private let queue = DispatchQueue(label: "com.postfrau.local-api")

    init(port: UInt16, token: String, runner: CommandRunner, dataFolderPath: String) {
        self.port = port
        self.token = token
        self.runner = runner
        self.dataFolderPath = dataFolderPath
    }

    // MARK: - Lifecycle

    /// Binds the socket, and does not return until it is actually listening.
    ///
    /// `NWListener.start` is asynchronous and reports failure through `stateUpdateHandler`, not by
    /// throwing — so without waiting for `.ready` a listener that never bound looks exactly like
    /// one that did, and the app would claim an API that answers nothing.
    func start() async throws {
        guard listener == nil else { return }
        guard let port = NWEndpoint.Port(rawValue: port) else {
            throw Failure.message("\(port) is not a usable port.")
        }

        let parameters = NWParameters.tcp
        // Bound to loopback explicitly. Without this the listener answers on every interface, and
        // "only local processes can reach it" stops being true the moment the Mac joins a café
        // network.
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: port)
        parameters.allowLocalEndpointReuse = true

        // The port comes from `requiredLocalEndpoint` alone. Passing it to `NWListener(using:on:)`
        // as well sets it twice and the listener fails to bind with EINVAL.
        let listener = try NWListener(using: parameters)
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { connection.cancel(); return }
            Task { await self.accept(connection) }
        }

        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Void, any Error>) in
            let resumed = Resumed()
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if resumed.claim() { continuation.resume() }
                case .failed(let error), .waiting(let error):
                    // `.waiting` here means the port is taken; it would retry forever otherwise.
                    if resumed.claim() { continuation.resume(throwing: error) }
                default:
                    break
                }
            }
            listener.start(queue: queue)
        }
        self.listener = listener
    }

    /// A continuation must be resumed exactly once, and `stateUpdateHandler` can fire repeatedly.
    private final class Resumed: @unchecked Sendable {
        private let lock = NSLock()
        private var done = false
        func claim() -> Bool {
            lock.lock(); defer { lock.unlock() }
            if done { return false }
            done = true
            return true
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
    }

    enum Failure: Error, LocalizedError {
        case message(String)
        var errorDescription: String? { if case .message(let m) = self { m } else { nil } }
    }

    // MARK: - Connections

    private func accept(_ connection: NWConnection) {
        connection.start(queue: queue)
        Task {
            defer { connection.cancel() }
            do {
                let request = try await withTimeout(Limits.readTimeout) {
                    try await Self.readRequest(from: connection)
                }
                let response = await handle(request)
                try await Self.send(response, over: connection)
            } catch {
                // A malformed or timed-out request gets a terse reply and the connection closed.
                // Nothing here is worth telling a caller that failed to speak HTTP.
                try? await Self.send(
                    HTTPResponse(status: 400, json: LocalAPI.Failure(error: "bad request")),
                    over: connection)
            }
        }
    }

    /// Runs `work`, giving up after `limit`. A connection that never finishes sending its headers
    /// would otherwise keep a task alive for as long as the app runs.
    private func withTimeout<T: Sendable>(
        _ limit: Duration, _ work: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await work() }
            group.addTask {
                try await Task.sleep(for: limit)
                throw Failure.message("timed out")
            }
            defer { group.cancelAll() }
            guard let first = try await group.next() else { throw Failure.message("no result") }
            return first
        }
    }

    // MARK: - Routing

    private func handle(_ request: HTTPRequest) async -> HTTPResponse {
        // A browser can be talked into issuing a cross-site request to a loopback port, and DNS
        // rebinding can make a hostile page's origin look local. Neither can set `Origin` to
        // nothing or forge `Host`, so both are checked before the token is even looked at.
        if request.headers["origin"] != nil {
            return HTTPResponse(
                status: 403,
                json: LocalAPI.Failure(error: "cross-origin requests are not accepted"))
        }
        let host = request.headers["host"]?.split(separator: ":").first.map(String.init)
        guard host == "127.0.0.1" || host == "localhost" else {
            return HTTPResponse(status: 403, json: LocalAPI.Failure(error: "unexpected Host"))
        }

        // The scheme is required rather than split off: splitting on a space and taking the last
        // component also accepts a bare `Authorization: <token>`, which is one more shape to have
        // to reason about for no benefit.
        let header = request.headers["authorization"] ?? ""
        let scheme = "Bearer "
        let bearer = header.hasPrefix(scheme) ? String(header.dropFirst(scheme.count)) : ""
        guard LocalAPI.tokensMatch(bearer, token) else {
            return HTTPResponse(
                status: 401, json: LocalAPI.Failure(error: "bad or missing bearer token"))
        }

        do {
            switch (request.method, request.path) {
            case ("GET", "/v1/ping"):
                return HTTPResponse(
                    status: 200,
                    json: LocalAPI.Ping(
                        version: Bundle.main.object(
                            forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?",
                        dataFolder: dataFolderPath))

            case ("GET", "/v1/list"):
                let items = try await runner.list(
                    path: request.query["path"],
                    recursive: request.query["recursive"] != "0")
                return HTTPResponse(status: 200, json: LocalAPI.ListResult(items: items))

            case ("GET", "/v1/detail"):
                guard let path = request.query["path"] else {
                    return HTTPResponse(
                        status: 400, json: LocalAPI.Failure(error: "path is required"))
                }
                return HTTPResponse(status: 200, json: try await runner.detail(path: path))

            case ("POST", "/v1/run"):
                let body = try JSONDecoder().decode(LocalAPI.RunBody.self, from: request.body)
                if let environment = body.environment {
                    _ = try await runner.useEnvironment(named: environment)
                }
                let result = try await runner.run(
                    requestAt: body.path,
                    overrides: body.variables ?? [:],
                    bodyCap: body.bodyCap ?? CommandRunner.defaultBodyCap,
                    captures: body.captures ?? [:])
                return HTTPResponse(status: 200, json: result)

            case ("POST", "/v1/send"):
                let body = try JSONDecoder().decode(LocalAPI.SendBody.self, from: request.body)
                if let environment = body.environment {
                    _ = try await runner.useEnvironment(named: environment)
                }
                var item = RequestItem(
                    name: "", method: HTTPMethod(rawValue: body.method.uppercased()),
                    url: body.url)
                item.headers = body.headers?.map { KeyValue(key: $0.name, value: $0.value) } ?? []
                if let text = body.body, !text.isEmpty {
                    item.body = .raw(text: text, language: .json)
                }
                let result = try await runner.send(
                    item,
                    overrides: body.variables ?? [:],
                    bodyCap: body.bodyCap ?? CommandRunner.defaultBodyCap,
                    captures: body.captures ?? [:])
                return HTTPResponse(status: 200, json: result)

            default:
                return HTTPResponse(status: 404, json: LocalAPI.Failure(error: "no such route"))
            }
        } catch {
            return HTTPResponse(
                status: 422, json: LocalAPI.Failure(error: CommandRunner.message(for: error)))
        }
    }

    // MARK: - A very small amount of HTTP

    private struct HTTPRequest {
        var method: String
        var path: String
        var query: [String: String]
        var headers: [String: String]
        var body: Data
    }

    private struct HTTPResponse {
        var status: Int
        var body: Data

        init<T: Encodable>(status: Int, json: T) {
            self.status = status
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            self.body = (try? encoder.encode(json)) ?? Data("{}".utf8)
        }

        var wireFormat: Data {
            let reason = status == 200 ? "OK" : "Error"
            var head = "HTTP/1.1 \(status) \(reason)\r\n"
            head += "Content-Type: application/json\r\n"
            head += "Content-Length: \(body.count)\r\n"
            // Nothing here is for a browser, and saying so costs one header.
            head += "X-Content-Type-Options: nosniff\r\n"
            head += "Connection: close\r\n\r\n"
            return Data(head.utf8) + body
        }
    }

    /// Reads until the headers are complete, then until `Content-Length` bytes have arrived.
    private static func readRequest(from connection: NWConnection) async throws -> HTTPRequest {
        var buffer = Data()
        var headerEnd: Range<Data.Index>?

        while headerEnd == nil {
            buffer.append(try await receive(from: connection))
            headerEnd = buffer.range(of: Data("\r\n\r\n".utf8))
            guard buffer.count <= Limits.maximumRequestBytes else {
                throw Failure.message("request too large")
            }
        }
        guard let headerEnd else { throw Failure.message("no headers") }

        let head = String(decoding: buffer[..<headerEnd.lowerBound], as: UTF8.self)
        var lines = head.components(separatedBy: "\r\n")
        let requestLine = lines.removeFirst().split(separator: " ")
        guard requestLine.count >= 2 else { throw Failure.message("bad request line") }

        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers[line[..<colon].lowercased()] =
                line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }

        var body = Data(buffer[headerEnd.upperBound...])
        let expected = headers["content-length"].flatMap(Int.init) ?? 0
        guard expected <= Limits.maximumRequestBytes else {
            throw Failure.message("request too large")
        }
        while body.count < expected {
            body.append(try await receive(from: connection))
        }

        let target = String(requestLine[1])
        let parts = target.split(separator: "?", maxSplits: 1)
        var query: [String: String] = [:]
        if parts.count == 2 {
            for pair in parts[1].split(separator: "&") {
                let kv = pair.split(separator: "=", maxSplits: 1)
                guard let name = kv.first else { continue }
                query[String(name).removingPercentEncoding ?? String(name)] =
                    kv.count == 2
                        ? (String(kv[1]).replacingOccurrences(of: "+", with: " ")
                            .removingPercentEncoding ?? String(kv[1]))
                        : ""
            }
        }

        return HTTPRequest(
            method: String(requestLine[0]), path: String(parts[0]),
            query: query, headers: headers, body: body)
    }

    private static func receive(from connection: NWConnection) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) {
                data, _, isComplete, error in
                if let error { continuation.resume(throwing: error); return }
                if let data, !data.isEmpty { continuation.resume(returning: data); return }
                continuation.resume(
                    throwing: isComplete
                        ? Failure.message("connection closed") : Failure.message("empty read"))
            }
        }
    }

    private static func send(_ response: HTTPResponse, over connection: NWConnection) async throws {
        let payload = response.wireFormat
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            connection.send(
                content: payload,
                completion: .contentProcessed { error in
                    if let error { continuation.resume(throwing: error) }
                    else { continuation.resume() }
                })
        }
    }
}
