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
        if let problem = conflict(in: arguments) {
            out.error(problem)
            return .usage
        }
        let patch = try patch(from: arguments)

        if let batch = try Batch(arguments) {
            return try await batch.run(arguments, overrides: overrides, patch: patch, out) {
                variables, patch, dryRun in
                if dryRun {
                    return .dry(try await runner.dryRun(
                        requestAt: path, overrides: variables, patch: patch))
                }
                return .sent(try await runner.run(
                    requestAt: path, overrides: variables, bodyCap: cap,
                    captures: captures, captureAsSecret: arguments.has("--secret"),
                    patch: patch))
            }
        }

        if arguments.has("--dry-run") {
            let dry = try await runner.dryRun(requestAt: path, overrides: overrides, patch: patch)
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
                patch: patch, onResult: stream)

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
            captures: captures, captureAsSecret: arguments.has("--secret"), patch: patch)
        return finish(result, arguments, out)
    }

    // MARK: - Changing a saved request for one run

    /// `--body`, `--field` and `-H` on `run`: what to change about the saved request, this once.
    /// Shared with `RemoteAPI`, which sends the same patch to the app.
    static func patch(from arguments: Arguments) throws -> RequestPatch {
        RequestPatch(
            body: try Edit.readBodyText(arguments),
            fields: arguments.pairs("--field").map { .init(path: $0.key, value: $0.value) },
            headers: arguments.colonPairs("--header", "-H")
                .map { HeaderField(name: $0.key, value: $0.value) })
    }

    /// Combinations that cannot mean what they say. Checked before anything is read or sent.
    static func conflict(in arguments: Arguments) -> String? {
        let changesBody = arguments.value("--body", "-d") != nil || !arguments.pairs("--field").isEmpty
        if arguments.has("--all"), changesBody {
            return "--body and --field apply to one request; with --all every request in the "
                + "folder would get the same body. Run the request by its path instead."
        }
        if arguments.has("--all"), arguments.value("--from-file") != nil {
            return "--from-file runs one request per line; it cannot be combined with --all."
        }
        if arguments.value("--from-file") == "-", arguments.value("--body", "-d") == "-" {
            return "--from-file - and --body - cannot both read standard input."
        }
        if arguments.value("--from-file") != nil, arguments.value("--each") == nil {
            return "--from-file needs --each NAME: the variable each line is stored in, as in "
                + "`--from-file banks.txt --each bank --field partner_bank_id={{bank}}`."
        }
        return nil
    }

    // MARK: - One request per line

    /// `run <path> --from-file banks.txt --each bank`: the same saved request, once per line,
    /// in order, each with its own correlation id.
    struct Batch {
        var inputs: [String]
        var variable: String
        var correlationHeader: String?

        /// The name a saved request can use, `{{correlation_id}}`, to put the id wherever its
        /// API expects one. `--correlation-header` is the shortcut for the common case.
        static let correlationVariable = "correlation_id"

        enum Outcome {
            case sent(RunResult)
            case dry(DryRunResult)
        }

        /// Nil when `--from-file` was not given.
        init?(_ arguments: Arguments) throws {
            guard let file = arguments.value("--from-file") else { return nil }
            let text: String
            if file == "-" {
                text = String(
                    decoding: FileHandle.standardInput.readDataToEndOfFile(), as: UTF8.self)
            } else {
                do {
                    text = try String(contentsOf: URL(filePath: file), encoding: .utf8)
                } catch {
                    throw CommandRunner.CommandError.invalid(
                        "cannot read \(file): \(CommandRunner.message(for: error))")
                }
            }
            // Blank lines and `#` comments are skipped, so a list can be annotated.
            inputs = text.split(whereSeparator: \.isNewline)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty && !$0.hasPrefix("#") }
            guard !inputs.isEmpty else {
                throw CommandRunner.CommandError.invalid("\(file) has no lines to run.")
            }
            variable = arguments.value("--each") ?? ""
            correlationHeader = arguments.value("--correlation-header")
        }

        /// Runs every line through `perform`. With `--json`, one NDJSON line per send, as it
        /// lands, each carrying `input` and `correlationId`.
        func run(
            _ arguments: Arguments,
            overrides: [String: String],
            patch: RequestPatch,
            _ out: Output,
            perform: ([String: String], RequestPatch, Bool) async throws -> Outcome
        ) async throws -> ExitCode {
            let dryRun = arguments.has("--dry-run")
            let width = inputs.map(Output.displayWidth).max() ?? 0
            var failures: [RunResult] = []

            for input in inputs {
                let id = UUID().uuidString.lowercased()
                var variables = overrides
                variables[variable] = input
                // A `--var correlation_id=…` is the caller's to keep.
                if variables[Self.correlationVariable] == nil {
                    variables[Self.correlationVariable] = id
                }
                var patch = patch
                if let correlationHeader {
                    patch.headers.append(HeaderField(name: correlationHeader, value: id))
                }

                switch try await perform(variables, patch, dryRun) {
                case .dry(let dry):
                    if out.isJSON {
                        out.ndjson(Labelled(input: input, correlationId: id, dryRun: dry))
                    } else {
                        out.print(out.bold("# \(variable)=\(input)") + out.dim("  \(id)"))
                        Run.report(dry, out)
                        out.print("")
                    }
                case .sent(var result):
                    result.input = input
                    result.correlationId = id
                    if out.isJSON {
                        out.ndjson(result)
                    } else {
                        let padding = String(
                            repeating: " ", count: max(0, width - Output.displayWidth(input)))
                        out.print([
                            out.status(result.status), input + padding,
                            out.dim(ByteCount.formatDuration(milliseconds: result.durationMs)),
                            out.dim(id),
                        ].joined(separator: "  "))
                        if let error = result.error { out.error(error) }
                    }
                    if !result.isSuccess {
                        failures.append(result)
                        if arguments.has("--stop-on-error") { break }
                    }
                }
            }

            if arguments.has("--fail"), !failures.isEmpty {
                return failures.contains { $0.error != nil } ? .transport : .httpFailure
            }
            return .ok
        }

        /// A dry run in a batch, with the line it was built for.
        private struct Labelled: Encodable {
            var input: String
            var correlationId: String
            var dryRun: DryRunResult
        }
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
                out.print(out.dim("… truncated"))
            }
        }
        // Always said, so an override that did not take is visible: the line names where the
        // body came from, not just what it is.
        if let bytes = dry.bodyBytes, bytes > 0 || dry.bodyOrigin != nil {
            out.print("")
            out.print(out.dim(
                "body: \(bytes) bytes"
                    + (bytes >= 1024 ? " (\(ByteCount.format(bytes)))" : "")
                    + ", \(dry.bodyOrigin.map { "from \($0)" } ?? "as saved")"))
        }
        for warning in dry.warnings { out.warning(warning) }
        if !dry.unresolvedVariables.isEmpty {
            out.warning("unresolved: \(dry.unresolvedVariables.joined(separator: ", "))")
        }
    }
}
