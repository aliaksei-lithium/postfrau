# Postfrau — status

**Current phase:** 2 (HTTP executor) — starting
**Last completed:** Phase 1 — Core models, persistence, resolver
**Build:** green — `make test` passes (117 Core tests in 0.4 s, plus app unit + UI smoke tests)

## What works

- Full domain model (`PLAN.md` §3) with explicit `CodingKeys`, `schemaVersion` on every persisted
  root, `type` discriminators on the payload enums, and tolerant decoding (unknown keys ignored,
  missing keys fall back to defaults).
- `WorkspaceStore` actor: loads and saves collections / environments / globals to an injectable
  data folder, plus settings and UI state to an injectable local root. Atomic + file-coordinated
  writes, `revision` bumps, `(revision, mtime, sha256)` fingerprints, malformed documents reported
  and skipped, foreign filenames ignored.
- `VariableResolver`: precedence, recursion with a depth limit, cycle detection, `{{ spaced }}`
  keys, `\{{escapes}}`, unshadowable `{{$dynamic}}` variables, and a tokenizer for the URL bar.
- `AuthResolver`: `.inherit` walks folder → collection, reports the source, and computes the
  header or query parameter that goes on the wire.
- `Keychain` (secrets), `HistoryLog` (JSONL, pruning, tolerant of a truncated last line),
  `Migrations` (version gate + hook), `AtomicFile`, `DataFolder` (provider detection, status).
- `docs/data-format.md` documents the on-disk format.

## Next

Phase 2: `RequestBuilder` (query merge, multipart, urlencoded, raw, auth application, default
headers) and the `HTTPExecutor` actor (per-profile `URLSession`s, TLS override, redirect
recording, `URLSessionTaskMetrics` → `Timing`, streaming body with spill to disk), tested through
a `URLProtocol` mock.

## Known issues / limitations

- App icon is a placeholder mark; the real one lands in Phase 11.
- The app UI is still the Phase 0 placeholder — nothing is wired to Core yet.
- Hardened runtime is off in the generated project and only enabled by `Scripts/release.sh`
  (`docs/decisions.md` D3).

## Decisions taken

`docs/decisions.md`: D1 hand-written `.icon` bundle · D2 `SWIFT_VERSION` spelling · D3 hardened
runtime placement · D4 UI-test actor isolation · D5 model type renames to avoid `Swift.Collection`,
`SwiftUI.Environment` and `View.Body` collisions · D6 CryptoKit in Core for SHA-256 ·
D7 fractional-second ISO-8601 timestamps · D8 `Keychain.deleteAll` loops `SecItemDelete`.
