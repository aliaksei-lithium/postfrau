import Foundation
import PostfrauCore

/// `--help`, `help`, `version`.
enum Help {
    static func version(_ out: Output) {
        let resolved = Configuration.resolve(dataDirectory: nil)
        out.print("postfrau \(Postfrau.appVersion)")
        out.print(out.dim("data folder  \(resolved.dataFolder.root.path) "
            + "(from \(resolved.origin))"))
        out.print(out.dim("local state  \(resolved.localRoot.path)"))
        if resolved.dataFolder.status != .ok {
            out.print(out.yellow("the data folder is not available"))
        }
    }

    static func usage(_ out: Output) {
        out.print("""
        postfrau — Postfrau from the command line

        \(out.bold("USAGE"))
          postfrau <command> [options]

        \(out.bold("BROWSING"))
          ls [path] [--tree]              what is in a collection or folder
          find WORDS… [--limit N]         search names, paths, descriptions and URLs
          get <path> [--var k=v]          one request, and what it resolves to
          schema [collection|request|environment|history]
          validate <file>                 what is this file, and what would be lost?

        \(out.bold("EDITING"))
          add <folder-path> --url … | --from-curl '…' | --file f.json | --stdin
          add <name> --collection         a new collection
          add <folder-path> --folder --name N
          set <path> [--url U] [--method M] [-H 'k: v'] [--param k=v]
                     [--body @f|-] [--auth bearer:T] [--name N]
          mv <path> <folder-path>         move an item
          rm <path> --yes                 delete an item
          dup <path>                      duplicate an item

        \(out.bold("SENDING"))
          run <path> [--all] [--var k=v] [--capture n=$.a.b] [--dry-run]
                     [--body text|@file|-] [--field a.b=v] [-H 'k: v']
                     [--from-file f --each NAME] [--correlation-header H]
                     [--fail] [--max-body 64k] [--out f] [--stop-on-error]
          send <METHOD> <url> [-H 'k: v'] [-d body|@file|-] [--save-to <folder>]

        \(out.bold("ENVIRONMENTS"))
          env ls | env get <name> | env add <name>
          env set <name> k=v [--secret] | env unset <name> k | env use <name>|none

        \(out.bold("HISTORY"))
          history [--last N] [--agent x] [--since 2h] [--status 4xx]
          history show <id>

        \(out.bold("TRANSFER"))
          import <file>                   OpenAPI 3.x (JSON or YAML), or Postman collection/environment
          import <spec> --into <collection> [--prune] [--dry-run]
                                          update a collection from a newer OpenAPI spec
          export <collection|environment> [--out file]
          open <path>                     show it in the app

        \(out.bold("SKILL"))
          skill install [--to dir]        write SKILL.md for an agent to read

        \(out.bold("GLOBAL OPTIONS"))
          --json            machine-readable output; run --all emits NDJSON
          --data-dir DIR    which workspace to use
          --env NAME        use this environment for this command
          --body, -d TEXT|@file|-   the request body: inline, from a file, or stdin.
                            On `run` it replaces the saved body for this send only
          --as NAME         attribute sends to an agent (or set POSTFRAU_AGENT)
          --record LEVEL    off | metadata | headers | full, for this command
          --reveal          print secret values instead of \(HistoryRedactor.placeholder)
          --quiet           only errors
          --help            help for a command

        \(out.bold("WHEN THE WORKSPACE IS UNREADABLE"))
          Set POSTFRAU_API_TOKEN (Settings ▸ Advanced ▸ Local API) and ls, find, get, run, send
          and version ask the running app over 127.0.0.1 instead of the filesystem — for a sandbox
          that denies the folder, where --data-dir cannot help. POSTFRAU_API_URL overrides the
          address. Other commands need a real folder and will say so.

        \(out.bold("EXIT CODES"))
          0 ok · 1 usage · 2 not found · 3 network · 4 HTTP >= 400 with --fail
          5 data folder unavailable
        """)
    }

