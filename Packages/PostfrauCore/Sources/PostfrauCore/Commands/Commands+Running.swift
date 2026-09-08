import Foundation

/// What one send produced, as the CLI reports it.
public struct RunResult: Sendable, Codable {
    public var path: String?
    public var name: String
    public var method: String
    public var url: String
    public var status: Int?
    public var reason: String?
    public var durationMs: Double
    public var bytes: Int
    public var headers: [HeaderField]
    /// The body, capped at whatever the caller asked for. Nil when it was not read.
    public var body: String?
    public var bodyTruncated: Bool
    public var error: String?
    /// Values pulled out with `--capture`.
    public var captured: [String: String]
    /// Anything the builder wanted to say: a missing variable, a skipped file.
    public var warnings: [String]

    public var isSuccess: Bool { (status ?? 0) < 400 && error == nil }
}

/// The request as it would go on the wire, for `--dry-run`.
public struct DryRunResult: Sendable, Codable {
    public var method: String
    public var url: String
    public var headers: [HeaderField]
    public var bodyPreview: String?
    public var bodyBytes: Int?
    public var warnings: [String]
    public var unresolvedVariables: [String]
}

extension CommandRunner {
    /// How much of a response body to keep. Bodies can be enormous; the CLI is usually piped into
    /// something that will read all of it, so the cap is explicit rather than assumed.
    public static let defaultBodyCap = 256 * 1024

    // MARK: - Building

    /// Builds a request without sending it.
    public func dryRun(
        requestAt path: String, overrides: [String: String] = [:]
    ) async throws -> DryRunResult {
        let resolved = try await resolve(path)
        guard case .request(let request, _, _) = resolved else {
            throw CommandError.invalid("“\(path)” is a \(resolved.kind), not a request.")
        }
        return try dryRun(request, overrides: overrides, requestID: request.id)
    }

    /// The ad-hoc form: a request that is not in any collection.
    public func dryRun(
        _ request: RequestItem, overrides: [String: String] = [:], requestID: UUID? = nil
    ) throws -> DryRunResult {
        let variableScope = requestID.map { scope(forRequestWithID: $0, overrides: overrides) }
            ?? adHocScope(overrides: overrides)
        let resolver = VariableResolver(scope: variableScope)
        let auth = requestID.map { effectiveAuth(forRequestWithID: $0) } ?? request.auth

        let built: BuiltRequest
        do {
            built = try RequestBuilder().build(request, resolver: resolver, effectiveAuth: auth)
        } catch {
            throw CommandError.invalid(CommandRunner.message(for: error))
        }
        defer { SecurityScopedFile.stopAccessing(built.accessedURLs) }
        built.payload.temporaryFileToClean.map { try? FileManager.default.removeItem(at: $0) }

        var preview: String?
        var bytes: Int?
        if case .data(let data) = built.payload {
            bytes = data.count
            preview = String(decoding: data.prefix(2048), as: UTF8.self)
        }

        return DryRunResult(
            method: request.method.rawValue,
            url: built.resolvedURL,
            // Redacted: a dry run is the thing people paste into a bug report.
            headers: HistoryRedactor.redact(headers: built.allHeaders),
            bodyPreview: preview,
            bodyBytes: bytes,
            warnings: built.warnings,
            unresolvedVariables: resolver.resolve(request.url).unresolved)
    }

    /// The scope for a request that has no home in a collection: the active environment and the
    /// globals, plus whatever `--var` supplied.
    func adHocScope(overrides: [String: String]) -> VariableScope {
        var scope = VariableScope.build(
            environment: loadedWorkspace.activeEnvironment,
            collection: nil,
            folderChain: [],
            globals: loadedWorkspace.globals)
        if !overrides.isEmpty {
            scope.layers.insert(
                VariableLayer(
                    source: .environment(name: "command line"),
                    variables: overrides.sorted { $0.key < $1.key }
                        .map { Variable(key: $0.key, value: $0.value) }),
                at: 0)
        }
        return scope
    }

    // MARK: - Sending

