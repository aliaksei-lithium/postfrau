import Foundation
import PostfrauCore

/// `add`, `set`, `mv`, `rm`, `dup` — changing what is stored.
enum Edit {
    // MARK: - add

    static func add(
        _ arguments: Arguments, _ runner: CommandRunner, _ out: Output
    ) async throws -> ExitCode {
        guard let target = arguments.positional(0) else {
            out.error("add needs somewhere to put it: `postfrau add <folder-path> --url …`")
            return .usage
        }

        // `add --collection Name` and `add --folder Name` make containers rather than requests.
        if arguments.has("--collection") {
            let added = try await runner.addCollection(named: target)
            report(added, "collection", out)
            return .ok
        }
        if arguments.has("--folder") {
            guard let name = arguments.value("--name") else {
                out.error("--folder needs --name.")
                return .usage
            }
            let added = try await runner.addFolder(named: name, toFolderAt: target)
            report(added, "folder", out)
            return .ok
        }

        var request: RequestItem
        var warnings: [String] = []

        if let command = arguments.value("--from-curl") {
            let result = try CurlParser().parse(command)
            request = result.request
            warnings = result.warnings
        } else if let file = arguments.value("--file") {
            request = try decodeRequest(from: try Data(contentsOf: URL(filePath: file)))
        } else if arguments.has("--stdin") {
            request = try decodeRequest(from: FileHandle.standardInput.readDataToEndOfFile())
        } else if let url = arguments.value("--url") {
            request = RequestItem(name: "", url: url)
        } else {
            out.error("add needs --url, --from-curl, --file or --stdin.")
            return .usage
        }

        // An explicit name always wins over one derived from the URL or the curl command.
        if let name = arguments.value("--name") { request.name = name }
        try apply(arguments, to: &request)

        let added = try await runner.addRequest(request, toFolderAt: target)
        for warning in warnings { out.warning(warning) }

        if out.isJSON {
            out.json(added)
        } else {
            out.print("added \(out.method(added.method)) \(out.bold(added.name))")
            out.print(out.dim(added.path))
        }
        return .ok
    }

    // MARK: - set

    static func set(
        _ arguments: Arguments, _ runner: CommandRunner, _ out: Output
    ) async throws -> ExitCode {
        guard let path = arguments.positional(0) else {
            out.error("set needs a path.")
            return .usage
        }

        var edit = RequestEdit()
        edit.name = arguments.value("--name")
        edit.url = arguments.value("--url")
        edit.method = (arguments.value("--method", "-X")).map { HTTPMethod(rawValue: $0.uppercased()) }
        edit.description = arguments.value("--about")
        edit.replacesHeaders = arguments.has("--replace-headers")
        edit.replacesParams = arguments.has("--replace-params")

        // `-H 'X-Trace: abc'` sets, `-H 'X-Trace:'` removes — the empty value is the signal.
        edit.headers = arguments.colonPairs("--header", "-H").map { key, value in
            (key, value.isEmpty ? nil : value)
        }
        edit.params = arguments.pairs("--param").map { key, value in
            (key, value.isEmpty ? nil : value)
        }
        if let auth = try auth(arguments) { edit.auth = auth }
        if let body = try readBody(arguments) { edit.body = body }

        let updated = try await runner.update(requestAt: path, with: edit)
        if out.isJSON {
            out.json(updated)
        } else {
            out.print("updated \(out.method(updated.method)) \(out.bold(updated.name))")
        }
        return .ok
    }

    // MARK: - mv, rm, dup

    static func move(
        _ arguments: Arguments, _ runner: CommandRunner, _ out: Output
    ) async throws -> ExitCode {
        guard let path = arguments.positional(0), let destination = arguments.positional(1) else {
            out.error("mv needs a path and a destination folder.")
            return .usage
        }
        let moved = try await runner.move(itemAt: path, toFolderAt: destination)
        report(moved, "moved", out)
        return .ok
    }

    static func remove(
        _ arguments: Arguments, _ runner: CommandRunner, _ out: Output
    ) async throws -> ExitCode {
        guard let path = arguments.positional(0) else {
            out.error("rm needs a path.")
            return .usage
        }
        // Deleting is the one thing here that cannot be undone from the command line, so it asks
        // unless told not to. A non-interactive caller has to say --yes, which is the point.
        guard arguments.has("--yes", "-y") else {
            out.error("rm will not delete “\(path)” without --yes.")
            return .usage
        }
        let removed = try await runner.remove(itemAt: path)
        report(removed, "removed", out)
        return .ok
    }

    static func duplicate(
        _ arguments: Arguments, _ runner: CommandRunner, _ out: Output
    ) async throws -> ExitCode {
        guard let path = arguments.positional(0) else {
            out.error("dup needs a path.")
            return .usage
        }
        let copy = try await runner.duplicate(itemAt: path)
        report(copy, "duplicated", out)
        return .ok
    }

    // MARK: - Shared

    /// Applies the request-shaping flags that `add` and `send` both accept.
    ///
    /// Throws for a value it cannot use — an `--auth` it does not understand, a `--param` file it
    /// cannot read — rather than leaving it out and carrying on.
    static func apply(_ arguments: Arguments, to request: inout RequestItem) throws {
        if let method = arguments.value("--method", "-X") {
            request.method = HTTPMethod(rawValue: method.uppercased())
        }
        for (key, value) in arguments.colonPairs("--header", "-H") {
            request.headers.append(KeyValue(key: key, value: value))
        }
        let params = try queryParams(arguments)
        if !params.isEmpty {
            // The URL's own query joins the table first, so `send 'https://x?a=1' --param b=2`
            // sends both rather than only b.
            request = RequestPatch.applying(params, to: request)
            request.url = URLQuery.compose(
                base: request.url,
                params: KeyValueRows.stripped(request.params),
                encode: request.settings.encodeURL)
        }
        if let auth = try auth(arguments) { request.auth = auth }
        if let body = try readBody(arguments) { request.body = body }
        if arguments.has("--insecure", "-k") { request.settings.verifyTLS = false }
        if arguments.has("--no-redirects") { request.settings.followRedirects = false }
    }

