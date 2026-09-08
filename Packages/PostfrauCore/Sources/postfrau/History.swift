import Foundation
import PostfrauCore

/// `history` and `history show <id>` — reading back what was sent, by anyone.
enum History {
    static func run(
        _ arguments: Arguments,
        _ runner: CommandRunner,
        _ resolved: Configuration.Resolved,
        _ out: Output
    ) async throws -> ExitCode {
        if arguments.positional(0) == "show" {
            return try await show(arguments, runner, out)
        }

        let limit = arguments.value("--last").flatMap(Int.init) ?? 50
        // Read more than asked for when filtering, or `--agent x --last 5` would look at the last
        // five entries rather than finding five from that agent.
        let hasFilters = arguments.has("--agent") || arguments.has("--since")
            || arguments.has("--status")
        var entries = await runner.history.load(limit: hasFilters ? max(limit * 20, 1000) : limit)

        if let agent = arguments.value("--agent") {
            entries = entries.filter {
                $0.source.displayName.compare(agent, options: .caseInsensitive) == .orderedSame
            }
        }
        if let since = arguments.value("--since") {
            guard let date = Arguments.since(since) else {
                out.error("--since takes a span like 30m, 2h or 7d.")
                return .usage
            }
            entries = entries.filter { $0.sentAt >= date }
        }
        if let status = arguments.value("--status") {
            guard let matches = statusMatcher(status) else {
                out.error("--status takes 404, 4xx or 2xx.")
                return .usage
            }
            entries = entries.filter { matches($0.statusCode) }
        }
        entries = Array(entries.prefix(limit))

        if out.isJSON {
            out.json(entries.map(Summary.init))
            return .ok
        }
        guard !entries.isEmpty else {
            out.print("no history matches")
            return .ok
        }
        out.table(entries.map { entry in
            [out.dim(String(entry.id.uuidString.prefix(8))),
             out.status(entry.statusCode),
             out.method(entry.method.rawValue),
             entry.displayPath,
             out.dim(entry.source.isAutomated ? entry.source.displayName : ""),
             out.dim(relative(entry.sentAt))]
        })
        return .ok
    }

    private static func show(
        _ arguments: Arguments, _ runner: CommandRunner, _ out: Output
    ) async throws -> ExitCode {
        guard let prefix = arguments.positional(1) else {
            out.error("history show needs an id — the short one from `postfrau history` is enough.")
            return .usage
        }
        let entries = await runner.history.load(limit: 5000)
        guard let entry = entries.first(where: {
            $0.id.uuidString.lowercased().hasPrefix(prefix.lowercased())
        }) else {
            out.error("no history entry starting with “\(prefix)”.")
            return .notFound
        }

        if out.isJSON {
            out.json(entry)
            return .ok
        }

        out.print("\(out.method(entry.method.rawValue)) \(entry.resolvedURL)")
        out.print("\(out.status(entry.statusCode))  "
            + out.dim(ByteCount.formatDuration(milliseconds: entry.durationMs))
            + "  " + out.dim(ByteCount.format(entry.responseBytes)))
        out.print(out.dim("\(entry.sentAt.formatted()) · \(entry.source.displayName) "
            + "· recorded \(entry.recordLevel.rawValue)"))
        if let error = entry.error { out.print(out.red(error)) }

        if let headers = entry.requestHeaders, !headers.isEmpty {
            out.print("")
            out.print(out.bold("request headers"))
            out.table(headers.map { ["  " + $0.name, $0.value] })
        }
        if let headers = entry.responseHeaders, !headers.isEmpty {
            out.print("")
            out.print(out.bold("response headers"))
            out.table(headers.map { ["  " + $0.name, $0.value] })
        }
        if let body = entry.requestBody {
            out.print("")
            out.print(out.bold("request body") + truncationNote(body, out))
            out.print(body.text)
        }
        if let body = entry.responseBody {
            out.print("")
            out.print(out.bold("response body") + truncationNote(body, out))
            out.print(body.text)
        }
        if !entry.hasRecordedExchange {
            out.print("")
            out.print(out.dim(
                "Only metadata was recorded. Settings ▸ History, or --record full, keeps more."))
        }
        return .ok
    }

    /// "just now" rather than "in 0 seconds": the relative style reads a moment ago as the
    /// future, which in a history listing is nonsense.
    static func relative(_ date: Date, from now: Date = Date()) -> String {
        let elapsed = now.timeIntervalSince(date)
        guard elapsed >= 60 else { return "just now" }
        return date.formatted(.relative(presentation: .numeric))
    }

    private static func truncationNote(_ body: RecordedBody, _ out: Output) -> String {
        guard body.truncated else { return "" }
        return out.dim("  first \(ByteCount.format(body.data.count)) "
            + "of \(ByteCount.format(body.originalBytes))")
    }

    /// `404`, `4xx`, `2xx`, or `failed` for the ones that never got a status.
    private static func statusMatcher(_ text: String) -> ((Int?) -> Bool)? {
        let lowered = text.lowercased()
        if lowered == "failed" { return { $0 == nil } }
        if let exact = Int(lowered) { return { $0 == exact } }
        guard lowered.count == 3, lowered.hasSuffix("xx"),
              let hundreds = Int(lowered.prefix(1))
        else { return nil }
        return { status in
            guard let status else { return false }
            return status / 100 == hundreds
        }
    }

    /// The stable shape `--json` promises, documented in SKILL.md.
    struct Summary: Encodable {
        var id: String
        var sentAt: Date
        var method: String
        var url: String
        var status: Int?
        var durationMs: Double
        var bytes: Int
        var source: String
        var error: String?
        var recorded: String

        init(_ entry: HistoryEntry) {
            id = entry.id.uuidString
            sentAt = entry.sentAt
            method = entry.method.rawValue
            url = entry.resolvedURL
            status = entry.statusCode
            durationMs = entry.durationMs
            bytes = entry.responseBytes
            source = entry.source.displayName
            error = entry.error
            recorded = entry.recordLevel.rawValue
        }
    }
}
