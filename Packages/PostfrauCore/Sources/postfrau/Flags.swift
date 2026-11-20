import Foundation
import PostfrauCore

/// Which flags each verb reads, so one it does not is an error rather than a no-op.
///
/// A flag nobody reads used to parse, do nothing, and exit 0. `run --param` was such a flag: the
/// request went out without the parameter, the exit code said it had worked, and the time went on
/// finding out why the server disagreed. Now a verb refuses what it would ignore — and when the
/// workspace is behind the Local API, it also refuses what cannot be forwarded to the app.
enum Flags {
    /// Read by every verb that touches a workspace, or by the output layer.
    static let global: Set<String> = [
        "--json", "--quiet", "--reveal", "--help", "-h", "--data-dir", "--env", "--as",
        "--record", "--keychain",
    ]

    private static let requestShape: Set<String> = [
        "--method", "-X", "--header", "-H", "--param", "--auth", "--body", "-d",
    ]
    private static let responses: Set<String> = [
        "--var", "--capture", "--secret", "--max-body", "--dry-run", "--fail", "--out",
    ]

    /// Per verb, on top of `global`.
    static let byVerb: [String: Set<String>] = [
        "ls": ["--tree"],
        "find": ["--limit"],
        "get": ["--var"],
        "add": requestShape.union([
            "--collection", "--folder", "--name", "--from-curl", "--file", "--stdin", "--url",
            "--insecure", "-k", "--no-redirects",
        ]),
        "set": requestShape.union([
            "--name", "--url", "--about", "--replace-headers", "--replace-params",
        ]),
        "mv": [],
        "rm": ["--yes", "-y"],
        "dup": [],
        "run": responses.union([
            "--all", "--stop-on-error", "--body", "-d", "--field", "--header", "-H", "--param",
            "--auth", "--from-file", "--each", "--correlation-header",
        ]),
        "send": requestShape.union(responses).union([
            "--insecure", "-k", "--no-redirects", "--save-to", "--name",
        ]),
        "env": ["--secret"],
        "history": ["--last", "--agent", "--since", "--status"],
        "import": ["--into", "--prune", "--dry-run"],
        "export": ["--out"],
        "open": [],
        "schema": [],
        "validate": [],
        "skill": ["--to"],
        "version": [],
        "help": [],
    ]

    /// What the Local API path cannot forward, per verb, with the reason to give.
    ///
    /// `--keychain` is not here: the app reads its own Keychain items anyway, so what it asks
    /// for already happens.
    static let notOverLocalAPI: [String: String] = [
        "--all": "run one request at a time, or loop over `postfrau ls --json`",
        "--save-to": "saving needs the data folder; send it, then `postfrau add` with a folder",
        "--name": "it only names what --save-to saves",
        "--data-dir": "the app uses its own data folder; unset \(LocalAPI.tokenVariable) to use this one",
    ]

    /// Flags whose every value has to have this separator in it.
    private static let shapes: [(String, Character)] = [
        ("--param", "="), ("--var", "="), ("--field", "="), ("--capture", "="),
        ("--header", ":"), ("-H", ":"),
    ]

    /// The error to print, or nil when every flag is one `verb` reads.
    static func problem(verb: String, _ arguments: Arguments, remote: Bool) -> String? {
        // An unknown verb is reported by the dispatcher, with its own message.
        guard let own = byVerb[verb] else { return nil }
        let unknown = arguments.unknownFlags(known: global.union(own))
        if !unknown.isEmpty {
            let list = unknown.joined(separator: ", ")
            return "`\(verb)` does not take \(list), so nothing was sent or changed. "
                + "`postfrau \(verb) --help` lists what it does take."
        }
        // `pairs` skips a value with no separator, which made `--param deposit_id` a no-op.
        for (flag, separator) in shapes {
            for value in arguments.flags[flag] ?? [] where !value.contains(separator) {
                let example = separator == ":" ? "'Name: value'" : "name=value"
                return "\(flag) takes \(example), and “\(value)” has no “\(separator)”; "
                    + "nothing was sent or changed."
            }
        }
        guard remote else { return nil }
        let blocked = arguments.flags.keys.filter { notOverLocalAPI[$0] != nil }.sorted()
        guard let first = blocked.first, let reason = notOverLocalAPI[first] else { return nil }
        return "\(first) does not work through the Local API (\(LocalAPI.tokenVariable) is set): "
            + "\(reason)."
    }
}
