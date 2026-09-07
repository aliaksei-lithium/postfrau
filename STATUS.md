# Postfrau — status

**Current phase:** 6 (Collections management) — next
**Last completed:** Phase 5 — Response viewer
**Build:** green — `make test` passes: 270 Core tests (~5 s), app unit tests, and 16 XCUITests that
drive the real UI.

> **Plan revision R3** (`PLAN.md`, 2026-09-07) added a `postfrau` CLI + Claude Code skill as
> **Phase 11**, rewrote **Phase 8** (per-entry history files, recording levels, attribution), and
> renumbered Polish & release to **Phase 12**. The `Commands/SendRequest` extraction R3 wanted in
> Phase 3 happens at the start of Phase 11, following that item's own instruction
> (`docs/decisions.md` D11).

## What works

**Compose a request, send it, read the response.** That whole loop is done and checked by tests
that drive the real UI, not by eye.

- **Core**: domain model and persistence; variable and auth resolvers; `RequestBuilder` and
  `HTTPExecutor`; `JSONPrettyPrinter` and `XMLPrettyPrinter` (tokenizers — key order, duplicate
  keys and number precision all survive); `JSONHighlighter` and `XMLHighlighter`;
  `ContentTypeSniffer`; `KeyValueRows`, `HeaderCatalog`, `ByteCount`.
- **Request editor**: key/value tables with completion, params mirrored two-way with the URL,
  headers plus a computed "Postfrau will also send" list, the full auth tab, every body mode with
  JSON Beautify and file pickers, a URL field that colours and explains `{{variables}}`, dirty
  tracking with a save prompt, inline rename.
- **Response viewer**: Pretty / Raw / Preview / Headers / Cookies; syntax highlighting computed
  off-main and applied when ready; HTML rendered in a `WebView` with JavaScript *and* subresource
  loading off so a preview cannot phone home; images and PDFs inline; a hex dump plus Save for
  binary; the system find bar (⌘F); wrap and line-number toggles; copy and save; a timing popover
  with a per-phase bar chart; the redirect chain; a friendly error card with Retry.

**Measured**: 2.2 MB pretty-prints in ~0.6 s and tokenizes in ~0.18 s. A 22 MB response downloads,
renders its first megabyte, and stays interactive while switching views and scrolling.

## Next

Phase 6: sidebar editing — create / rename / duplicate / delete / drag-and-drop, the collection and
folder editor, filtering, ⌘K quick open, undo, and the 5 000-request stress test.

## Known issues / limitations

- Sidebar is read-only apart from rename (Phase 6). No environments editor yet (Phase 7).
- The Settings *window* does not exist yet (Phase 12), so preferences that have no inline control —
  notably "allow JavaScript in previews" — can only be changed by editing `settings.json`.
- `URLSession` occasionally leaves a `CFNetworkDownload_*.tmp` in the container's tmp when a
  download is cancelled. Postfrau's own spill files are cleaned up; these are the framework's.
- App icon is a placeholder mark (Phase 12). Hardened runtime is off in the generated project and
  enabled only by `Scripts/release.sh` (`docs/decisions.md` D3).
- `ResponseViewerTests.testALargeResponseStaysResponsive` needs a local fixture server and skips
  without one; the file's doc comment says how to start it.

## Decisions taken

`docs/decisions.md` D1–D21. Most consequential: D9 `download(for:)` instead of `bytes(for:)`
(~40x faster on large bodies) · D11 `Commands` extraction deferred to Phase 11 · D13 accessibility
defects only driving the real UI could find · D18 ⌘W intercepted with a key monitor ·
D20 response bodies wrap by default, after sampling found TextKit measuring one multi-megabyte
line and blocking the main thread for 30 s.
