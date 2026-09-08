---
name: postfrau
description: >
  Inspect and edit HTTP request collections, send requests, import an OpenAPI or Postman
  specification, and read the history of what was sent, using the `postfrau` command line tool.
  Use this whenever the user mentions postfrau, an API collection, an OpenAPI or Swagger spec,
  running or sending a saved request, or asks to try an HTTP endpoint and keep it for later.
---

# postfrau

`postfrau` is the command line half of Postfrau, a macOS HTTP client. It reads and writes the
same collections the app shows, and everything it sends appears in the app's history attributed
to you.

Run `postfrau --help`, or `postfrau <command> --help`, for the full flag list. This file covers
what you need to work without further help.

## Ground rules

- **Say who you are.** Pass `--as claude` (or set `POSTFRAU_AGENT=claude`) so the user can see
  in the app which requests came from you. Do this on every command that sends.
- **Secrets are hidden.** Values marked secret print as `•••`. `--reveal` prints them; only use
  it when the user has asked you to show one.
- **Nothing is destructive by accident.** `rm` refuses to run without `--yes`.
- **Check before you send.** `--dry-run` prints the exact request — final URL, headers, body —
  and writes no history.
- **`--json` for parsing.** The human output is aligned text meant for a terminal; do not parse
  it. `run --all --json` emits NDJSON, one object per line.

## Addressing things

Items are addressed by path, from the collection down, case-insensitively:

```
postfrau get 'Acme API/Users/List users'
```

A literal `/` in a name is written `\/`. A UUID works anywhere a path does.

## Commands

### Looking around

```bash
postfrau ls                                  # collections
postfrau ls 'Acme API' --tree                # the whole tree
postfrau get 'Acme API/Users/List users'     # one request, resolved
postfrau get 'Acme API/Users/List' --json    # the same, machine-readable
```

`get` shows both the stored URL (`{{baseUrl}}/users`) and what it resolves to right now, plus
any variables nothing defines — check `unresolvedVariables` before deciding a request is broken.

### Sending

```bash
postfrau run 'Acme API/Users/List users' --as claude
postfrau run 'Acme API/Users' --all --json --as claude      # a whole folder, NDJSON
postfrau run 'Acme API/Health' --dry-run                    # what would be sent
postfrau send GET https://api.example.com/health --as claude
postfrau send POST https://api.example.com/users \
  -H 'Content-Type: application/json' -d '{"name":"Ada"}' --as claude
```

Useful flags: `--var k=v` overrides a variable for this run; `--fail` exits 4 on a status of 400
or more; `--max-body 1m` raises the body limit; `--out file.json` writes the body to a file.

### Editing

```bash
postfrau add 'Acme API' --collection                        # a new collection
postfrau add 'Acme API' --folder --name Users
postfrau add 'Acme API/Users' --url 'https://api.example.com/users' --name 'List users'
postfrau add 'Acme API/Users' --from-curl "curl -X POST https://api.example.com/users -d '{}'"
postfrau set 'Acme API/Users/List users' --method GET -H 'Accept: application/json'
postfrau set 'Acme API/Users/List users' -H 'X-Debug:'      # an empty value removes it
postfrau mv 'Acme API/Health' 'Acme API/Users'
postfrau rm 'Acme API/Users/Old' --yes
```

`set` changes only what it is given; everything else is left alone.

### Environments

```bash
postfrau env ls
postfrau env add Staging
postfrau env set Staging baseUrl=https://staging.example.com
postfrau env set Staging token=abc123 --secret
postfrau env use Staging
postfrau env get Staging                     # secrets print as •••
```

### Importing a specification

```bash
postfrau validate api.json      # what is this file, and what will be lost?
postfrau import api.json        # OpenAPI 3.x, or a Postman collection or environment
```

An OpenAPI import gives you a sendable collection, not a transcription: `servers[0]` becomes
`{{baseUrl}}`, tags become folders, path templates become `{{variables}}` to fill in, security
becomes the collection's auth with `{{token}}` placeholders, and a request body is built from the
spec's example — or synthesised from its schema when it gives none. Read the warnings: they name
what could not be modelled.

JSON only. For a YAML spec, convert it first: `yq -o=json spec.yaml > spec.json`.

### History

```bash
postfrau history --last 20
postfrau history --agent claude --since 2h
postfrau history --status 5xx --json
postfrau history show 1f0d567c
```

## The `--json` shapes

`ls` → an array of `{path, name, kind, id, method?, url?, depth}`.

`get` → `{path, id, name, method, url, resolvedURL, headers[], params[], auth, body, description?,
unresolvedVariables[]}`. `auth` is a word (`bearer`, `basic:ada`, `none`, `inherit`), never a
credential.

`run` / `send` → `{path?, name, method, url, status?, reason?, durationMs, bytes, headers[],
body?, bodyTruncated, error?, captured{}, warnings[]}`. `status` is absent and `error` is set when
the request never reached a server.

`history` → an array of `{id, sentAt, method, url, status?, durationMs, bytes, source, error?,
recorded}`. `history show <id> --json` returns the full entry instead.

For the file formats themselves, run `postfrau schema collection|request|environment|history`.

## Exit codes

| code | meaning |
|------|---------|
| 0 | ok |
| 1 | usage — a bad flag, a missing argument, an edit that changes nothing |
| 2 | not found — no such path, environment or history entry |
| 3 | the request never reached a server |
| 4 | an HTTP status of 400 or more, and `--fail` was given |
| 5 | the data folder is unavailable |

## Workflows

### Explore an API and keep what works

```bash
postfrau send GET https://api.example.com/v1/status --as claude
postfrau add 'My API' --collection
postfrau add 'My API' --folder --name Health
postfrau send GET https://api.example.com/v1/status \
  --save-to 'My API/Health' --name 'Status' --as claude
postfrau run 'My API/Health/Status' --as claude
```

Build the collection as you learn the API, rather than at the end: each `--save-to` keeps a
request that already worked.

### Run a request and look at the response

```bash
postfrau run 'Acme API/Users/List users' --json --as claude > response.json
```

Then read `response.json`. Prefer `--json` and a file over reading a large body off stdout. If
`status` is missing and `error` is set, the request failed before it reached the server — check
the URL with `postfrau get <path>` rather than retrying blindly.

### Log in, then call an authenticated endpoint

```bash
postfrau env use Staging
postfrau run 'Acme API/Auth/Login' --capture token='$.data.access_token' --secret --as claude
postfrau run 'Acme API/Users/Me' --as claude
```

`--capture` evaluates a small JSONPath (`$.a.b[0].c`) against the response and stores the result
in the active environment, so `{{token}}` in the next request resolves. With `--all`, a capture
from one request is visible to the ones after it, so a whole folder can log in and then work.

If the capture matches nothing, the command exits 2 and says so — the request itself still
succeeded, and is in the history.

## When something is not working

- `postfrau version` prints which data folder is in use and where it came from.
- Exit code 5 means the folder is not available: an unmounted volume, or a path the app has
  since changed. `--data-dir` points at one explicitly.
- A secret that will not resolve may be a Keychain prompt nobody answered. Supply it for one
  command with `POSTFRAU_SECRET_<KEY>=value` in the environment instead.