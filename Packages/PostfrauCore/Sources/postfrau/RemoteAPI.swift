import Foundation
import PostfrauCore

/// Talking to a running Postfrau instead of to the filesystem.
///
/// Set `POSTFRAU_API_TOKEN` and the CLI stops looking for a data folder altogether: it asks the
/// app, which is the process that actually holds the bookmark to it. That is the only way an
/// agent in a sandbox that denies the workspace can list, find and send — no `--data-dir` helps
/// when the folder itself is unreadable. See `docs/decisions.md` D48.
///
/// Only the verbs that make sense down a socket are offered. Editing a workspace, importing and
/// exporting all want a real folder, and saying so is better than half-working.
enum RemoteAPI {
    struct Endpoint {
        var url: URL
        var token: String
    }

    /// The verbs that work remotely. Anything else gets told plainly that it does not.
    static let supportedVerbs: Set<String> = ["ls", "find", "get", "run", "send", "version"]

    static func fromEnvironment() -> Endpoint? {
        let environment = ProcessInfo.processInfo.environment
        guard let token = environment[LocalAPI.tokenVariable], !token.isEmpty else { return nil }
        let text = environment[LocalAPI.urlVariable]
            ?? LocalAPI.defaultURL(port: LocalAPI.defaultPort)
        guard let url = URL(string: text) else { return nil }
        return Endpoint(url: url, token: token)
    }

    /// Runs one command against the app. Returns the exit code the CLI should use.
    static func run(
        verb: String, _ arguments: Arguments, _ endpoint: Endpoint, _ out: Output
    ) async -> ExitCode {
        guard supportedVerbs.contains(verb) else {
            out.error(
                "`\(verb)` needs a data folder, and \(LocalAPI.tokenVariable) is set, so this "
                    + "command is talking to the app instead. Remotely you can: "
                    + supportedVerbs.sorted().joined(separator: ", ") + ".")
            return .usage
        }

        do {
            switch verb {
            case "version":
                let ping: LocalAPI.Ping = try await get("/v1/ping", [:], endpoint)
                out.print("postfrau (via the app at \(endpoint.url.absoluteString))")
                out.print("app          \(ping.version)")
                out.print("data folder  \(ping.dataFolder)")
                return .ok

            case "ls":
                var query = ["recursive": arguments.has("--tree") ? "1" : "0"]
                if let path = arguments.positional(0) { query["path"] = path }
                let result: LocalAPI.ListResult = try await get("/v1/list", query, endpoint)
                return Browse.render(result.items, arguments, out)

            case "find":
                let terms = arguments.positional.joined(separator: " ")
                guard !terms.isEmpty else {
                    out.error(
                        "find needs something to look for: `postfrau find projection recovery`")
                    return .usage
                }
                let query = [
                    "q": terms, "limit": arguments.value("--limit") ?? "20",
                ]
                let result: LocalAPI.FindResult = try await get("/v1/find", query, endpoint)
                return Browse.render(result.items, out)

            case "get":
                guard let path = arguments.positional(0) else {
                    out.error("get needs a path. Try `postfrau ls` to see what is there.")
                    return .usage
                }
                let detail: RequestDetail = try await get("/v1/detail", ["path": path], endpoint)
                return Browse.render(detail, out)

            case "run":
                guard let path = arguments.positional(0) else {
                    out.error("run needs a path to a saved request.")
                    return .usage
                }
                let body = LocalAPI.RunBody(
                    path: path,
                    environment: arguments.value("--env"),
                    variables: pairs(arguments, "--var"),
                    captures: pairs(arguments, "--capture"),
                    bodyCap: arguments.value("--max-body").flatMap { Arguments.byteCount($0) },
                    dryRun: arguments.has("--dry-run"))
                if arguments.has("--dry-run") {
                    let dry: DryRunResult = try await post("/v1/run", body, endpoint)
                    Run.report(dry, out)
                    return .ok
                }
                let result: RunResult = try await post("/v1/run", body, endpoint)
                return Run.finish(result, arguments, out)

            case "send":
                guard let method = arguments.positional(0),
                      let url = arguments.positional(1)
                else {
                    out.error("send needs a method and a URL: `postfrau send GET https://…`")
                    return .usage
                }
                let body = LocalAPI.SendBody(
                    method: method, url: url,
                    headers: arguments.colonPairs("--header", "-H")
                        .map { HeaderField(name: $0.0, value: $0.1) },
                    body: arguments.value("--body") ?? arguments.value("-d"),
                    environment: arguments.value("--env"),
                    variables: pairs(arguments, "--var"),
                    captures: pairs(arguments, "--capture"),
                    bodyCap: arguments.value("--max-body").flatMap { Arguments.byteCount($0) },
                    dryRun: arguments.has("--dry-run"))
                if arguments.has("--dry-run") {
                    let dry: DryRunResult = try await post("/v1/send", body, endpoint)
                    Run.report(dry, out)
                    return .ok
                }
                let result: RunResult = try await post("/v1/send", body, endpoint)
                return Run.finish(result, arguments, out)

            default:
                return .usage
            }
        } catch let error as Failure {
            out.error(error.message)
            return error.code
        } catch {
            out.error(error.localizedDescription)
            return .transport
        }
    }

    // MARK: - Transport

    private struct Failure: Error {
        var message: String
        var code: ExitCode
    }

    private static func pairs(_ arguments: Arguments, _ flag: String) -> [String: String]? {
        let found = Dictionary(arguments.pairs(flag), uniquingKeysWith: { _, new in new })
        return found.isEmpty ? nil : found
    }

    private static func get<T: Decodable>(
        _ path: String, _ query: [String: String], _ endpoint: Endpoint
    ) async throws -> T {
        var components = URLComponents(
            url: endpoint.url.appending(path: path), resolvingAgainstBaseURL: false)
        components?.queryItems = query.isEmpty
            ? nil : query.map { URLQueryItem(name: $0.key, value: $0.value) }
        guard let url = components?.url else {
            throw Failure(message: "\(endpoint.url) is not a usable address.", code: .usage)
        }
        return try await send(URLRequest(url: url), endpoint)
    }

    private static func post<Body: Encodable, T: Decodable>(
        _ path: String, _ body: Body, _ endpoint: Endpoint
    ) async throws -> T {
        var request = URLRequest(url: endpoint.url.appending(path: path))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(body)
        return try await send(request, endpoint)
    }

    private static func send<T: Decodable>(
        _ request: URLRequest, _ endpoint: Endpoint
    ) async throws -> T {
        var request = request
        request.setValue("Bearer \(endpoint.token)", forHTTPHeaderField: "Authorization")
        // No timeout beyond the request's own: a `run` here is a real HTTP call being made by the
        // app on our behalf, and it takes as long as that endpoint takes.
        request.timeoutInterval = 600

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw Failure(
                message: "cannot reach Postfrau at \(endpoint.url.absoluteString) — is the app "
                    + "running, with Settings ▸ Advanced ▸ Local API switched on? (\(error.localizedDescription))",
                code: .dataFolderUnavailable)
        }

        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            let detail = (try? JSONDecoder().decode(LocalAPI.Failure.self, from: data))?.error
                ?? "HTTP \(status)"
            throw Failure(
                message: detail, code: status == 401 ? .usage : .dataFolderUnavailable)
        }
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw Failure(message: "the app sent something unreadable back.", code: .transport)
        }
    }
}
