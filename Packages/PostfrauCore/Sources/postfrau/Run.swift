import Foundation
import PostfrauCore

/// `run` and `send` — the commands that actually talk to a server.
enum Run {
    static func run(
        _ arguments: Arguments, _ runner: CommandRunner, _ out: Output
    ) async throws -> ExitCode {
        guard let path = arguments.positional(0) else {
            out.error("run needs a path. Try `postfrau ls --tree`.")
            return .usage
        }

        let overrides = Dictionary(arguments.pairs("--var"), uniquingKeysWith: { _, new in new })
        let captures = Dictionary(arguments.pairs("--capture"), uniquingKeysWith: { _, new in new })
        let cap: Int = arguments.value("--max-body").flatMap { Arguments.byteCount($0) }
            ?? CommandRunner.defaultBodyCap

        if arguments.has("--dry-run") {
            let dry = try await runner.dryRun(requestAt: path, overrides: overrides)
            report(dry, out)
            return .ok
        }

        if arguments.has("--all") {
            // NDJSON as each result lands, so a long folder can be watched rather than waited on.
            // Written as an `if` because a ternary producing an optional closure defeats the
            // type checker here.
            var stream: (@Sendable (RunResult) -> Void)?
            if out.isJSON {
                stream = { result in out.ndjson(result) }
            }
            let results = try await runner.runAll(
                under: path, overrides: overrides, bodyCap: cap,
                stopOnError: arguments.has("--stop-on-error"),
                captures: captures, captureAsSecret: arguments.has("--secret"),
                onResult: stream)

            if !out.isJSON {
                out.table(results.map { result in
                    [out.status(result.status), out.method(result.method), result.name,
                     out.dim(ByteCount.formatDuration(milliseconds: result.durationMs))]
                })
            }
            let failed = results.filter { !$0.isSuccess }
            if arguments.has("--fail"), !failed.isEmpty {
                return failed.contains { $0.error != nil } ? .transport : .httpFailure
            }
            return .ok
        }

        let result = try await runner.run(
            requestAt: path, overrides: overrides, bodyCap: cap,
            captures: captures, captureAsSecret: arguments.has("--secret"))
        return finish(result, arguments, out)
    }

    // MARK: - send

    static func send(
        _ arguments: Arguments, _ runner: CommandRunner, _ out: Output
    ) async throws -> ExitCode {
        guard let method = arguments.positional(0), let url = arguments.positional(1) else {
            out.error("send needs a method and a URL: `postfrau send GET https://…`")
            return .usage
        }

        var request = RequestItem(name: "", method: HTTPMethod(rawValue: method.uppercased()), url: url)
        Edit.apply(arguments, to: &request)

        let overrides = Dictionary(arguments.pairs("--var"), uniquingKeysWith: { _, new in new })
        let captures = Dictionary(arguments.pairs("--capture"), uniquingKeysWith: { _, new in new })
        let cap: Int = arguments.value("--max-body").flatMap { Arguments.byteCount($0) }
            ?? CommandRunner.defaultBodyCap

        if arguments.has("--dry-run") {
            report(try await runner.dryRun(request, overrides: overrides), out)
            return .ok
        }

        let result = try await runner.send(
            request, overrides: overrides, bodyCap: cap,
            captures: captures, captureAsSecret: arguments.has("--secret"))

        // `--save-to` turns a one-off into something worth keeping.
        if let destination = arguments.value("--save-to") {
            if request.name.isEmpty { request.name = arguments.value("--name") ?? "" }
            let saved = try await runner.addRequest(request, toFolderAt: destination)
            if !out.isJSON { out.print(out.dim("saved as \(saved.path)")) }
        }
        return finish(result, arguments, out)
    }

    // MARK: - Reporting

    /// Not private: the loopback API path in `RemoteAPI` reports a result the same way, so that
    /// `postfrau run` prints and exits identically whether the workspace was read here or by the
    /// app on the other end of a socket.
    static func finish(
        _ result: RunResult, _ arguments: Arguments, _ out: Output
    ) -> ExitCode {
        if let path = arguments.value("--out"), let body = result.body {
            try? Data(body.utf8).write(to: URL(filePath: path))
        }

        if out.isJSON {
            out.json(result)
        } else {
            report(
                result, out, writesBody: arguments.value("--out") == nil,
                masksCaptures: arguments.has("--secret"))
        }

        if let error = result.error {
            if !out.isJSON { out.error(error) }
            return .transport
        }
        if arguments.has("--fail"), (result.status ?? 0) >= 400 { return .httpFailure }
        return .ok
    }

    private static func report(
        _ result: RunResult, _ out: Output, writesBody: Bool, masksCaptures: Bool = false
    ) {
        let summary = [
            out.status(result.status),
            result.reason ?? "",
            out.dim(ByteCount.formatDuration(milliseconds: result.durationMs)),
            out.dim(ByteCount.format(result.bytes)),
        ].filter { !$0.isEmpty }.joined(separator: "  ")
        out.print(summary)

        for warning in result.warnings { out.warning(warning) }

        if !result.captured.isEmpty {
            for (name, value) in result.captured.sorted(by: { $0.key < $1.key }) {
                // Only a value stored as a secret is masked; masking an ordinary one would hide
                // the very thing the caller asked to see.
                out.print(out.dim("captured \(name)=") + (masksCaptures ? out.secret(value) : value))
            }
        }

        guard writesBody, let body = result.body, !body.isEmpty else { return }
        out.print("")
        out.print(body)
        if result.bodyTruncated {
            out.print(out.dim("… truncated; use --max-body to raise the limit"))
        }
    }

    /// Shared with `RemoteAPI`, so a dry run reads the same whether the workspace is on this
    /// disk or behind the app.
    static func report(_ dry: DryRunResult, _ out: Output) {
        if out.isJSON {
            out.json(dry)
            return
        }
        out.print("\(out.method(dry.method)) \(dry.url)")
        for header in dry.headers {
            out.print("  \(header.name): \(header.value)")
        }
        if let preview = dry.bodyPreview, !preview.isEmpty {
            out.print("")
            out.print(preview)
            if let bytes = dry.bodyBytes, bytes > preview.utf8.count {
                out.print(out.dim("… \(ByteCount.format(bytes)) in total"))
            }
        }
        for warning in dry.warnings { out.warning(warning) }
        if !dry.unresolvedVariables.isEmpty {
            out.warning("unresolved: \(dry.unresolvedVariables.joined(separator: ", "))")
        }
    }
}