    /// Sends a request stored in a collection.
    public func run(
        requestAt path: String,
        overrides: [String: String] = [:],
        bodyCap: Int = CommandRunner.defaultBodyCap,
        captures: [String: String] = [:],
        captureAsSecret: Bool = false
    ) async throws -> RunResult {
        let workspace = try await load()
        let resolved = try await resolve(path)
        guard case .request(let request, _, _) = resolved else {
            throw CommandError.invalid("“\(path)” is a \(resolved.kind), not a request.")
        }
        return try await send(
            request,
            path: ItemResolver.path(toItemWithID: request.id, in: workspace)?.description,
            requestID: request.id, overrides: overrides, bodyCap: bodyCap,
            captures: captures, captureAsSecret: captureAsSecret)
    }

    /// Sends every request under a folder or collection, in order.
    ///
    /// - Parameter stopOnError: stop at the first failure rather than carrying on. Off by default
    ///   because the usual reason to run a folder is to see everything that is broken at once.
    public func runAll(
        under path: String,
        overrides: [String: String] = [:],
        bodyCap: Int = CommandRunner.defaultBodyCap,
        stopOnError: Bool = false,
        captures: [String: String] = [:],
        captureAsSecret: Bool = false,
        onResult: (@Sendable (RunResult) -> Void)? = nil
    ) async throws -> [RunResult] {
        let workspace = try await load()
        let resolved = try await resolve(path)

        let requests: [RequestItem]
        switch resolved {
        case .request(let request, _, _): requests = [request]
        case .collection(let collection): requests = collection.allRequests().map(\.request)
        case .folder(let folder, _): requests = Self.requests(in: folder.items)
        }
        guard !requests.isEmpty else {
            throw CommandError.notFound("Nothing to run under “\(path)”.")
        }

        var results: [RunResult] = []
        var running = overrides
        for request in requests {
            let result = try await send(
                request,
                path: ItemResolver.path(toItemWithID: request.id, in: workspace)?.description,
                requestID: request.id, overrides: running, bodyCap: bodyCap,
                captures: captures, captureAsSecret: captureAsSecret)
            results.append(result)
            onResult?(result)
            // A capture from one request is available to the next — which is the whole point of
            // running a folder: log in, then call the endpoint that needs the token.
            running.merge(result.captured) { _, new in new }
            if stopOnError && !result.isSuccess { break }
        }
        return results
    }

    /// The one-off form: `postfrau send GET https://…`.
    public func send(
        _ request: RequestItem,
        path: String? = nil,
        requestID: UUID? = nil,
        overrides: [String: String] = [:],
        bodyCap: Int = CommandRunner.defaultBodyCap,
        captures: [String: String] = [:],
        captureAsSecret: Bool = false
    ) async throws -> RunResult {
        _ = try await load()
        let variableScope = requestID.map { scope(forRequestWithID: $0, overrides: overrides) }
            ?? adHocScope(overrides: overrides)
        let resolver = VariableResolver(scope: variableScope)
        let auth = requestID.map { effectiveAuth(forRequestWithID: $0) } ?? request.auth
        let secretValues = HistoryRecorder.secrets(
            in: variableScope, auth: auth, resolver: resolver)

        let started = Date()
        var built: BuiltRequest
        do {
            built = try RequestBuilder().build(request, resolver: resolver, effectiveAuth: auth)
        } catch {
            let failure = RunResult(
                path: path, name: request.name, method: request.method.rawValue,
                url: request.url, status: nil, reason: nil, durationMs: 0, bytes: 0,
                headers: [], body: nil, bodyTruncated: false,
                error: CommandRunner.message(for: error), captured: [:], warnings: [])
            await record(failure, request: request, resolvedURL: request.url,
                         built: nil, response: nil, secrets: secretValues, startedAt: started)
            return failure
        }
        defer { SecurityScopedFile.stopAccessing(built.accessedURLs) }

        // The transport's own do/catch ends here, before captures: a `--capture` that matches
        // nothing is the caller's mistake, not a failed request, and folding it into `result.error`
        // would report a 200 as a connection failure and send them looking in the wrong place.
        var result: RunResult
        var response: HTTPResponse?
        var data = Data()

        do {
            let received = try await executor.send(built, settings: request.settings)
            response = received
            data = (try? received.body.prefix(bodyCap)) ?? Data()
            result = RunResult(
                path: path, name: request.name, method: request.method.rawValue,
                url: built.resolvedURL, status: received.statusCode,
                reason: received.reasonPhrase,
                durationMs: received.timing.totalMilliseconds, bytes: received.byteCount,
                headers: received.headers, body: String(decoding: data, as: UTF8.self),
                bodyTruncated: received.byteCount > data.count,
                error: nil, captured: [:], warnings: built.warnings)
        } catch {
            result = RunResult(
                path: path, name: request.name, method: request.method.rawValue,
                url: built.resolvedURL, status: nil, reason: nil,
                durationMs: Date().timeIntervalSince(started) * 1000, bytes: 0,
                headers: [], body: nil, bodyTruncated: false,
                error: CommandRunner.message(for: error), captured: [:],
                warnings: built.warnings)
        }

        // Whatever happened is history before anything else can go wrong.
        await record(result, request: request, resolvedURL: built.resolvedURL,
                     built: built, response: response, secrets: secretValues, startedAt: started)
        response?.body.discardTemporaryFile()

        if !captures.isEmpty, result.error == nil {
            result.captured = try await capture(
                captures, from: data, asSecret: captureAsSecret,
                truncatedForCapture: result.bodyTruncated)
        }
        return result
    }

