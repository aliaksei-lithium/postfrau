# Postfrau — status

**v1 complete.** All twelve phases of `PLAN.md` are ticked; `Scripts/release.sh` produces
`dist/Postfrau-1.5.dmg`.

**Build:** green — `make test` passes: 522 Core tests (~6 s) plus the app unit tests.
`make live-test` adds the ones that talk to the real network; `make ui-test` the ones that drive
the window.

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
- **`postfrau`, the command line tool** (new): everything the app does to a workspace, from a
  shell — for scripts, and for agents. `ls`, `get`, `add`, `set`, `mv`, `rm`, `dup`, `run`,
  `send`, `env`, `history`, `import`, `export`, `open`, `schema`, `validate`. Items are addressed
  by the names a person types (`Acme API/Users/List users`, case-insensitive) or by id. It finds
  the same data folder the app is using, writes to the same history, and attributes every send —
  `--as claude` shows up in the app's sidebar with a badge. `--capture token='$.data.token'`
  pulls a value out of a response into the active environment, so a folder can log in and then
  work. `--dry-run` prints what would go on the wire and records nothing; `--json` is a stable
  shape, and `run --all` emits NDJSON. `postfrau skill install` writes the `SKILL.md` an agent
  reads, generated from the same text compiled into the binary so the two cannot disagree.
- **Import and export**: Postman v2.1 collections in both directions, Postman environments
  in both directions, and cURL in both directions. One File ▸ Import… that works out what a file
  is by reading it — a collection, an environment or a saved curl command — plus dropping a file
  on the sidebar. Anything the importer cannot model is kept verbatim, so an export puts back the
  scripts, saved examples and `protocolProfileBehavior` it never understood, and a round trip
  gives back an identical model. Pasting a curl command into the URL bar fills in the whole
  request, moving a `Bearer` or `Basic` header into the Auth tab where it can be edited. ⌘⇧C
  copies the request back out as curl, with variables resolved or left as `{{names}}`. A secret's
  value is never written into an exported file.
- **Sync**: point the data folder at anything a sync client watches — iCloud Drive, Google
  Drive, Dropbox, a git checkout — and two Macs share collections and environments with no server
  in between. An `NSFilePresenter` and a `DispatchSource` together catch both coordinated and
  plain writes; a burst is coalesced for 500 ms and answered with one diff, and Postfrau
  recognises its own writes by fingerprint so a save never comes back as a foreign edit. A change
  to something you are not editing is adopted silently, open tabs and all; a change to something
  with unsaved edits keeps your copy on screen and parks theirs in `conflicts/` behind a banner
  offering *Keep mine* / *Take theirs* / *Show both*. A file that disappears marks its collection
  missing with *Restore from memory*. Settings ▸ Data chooses the folder, with a sheet that asks
  what to do about data already there (move / use theirs / merge by revision), and nothing is ever
  deleted. iCloud placeholders are requested on launch and show a per-collection spinner.
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
append 150 entries at once with nothing lost and no torn read. Two app instances sharing one data
folder both pick up an external change within about three seconds. An imported Postman collection
sends to httpbin and comes back 200, body and headers intact.

## Next — what v1.1 should start with

1. **The launch time.** 0.95–1.4 s from `open` to a painted window against a 300 ms target, and it
   has never been isolated from LaunchServices and dyld. Measure it properly with Instruments
   first; the answer may be that most of it is not ours, but nobody knows yet.
2. **Finish the accessibility pass properly.** Reduce Transparency and Increase Contrast could not
   be toggled from a script on macOS 26 (`docs/decisions.md` D40). Someone at the keyboard should
   turn both on and look, and run VoiceOver over the request editor.
3. **Watch the history folder** rather than re-reading on activation (D41). The Phase 9 watcher
   already does this for the data folder; history deserves the same, so an agent's send appears
   while you are looking at the window.
4. **A designed app icon.** The structure is right — layered, so macOS derives the light, dark,
   clear and tinted renderings — but the glyph is a placeholder mark.
5. **A real Postman export** to round-trip against, and a second Mac to prove iCloud sync between
   two machines rather than two instances.

## Known issues / limitations

- The 5 000-request **end-to-end typing-latency** assertion is unverified — see the note above and
  `PLAN.md` Phase 6. Everything it was written to catch has been fixed and is covered by Core tests.
