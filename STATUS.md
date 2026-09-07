# Postfrau — status

**Current phase:** 4 (Request editor complete) — next
**Last completed:** Phase 3 — App shell & first end-to-end send
**Build:** green — `make test` passes: 193 Core tests (5.3 s), app unit tests, and 5 XCUITests that
drive the real UI.

> **Plan revision R3** (`PLAN.md`, 2026-09-07) added a `postfrau` CLI + Claude Code skill as
> **Phase 11**, rewrote **Phase 8** (per-entry history files, recording levels, attribution), and
> renumbered Polish & release to **Phase 12**. R3 also asked for the send pipeline to move into a
> Core `Commands` layer during Phase 3; that phase was already built when the revision landed, so —
> following the item's own instruction — the extraction happens at the start of Phase 11
> (`docs/decisions.md` D11).

## What works

**The app sends requests end to end.** Launch → pick a request from the sample collection → ⌘↩ →
status, timing, size, pretty-ish body, headers and cookies. Cancel works mid-flight, tabs and
window state come back after a relaunch.

- **Core** (Phases 1–2): full domain model, `WorkspaceStore` (atomic + file-coordinated writes,
  revisions, own-write fingerprints), `VariableResolver`, `AuthResolver`, `Keychain`, `HistoryLog`,
  `RequestBuilder` (every body mode), `HTTPExecutor` (per-profile sessions, TLS override, redirect
  recording, metrics → timing, disk-streamed bodies, real cancellation).
- **App**: `AppState` with debounced autosave driven by the macOS 26 `Observations` sequence;
  `NavigationSplitView` shell with a persisted, draggable split; sidebar outline + history list;
  custom tab bar (dirty dot, close, drag to reorder, ⌘T/⌘W/⌘⇧[/]); URL bar, method picker,
  Send/Cancel with a progress bar; response pane with status pill, timing, size, body in an
  `NSTextView`, headers and cookies tables; toolbar environment picker with a resolved-variable
  quick-look; status bar; menu bar with the Phase 3 shortcuts; first-run sample collection.
- **Verification**: the Phase 3 acceptance criteria are XCUITests, not eyeballing — launch,
  open-from-sidebar-and-send, cancel a 10 s request, and restore tabs across a ⌘Q. A separate
  `ScreenshotTests` captures the window in light and dark.

## Next

Phase 4: `KeyValueEditor`, params ↔ URL two-way sync, headers with autocomplete and an
"auto headers" section, the full Auth tab, all body modes, the `TokenTextField` URL bar with
`{{variable}}` colouring, dirty-tab save prompts, and inline rename.

## Known issues / limitations

- Params / Headers / Auth tabs are read-only placeholders until Phase 4; the raw JSON body editor
  works. The response body is not syntax-highlighted or pretty-printed yet (Phase 5).
- Sidebar is read-only — no create/rename/delete/drag (Phase 6).
- `URLSession` leaves occasional `CFNetworkDownload_*.tmp` files in the container's tmp when a
  download is cancelled. Postfrau's own spill files are cleaned up; these are the framework's.
- App icon is a placeholder mark (Phase 12). Hardened runtime is off in the generated project and
  enabled only by `Scripts/release.sh` (`docs/decisions.md` D3).

## Decisions taken

`docs/decisions.md` D1–D15. Most consequential: D5 model type renames · D9 `download(for:)` instead
of `bytes(for:)` (measured ~40x faster on large bodies) · D11 `Commands` extraction deferred to
Phase 11 · D12 the three launch overrides and why each is needed · D13 four accessibility defects
that only driving the real UI could find · D14 quit-time flush.