    static func forVerb(_ verb: String, _ out: Output) {
        switch verb {
        case "run":
            out.print("""
            postfrau run <path> [options]

              --all             every request under a folder, in order
              --stop-on-error   with --all or --from-file, stop at the first failure
              --var k=v         override a variable; repeatable

            Changing the saved request for this send only (nothing is saved):
              --body TEXT | @file | -   replace the body; -d is the same flag.
                                {{variables}} in it resolve, so a file can be a template
              --field a.b=v     set one field of the JSON body; repeatable. The value is
                                JSON if it parses (42, true, "42", {"x":1}), else a string,
                                and {{variables}} resolve first: --field id={{bank}}
              -H 'k: v'         add a header, or replace one of the same name

            One request per line of a file:
              --from-file FILE  run once per non-blank line (# starts a comment); - is stdin
              --each NAME       the variable each line is stored in
              --correlation-header H   send each run's generated id in header H; the id
                                is also {{correlation_id}}. With --json: NDJSON, one line
                                per send, carrying input and correlationId

            Responses:
              --capture n=$.a.b store a value from the response in the active environment
              --secret          store captured values as secrets
              --dry-run         print what would be sent; writes no history
              --fail            exit 4 when the status is 400 or more
              --max-body 64k    how much of the response to read
              --out FILE        write the body to a file instead of stdout

            A capture from one request is visible to the next, which is what makes
            `run --all` useful: log in, capture the token, call the endpoint.

            --dry-run prints the body that would go out, its size in bytes, and
            where it came from ("as saved", "from --body", "from --field id").

            Examples:
              postfrau run "Payments/Create" --body @payload.json --dry-run
              postfrau run "Payments/Create" --field partner_bank_id=42
              postfrau run "Payments/Create" --from-file banks.txt --each bank \\
                  --field partner_bank_id={{bank}} --correlation-header X-Correlation-ID --json
            """)
        case "send":
            out.print("""
            postfrau send <METHOD> <url> [options]

              -H 'k: v'         a header; repeatable
              -d body | @file | -   a body, from the argument, a file, or stdin
              --param k=v       a query parameter; repeatable
              --auth SPEC       none | bearer:T | basic:U:P | apikey:K:V[:query]
              --save-to <folder-path> --name N   keep it afterwards
              --insecure, -k    do not verify TLS
              --dry-run, --fail, --var, --capture, --max-body, --out  as for run
            """)
        case "history":
            out.print("""
            postfrau history [options]
            postfrau history show <id>

              --last N          how many (default 50)
              --agent NAME      only what this agent sent
              --since 30m|2h|7d only what is newer than that
              --status 404|4xx|failed
            """)
        case "env":
            out.print("""
            postfrau env ls
            postfrau env get <name> [--reveal]
            postfrau env add <name>
            postfrau env set <name> k=v [k=v …] [--secret]
            postfrau env unset <name> <key>
            postfrau env use <name> | none

            A secret's value lives in the Keychain, never in the workspace files.
            """)
        case "import":
            out.print("""
            postfrau import <file>
            postfrau import <spec> --into <collection> [--prune] [--dry-run]

            Reads an OpenAPI 3.0/3.1 document — JSON or YAML (.yaml, .yml) — a Postman
            v2.1 collection, or a Postman environment, and adds it to the workspace.

            --into C          update collection C from a newer version of its OpenAPI
                              spec instead of adding a new collection. Requests are
                              matched by method and path; new operations are added,
                              changed ones updated, and fields you edited since the
                              last import are kept (and listed when the spec changed
                              them too)
            --prune           with --into, delete operations the spec no longer has.
                              Without it they move to a "Removed from spec" folder
            --dry-run         with --into, report what would change and save nothing

            Examples:
              postfrau import deposits.yaml
              postfrau import deposits.yaml --into "Deposit Accounting Service API" --dry-run
            """)
        case "add", "set":
            out.print("""
            postfrau add <folder-path> --url URL [--name N] [--method M] [-H 'k: v']
            postfrau add <folder-path> --from-curl 'curl …'
            postfrau add <folder-path> --file request.json | --stdin
            postfrau add <name> --collection
            postfrau add <folder-path> --folder --name N

            postfrau set <path> [--url U] [--method M] [--name N] [--about TEXT]
                                [-H 'k: v'] [-H 'k:'] [--param k=v] [--param k=]
                                [--body TEXT|@file|-] [--auth SPEC]
                                [--replace-headers] [--replace-params]

            `set` changes only what it is given. A header or param with an empty
            value is removed: -H 'X-Trace:' takes X-Trace off.
            """)
        default:
            usage(out)
        }
    }
}

/// `skill install` — writes the file an agent reads to learn this tool.
enum Skill {
    static func run(_ arguments: Arguments, _ out: Output) -> ExitCode {
        guard arguments.positional(0) == "install" else {
            out.error("skill takes `install`.")
            return .usage
        }

        let directory = URL(
            filePath: arguments.value("--to") ?? ".claude/skills/postfrau",
            directoryHint: .isDirectory)
        do {
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true)
            let url = directory.appending(path: "SKILL.md", directoryHint: .notDirectory)
            try Data(SkillDocument.text.utf8).write(to: url, options: [.atomic])
            if out.isJSON {
                out.json(["path": url.path])
            } else {
                out.print("wrote \(url.path)")
            }
            return .ok
        } catch {
            out.error(CommandRunner.message(for: error))
            return .usage
        }
    }
}