    // MARK: - Capture

    /// Pulls values out of a JSON response and stores them in the active environment.
    ///
    /// This is what makes `run --all` useful: log in, capture the token, and the next request in
    /// the folder can use it.
    func capture(
        _ expressions: [String: String], from data: Data, asSecret: Bool,
        truncatedForCapture: Bool = false
    ) async throws -> [String: String] {
        guard let root = try? Postfrau.makeDecoder().decode(JSONValue.self, from: data) else {
            // The commonest cause is a body cut short by `--max-body`, which leaves valid JSON
            // looking like a syntax error. Say which it is rather than making them guess.
            throw CommandError.invalid(
                truncatedForCapture
                    ? "The response was cut short by --max-body (\(data.count) bytes read), "
                        + "so it could not be parsed as JSON. Raise the limit to capture from it."
                    : "The response is not JSON, so nothing could be captured.")
        }

        var captured: [String: String] = [:]
        for (name, expression) in expressions.sorted(by: { $0.key < $1.key }) {
            guard let value = JSONPath.evaluate(expression, on: root) else {
                throw CommandError.notFound(
                    "“\(expression)” matched nothing in the response.")
            }
            captured[name] = value
        }

        let workspace = try await load()
        guard let active = workspace.activeEnvironment else {
            throw CommandError.invalid(
                "Captured values are stored in the active environment, and there is none. "
                    + "`postfrau env use <name>` first.")
        }
        // Not `try?`: a capture that could not be stored — most often a secret when the Keychain
        // is off limits — has to say so, or the next request fails with an empty variable and no
        // explanation.
        for (name, value) in captured {
            _ = try await setVariable(
                name, to: value, inEnvironmentNamed: active.name, isSecret: asSecret)
        }
        return captured
    }

    // MARK: - History

    private func record(
        _ result: RunResult,
        request: RequestItem,
        resolvedURL: String,
        built: BuiltRequest?,
        response: HTTPResponse?,
        secrets: Set<String>,
        startedAt: Date
    ) async {
        let settings = (try? await currentSettings()) ?? AppSettings()
        let policy = HistoryRecorder.Policy(
            level: recordLevel ?? settings.historyRecording,
            secrets: secrets,
            bodyCap: settings.historyBodyCapBytes,
            source: source)

        guard let entry = await HistoryRecorder.entry(
            for: HistoryRecorder.Exchange(
                request: request, resolvedURL: resolvedURL, built: built,
                response: response, error: result.error, startedAt: startedAt),
            policy: policy)
        else { return }
        try? await history.append(entry)
    }

    // MARK: - Helpers

    static func requests(in items: [CollectionItem]) -> [RequestItem] {
        items.flatMap { item -> [RequestItem] in
            switch item {
            case .request(let request): [request]
            case .folder(let folder): requests(in: folder.items)
            }
        }
    }

    /// The sentence to show for an error. Used by the CLI as well as the app.
    public nonisolated static func message(for error: any Error) -> String {
        (error as? any LocalizedError)?.errorDescription ?? error.localizedDescription
    }
}
