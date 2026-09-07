# Postfrau — status

**Current phase:** 8 (History) — next
**Last completed:** Phase 7 — Environments, globals, secrets
**Build:** green — `make test` passes: 325 Core tests (~5 s) plus 13 app unit tests.

> **UI tests need a free desktop.** `make ui-test` runs the XCUITest suite separately, because it
> drives the real UI and therefore needs a display where Postfrau's window can come to the front.
> Partway through Phase 6 this machine's display became occupied by a full-screen app on its own
> Space, and from that point every click-based test failed — including tests that had just passed
> on unchanged, committed code. `make test` (the commit gate) is unaffected.
> See `docs/decisions.md` D22.

> **Plan revision R3** (`PLAN.md`, 2026-09-07) added a `postfrau` CLI + Claude Code skill as
> **Phase 11**, rewrote **Phase 8** (per-entry history files, recording levels, attribution), and
> renumbered Polish & release to **Phase 12**. The `Commands/SendRequest` extraction R3 wanted in
> Phase 3 happens at the start of Phase 11 (`docs/decisions.md` D11).

## What works

Compose a request, organise it, send it, read the response — the whole loop.

- **Core**: domain model and persistence; variable and auth resolvers; `RequestBuilder` and
  `HTTPExecutor`; JSON/XML pretty printers and highlighters; `ContentTypeSniffer`; `FuzzyMatcher`;
  `CollectionFilter`; tree navigation and moves; the stress-collection generator.
- **Request editor**: key/value tables with completion, params mirrored two-way with the URL,
  headers plus a computed "Postfrau will also send" list, the full auth tab, every body mode with
  JSON Beautify and file pickers, a URL field that colours and explains `{{variables}}`, dirty
  tracking with a save prompt.
- **Response viewer**: Pretty / Raw / Preview / Headers / Cookies, highlighting computed off-main,
  HTML in a `WebView` with JavaScript and subresource loading off, images and PDFs inline, a hex
  dump for binary, the system find bar, timing popover, redirect chain.
- **Environments** (new): the ⌘E window with environments on the left and globals pinned first;
  variables with a secret toggle, kept in the Keychain and blanked on disk; the toolbar picker and
  its resolved-value quick-look (sources labelled, shadowing shown, secrets masked until clicked);
  unresolved-variable markers on the request editor's section tabs and in the Send tooltip.
- **Collections**: create / rename / duplicate / delete collections, folders and requests
  from context menus and shortcuts; drag-and-drop between folders and across collections, with
  illegal drops (a folder into itself) refused; collection and folder editor tabs for name,
  description, auth and variables; a filter that keeps ancestors visible and highlights matches;
  ⌘K fuzzy quick open; ⌘Z undo for every structural edit; a Debug menu that generates a
  5 000-request collection.

**Measured**: 2.2 MB pretty-prints in ~0.6 s and tokenizes in ~0.18 s. A 22 MB response renders its
first megabyte and stays interactive. A 5 000-request collection loads in 1.5 s to an interactive
window, and seven successive filter passes over it take under 350 ms in total.

## Next

Phase 8 (rewritten by R3): `HistoryStore` with one file per entry, recording levels
(off / metadata / headers / full) with redaction, attribution (`.app` / `.cli` / `.agent`), and the
sidebar's history section.

## Known issues / limitations

- The 5 000-request **end-to-end typing-latency** assertion is unverified — see the note above and
  `PLAN.md` Phase 6. Everything it was written to catch has been fixed and is covered by Core tests.
- The environments window has not been eyeballed yet — it is covered by tests, but the display
  problem above blocks a screenshot of a window that has never been shown (`docs/decisions.md` D27).
- **iCloud Keychain sync cannot work on this build.** Synchronizable Keychain items need a real
  signing identity; an ad-hoc build gets `errSecMissingEntitlement`. The toggle now reports that
  and reverts rather than pretending (`docs/decisions.md` D26). Local secret storage works fully.
- The Settings *window* does not exist yet (Phase 12), so preferences without an inline control —
  notably "allow JavaScript in previews" — can only be changed by editing `settings.json`.
- `URLSession` occasionally leaves a `CFNetworkDownload_*.tmp` in the container's tmp when a
  download is cancelled. Postfrau's own spill files are cleaned up; these are the framework's.
- App icon is a placeholder mark (Phase 12). Hardened runtime is off in the generated project and
  enabled only by `Scripts/release.sh` (`docs/decisions.md` D3).

## Decisions taken

`docs/decisions.md` D1–D27. Most consequential: D9 `download(for:)` instead of `bytes(for:)` ·
D11 `Commands` extraction deferred to Phase 11 · D20 response bodies wrap by default (TextKit was
measuring one multi-megabyte line and blocking the main thread for 30 s) · D22 UI tests split out
of the commit gate · D24 the sidebar filter is computed once per change and capped ·
D25 menu commands hold the state instead of reading it through focus.
