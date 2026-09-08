import Foundation
import PostfrauCore

/// `env ls | get | set | unset | use`.
enum Environments {
    static func run(
        _ arguments: Arguments, _ runner: CommandRunner, _ out: Output
    ) async throws -> ExitCode {
        switch arguments.positional(0) ?? "ls" {
        case "ls": return try await list(runner, out)
        case "get": return try await get(arguments, runner, out)
        case "set": return try await set(arguments, runner, out)
        case "unset": return try await unset(arguments, runner, out)
        case "use": return try await use(arguments, runner, out)
        case "add": return try await add(arguments, runner, out)
        default:
            out.error("env takes ls, get, set, unset, use or add.")
            return .usage
        }
    }

    private static func list(_ runner: CommandRunner, _ out: Output) async throws -> ExitCode {
        let environments = try await runner.listEnvironments()
        if out.isJSON {
            out.json(environments.map {
                ["name": $0.name, "active": "\($0.isActive)", "variables": "\($0.count)"]
            })
            return .ok
        }
        guard !environments.isEmpty else {
            out.print("no environments yet — `postfrau env add <name>`")
            return .ok
        }
        out.table(environments.map { environment in
            [environment.isActive ? out.green("*") : " ",
             environment.name,
             out.dim("\(environment.count) variable(s)")]
        })
        return .ok
    }

    private static func get(
        _ arguments: Arguments, _ runner: CommandRunner, _ out: Output
    ) async throws -> ExitCode {
        guard let name = arguments.positional(1) else {
            out.error("env get needs a name.")
            return .usage
        }
        let environment = try await runner.environment(named: name)

        if out.isJSON {
            out.json(environment.variables.map { variable in
                [
                    "key": variable.key,
                    // A secret's value is only in the output when it was asked for by name.
                    "value": variable.isSecret ? out.secret(variable.value) : variable.value,
                    "secret": "\(variable.isSecret)",
                    "enabled": "\(variable.enabled)",
                ]
            })
            return .ok
        }
        out.print(out.bold(environment.name))
        out.table(environment.variables.map { variable in
            [variable.key,
             variable.isSecret ? out.secret(variable.value) : variable.value,
             variable.isSecret ? out.dim("secret") : ""]
        })
        return .ok
    }

    private static func set(
        _ arguments: Arguments, _ runner: CommandRunner, _ out: Output
    ) async throws -> ExitCode {
        guard let name = arguments.positional(1) else {
            out.error("env set needs an environment name and k=v.")
            return .usage
        }
        // The pair may be positional (`env set prod token=abc`) or come from --secret-value, so a
        // token with an `=` in it does not have to be escaped.
        let pairs = arguments.positional.dropFirst(2).compactMap { text -> (String, String)? in
            guard let equals = text.firstIndex(of: "=") else { return nil }
            return (String(text[text.startIndex..<equals]),
                    String(text[text.index(after: equals)...]))
        }
        guard !pairs.isEmpty else {
            out.error("env set needs at least one k=v.")
            return .usage
        }

        let isSecret = arguments.has("--secret")
        // `--secret` applies to the whole command, so setting two variables at once with it
        // would quietly hide both — including, say, a base URL that then reads as ••• forever.
        guard !isSecret || pairs.count == 1 else {
            out.error(
                "--secret applies to every k=v in the command. Set the secret on its own line.")
            return .usage
        }

        for (key, value) in pairs {
            _ = try await runner.setVariable(
                key, to: value, inEnvironmentNamed: name, isSecret: isSecret)
        }
        if !out.isJSON {
            out.print("set \(pairs.map(\.0).joined(separator: ", ")) in \(out.bold(name))")
        }
        return .ok
    }

    private static func unset(
        _ arguments: Arguments, _ runner: CommandRunner, _ out: Output
    ) async throws -> ExitCode {
        guard let name = arguments.positional(1), let key = arguments.positional(2) else {
            out.error("env unset needs an environment name and a key.")
            return .usage
        }
        _ = try await runner.unsetVariable(key, inEnvironmentNamed: name)
        if !out.isJSON { out.print("unset \(key) in \(out.bold(name))") }
        return .ok
    }

    private static func use(
        _ arguments: Arguments, _ runner: CommandRunner, _ out: Output
    ) async throws -> ExitCode {
        let chosen = try await runner.useEnvironment(named: arguments.positional(1))
        if !out.isJSON { out.print("using \(out.bold(chosen))") }
        return .ok
    }

    private static func add(
        _ arguments: Arguments, _ runner: CommandRunner, _ out: Output
    ) async throws -> ExitCode {
        guard let name = arguments.positional(1) else {
            out.error("env add needs a name.")
            return .usage
        }
        _ = try await runner.addEnvironment(named: name)
        if !out.isJSON { out.print("added \(out.bold(name))") }
        return .ok
    }
}