    /// `--param name=value`, repeatable, in order. A name given twice is sent twice.
    ///
    /// `name=@ids.txt` reads one value per line from the file — blank lines and `#` comments
    /// skipped — so a list of 40 ids is one flag rather than forty. Read here, on this side of any
    /// socket: the Local API gets the values, not a path it cannot open.
    static func queryParams(_ arguments: Arguments) throws -> [RequestPatch.QueryParam] {
        try arguments.pairs("--param").flatMap { name, value -> [RequestPatch.QueryParam] in
            guard value.hasPrefix("@") else { return [.init(name: name, value: value)] }
            let path = String(value.dropFirst())
            let text: String
            do {
                text = path == "-"
                    ? String(decoding: FileHandle.standardInput.readDataToEndOfFile(), as: UTF8.self)
                    : try String(contentsOf: URL(filePath: path), encoding: .utf8)
            } catch {
                throw CommandRunner.CommandError.invalid(
                    "--param \(name)=@\(path): cannot read \(path): "
                        + CommandRunner.message(for: error))
            }
            let values = text.split(whereSeparator: \.isNewline)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty && !$0.hasPrefix("#") }
            guard !values.isEmpty else {
                throw CommandRunner.CommandError.invalid(
                    "--param \(name)=@\(path): \(path) has no values in it.")
            }
            return values.map { .init(name: name, value: $0) }
        }
    }

    /// `--auth`, parsed, or nil when it was not given. An `--auth` that does not parse is an error.
    static func auth(_ arguments: Arguments) throws -> Auth? {
        guard let text = arguments.value("--auth") else {
            if arguments.has("--auth") {
                throw CommandRunner.CommandError.invalid("--auth needs a value. " + authSyntax)
            }
            return nil
        }
        guard let parsed = parseAuth(text) else {
            throw CommandRunner.CommandError.invalid("--auth “\(text)” is not one Postfrau knows. " + authSyntax)
        }
        return parsed
    }

    static let authSyntax =
        "It takes none, inherit, bearer (the environment's {{token}}), bearer:TOKEN, "
        + "basic:USER:PASS or apikey:KEY:VALUE[:query]."

    /// `-d text`, `-d @file`, `-d -` (stdin).
    static func readBody(_ arguments: Arguments) throws -> RequestBody? {
        try readBodyText(arguments).map { RequestBody.raw(guessingLanguageOf: $0) }
    }

    /// The text of `--body`/`-d`, with `@file` and `-` read. Nil when neither flag was given.
    ///
    /// The Local API path needs the text rather than a `RequestBody`: the file is on this side of
    /// the socket, and forwarding `@payload.json` verbatim would send the file's name as the body.
    static func readBodyText(_ arguments: Arguments) throws -> String? {
        guard let raw = arguments.value("--body", "-d") else { return nil }
        if raw == "-" {
            return String(decoding: FileHandle.standardInput.readDataToEndOfFile(), as: UTF8.self)
        }
        if raw.hasPrefix("@") {
            let path = String(raw.dropFirst())
            do {
                return try String(contentsOf: URL(filePath: path), encoding: .utf8)
            } catch {
                throw CommandRunner.CommandError.invalid(
                    "cannot read the body from \(path): \(CommandRunner.message(for: error))")
            }
        }
        return raw
    }

    /// The variable bare `--auth bearer` reads.
    static let bearerVariable = "token"

    /// `bearer`, `bearer:TOKEN`, `basic:USER:PASS`, `apikey:KEY:VALUE[:query]`, `none`, `inherit`.
    static func parseAuth(_ text: String) -> Auth? {
        let parts = text.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        switch parts.first?.lowercased() {
        case "none": return Auth.none
        case "inherit": return .inherit
        case "bearer":
            // Bare `bearer` is the environment's `token` — the name an imported collection's
            // bearer auth uses — so a one-off `send --env Prod --auth bearer` carries the same
            // credential a saved request in that collection would.
            guard parts.count >= 2 else { return .bearer(token: "{{\(bearerVariable)}}") }
            // The token itself may contain colons, so everything after the first one is the value.
            let token = parts.dropFirst().joined(separator: ":")
            return token.isEmpty ? nil : .bearer(token: token)
        case "basic":
            guard parts.count >= 3 else { return nil }
            return .basic(username: parts[1], password: parts.dropFirst(2).joined(separator: ":"))
        case "apikey":
            guard parts.count >= 3 else { return nil }
            let location: APIKeyLocation = parts.count >= 4 && parts[3] == "query" ? .query : .header
            return .apiKey(key: parts[1], value: parts[2], location: location)
        default: return nil
        }
    }

    static func decodeRequest(from data: Data) throws -> RequestItem {
        do {
            return try Postfrau.makeDecoder().decode(RequestItem.self, from: data)
        } catch {
            throw CommandRunner.CommandError.invalid(
                "That is not a request document. `postfrau schema request` shows the shape.")
        }
    }

    static func report(_ item: ListedItem, _ verb: String, _ out: Output) {
        if out.isJSON {
            out.json(item)
        } else {
            out.print("\(verb) \(out.bold(item.name))")
            out.print(out.dim(item.path))
        }
    }
}
