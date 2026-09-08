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
        apply(arguments, to: &request)

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
        if let auth = arguments.value("--auth") {
            guard let parsed = parseAuth(auth) else {
                out.error(
                    "--auth must be none, inherit, bearer:TOKEN, basic:USER:PASS "
                        + "or apikey:KEY:VALUE[:query].")
                return .usage
            }
            edit.auth = parsed
        }
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
    static func apply(_ arguments: Arguments, to request: inout RequestItem) {
        if let method = arguments.value("--method", "-X") {
            request.method = HTTPMethod(rawValue: method.uppercased())
        }
        for (key, value) in arguments.colonPairs("--header", "-H") {
            request.headers.append(KeyValue(key: key, value: value))
        }
        for (key, value) in arguments.pairs("--param") {
            request.params.append(KeyValue(key: key, value: value))
        }
        if !request.params.isEmpty {
            request.url = URLQuery.compose(
                base: request.url,
                params: KeyValueRows.stripped(request.params),
                encode: request.settings.encodeURL)
        }
        if let auth = arguments.value("--auth"), let parsed = parseAuth(auth) {
            request.auth = parsed
        }
        if let body = (try? readBody(arguments)) ?? nil { request.body = body }
        if arguments.has("--insecure", "-k") { request.settings.verifyTLS = false }
        if arguments.has("--no-redirects") { request.settings.followRedirects = false }
    }

    /// `-d text`, `-d @file`, `-d -` (stdin).
    static func readBody(_ arguments: Arguments) throws -> RequestBody? {
        guard let raw = arguments.value("--body", "-d") else { return nil }
        let text: String
        if raw == "-" {
            text = String(decoding: FileHandle.standardInput.readDataToEndOfFile(), as: UTF8.self)
        } else if raw.hasPrefix("@") {
            text = try String(contentsOf: URL(filePath: String(raw.dropFirst())), encoding: .utf8)
        } else {
            text = raw
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let language: RawLanguage =
            trimmed.hasPrefix("{") || trimmed.hasPrefix("[") ? .json
            : (trimmed.hasPrefix("<") ? .xml : .text)
        return .raw(text: text, language: language)
    }

    /// `bearer:TOKEN`, `basic:USER:PASS`, `apikey:KEY:VALUE[:query]`, `none`, `inherit`.
    static func parseAuth(_ text: String) -> Auth? {
        let parts = text.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        switch parts.first?.lowercased() {
        case "none": return Auth.none
        case "inherit": return .inherit
        case "bearer":
            // The token itself may contain colons, so everything after the first one is the value.
            guard parts.count >= 2 else { return nil }
            return .bearer(token: parts.dropFirst().joined(separator: ":"))
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
