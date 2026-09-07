# Postfrau — status

**Current phase:** 5 (Response viewer) — next
**Last completed:** Phase 4 — Request editor complete
**Build:** green — `make test` passes: 227 Core tests (~5 s), app unit tests, and 12 XCUITests that
drive the real UI.

> **Plan revision R3** (`PLAN.md`, 2026-09-07) added a `postfrau` CLI + Claude Code skill as
> **Phase 11**, rewrote **Phase 8** (per-entry history files, recording levels, attribution), and
> renumbered Polish & release to **Phase 12**. The `Commands/SendRequest` extraction R3 wanted in
> Phase 3 happens at the start of Phase 11, following that item's own instruction
> (`docs/decisions.md` D11).

## What works

**The request composer is complete.** A POST with a JSON body, a bearer token and two query
parameters against `httpbin.org/anything` comes back with everything echoed correctly, and a
form-data file upload — picked through `NSOpenPanel`, stored as a security-scoped bookmark,
streamed from disk — arrives with its contents intact. Both are XCUITests, not claims.

- **Core** (Phases 1–2, plus Phase 4 additions): domain model, `WorkspaceStore`,
  `VariableResolver`, `AuthResolver`, `Keychain`, `HistoryLog`, `RequestBuilder`, `HTTPExecutor`,
  and now `JSONPrettyPrinter` (byte-level tokenizer: key order, duplicate keys and full number
  precision survive; 2.2 MB in well under a second), `KeyValueRows`, `HeaderCatalog`.
- **App**: everything from Phase 3, plus the full editor — `KeyValueEditor` with a trailing blank
  row, hover-delete and ⌘⌫; Params mirrored two-way with the URL; Headers with name/value
  autocomplete and a read-only "Postfrau will also send" section computed by the real builder;
  the Auth tab (Inherit / None / Basic / Bearer / API Key) with reveal toggles and an on-the-wire
  preview; every body mode with a JSON Beautify button and file pickers; a `TokenTextField` URL bar
  that colours `{{variables}}` green or red and explains them on hover; dirty tracking with a
  Save / Don't Save / Cancel prompt; inline rename from the tab and the sidebar.

## Next

Phase 5: the response viewer — `JSONHighlighter` / `XMLHighlighter`, Pretty / Raw / Preview tabs
(SwiftUI `WebView` with JavaScript off), the large-body policy, find bar, timing popover, redirect
chain, and the hex view for binary responses.

## Known issues / limitations

- The response body is not syntax-highlighted or pretty-printed yet (Phase 5).
- Sidebar is read-only — no create/delete/drag; only rename (Phase 6).
- No environments editor yet (Phase 7): variables can be read but not edited in the UI.
- `URLSession` occasionally leaves a `CFNetworkDownload_*.tmp` in the container's tmp when a
  download is cancelled. Postfrau's own spill files are cleaned up; these are the framework's.
- App icon is a placeholder mark (Phase 12). Hardened runtime is off in the generated project and
  enabled only by `Scripts/release.sh` (`docs/decisions.md` D3).

## Decisions taken

`docs/decisions.md` D1–D18. Most consequential: D5 model type renames · D9 `download(for:)` instead
of `bytes(for:)` (~40x faster on large bodies) · D11 `Commands` extraction deferred to Phase 11 ·
D13 four accessibility defects only driving the real UI could find · D16 pretty printer built a
phase early · D17 blank editor rows normalized out of dirty tracking · D18 ⌘W intercepted with a
key monitor, because SwiftUI reverts menu edits and a `Window` scene quits when its last window
closes.
