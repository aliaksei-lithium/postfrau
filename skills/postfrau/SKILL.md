---
name: postfrau
description: >
  Send and inspect HTTP requests from saved collections with the `postfrau` command line tool:
  find a request by description, run it against an environment, fill its variables, read the
  response, and edit or import collections. Use whenever the user mentions postfrau, an API
  collection, an OpenAPI or Swagger spec, running or sending a saved request, or asks to call an
  endpoint in a named environment.
---

# postfrau

The command line half of Postfrau, a macOS HTTP client. Same collections the app shows; every
send lands in the app's history, attributed.

## Start here

A request like *"get the deposit response in prod_deu for deposit FDA_11!_222"* maps onto three
commands. Never guess a path — find it.

```bash
postfrau find deposit specific --json                  # 1. locate it
postfrau get '<path>'                                  # 2. see what it needs
postfrau run '<path>' --env prod_deu \
  --var deposit_id=FDA_11!_222 --json --as cursor      # 3. send it
```

Reading the words:

| In the request | Becomes |
|---|---|
| a name or description — "deposit response", "projection recovery" | `find <words>` |
| "in prod_deu", "on staging" | `--env prod_deu` |
| an id or value — "for deposit FDA_11!_222" | `--var deposit_id=FDA_11!_222` |
| "what would it send", anything against production | add `--dry-run` first |

Step 2 is not optional: `get` prints the stored URL, the resolved URL, and
`unresolvedVariables` — that list is exactly which `--var` flags step 3 needs.

Quote values in single quotes. `!`, `$` and `&` are shell metacharacters.

## Rules

- `--as <your own name>` on everything that sends — `--as cursor`, `--as claude`, `--as copilot`.
  Or set `POSTFRAU_AGENT` once. The user reads it in the history to tell tools apart.
- `--json` for anything you parse. Human output is aligned text. `run --all --json` is NDJSON.
- `--dry-run` before anything that writes, and before anything pointed at production.
- `rm` needs `--yes`. Secrets print as `•••` unless asked for with `--reveal`.

## Variables

`--var` fills `{{placeholders}}` only. A value written literally in the request is not a variable
and `--var` will not change it — `set` the request or use `send` instead. This fails silently, so
check the resolved URL with `--dry-run` when a value does not take.

```bash
postfrau get '<path>' --var deposit_id=FDA_11!_222     # preview the resolution
postfrau env ls                                        # what environments exist
postfrau env use prod_deu                              # or pass --env per command
```

## Commands

```bash
# Look
postfrau find WORDS [--limit N]        # search names, paths, descriptions, URLs
postfrau ls [path] [--tree]            # structure, not search
postfrau get <path> [--var k=v]        # one request, stored + resolved

# Send
postfrau run <path> [--env E] [--var k=v] [--dry-run] [--fail] [--out f.json]
postfrau run <folder> --all --json     # every request under it, in order
postfrau send GET https://api.example.com/health
postfrau send POST https://api.example.com/users \
  -H 'Content-Type: application/json' -d '{"name":"Ada"}'

# Edit
postfrau add 'Acme API' --collection
postfrau add 'Acme API' --folder --name Users
postfrau add 'Acme API/Users' --url 'https://api.example.com/users' --name 'List users'
postfrau add 'Acme API/Users' --from-curl "curl -X POST https://api.example.com/users -d '{}'"
postfrau set <path> --method GET -H 'Accept: application/json'
postfrau set <path> -H 'X-Debug:'      # empty value removes the header
postfrau mv <path> <destination>
postfrau rm <path> --yes

# Environments
postfrau env add Staging
postfrau env set Staging baseUrl=https://staging.example.com
postfrau env set Staging token=abc123 --secret
postfrau env use Staging

# History
postfrau history --last 20
postfrau history --agent claude --since 2h --status 5xx --json
postfrau history show 1f0d567c

# Import
postfrau validate api.json             # what is it, what would be lost
postfrau import api.json               # OpenAPI 3.x, Postman collection or environment
```

Paths run from the collection down and are case-insensitive: `'Acme API/Users/List users'`. A
literal `/` in a name is `\/`. A UUID works anywhere a path does. `set` changes only what it is
given.

An OpenAPI import is sendable, not a transcription: `servers[0]` → `{{baseUrl}}`, tags → folders,
path templates → `{{variables}}`, security → collection auth. JSON only; convert YAML with
`yq -o=json spec.yaml > spec.json`. Read the warnings — they name what could not be modelled.

## Capture a token, then use it

```bash
postfrau run 'Acme API/Auth/Login' --capture token='$.data.access_token' --secret --as claude
postfrau run 'Acme API/Users/Me' --as claude
```

`--capture` runs a small JSONPath (`$.a.b[0].c`) against the response and stores it in the active
environment, so `{{token}}` resolves next time. With `--all`, a capture is visible to the requests
after it. No match exits 2; the request itself still succeeded.

## JSON shapes

- `find` → `[{path, name, method, url, description?}]`
- `ls` → `[{path, name, kind, id, method?, url?, depth}]`
- `get` → `{path, id, name, method, url, resolvedURL, headers[], params[], auth, body,
  description?, unresolvedVariables[]}` — `auth` is a word, never a credential
- `run` / `send` → `{path?, name, method, url, status?, reason?, durationMs, bytes, headers[],
  body?, bodyTruncated, error?, captured{}, warnings[]}` — `status` absent and `error` set means
  it never reached a server
- `history` → `[{id, sentAt, method, url, status?, durationMs, bytes, source, error?, recorded}]`

`postfrau schema collection|request|environment|history` gives the file formats.

## Exit codes

| code | meaning |
|---|---|
| 0 | ok |
| 1 | usage — bad flag, missing argument, an edit that changes nothing |
| 2 | not found — no such path, environment, history entry, or `find` match |
| 3 | never reached a server |
| 4 | HTTP status ≥ 400, and `--fail` was given |
| 5 | data folder unavailable |

## In a sandbox that cannot read the files

If the collections folder or `~/Library/Containers` is unreadable, `--data-dir` will not help.
Ask the running app instead:

```bash
export POSTFRAU_API_TOKEN=<Settings ▸ Advanced ▸ Local API>
export POSTFRAU_API_URL=http://127.0.0.1:7717     # only if the port was changed
```

`ls`, `find`, `get`, `run`, `send`, `version` then work identically — same output, same exit
codes, sends still recorded. `add`, `set`, `mv`, `rm`, `import`, `export`, `history` and `env`
need a real folder and will say so.

Works only while Postfrau is running. If it cannot reach the app, say so and ask the user to
check that switch — do not copy their files somewhere readable.

## When something is wrong

- `postfrau version` — which data folder, and where it came from; or which app, with a token set.
- Exit 5 — folder unavailable. Unreadable rather than wrong? Use the local API above.
- A secret that will not resolve is usually an unanswered Keychain prompt: pass
  `POSTFRAU_SECRET_<KEY>=value` in the environment for that one command.
- `find` returns nothing (exit 2) when not every word matches. Drop a word rather than guessing a
  path.