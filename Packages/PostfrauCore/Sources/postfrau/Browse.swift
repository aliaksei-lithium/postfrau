import Foundation
import PostfrauCore

/// `ls` and `get` — looking without touching.
enum Browse {
    static func list(
        _ arguments: Arguments, _ runner: CommandRunner, _ out: Output
    ) async throws -> ExitCode {
        let path = arguments.positional(0)
        let rows = try await runner.list(path: path, recursive: arguments.has("--tree"))
        return render(rows, arguments, out)
    }

    /// Printing, split from fetching so the loopback API renders exactly what a local run does.
    static func render(_ rows: [ListedItem], _ arguments: Arguments, _ out: Output) -> ExitCode {
        if out.isJSON {
            out.json(rows)
            return .ok
        }
        guard !rows.isEmpty else {
            out.print("nothing here")
            return .ok
        }

        if arguments.has("--tree") {
            for row in rows {
                let indent = String(repeating: "  ", count: row.depth)
                let label = row.kind == "folder"
                    ? out.bold(row.name) + "/"
                    : "\(out.method(row.method ?? "")) \(row.name)"
                out.print("\(indent)\(label)")
            }
            return .ok
        }

        out.table(rows.map { row in
            row.kind == "request"
                ? [out.method(row.method ?? ""), row.name, out.dim(row.url ?? "")]
                : ["", out.bold(row.name) + "/", ""]
        })
        return .ok
    }

    static func get(
        _ arguments: Arguments, _ runner: CommandRunner, _ out: Output
    ) async throws -> ExitCode {
        guard let path = arguments.positional(0) else {
            out.error("get needs a path. Try `postfrau ls` to see what is there.")
            return .usage
        }
        let overrides = Dictionary(
            arguments.pairs("--var"), uniquingKeysWith: { _, new in new })
        return render(try await runner.detail(path: path, overrides: overrides), out)
    }

    /// Printing, split from fetching, for the same reason as `render(_:_:_:)` above.
    static func render(_ detail: RequestDetail, _ out: Output) -> ExitCode {
        if out.isJSON {
            out.json(detail)
            return .ok
        }

        out.print("\(out.method(detail.method)) \(out.bold(detail.name))")
        out.print(out.dim(detail.path))
        out.print("")
        out.print("url        \(detail.url)")
        if detail.resolvedURL != detail.url {
            out.print("resolved   \(detail.resolvedURL)")
        }
        out.print("auth       \(detail.auth)")
        if let description = detail.description, !description.isEmpty {
            out.print("about      \(description)")
        }

        if !detail.headers.isEmpty {
            out.print("")
            out.print(out.bold("headers"))
            out.table(detail.headers.map { header in
                // A header that is a credential is masked like any other secret.
                let isSensitive = HistoryRedactor.sensitiveHeaders
                    .contains(header.name.lowercased())
                return ["  " + header.name, isSensitive ? out.secret(header.value) : header.value]
            })
        }

        if detail.body.kind != "none" {
            out.print("")
            out.print(out.bold("body") + out.dim("  \(detail.body.kind)"))
            if let text = detail.body.text {
                for line in text.split(separator: "\n", omittingEmptySubsequences: false).prefix(40) {
                    out.print("  \(line)")
                }
            }
            for field in detail.body.fields ?? [] { out.print("  \(field)") }
        }

        if !detail.unresolvedVariables.isEmpty {
            out.print("")
            out.print(out.yellow(
                "unresolved  \(detail.unresolvedVariables.joined(separator: ", "))"))
        }
        return .ok
    }
}