- The environments window has not been eyeballed yet — it is covered by tests
  (`docs/decisions.md` D27). Now that the display wakes on demand, this is worth a look in Phase 9.
- **iCloud Keychain sync cannot work on this build.** Synchronizable Keychain items need a real
  signing identity; an ad-hoc build gets `errSecMissingEntitlement`. The toggle now reports that
  and reverts rather than pretending (`docs/decisions.md` D26). Local secret storage works fully.
- **The launch-time target is not met**: 0.95–1.4 s to a painted window against 300 ms, not
  isolated from LaunchServices and dyld (`docs/decisions.md` D40).
- **Reduce Transparency and Increase Contrast were never seen.** `com.apple.universalaccess` is
  TCC-protected on macOS 26, so a script cannot turn them on (D40).
- The **conflict banner** has been exercised by test but not photographed: producing one by hand
  means holding a collection unsaved while another process writes it, and autosave closes that
  window in 300 ms. The *missing collection* banner, which shares the component, was eyeballed.
- Sync has been proved between **two instances on one Mac**, not between two Macs over a real
  iCloud Drive account — this machine has one login. The iCloud-specific paths (placeholder
  download, ignoring Apple's own conflict versions) are covered by tests, not by a live account.
- The "Agents only" filter has been exercised by test but not photographed: it is a segmented
  picker in a sidebar row that AppleScript could not reach, and screen control was declined.
- **File ▸ Import… and drag-onto-sidebar have not been driven by hand** (`docs/decisions.md` D34).
  A sandboxed app's open panel runs in another process that will not take synthesized keystrokes,
  and a drag cannot be synthesized here. Everything downstream of the URL the panel returns is
  tested, and the paste-a-curl path was driven end to end in the running app.
- The login keychain wedged partway through the final session — a `SecurityAgent` prompt nobody
  could answer, which blocked `SecItem…` calls indefinitely. Killing that process cleared it, and
  the full suite then ran with **no skips at all**. The guards added for it stay: a keychain that
  will not answer now makes the affected tests skip rather than hang (`docs/decisions.md` D37,
  D43), which is what you want on a CI runner.
- The last Phase 11 acceptance clause — "a fresh Claude Code session … completes all three
  `SKILL.md` workflows without help" — **has not been tried**, because I cannot start an
  independent session. I ran the three workflows verbatim from the document myself instead, which
  is what found `--save-to` doing nothing (D38).
- The Postman importer is measured against **hand-written fixtures**, not a real export from
  Postman. They cover every body mode, nesting, disabled flags, an unsupported auth scheme and
  unknown fields, but a genuine export would be worth a round trip.
- `URLSession` occasionally leaves a `CFNetworkDownload_*.tmp` in the container's tmp when a
  download is cancelled. Postfrau's own spill files are cleaned up; these are the framework's.
- App icon is a placeholder mark (Phase 12). Hardened runtime is off in the generated project and
  enabled only by `Scripts/release.sh` (`docs/decisions.md` D3).

## Decisions taken

`docs/decisions.md` D1–D39. Most consequential: D9 `download(for:)` instead of `bytes(for:)` ·
D11 `Commands` extraction deferred to Phase 11 · D20 response bodies wrap by default (TextKit was
measuring one multi-megabyte line and blocking the main thread for 30 s) · D22 UI tests split out
of the commit gate · D24 the sidebar filter is computed once per change and capped ·
D25 menu commands hold the state instead of reading it through focus · D28 app tests echo through
a `URLProtocol` because the sandbox forbids the app from binding a socket · D30 a restored history
tab is re-attached from the log rather than duplicated into `ui-state.json` · D31 `dataFolderPath`
is a real fallback, because a bookmark cannot be shared with a second process · D32 a vanished
folder is one event and is recovered by polling · D35 live tests need `TEST_RUNNER_`-prefixed
environment variables, without which the whole suite skipped silently and ran green ·
D37 the CLI never touches the Keychain unless asked, because `SecItem…` blocks on a dialog
rather than failing · D38 every value-taking CLI flag is declared, after `--save-to` shipped
doing nothing at all · D39 `postfrau://` needs `onOpenURL`; SwiftUI never calls the delegate.
