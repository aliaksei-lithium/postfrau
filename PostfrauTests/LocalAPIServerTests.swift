import Foundation
import Testing
@testable import Postfrau
import PostfrauCore

/// The loopback API, end to end: a real listener, real sockets, real HTTP.
///
/// The guards are the point. A token check that lets an empty token through, or a listener that
/// quietly binds every interface, are both failures nobody would notice from the outside until it
/// mattered — so they are asserted here rather than reasoned about.
@Suite("Local API server", .serialized)
struct LocalAPIServerTests {
    /// A port unlikely to collide with anything else on the machine running the tests.
    private static func freePort() -> UInt16 { UInt16.random(in: 42_000...48_000) }

    private func makeServer(port: UInt16, token: String) -> (LocalAPIServer, URL) {
        let root = URL.temporaryDirectory.appending(path: "api-\(UUID().uuidString)")
        let folder = DataFolder(root: root.appending(path: "Data"), needsCoordination: false)
        let store = WorkspaceStore(dataFolder: folder, localRoot: root)
        let server = LocalAPIServer(
            port: port, token: token,
            runner: CommandRunner(
                store: store, history: HistoryStore(root: root.appending(path: "history"))),
            dataFolderPath: folder.root.path)
        return (server, root)
    }

    /// Runs `body` against a started server, then always stops it.
    private func withServer(
        token: String = LocalAPI.makeToken(),
        _ body: (URL, String) async throws -> Void
    ) async throws {
        let port = Self.freePort()
        let (server, root) = makeServer(port: port, token: token)
        defer { try? FileManager.default.removeItem(at: root) }
        do {
            try await server.start()
        } catch {
            // A machine that will not let a test bind a socket cannot exercise any of this, and
            // failing here would say the feature is broken when the sandbox is simply closed.
            withKnownIssue("this environment does not allow listening sockets") { throw error }
            return
        }
        defer { Task { await server.stop() } }
        try await body(URL(string: LocalAPI.defaultURL(port: Int(port)))!, token)
    }

    private func status(
        _ url: URL, _ headers: [String: String], method: String = "GET", body: Data? = nil
    ) async throws -> (code: Int, data: Data) {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.httpBody = body
        request.timeoutInterval = 10
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        let (data, response) = try await URLSession.shared.data(for: request)
        return ((response as? HTTPURLResponse)?.statusCode ?? 0, data)
    }

    /// A dry run must not reach the network, whichever side of the socket it is asked from.
    ///
    /// It used to. `--dry-run` was implemented only in the tool's local path, and the flag was
    /// simply not on the wire — so a caller working through the app, which is a caller in a
    /// sandbox, silently sent the request it was asking about. The skill tells agents to dry-run
    /// before anything pointed at production, so the instruction did the opposite of its purpose.
    @Test func aDryRunOverTheAPIDoesNotSend() async throws {
        try await withServer { url, token in
            // Points at a port with nothing on it: if this ever sends, it fails rather than
            // quietly succeeding somewhere real.
            let unreachable = "http://127.0.0.1:9/never"
            let body = try JSONEncoder().encode(
                LocalAPI.SendBody(method: "GET", url: unreachable, dryRun: true))
            let (code, data) = try await status(
                url.appending(path: "/v1/send"),
                ["Authorization": "Bearer \(token)"], method: "POST", body: body)

            #expect(code == 200)
            // A dry run answers with what *would* be sent…
            let dry = try JSONDecoder().decode(DryRunResult.self, from: data)
            #expect(dry.method == "GET")
            #expect(dry.url == unreachable)
            // …and nothing that only a real send could produce.
            #expect((try? JSONDecoder().decode(RunResult.self, from: data)) == nil)
        }
    }

    @Test func aGoodTokenGetsAnAnswer() async throws {
        try await withServer { base, token in
            let (code, data) = try await status(
                base.appending(path: "/v1/ping"), ["Authorization": "Bearer \(token)"])
            #expect(code == 200)
            let ping = try JSONDecoder().decode(LocalAPI.Ping.self, from: data)
            #expect(!ping.dataFolder.isEmpty)
        }
    }

    @Test func everyWayOfNotHavingTheTokenIsRefused() async throws {
        try await withServer { base, token in
            let url = base.appending(path: "/v1/ping")
            // Hoisted out of `#expect`: the macro cannot absorb a `try` for us.
            let none = try await status(url, [:]).code
            let wrong = try await status(url, ["Authorization": "Bearer wrong"]).code
            let empty = try await status(url, ["Authorization": ""]).code
            let bearerOnly = try await status(url, ["Authorization": "Bearer "]).code
            // Right token, wrong scheme.
            let schemeless = try await status(url, ["Authorization": token]).code
            #expect(none == 401)
            #expect(wrong == 401)
            #expect(empty == 401)
            #expect(bearerOnly == 401)
            #expect(schemeless == 401)
        }
    }

    /// A page in a browser can be made to POST at a loopback port, and DNS rebinding can make a
    /// hostile origin resolve to 127.0.0.1. Neither can suppress `Origin` or forge `Host`.
    @Test func browserShapedRequestsAreRefusedEvenWithTheToken() async throws {
        try await withServer { base, token in
            let url = base.appending(path: "/v1/ping")
            let authorized = ["Authorization": "Bearer \(token)"]
            let withOrigin = try await status(
                url, authorized.merging(["Origin": "https://evil.test"]) { _, b in b }).code
            let withHost = try await status(
                url, authorized.merging(["Host": "evil.test"]) { _, b in b }).code
            #expect(withOrigin == 403)
            #expect(withHost == 403)
        }
    }

    @Test func anUnknownRouteIs404() async throws {
        try await withServer { base, token in
            let (code, _) = try await status(
                base.appending(path: "/v1/nope"), ["Authorization": "Bearer \(token)"])
            #expect(code == 404)
        }
    }

    /// Bound to loopback, not to every interface — otherwise "only local processes can reach it"
    /// stops being true the moment the Mac joins a network.
    @Test func theListenerIsNotReachableFromANonLoopbackAddress() async throws {
        let port = Self.freePort()
        let (server, root) = makeServer(port: port, token: LocalAPI.makeToken())
        defer { try? FileManager.default.removeItem(at: root) }
        do { try await server.start() } catch {
            withKnownIssue("this environment does not allow listening sockets") { throw error }
            return
        }
        defer { Task { await server.stop() } }

        // The machine's own LAN address, if it has one. Nothing to check when it does not.
        guard let address = Self.primaryIPv4Address() else { return }
        var request = URLRequest(url: URL(string: "http://\(address):\(port)/v1/ping")!)
        request.timeoutInterval = 3
        await #expect(throws: (any Error).self) {
            _ = try await URLSession.shared.data(for: request)
        }
    }

    private static func primaryIPv4Address() -> String? {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return nil }
        defer { freeifaddrs(head) }
        for pointer in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let interface = pointer.pointee
            guard interface.ifa_addr.pointee.sa_family == UInt8(AF_INET),
                  let name = String(cString: interface.ifa_name, encoding: .utf8),
                  name.hasPrefix("en")
            else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(
                interface.ifa_addr, socklen_t(interface.ifa_addr.pointee.sa_len),
                &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0
            else { continue }
            return String(decoding: host.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) },
                          as: UTF8.self)
        }
        return nil
    }
}
