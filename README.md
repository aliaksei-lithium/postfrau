<p align="center">
  <img src="docs/images/icon.png" width="132" alt="">
</p>

<h1 align="center">Postfrau</h1>

<p align="center">
  An HTTP client for macOS 26.<br>
  Collections are JSON files in a folder you choose — no account, no cloud, nothing uploaded.
</p>

<p align="center">
  <a href="https://github.com/aliaksei-lithium/postfrau/releases/latest"><img src="https://img.shields.io/github/v/release/aliaksei-lithium/postfrau?color=6b4fe8&label=download" alt="Latest release"></a>
  <img src="https://img.shields.io/badge/macOS-26-6b4fe8" alt="macOS 26">
  <img src="https://img.shields.io/badge/licence-MIT-6b4fe8" alt="MIT licence">
</p>

![Postfrau](docs/images/main.png)

## Install

Download the DMG from [Releases](https://github.com/aliaksei-lithium/postfrau/releases) and drag
Postfrau to Applications.

The app is ad-hoc signed, so macOS quarantines it. Either **right-click → Open** the first time,
or clear the flag:

```bash
xattr -dr com.apple.quarantine /Applications/Postfrau.app
```

If macOS still refuses with *"Postfrau is damaged"*, that is the quarantine flag — the command
above fixes it.

## Features

- Request editor: params mirrored with the URL, headers, all auth schemes, every body mode
- Response viewer: pretty / raw / preview / headers / cookies, images and PDFs inline, hex for binary
- Collections and folders with inherited variables and auth
- Environments and globals; secrets live in the Keychain, never in the files
- History of every send, redacted by default
- Light, dark or follow-the-system, set per machine — the collections folder stays shared
- Sync by pointing the data folder at iCloud Drive, Dropbox or a git checkout
- Import OpenAPI 3.x; import/export Postman v2.1 and cURL, both directions
- `postfrau` CLI that does all of the above from a shell, including `find` across every request
- A loopback API, so an agent in a sandbox that cannot read your files can still list and send

## Importing an API

```bash
postfrau import openapi.json     # OpenAPI 3.x, or a Postman collection/environment
```

Or **File ▸ Import…**, or drop the file on the sidebar.

An OpenAPI import produces a collection you can send from: `servers[0]` becomes `{{baseUrl}}`,
tags become folders, path templates become `{{variables}}`, security becomes the collection's
auth, and bodies come from the spec's examples — or are synthesised from its schemas. JSON only;
convert YAML first with `yq -o=json spec.yaml > spec.json`.

## CLI

```bash
postfrau find deposit balance                 # search names, paths, descriptions, URLs
postfrau get 'Acme API/Users/List users'      # stored URL, resolved URL, what is unresolved
postfrau run 'Acme API/Users/List users' --env staging --var user_id=42 --json
postfrau send POST https://api.example.com/users -H 'Content-Type: application/json' -d '{"name":"Ada"}'
postfrau history --last 20
```

`run` can change a saved request for one send, without saving anything — check it first with
`--dry-run`, which prints the body, its size, and whether it is as saved or from `--body`:

```bash
postfrau run 'Payments/Create' --body @payload.json --dry-run   # replace the body; {{vars}} resolve
postfrau run 'Payments/Create' --field partner_bank_id=42        # set one JSON field
postfrau run 'Payments/Create' -H 'X-Request-ID: abc'            # add or replace a header
```

And send the same request once per line of a file — one NDJSON line per send with `--json`,
each carrying its input and its own correlation id:

```bash
postfrau run 'Payments/Create' --from-file banks.txt --each bank \
  --field 'partner_bank_id={{bank}}' --correlation-header X-Correlation-ID --json
```

Install it from **Settings ▸ Advanced**, or `make install` from a checkout.

For agents: `postfrau skill install --to .claude/skills/postfrau` writes a `SKILL.md` with the
commands, JSON shapes and exit codes.

## Build

Needs macOS 26, Xcode 26 and [XcodeGen](https://github.com/yonaskolb/XcodeGen). No other dependencies.

```bash
make gen      # generate the Xcode project
make build    # app + CLI
make run
make test     # 562 Core tests + app tests
make release  # signed DMG in dist/
```

Set `CODESIGN_IDENTITY` to sign with a Developer ID, `NOTARY_PROFILE` to notarize. Both optional.

## Where your data lives

| What | Where | Synced |
|---|---|---|
| Collections, environments, globals | the folder you choose | by your sync client |
| Secrets | login Keychain | only with iCloud Keychain on |
| History, settings, window state | app container | never |

## Not Supported

No scripting, test assertions, mock server, team sync, WebSocket or gRPC.

## Licence

MIT
