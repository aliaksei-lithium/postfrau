# Postfrau — status

**Current phase:** 9 (Sync via data folder) — next
**Last completed:** Phase 8 — History
**Build:** green — `make test` passes: 339 Core tests (~6 s) plus 23 app unit tests.

> **UI tests need a free, awake desktop.** `make ui-test` runs the XCUITest suite separately,
> because it drives the real UI and needs a display where Postfrau's window can come to the front.
> `make test` (the commit gate) is unaffected. See `docs/decisions.md` D22.
>
> Part of what looked like an occupied display in Phase 6 was the display being *asleep*: with the
> screen off, `screencapture -l` fails with "could not create image from window", every window is
> reported off-screen, and the accessibility API returns no windows at all. `caffeinate -u -t 3`
> before a screenshot makes all three work. Phase 8 was eyeballed this way, in light and dark.

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
- **History** (new): one JSON file per send under `history/<day>/`, so the app and (from Phase 11)
  the CLI can record at the same time without a shared file to tear. Recording levels — **off**,
  **metadata** (the default), **headers**, **full** — set app-wide in Settings ▸ History and
  overridable per collection. Redaction runs before every write, at every level: sensitive headers
  are blanked, and every secret variable *and* every credential typed into the Auth tab is replaced
  with ••• wherever it appears, including inside a body echoed back by the server. Every entry
  records who sent it (`.app` / `.cli` / `.agent(name)`). The sidebar groups by day with method,
  status colour, path, relative time and a badge on anything not sent from the app; it filters by
  text and by source. Opening an entry gives a tab whose response pane shows the recording
  read-only under a "recorded" banner — re-attached from the log after a relaunch, and replaced the
  moment you send from that tab. "Save to Collection", delete one, clear all.
- **Collections**: create / rename / duplicate / delete collections, folders and requests
  from context menus and shortcuts; drag-and-drop between folders and across collections, with
  illegal drops (a folder into itself) refused; collection and folder editor tabs for name,
  description, auth and variables; a filter that keeps ancestors visible and highlights matches;
  ⌘K fuzzy quick open; ⌘Z undo for every structural edit; a Debug menu that generates a
  5 000-request collection.

**Measured**: 2.2 MB pretty-prints in ~0.6 s and tokenizes in ~0.18 s. A 22 MB response renders its
first megabyte and stays interactive. A 5 000-request collection loads in 1.5 s to an interactive
window, and seven successive filter passes over it take under 350 ms in total. 1 000 history
entries across five day folders load in 71 ms. A second process and the in-process store each
append 150 entries at once with nothing lost and no torn read.

## Next

Phase 9 — sync via the data folder: a user-chosen folder resolved from a security-scoped bookmark,
file coordination, external-change detection and conflict handling.

## Known issues / limitations

- The 5 000-request **end-to-end typing-latency** assertion is unverified — see the note above and
  `PLAN.md` Phase 6. Everything it was written to catch has been fixed and is covered by Core tests.
- The environments window has not been eyeballed yet — it is covered by tests
  (`docs/decisions.md` D27). Now that the display wakes on demand, this is worth a look in Phase 9.
- **iCloud Keychain sync cannot work on this build.** Synchronizable Keychain items need a real
  signing identity; an ad-hoc build gets `errSecMissingEntitlement`. The toggle now reports that
  and reverts rather than pretending (`docs/decisions.md` D26). Local secret storage works fully.
- The Settings window exists but holds only the History pane (`docs/decisions.md` D29). The rest of
  the preferences — including "allow JavaScript in previews" — still need `settings.json` edited by
  hand until Phase 12.
- The "Agents only" filter has been exercised by test but not photographed: it is a segmented
  picker in a sidebar row that AppleScript could not reach, and screen control was declined.
- `URLSession` occasionally leaves a `CFNetworkDownload_*.tmp` in the container's tmp when a
  download is cancelled. Postfrau's own spill files are cleaned up; these are the framework's.
- App icon is a placeholder mark (Phase 12). Hardened runtime is off in the generated project and
  enabled only by `Scripts/release.sh` (`docs/decisions.md` D3).

## Decisions taken

`docs/decisions.md` D1–D30. Most consequential: D9 `download(for:)` instead of `bytes(for:)` ·
D11 `Commands` extraction deferred to Phase 11 · D20 response bodies wrap by default (TextKit was
measuring one multi-megabyte line and blocking the main thread for 30 s) · D22 UI tests split out
of the commit gate · D24 the sidebar filter is computed once per change and capped ·
D25 menu commands hold the state instead of reading it through focus · D28 app tests echo through
a `URLProtocol` because the sandbox forbids the app from binding a socket · D30 a restored history
tab is re-attached from the log rather than duplicated into `ui-state.json`.
