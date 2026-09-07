# Postfrau on-disk format

Schema version **1**.

Everything Postfrau persists is JSON, one document per file, human-readable and diffable. There
are two roots with very different rules.

## Roots

### Data folder — syncable

Default `~/Library/Application Support/Postfrau/Data` inside the app container; the user can
point it anywhere (Settings ▸ Data), typically at a folder inside iCloud Drive, Google Drive or
Dropbox so a sync client — never Postfrau — moves the bytes between Macs.

```
<data folder>/
├── postfrau-workspace.json          marker; identifies the folder as a Postfrau workspace
├── collections/<uuid>.json          one file per collection, whole tree inside
├── environments/<uuid>.json         one file per environment
└── globals.json                     variables visible everywhere
```

Rules:

- **One document per file.** A sync client can copy files independently without producing an
  inconsistent workspace.
- **Atomic writes.** Bytes go to a hidden temporary file in the *same* directory and are renamed
  over the destination, so a reader never sees a half-written document.
- **Coordinated writes.** Every read and write in the data folder is wrapped in
  `NSFileCoordinator`, which is how iCloud Drive learns about the change. (The built-in default
  folder lives inside the sandbox container where nothing else touches it, so coordination is
  skipped there.)
- **Only `<uuid>.json` is ours.** Anything else in `collections/` or `environments/` — a Dropbox
  "conflicted copy", a stray note — is ignored rather than mis-parsed.
- **Reads tolerate unknown keys** and missing fields, which fall back to their defaults.
- **Secrets never land here.** A variable with `isSecret: true` is written with an empty `value`;
  the real value lives in the Keychain.
- Every synced document carries `revision` (incremented on each write) and `updatedAt`. The store
  remembers the `(revision, mtime, sha256)` it last wrote per file so a later change can be
  recognised as Postfrau's own or as one delivered by a sync client.

### Local state — never leaves the machine

`~/Library/Containers/com.postfrau.Postfrau/Data/Library/Application Support/Postfrau/`

```
├── settings.json      preferences, incl. the data folder's security-scoped bookmark
├── ui-state.json      open tabs (with unsaved drafts), selection, window frame, active environment
├── history.jsonl      one HistoryEntry per line, pruned to maxHistoryEntries
└── conflicts/         foreign versions saved when a sync conflict is detected
```

`history.jsonl` is line-delimited rather than one array so appending is O(1) and a crash mid-write
can cost at most the last entry — the loader skips lines that fail to decode.

## Conventions

- **Timestamps** are ISO-8601 with fractional seconds (`2026-09-07T14:18:52.500Z`). The decoder
  also accepts the plain form so documents written by other tools still load.
- **Identifiers** are lower-cased UUID strings. A collection's file name is its id.
- **Object keys are sorted** so a diff shows real changes, not re-ordering.
- **Enums with payloads** (`Auth`, `RequestBody`, `CollectionItem`, `FormValue`) carry a `type`
  discriminator plus the fields for that case:

```json
{ "type": "bearer", "token": "{{apiToken}}" }
{ "type": "folder", "folder": { "id": "…", "name": "Users", "items": [] } }
```

- **Unmodelled fields survive.** Importing a Postman collection keeps anything Postfrau does not
  understand (`event[]` scripts, `protocolProfileBehavior`, vendor extensions) under `extras` on
  the nearest node, so export round-trips them untouched.

## Variables

Resolution precedence, highest first: **active environment → folder chain (innermost first) →
collection → globals**. Values may reference other variables, recursively, to a depth of 10;
a cycle or an over-deep chain leaves the reference as literal text and is reported to the UI.
`{{$dynamic}}` names (`$guid`, `$randomUUID`, `$timestamp`, `$isoTimestamp`, `$randomInt`) are
evaluated last and can never be shadowed by a user variable. Whitespace inside the braces is
trimmed (`{{ baseUrl }}` works). A backslash escapes the opening braces: `\{{notAVariable}}`
renders as the literal text `{{notAVariable}}`.

## Keychain

Secret variable values are generic passwords:

| Attribute | Value |
|---|---|
| `kSecAttrService` | `com.postfrau.secrets` |
| `kSecAttrAccount` | `"<environmentID>.<variableKey>"` |
| `kSecAttrAccessible` | `kSecAttrAccessibleAfterFirstUnlock` |
| `kSecAttrSynchronizable` | follows the "Sync secrets via iCloud Keychain" setting |

Globals use the fixed scope id `00000000-0000-0000-0000-0000000067CB` in place of an environment
id. Deleting a variable or an environment deletes its Keychain items. Because
`kSecAttrSynchronizable` is part of an item's identity, flipping the iCloud setting rewrites every
item rather than updating a flag.

## Versioning

Every persisted root document carries `schemaVersion`. On load the raw JSON passes through
`Migrations.migrate(_:)` before decoding, so the model types never need to know about historical
shapes. A document from a *newer* schema is refused with a readable error rather than being
silently mangled.

Bumping `Postfrau.schemaVersion` requires:

1. a step in `Migrations.steps` that converts version *n* to *n + 1*, and
2. a fixture test that loads a real document written by the older build.
