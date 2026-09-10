import Foundation
import PostfrauCore

/// `postfrau` — the command line half of Postfrau.
///
/// Everything the app can do to a workspace, for a process with no window: an agent with a shell,
/// a script, a CI job. Whatever it does shows up in the app, attributed, in the same history.
let exitCode = await CLI.run(Array(CommandLine.arguments.dropFirst()))
exit(exitCode.rawValue)

enum CLI {
    /// Flags that take a value. Everything else is boolean, so an unrecognised flag can never
    /// swallow the argument after it and be mistaken for a path.
    ///
    /// Every flag a command reads with `value`, `values`, `pairs` or `colonPairs` has to be in
    /// here. One that is missing is not an error anywhere — it parses as a boolean, its value
    /// becomes a stray positional, and the command quietly does nothing. `CLITests` pins the list
    /// against the sources so that cannot happen again.
    static let valueFlags: Set<String> = [
        "--about", "--agent", "--as", "--auth", "--body", "-d", "--capture", "--data-dir",
        "--env", "--file", "--from-curl", "--header", "-H", "--last", "--max-body", "--method",
        "-X", "--name", "--out", "--param", "--record", "--save-to", "--since", "--status",
        "--to", "--url", "--var", "--limit",
    ]

    static func run(_ arguments: [String]) async -> ExitCode {
        // Everything is parsed in one pass, so a global flag works before the verb as well as
        // after it: `postfrau --json ls` and `postfrau ls --json` are the same command.
        let all: Arguments
        do {
            all = try Arguments(arguments, valueFlags: valueFlags)
        } catch {
            Output().error(CommandRunner.message(for: error))
            return .usage
        }

        let out = Output(
            isJSON: all.has("--json"),
            isQuiet: all.has("--quiet"),
            reveals: all.has("--reveal"))

        guard let verb = all.positional(0) else {
            if all.has("--version") { Help.version(out); return .ok }
            Help.usage(out)
            return arguments.isEmpty ? .usage : .ok
        }
        if all.has("--help", "-h") {
            Help.forVerb(verb, out)
            return .ok
        }
        let parsed = all.droppingVerb()

        switch verb {
        case "version":
            if let endpoint = RemoteAPI.fromEnvironment() {
                return await RemoteAPI.run(verb: verb, parsed, endpoint, out)
            }
            Help.version(out)
            return .ok
        case "help": Help.usage(out); return .ok
        case "schema": return Schema.run(parsed, out)
        case "validate": return Validate.run(parsed, out)
        case "skill": return Skill.run(parsed, out)
        default: break
        }

        // With a token set, the workspace lives behind the app rather than on a disk this
        // process can read. Checked before resolving a data folder, because the whole point is
        // that there may not be one.
        if let endpoint = RemoteAPI.fromEnvironment() {
            return await RemoteAPI.run(verb: verb, parsed, endpoint, out)
        }

        // Everything else needs the workspace.
        let resolved = Configuration.resolve(dataDirectory: parsed.value("--data-dir"))
        guard resolved.dataFolder.status == .ok else {
            // Saying only that it failed leaves a sandboxed caller — which is the common way to
            // land here — with nowhere to go. The way out is the running app, so say so here
            // rather than only in the skill.
            out.error(
                "the data folder at \(resolved.dataFolder.root.path) is not available "
                    + "(chosen from \(resolved.origin)).")
            out.print("")
            out.print(
                "If this process cannot read that folder — a sandbox, or another user's "
                    + "session — ask the running app instead. In Postfrau, turn on "
                    + "Settings ▸ Advanced ▸ Local API, then:")
            out.print("")
            out.print("    export \(LocalAPI.tokenVariable)=<the token shown in that pane>")
            out.print("")
            out.print(
                "`" + RemoteAPI.supportedVerbs.sorted().joined(separator: "`, `")
                    + "` then work without touching the folder at all.")
            return .dataFolderUnavailable
        }

        let runner = Configuration.makeRunner(
            resolved,
            source: Configuration.source(from: parsed.value("--as")),
            recordLevel: parsed.value("--record").flatMap(HistoryRecordLevel.init(rawValue:)))
        await runner.setSecretOverrides(Configuration.secretOverrides())
        await runner.setUsesKeychain(parsed.has("--keychain"))

        // `--env` selects an environment for this invocation only.
        if let environment = parsed.value("--env") {
            do { _ = try await runner.useEnvironment(named: environment) }
            catch {
                out.error(CommandRunner.message(for: error))
                return .notFound
            }
        }

        do {
            let code = try await dispatch(verb, parsed, runner, resolved, out)
            await reportUnavailableSecrets(runner, out, verb: verb)
            return code
        } catch let error as CommandRunner.CommandError {
            out.error(CommandRunner.message(for: error))
            return switch error {
            case .notFound: .notFound
            case .dataFolderUnavailable: .dataFolderUnavailable
            case .invalid: .usage
            }
        } catch {
            out.error(CommandRunner.message(for: error))
            return .usage
        }
    }

    /// The verbs whose output depends on a secret actually having a value.
    ///
    /// Every command hydrates the workspace, so a missing secret is noticed whatever was asked
    /// for — but warning about a token while listing or searching is noise in front of the answer,
    /// and to an agent reading the output it looks like something went wrong with the search.
    private static let verbsThatUseSecrets: Set<String> = ["get", "run", "send", "env"]

    /// Says once, at the end, that a secret could not be supplied — rather than letting the user
    /// puzzle over a request that went out with an empty token.
    private static func reportUnavailableSecrets(
        _ runner: CommandRunner, _ out: Output, verb: String
    ) async {
        guard verbsThatUseSecrets.contains(verb) else { return }
        let missing = Set(await runner.unavailableSecrets).sorted()
        guard !missing.isEmpty else { return }
        out.warning(
            "no value for \(missing.joined(separator: ", ")). "
                + "Secrets live in the Keychain, which the command line tool does not read by "
                + "default; pass --keychain to allow it (macOS will ask once), or set "
                + "POSTFRAU_SECRET_\(missing[0].uppercased()).")
    }

    private static func dispatch(
        _ verb: String,
        _ parsed: Arguments,
        _ runner: CommandRunner,
        _ resolved: Configuration.Resolved,
        _ out: Output
    ) async throws -> ExitCode {
            switch verb {
            case "ls": return try await Browse.list(parsed, runner, out)
            case "find": return try await Browse.find(parsed, runner, out)
            case "get": return try await Browse.get(parsed, runner, out)
            case "add": return try await Edit.add(parsed, runner, out)
            case "set": return try await Edit.set(parsed, runner, out)
            case "mv": return try await Edit.move(parsed, runner, out)
            case "rm": return try await Edit.remove(parsed, runner, out)
            case "dup": return try await Edit.duplicate(parsed, runner, out)
            case "run": return try await Run.run(parsed, runner, out)
            case "send": return try await Run.send(parsed, runner, out)
            case "env": return try await Environments.run(parsed, runner, out)
            case "history": return try await History.run(parsed, runner, resolved, out)
            case "import": return try await Transfer.importFile(parsed, runner, out)
            case "export": return try await Transfer.export(parsed, runner, out)
            case "open": return try await Open.run(parsed, runner, out)
            default:
                out.error("unknown command “\(verb)”. Try `postfrau help`.")
                return .usage
            }
    }
}
