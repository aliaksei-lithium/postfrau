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

    static func find(
        _ arguments: Arguments, _ runner: CommandRunner, _ out: Output
    ) async throws -> ExitCode {
        // Every positional is part of the query, so it need not be quoted:
        // `postfrau find projection recovery` works as typed.
        let terms = arguments.positional.joined(separator: " ")
        guard !terms.isEmpty else {
            out.error("find needs something to look for: `postfrau find projection recovery`")
            return .usage
        }
        let limit = arguments.value("--limit").flatMap(Int.init) ?? 20
        return render(try await runner.find(terms, limit: limit), out)
    }

    /// Printing, split from fetching, so the loopback API renders exactly what a local run does.
    static func render(_ found: [FoundItem], _ out: Output) -> ExitCode {
        if out.isJSON {
            out.json(found)
            return .ok
        }
        guard !found.isEmpty else {
            out.print("nothing matched")
            return .notFound
        }
        // Two lines per result, rather than three columns.
        //
        // The path is printed whole, however long it is: it is the one thing here that is not for
        // reading but for *using*, and a path with a `…` in the middle looks like something you
        // could copy when it is not. Paths in an imported spec run past a hundred characters, so
        // a table wide enough for them wraps in any real terminal and the wrapping is what makes
        // the output unreadable. On its own line it never wraps, and the description sits under
        // it where it can be clipped without costing anything.
        // Padded to the widest verb so the paths start in one column and can be read down.
        let verbWidth = found.map(\.method.count).max() ?? 0
        for item in found {
            let pad = String(repeating: " ", count: verbWidth - item.method.count)
            out.print("\(out.method(item.method))\(pad)  \(item.path)")
            if let note = item.description ?? Optional(item.url), !note.isEmpty {
                out.print(out.dim("      " + oneLine(note, 96)))
            }
        }
        // What to do with what was just printed. An agent that has never run this tool before
        // should not have to infer the next command, and a person loses one line.
        if let first = found.first {
            out.print("")
            out.print(out.dim("open:  postfrau get '\(first.path)'"))
            out.print(out.dim("send:  postfrau run '\(first.path)' --as <your name>"))
        }
        return .ok
    }

    /// One readable line out of a description that may be a page of HTML.
    ///
    /// Tags are dropped rather than rendered, entities left alone: this is a signpost, not a
    /// document viewer, and anything wanting the real text should be reading `--json`.
    private static func summarize(_ text: String, limit: Int = 160) -> String {
        var stripped = ""
        var insideTag = false
        for character in text {
            switch character {
            case "<": insideTag = true
            case ">": insideTag = false
            default: if !insideTag { stripped.append(character) }
            }
        }
        let flattened = stripped
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        return flattened.count <= limit ? flattened : flattened.prefix(limit - 1) + "…"
    }

    /// First line, clipped.
    ///
    /// An OpenAPI `description` is routinely a dozen lines of prose, and a name imported from a
    /// `summary` can be a whole sentence. Printed raw they turn one row of `find` into a page.
    /// `--json` still carries the whole thing, which is what an agent should read.
    private static func oneLine(_ text: String, _ limit: Int) -> String {
        let first = text.split(separator: "\n", omittingEmptySubsequences: false)[0]
            .trimmingCharacters(in: .whitespaces)
        return first.count <= limit ? first : first.prefix(limit - 1) + "…"
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
            // Flattened and clipped. An imported OpenAPI `description` is routinely a page of
            // HTML — role tables, notes, markup — and printing it raw buries the two lines that
            // matter underneath, including the list of unresolved variables. `--json` still
            // carries the whole thing.
            out.print("about      \(summarize(description))")
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
