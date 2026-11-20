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
  Only the JSON goes to stdout; warnings and errors go to stderr. For a large response, write
  stdout to a file and read the file, rather than piping both streams into a parser.
- `--env NAME` on each command. Not `env use`: that switches the environment in the user's
  window too.
- Flags work before or after the command name: `postfrau --env E run …` = `postfrau run … --env E`.
- `--dry-run` before anything that writes, and before anything pointed at production.
- `rm` needs `--yes`. Secrets print as `•••` unless asked for with `--reveal`.
- A flag the command does not take exits 1 and sends nothing — so does `--param` without `=`.
  Exit 0 means every flag was used.

## Variables

`--var` fills `{{placeholders}}` only. A value written literally in the request is not a variable
and `--var` will not change it — `set` the request or use `send` instead. This fails silently, so
check the resolved URL with `--dry-run` when a value does not take.

```bash
postfrau get '<path>' --var deposit_id=FDA_11!_222     # preview the resolution
postfrau env ls                                        # what environments exist
postfrau env use prod_deu                              # or pass --env per command
```

## Changing a saved request for one send

Nothing here is saved; the stored request keeps its body. `--dry-run` ends with
`body: N bytes, from --body` (or `as saved`) and `params: N sent, from --param …` — check they
say what you meant.

```bash
postfrau run '<path>' --body @payload.json --dry-run  # replace the body ({{vars}} resolve)
postfrau run '<path>' --field partner_bank_id=42       # set one JSON field; repeatable
postfrau run '<path>' -H 'X-Request-ID: abc'           # add or replace a header
postfrau run '<path>' --param deposit_id=OMA_1 --param deposit_id=OMA_2   # ?deposit_id=…&deposit_id=…
postfrau run '<path>' --param deposit_id=@ids.txt      # one value per line of the file
postfrau run '<path>' --param page=                    # send no page at all
postfrau run '<path>' --auth bearer:abc                # replace the auth (none, inherit, …)
```

`--param name=…` replaces every saved row called `name` — enabled or disabled — so repeat it for
an array. An OpenAPI import keeps optional params and array examples as *disabled* rows: they
are not sent until you pass them. A dry run lists them in `warnings`.

## Authenticated requests

| Goal | Do | Avoid |
|---|---|---|
| Call an endpoint that needs the collection's token | `run '<path>' --env E` — it carries the collection's or folder's auth | `send` with a URL copied out of `get`: it has no auth unless you pass `--auth` |
| A one-off URL with the environment's token | `send GET '<url>' --env E --auth bearer` (uses E's `{{token}}`) | `--auth bearer:<pasted token>` |
| The saved request with another body | `run '<path>' --env E --body @payload.json` | `set --body`, or editing collection files |
| Check auth before sending | `--dry-run`: an `Authorization` header is listed (value `•••`) | Retrying a 401/403 unchanged |

`--auth` whose variables have no value in the environment exits 1 and sends nothing.

`--field` values are JSON when they parse (`42`, `true`, `'id="42"'` for a string of digits),
text otherwise, and `{{variables}}` resolve first. To run the same request once per id:

```bash
postfrau run '<path>' --from-file banks.txt --each bank \
  --field 'partner_bank_id={{bank}}' --correlation-header X-Correlation-ID --json --as claude
```

One NDJSON line per send, in order, each with `input` and its own `correlationId`.

## Commands

```bash
# Look
postfrau find WORDS [--limit N]        # ranked: names, paths, descriptions, URLs
postfrau ls [path] [--tree]            # structure, not search
postfrau get <path> [--var k=v]        # one request, stored + resolved

# Send
postfrau run <path> [--env E] [--var k=v] [--dry-run] [--fail] [--out f.json]
postfrau run <path> [--body @f.json] [--field a.b=v] [-H 'k: v']   # this send only
postfrau run <folder> --all --json     # every request under it, in order
postfrau send GET https://api.example.com/health
postfrau send POST https://api.example.com/users \
  -H 'Content-Type: application/json' -d '{"name":"Ada"}'
postfrau send GET 'https://api.example.com/v2/x' --env Prod --auth bearer   # Prod's {{token}}

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
path templates → `{{variables}}`, security → collection auth. JSON or YAML. For a newer version
of the spec, `import spec.yaml --into "<collection>" --dry-run` shows the merge; drop `--dry-run`
to apply it (edited fields are kept). Read the warnings — they name what could not be modelled.

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
  it never reached a server. `url` is what the server saw: no `#fragment`
- `--dry-run` → `{method, url, headers[], params[{name, value}], paramsOrigin?, bodyPreview?,
  bodyBytes?, bodyOrigin?, warnings[], unresolvedVariables[]}` — `params` is the query as sent
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

An agent's sandbox usually cannot read the app's data folder, so commands exit 5. `--data-dir`
will not help, and copying the folder or widening the sandbox is not the fix. Ask the running app
instead, through the CLI:

```bash
POSTFRAU_AGENT=claude postfrau version        # must say "via the app at http://127.0.0.1:7717"
POSTFRAU_AGENT=claude postfrau ls
```

That needs `POSTFRAU_API_TOKEN` (Settings ▸ Advanced ▸ Local API) **exported** in the shell
postfrau runs in. An agent's shell is usually a non-interactive zsh, which reads `~/.zshenv` and
not `~/.zshrc`, so the user puts this line in `~/.zshenv`:

```bash
export POSTFRAU_API_TOKEN=<the token from that pane>
```

- Call `postfrau` directly. No `zsh -lc`, `bash -c` or `env` wrapper, and never `curl` the port:
  the CLI is the client.
- Do not read `~/.zshenv`, print the token, or put it on a command line.
- If `version` does not mention the app and exits 5, the token is not exported: say so and stop.
  A shell already running does not re-read `~/.zshenv`; only a new one sees the change.
- `POSTFRAU_API_URL` overrides the address, only if the port was changed.

`ls`, `find`, `get`, `run`, `send`, `version` then work identically — same output, same exit
codes, sends still recorded. `env`, `set`, `add`, `mv`, `rm`, `import`, `export` and `history`
need the folder and say "Remotely you can: …" — expected; use `--env`, `--body`, `--param` on
`run` instead. `run --all` and `send --save-to` exit 1 for the same reason. An app older than the
tool exits 1 rather than ignore `--param` or `--auth`.

Works only while Postfrau is running. If it cannot reach the app, say so and ask the user to
check that switch.

## When something is wrong

- `postfrau version` — which data folder, and where it came from; or which app, with a token set.
- Exit 5 — folder unavailable. Unreadable rather than wrong? Use the local API above.
- 401 or 403 — run it again with `--dry-run` and look for `Authorization`. None: the request has
  no auth of its own; `run` the saved one with `--env`, or pass `--auth bearer`.
- Secrets (tokens) are read only from the Keychain, where the app keeps them — never from the
  workspace files. Without `--keychain` a secret has no value, and `warnings` in the `--json`
  result says `no value for secret "token"`. Check `warnings` before trusting a 401: add
  `--keychain` (macOS may ask the user once), or pass `POSTFRAU_SECRET_<KEY>=value` for one command.
- `find` ranks; it does not require every word. The best match is first, so read the descriptions
  before picking. Nothing at all (exit 2) means try fewer or different words — never guess a path.