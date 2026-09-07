# Postfrau — status

**Current phase:** 3 (App shell & first end-to-end send) — starting
**Last completed:** Phase 2 — HTTP executor
**Build:** green — `make test` passes (193 Core tests in 5.3 s, plus app unit + UI smoke tests)

## What works

Core is feature-complete for sending:

- **Model & persistence** (Phase 1): full domain model, `WorkspaceStore` with atomic +
  file-coordinated writes and own-write fingerprints, `Keychain`, `HistoryLog`, `Migrations`.
- **Resolvers** (Phase 1): `VariableResolver` (precedence, recursion, cycles, escapes, dynamics,
  URL-bar tokens) and `AuthResolver` (inherit chain + wire values).
- **`RequestBuilder`**: variable resolution, params-own-the-query composition with an
  `encodeURL` switch, auth application (header or query), default headers the user can override,
  and every body mode — raw with per-language `Content-Type`, urlencoded with form escaping,
  multipart (in memory when text-only, streamed from a temp file as soon as a part is a file),
  and binary streamed from a security-scoped bookmark.
- **`HTTPExecutor`** actor: per-profile `URLSession`s with their own cookie jars, TLS override,
  redirect recording and limits, `URLSessionTaskMetrics` → `Timing`, bodies streamed to disk with
  a 20 MB spill threshold and a 200 MB cap enforced mid-transfer, and real task cancellation.
- Cookie parsing, reason phrases, byte/duration formatting.

Verified live: `GET https://example.com` → `200 OK  559 B  125 ms`, with a full DNS / Connect /
TLS / Request / Waiting / Download breakdown. Opt-in live tests run with `POSTFRAU_LIVE_TESTS=1`.

## Next

Phase 3: `AppState`, the three-pane layout, tab bar, URL bar, `SendController`, the response pane
with a `CodeTextView` (NSTextView), the toolbar environment picker, and a first-run sample
collection — i.e. the first end-to-end send from the UI.

## Known issues / limitations

- The app UI is still the Phase 0 placeholder; nothing is wired to Core yet.
- App icon is a placeholder mark; the real one lands in Phase 11.
- Hardened runtime is off in the generated project and enabled only by `Scripts/release.sh`
  (`docs/decisions.md` D3).

## Decisions taken

`docs/decisions.md`: D1 hand-written `.icon` bundle · D2 `SWIFT_VERSION` spelling · D3 hardened
runtime placement · D4 UI-test actor isolation · D5 model type renames · D6 CryptoKit in Core ·
D7 fractional-second timestamps · D8 `Keychain.deleteAll` loops `SecItemDelete` ·
D9 `download(for:)` instead of `bytes(for:)` (measured 40x faster on large bodies) ·
D10 session profiles key on TLS and cookies only.
