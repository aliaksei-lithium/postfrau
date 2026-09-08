# Decision log

ADR-style entries, newest last. Every deviation from `PLAN.md` gets one, and `PLAN.md` is edited to
match so the plan stays truthful.

---

## D1 — Hand-written `Postfrau.icon` bundle instead of Icon Composer

**Phase 0.** Icon Composer is a GUI app and cannot be driven headlessly, so the placeholder icon is a
hand-written `.icon` bundle: `icon.json` (linear gradient fill, one image layer, neutral shadow,
translucency) plus `Assets/glyph.png` rendered once by a CoreGraphics script. `xcrun actool` compiles
it to `Postfrau.icns` + `Assets.car` without complaint, which confirms the format. The final icon in
Phase 11 can be authored in Icon Composer and dropped in at the same path.

## D2 — `SWIFT_VERSION = 6.0`, not `6`

**Phase 0.** `project.yml` sets `SWIFT_VERSION: "6.0"`. Xcode's build setting takes a language-mode
version (`5.0` / `6.0`), not a compiler version; `PLAN.md` §6 Phase 0 said `SWIFT_VERSION=6`, which is
the same thing but written in a form Xcode normalizes anyway. Recorded so the discrepancy with the
plan text isn't mistaken for a mistake later.

## D3 — Hardened runtime off in the project, on only in `release.sh`

**Phase 0.** With `ENABLE_HARDENED_RUNTIME = YES` in the shared build settings, `xcodebuild test`
failed: the ad-hoc-signed `PostfrauUITests-Runner.app` refused to `dlopen` the equally ad-hoc-signed
`PostfrauUITests.xctest` ("mapping process and mapped file (non-platform) have different Team IDs").
That is hardened-runtime library validation, which cannot be satisfied by two independent ad-hoc
signatures and there is no Developer ID on this machine. The runtime is therefore off in `project.yml`
and turned on by `Scripts/release.sh` for the Release archive, where it actually matters
(notarization). If a Developer ID is ever configured, the setting can move back into `project.yml`.

## D4 — UI-test target keeps `nonisolated` default actor isolation

**Phase 0.** `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` makes an `XCTestCase` subclass main-actor
isolated, which conflicts with the `nonisolated` `init(invocation:)` / `init(selector:)` it overrides.
`PostfrauUITests` therefore builds `nonisolated` by default (XCTest's own model); the app and
`PostfrauTests` (Swift Testing, no base class) stay main-actor by default as `PLAN.md` §0 specifies.

## D5 — Model type names that avoid collisions: `RequestCollection`, `RequestEnvironment`, `RequestBody`, `CollectionItem`

**Phase 1.** `PLAN.md` §3 names four types `Collection`, `Environment`, `Body` and `Item`. Each
would shadow something the code needs:

| Plan name | Collides with | Consequence |
|---|---|---|
| `Collection` | `Swift.Collection` | any `where C: Collection` inside PostfrauCore stops compiling |
| `Environment` | `SwiftUI.Environment` | `@Environment(\.foo)` becomes ambiguous in every view that imports both |
| `Body` | `View.Body` associated type | `Body.none` inside a `View` resolves to the view's own `Body` |
| `Item` | far too generic | unhelpful in the app layer's namespace |

They are therefore `RequestCollection`, `RequestEnvironment`, `RequestBody` and `CollectionItem`.
`PLAN.md` §3 has been updated to match. Everything else keeps its planned name.

## D6 — `CryptoKit` in Core for SHA-256

**Phase 1.** `PLAN.md` §7 rule 1 says Core imports only Foundation and Security. Own-write
fingerprinting (§4) needs a content digest, and Security exposes no convenient hashing API.
`CryptoKit` is a system framework with no dependency cost, so `AtomicFile` imports it rather than
hand-rolling SHA-256 or reaching for CommonCrypto's deprecated C API. Rule 1 in `PLAN.md` now
reads "Foundation, Security and CryptoKit".

## D7 — ISO-8601 timestamps with fractional seconds

**Phase 1.** Plain `.iso8601` truncates to whole seconds, so a document did not round-trip to an
equal model and equality-based tests were meaningless. The shared coders use
`Date.ISO8601FormatStyle(includingFractionalSeconds: true)` for writing and accept both forms when
reading. Millisecond precision is enough for `createdAt` / `updatedAt`; tests that compare whole
models use timestamps that are exact at that precision.

## D8 — `Keychain.deleteAll` loops `SecItemDelete`

**Phase 1.** On macOS's file-based keychain a service-wide `SecItemDelete` removes exactly **one**
matching item and returns `errSecSuccess`, and the call rejects `kSecMatchLimit`. Verified with a
standalone probe: adding two items and deleting service-wide left one behind. `deleteAll` therefore
repeats the delete until `errSecItemNotFound`, bounded so it can never spin forever.

## D9 — `download(for:delegate:)` instead of `bytes(for:delegate:)` for response bodies

**Phase 2.** `PLAN.md` §6 Phase 2 specified collecting the body via `bytes(for:)`. Measured on this
machine against a local `http.server` (9.2 MB JSON):

| Approach | 213 B body | 9.2 MB body |
|---|---|---|
| `data(for:)` | 10.8 ms | 8.0 ms |
| `download(for:)` + read back | 3.9 ms | 13.4 ms |
| `bytes(for:)` byte loop | 1.5 ms | **555.8 ms** |

`URLSession.AsyncBytes` yields one `UInt8` per iteration, so a 20 MB response would spend well over
a second in the loop — a visible stall in front of every large response, and precisely the case
Phase 5 has to keep smooth. `download(for:)` streams to a file with flat memory use, which makes
the spill-to-disk path free: bodies at or below 20 MB are read back into memory, larger ones keep
their file. The 200 MB hard cap is enforced *during* the transfer by `TaskObserver`'s
`didWriteData` callback, which cancels the task; the executor distinguishes that from a user
cancel via a flag on the observer.

## D10 — Session profiles key on TLS and cookies only

**Phase 2.** `PLAN.md` §6 Phase 2 keyed the `URLSession` cache on "(TLS verify on/off, redirects
on/off, cookies on/off)". Redirect policy and timeout are per-task — they are decided in the task
delegate and on `URLRequest` — so including them would multiply the session cache for no reason.
The profile is `(verifyTLS, sendCookies)`, which is exactly the set that cannot vary per request.
Each profile gets its own `HTTPCookieStorage` so a request that opted out of cookies never sees
another profile's session cookie.

## D11 — `Commands/SendRequest` extraction deferred to Phase 11

**Phase 3 (plan revision R3).** R3 added an item to Phase 3: put the send pipeline in Core as
`Commands/SendRequest` so the CLI can reuse it. The revision arrived while Phase 3's UI was already
built and working, and the item itself says: *"If Phase 3 is already past this point, do the
extraction at the start of Phase 11 instead — don't rework finished UI now."* That is what is
happening. `SendController` currently holds the pipeline (resolve scope → build → execute → record
history); Phase 11 lifts that body into `Commands/SendRequest` and leaves `SendController` as the
thin main-actor wrapper adding cancellation and tab state, per §7 rule 14.

## D12 — Launch overrides for the local state root, and why there are three of them

**Phase 3.** Deterministic UI tests need each run to start from an empty state directory. Three
mechanisms exist because each is the only one that works in its situation:

- `POSTFRAU_LOCAL_ROOT` (environment) — works from a shell; Phase 9 uses it for a second instance.
  **Does not work from XCUITest**: `XCUIApplication.launchEnvironment` never reaches an app started
  through LaunchServices. Verified by observation — the directory was never created.
- `--local-root <absolute path>` (launch argument) — arguments *do* reach the app (verified by
  printing `ProcessInfo.arguments` into the accessibility tree).
- `--local-root-name <name>` — the XCUITest runner is itself sandboxed into
  `com.postfrau.PostfrauUITests.xctrunner`, so `homeDirectoryForCurrentUser` there resolves to the
  *runner's* container and any path it invents is one the app is forbidden to write. The runner
  passes a folder *name* and the app places it inside its own container.

`--reset-state` empties the resolved folder first. `--appearance dark|light` forces one appearance
for the process, so both renderings can be reviewed without touching the machine's system setting
(the usual `-AppleInterfaceStyle` argument-domain trick does not reach a LaunchServices-started app
either).

## D13 — Accessibility defects found by driving the real UI

**Phase 3.** Writing the acceptance criteria as XCUITests rather than checking them by eye surfaced
four defects that a screenshot would never have shown, all of which also broke VoiceOver:

1. `.onTapGesture` on the tab bar's container collapsed **every tab into one accessibility
   element** whose label was the concatenation of all tab titles. The gesture moved into
   `.background { }`.
2. `.accessibilityLabel` on an `NSViewRepresentable` does not reach the wrapped view, so the
   response body `NSTextView` was unnamed. `CodeTextView` now takes a label and calls
   `setAccessibilityLabel` / `setAccessibilityRole` on the text view itself.
3. Sidebar request rows exposed nothing at all: a label on a bare `HStack` needs
   `.accessibilityElement(children: .ignore)` to become an element.
4. Two different segmented controls were both titled "View", so a query for the response's Headers
   tab could land on the request editor's.

## D14 — `applicationShouldTerminate` flush; `XCUIApplication.terminate()` bypasses it

**Phase 3.** Autosave is debounced by 300 ms, so quitting immediately after an edit dropped it.
`AppDelegate.applicationShouldTerminate` now returns `.terminateLater`, flushes, and replies, with
a 3 s watchdog so a stuck write cannot wedge the quit. The relaunch test originally used
`XCUIApplication.terminate()`, which kills the process outright — `applicationShouldTerminate` was
never called (verified with a marker file). The test quits with ⌘Q instead, which is both the real
quit path and what a user does.

## D15 — First-run sample install must follow UI-state restore

**Phase 3.** `installSampleCollection` expands the new collection, but `restore(uiState)` assigns
the expansion set wholesale, so installing first meant the sample always appeared collapsed on
first run. The order in `AppState.load` is now: load workspace → restore UI state → install the
sample if there are no collections.

## D16 — `JSONPrettyPrinter` built in Phase 4, not Phase 5

**Phase 4.** `PLAN.md` lists the pretty printer under Phase 5, but Phase 4's Body tab needs a
"Beautify" button, so it was written a phase early. It is the same component Phase 5's Pretty tab
will use — no duplication, just ordering. It is a byte-level tokenizer rather than a
`JSONSerialization` round-trip because Foundation reorders object keys, collapses duplicates, and
rewrites numbers through `Double`: `9007199254740993` comes back as `…992`, `1.0` as `1`. Tests
assert on exactly those cases. A 2.2 MB document re-indents in well under the 1 s the plan sets.

## D17 — Blank editor rows live in the model; dirty tracking normalizes them away

**Phase 4.** Every key/value table shows a trailing blank row to type into, and the simplest place
for that row is the model itself (a parallel "display" array has to be kept in sync on every
keystroke). The consequence is that merely *opening* the Params tab would change the draft and
light up the unsaved-changes dot. `RequestItem.normalized()` strips blank rows, `isDirty` compares
normalized drafts, and `saveTab` writes the normalized form — so the scaffolding never reaches disk
and never looks like an edit. `KeyValueRows` holds the rules, with tests.

## D18 — ⌘W is intercepted with a local key monitor

**Phase 4.** §5 assigns ⌘W to "close tab". A SwiftUI `Window` scene always gets a File ▸ Close item
on ⌘W, and when two menu items share a key equivalent AppKit picks the system one — so ⌘W closed
the window, and since a `Window` scene quits when its last window closes, the app appeared to
crash. Retargeting the menu item's key equivalent does not stick: it applies (verified) and SwiftUI
then rebuilds the menu and reverts it. `NSEvent.addLocalMonitorForEvents` runs before menu
dispatch, so that is where the decision is made; the menu item keeps ⌘W as its label.

Two related fixes came out of the same investigation: `applicationShouldTerminateAfterLastWindowClosed`
now returns false (closing the window should not quit a single-window app — Phase 12 wants ⌘N to
bring it back), and the unsaved-changes confirmation moved from the tab row to the window. A
`confirmationDialog` presented by the very view that is about to be removed is a crash waiting to
happen; the window outlives every tab.

## D19 — Highlighters live in Core and emit kinds, not colours

**Phase 5.** `PLAN.md` §2 puts `Highlighting/` in the app target. The tokenizers are pure text
processing and exactly the kind of thing §7 rule 7 says must be tested, so they live in
`PostfrauCore/Text` and are covered by `swift test`; they emit `SyntaxKind`s and UTF-16 offsets.
The app keeps `Highlighting/Theme.swift`, which maps kinds to `NSColor`s built from system colours
so light, dark and Increase Contrast all come for free. `PLAN.md` §2's tree has been updated.

Both tokenizers scan the UTF-16 view rather than `Character`s: every character JSON and XML give
structural meaning is ASCII, the offsets are then directly usable as `NSRange`s, and grapheme
breaking a multi-megabyte document is far too slow. Neither ever throws — a truncated response
must still be readable, so malformed input is coloured as best it can be.

## D20 — Response bodies wrap by default, and TextKit is why

**Phase 5.** The 20 MB acceptance test failed with XCUITest reporting *"process main thread busy
for 30.0s"*. Sampling the stuck process put the whole main thread inside
`NSTextView._updateContentHeight` → `NSTextLayoutManager.estimatedSizeForLastTextContainer` →
`CTLineGetOffsetForStringIndex` → `TLine::EnumerateCaretOffsets`.

The cause: with wrapping off, the text container is unbounded, so TextKit has to measure the widest
line *in full* to size the view. A minified JSON response is a single line several megabytes long,
and measuring one costs tens of seconds. Measured separately, setting a 1 MB string takes 30 ms
without wrapping and 0.3 ms with it — and that fixture had newlines; a single long line is far
worse. `wrapResponseLines` therefore defaults to true, with the toggle still in the response menu.

Two smaller fixes came from the same investigation: line counting for the gutter moved from
`Character`s to UTF-8 (7 ms → 1.8 ms per update on 1 MB), and the render limit now follows §5
properly — bodies up to 5 MB render whole, larger ones show the first 1 MB with a "Load Full
Response" button.

## D21 — The system find bar instead of a hand-rolled one

**Phase 5.** `PLAN.md` §5 asks for a find bar with match count, next/previous and a wrap toggle.
`NSTextView.usesFindBar` provides exactly that, in the form every other Mac app uses, including
match count and find-and-scroll. ⌘F (menu: Request ▸ Find in Response) bumps a counter the body
view watches, which opens the bar and takes first responder. Writing one by hand would be more
code and less familiar.

## D22 — XCUITests moved out of `make test` into `make ui-test`

**Phase 6.** The XCUITest suite drives the real UI, which means it needs a display where
Postfrau's window can come to the front. Partway through this phase the development machine ended
up with a full-screen app occupying its own Space; from then on *every* click-based test failed
with "unable to find hit point", including tests that had passed minutes earlier on unchanged,
committed code. Diagnosis: `XCUIApplication.windows.count == 0` while child elements still
resolved with correct screen frames — the app was frontmost (its menu bar was showing) but its
window was on another Space, so nothing was clickable. Neither `activate()`,
`makeKeyAndOrderFront`, nor `.moveToActiveSpace` can pull a normal window onto a full-screen
Space, and moving somebody else's windows is not the app's business.

So `make test` — the gate before every commit — runs the Core tests and the app's unit tests,
which need no window and are deterministic. `make ui-test` runs the XCUITests and is run when the
desktop is free. `Scripts/screenshot.sh` now captures the window by id with `.optionAll` rather
than by screen region, so visual checks keep working even when the window is occluded or on
another Space.

## D23 — Undo is whole-collection snapshots

**Phase 6.** Every structural sidebar edit registers an undo that restores a copy of the affected
collection taken before the change. Hand-written inverses for move / delete / duplicate across a
nested tree are where undo bugs live, and the trees are small enough that a snapshot is cheap — a
5 000-request collection is about 2 MB of model, and these are user-scale actions, not keystrokes.
Cross-collection moves snapshot both sides under one action name so a single ⌘Z puts everything
back.

## D24 — The sidebar filter is computed once per change, not per row, and capped

**Phase 6.** The 5 000-request stress test found the obvious implementation to be quadratic: each
`DisclosureGroup` asked "should I be forced open?", and each answer re-filtered the whole tree —
O(rows x tree) *per frame*. It wedged the main thread badly enough that XCUITest could not deliver
keystrokes at all. `AppState.sidebarSnapshot` now computes the pruned tree and the forced-open set
in one traversal, memoized against (query, collection count, edit generation), and the rows are
handed the result.

Two further changes came from the same measurement: matches are capped at 200 with the sidebar
saying how many were left out — a broad query matches thousands of requests, and drawing thousands
of force-expanded outline rows is slow however fast the filtering is — and the filter is debounced
by 200 ms so a burst of typing renders once rather than once per keystroke.

## D25 — Menu commands hold the state instead of reading it through focus

**Phase 6.** `AppCommands` took its `AppState` from `@FocusedValue`, which left menu items
silently disabled whenever the focused value had not propagated: the Debug ▸ Generate Stress
Collection item looked enabled, accepted a click, and did nothing. Postfrau is a single-window app
with exactly one `AppState`, so the state is now passed into `AppCommands` directly.

The enabled test for each item runs inside a small `CommandButton` view rather than in the `App`'s
`commands` builder. Reading `@Observable` state directly in that builder makes the whole Scene —
the window included — a dependency of the state, so every edit tears the window down and rebuilds
it.

## D26 — iCloud Keychain needs a signed build; the app says so instead of failing silently

**Phase 7.** `PLAN.md` Phase 9 asked for a finding on this, and it arrived early: writing a
`kSecAttrSynchronizable` item from this ad-hoc-signed build returns `errSecMissingEntitlement`
(-34018). iCloud Keychain requires a real signing identity with a Keychain access group, which
needs the paid Developer Program this project does not have.

`Keychain.KeychainError` gained a `.missingEntitlement` case whose message says exactly that, and
`SecretsStore.setSynchronizable` writes to the destination store *before* deleting from the
source — so a refused move leaves every secret where it was and the setting flips back rather than
claiming a sync that is not happening. The test asserts that behaviour instead of asserting a
successful move, since the successful path cannot run on an unsigned build.

Local (non-synchronizable) Keychain storage works fully, which is what every other Phase 7
criterion depends on.

## D27 — `ImageRenderer` cannot stand in for a screenshot of these views

**Phase 7.** With the display occupied (D22), rendering views to PNGs with `ImageRenderer` looked
like a way to keep eyeballing the UI. It is not: `NavigationSplitView` and `List` render as a
"not supported" placeholder, because they need a real window to host. The attempt was removed
rather than kept as a test that passes while producing a meaningless image.
`Scripts/screenshot.sh` (capture by window id, `.optionAll`) remains the way to look at the app,
and it works for any window that has actually been displayed.

## D28 — App tests answer requests with a `URLProtocol` echo, not a local HTTP server

**What.** `PostfrauTests` intercepts requests with `EchoURLProtocol`, a `URLProtocol` that answers
with a JSON echo of what it was asked for, rather than binding a real socket in-process.

**Why.** The first attempt was a genuine `NWListener` on an ephemeral port, so the Phase 8
recording tests would exercise a real `URLSession` round trip end to end. It cannot work: the app
is sandboxed with `com.apple.security.network.client` only, and the test bundle runs inside the
app, so `bind` fails with `Operation not permitted`. Adding `network.server` would widen the
shipping app's sandbox for the sake of a test — the wrong trade for an HTTP *client*.

**What changed.** The whole of Postfrau stays in the path — request building, auth resolution, the
executor, the recording and the redaction; only the wire is replaced. `PLAN.md` Phase 8 records
the deviation. The kickoff allows either form ("`URLProtocol` mocks or an in-process listener").

## D29 — Settings ships as one pane, not a tab view

**What.** `SettingsWindow` renders `HistorySettings` directly. There is no `TabView`.

**Why.** Phase 8 is the first phase that needs a Settings window, and it has exactly one pane to
put in it. A `TabView` with a single tab draws a tab strip that explains nothing and, in the first
build, also stopped the window sizing to its content (the "Delete All History…" button was clipped
off the bottom edge).

**What changed.** Phase 12, which adds the remaining panes, adds the tab strip with them.
`PLAN.md` Phase 8 and Phase 12 both note it.

## D30 — A recorded history tab is re-attached from the log, not stored in the UI state

**What.** `TabState` carries `historyEntryID`; the recorded headers and body are not written into
`ui-state.json`. On launch, once history has been read, `reattachRecordedTabs()` looks the entry up
and rebuilds the response.

**Why.** A restored history tab that shows "No response yet" is a bug the user sees every relaunch.
The obvious fix — persist the exchange with the tab — would copy a capped body (up to
`historyBodyCapBytes`, 256 KB by default, per tab) into a file that is rewritten on every quit,
duplicating something the history log already holds.

**What changed.** `UIState.sidebarSection`, which had been in the model since Phase 3 but was never
read or written, is wired up in the same place: the sidebar section now survives a relaunch too.

## D31 — `dataFolderPath` is a real fallback, not just a label

**What.** `DataFolderBookmark.folder` uses `settings.dataFolderPath` when there is no
`dataFolderBookmark`, instead of going straight to the default folder.

**Why.** A security-scoped bookmark belongs to the process that created it. Phase 9's own manual
test — two instances on one Mac sharing a folder — cannot work without this, and neither can the
`postfrau` CLI in Phase 11: a second process has only the path. The fallback works wherever the
sandbox already permits the location (inside the container, or a folder the user has granted) and
reports `.missing` / `.unreadable` honestly where it does not, so nothing is silently wrong.

**What changed.** The bookmark still wins when both are present. `PLAN.md` Phase 9 records it.

## D32 — A vanished folder is one event, recovered by polling

**What.** `absorbFolderChanges` re-reads `DataFolder.status` before diffing and stops if the folder
is not there, showing "folder unavailable" instead. A `folderRecoveryTask` then polls every three
seconds until it returns, and restarts the watcher when it does.

**Why.** Two problems, one cause. Diffing a folder that has gone reports *every* document as
removed, so unmounting a volume would bury the user in "no longer in the data folder" banners for
what is a single event. And a `DispatchSource` on a deleted directory fires once and is then dead,
so without polling an unmounted volume would need a relaunch. Polling is the honest tool: there is
nothing left to subscribe to.

**What changed.** Found by deleting the data folder under a running app: it survived, but the
status chip still read "synced just now". Both halves are covered by `PostfrauTests/SyncTests`.

## D33 — Relocation backups are per-document JSON, not a zip

**What.** Switching to a folder whose data wins writes each local collection and environment to
`conflicts/<name> (before switch)-<host>-<date>.json` rather than a single zip archive.

**Why.** `PLAN.md` said "a backup zip". Zipping needs either an archiver dependency (forbidden by
§0) or `NSFileCoordinator`'s bundle trickery, and it buys nothing: the merge path already writes
per-document copies to the same place, and a single document is far easier to recover from a
folder of readable JSON than from inside an archive.

**What changed.** `PLAN.md` Phase 9 now says "a backup", with the shape named.

## D34 — The import file picker is tested through `importFile(at:)`, not through the panel

**What.** `File ▸ Import…` and the sidebar's drop target are covered by tests that call
`AppState.importData` / `importFile(at:)` directly. The `NSOpenPanel` step itself was not driven
by hand.

**Why.** A sandboxed app gets its open panel from
`com.apple.appkit.xpc.openAndSavePanelService`, a separate process. Its contents do not appear in
the app's accessibility tree (the window reports a single UI element), and synthesized keystrokes
sent through System Events — ⌘⇧G, type-select, Return — do not reach it. Drag-and-drop cannot be
synthesized here either.

**What changed.** Nothing in the app. What the panel returns is a `URL`, and everything after that
URL is tested. The acceptance that mattered — an imported request actually sending — is covered by
`make live-test`, which imports a Postman export and sends two of its requests to httpbin.

## D35 — Live tests need `TEST_RUNNER_`-prefixed environment variables

**What.** `make live-test` passes `TEST_RUNNER_POSTFRAU_LIVE_TESTS=1`, not
`POSTFRAU_LIVE_TESTS=1`, to the app test bundle.

**Why.** `xcodebuild` does not forward the invoking shell's environment to the test host, so
`.enabled(if: ProcessInfo…environment["POSTFRAU_LIVE_TESTS"] == "1")` silently skipped the whole
suite — a green run that had tested nothing. `TEST_RUNNER_<NAME>` is the documented way in; the
prefix is stripped before the host sees it. The Core package tests read the plain name, because
SwiftPM does pass the shell environment through.

## D36 — The CLI is bundled by `make`, not by an Xcode build phase

**What.** `make build` and `Scripts/release.sh` run `swift build --product postfrau` and copy the
result into `Postfrau.app/Contents/Helpers/postfrau`. `PLAN.md` asked for an Xcode build phase.

**Why.** A build phase that shells out to `swift build` needs `ENABLE_USER_SCRIPT_SANDBOXING`
turned off for the whole target, and it would rebuild the package on every app build — several
seconds added to a loop that is currently under two. The Makefile already owns the build.

**And it goes in `Contents/Helpers`, never `Contents/MacOS`.** macOS filesystems are
case-insensitive, so copying a file called `postfrau` beside the app's own `Postfrau` executable
*overwrites the app*. Found the hard way: the app kept "launching" and printing CLI help.

## D37 — The command line tool does not touch the Keychain unless asked

**What.** `postfrau` reads and writes secret values only when `--keychain` is passed. Otherwise
secrets come from `POSTFRAU_SECRET_<KEY>` environment variables, and a variable with no value
available is reported at the end of the command.

**Why.** A second binary reaching for Keychain items the app created raises the one-time "Always
Allow" dialog. `SecItemCopyMatching` and `SecItemAdd` do not fail while that dialog is up — they
block, forever. On a Mac with someone sitting at it that is one click; from a script, a CI job or
an agent it is a process that never returns. A tool that can hang indefinitely is worse than one
that says a value is missing and carries on.

**What changed.** Found by running `postfrau get` against a workspace with a secret in it: the
process sat for two minutes with no output, and a sample showed it inside `SecItemCopyMatching`.
The same hazard took the *test suite* down — `KeychainTests.isUsable` probed by writing an item
and blocked there, turning a six-second run into an indefinite hang. Both test targets now ask
`KeychainProbe`, which runs the probe on its own thread with a three-second deadline and treats
silence as "unusable"; the stranded thread cannot be interrupted and is accepted, because a leaked
thread in a process about to exit is a better trade than never finishing.

## D38 — Every value-taking flag is declared, and a test pins the list

**What.** `CLI.valueFlags` lists every flag that carries a value. `CLITests` exercises the ones
that would otherwise fail silently.

**Why.** A flag missing from that set is not an error anywhere: it parses as a boolean, its value
becomes a stray positional argument, and the command quietly does the wrong thing. `--save-to`
shipped that way — `postfrau send … --save-to 'My API/Health'` returned 0 and saved nothing. It
was found by running the three `SKILL.md` workflows verbatim, which is the only thing that would
have found it: every unit test passed.

## D39 — `postfrau://` is handled by `onOpenURL`, not the app delegate

**What.** `PostfrauApp` handles the URL scheme with `.onOpenURL`; `AppDelegate` does not implement
`application(_:open:)`.

**Why.** SwiftUI installs its own Apple Event handler for `kAEGetURL`, so the delegate method is
never called in a SwiftUI app — the URL arrives and nothing happens. Diagnosed by watching
`postfrau open` report success while the app did not change.

Registering the scheme also has to happen in `project.yml`, not in `Info.plist`: XcodeGen
regenerates that file from the `info.properties` block on every `make gen`, silently discarding
edits made to it directly.

## D40 — Two Phase 12 checks this environment cannot perform

**What.** Two items are ticked with the work done but the *verification* missing, and both say so
in `PLAN.md` rather than being quietly claimed.

**Reduce Transparency and Increase Contrast.** `com.apple.universalaccess` is TCC-protected on
macOS 26: `defaults write` to it returns success and changes nothing, and there is no scriptable
route to the toggle. Glass is confined to the toolbar and sidebar — surfaces macOS itself renders
opaque under Reduce Transparency — and content is flat everywhere, so the design should hold. That
is an argument, not an observation, and it is recorded as one.

**The Instruments pass.** Time Profiler, Allocations and the SwiftUI instrument need a GUI this
session cannot drive. What was measured instead is wall-clock launch: 0.95–1.4 s from `open` to a
painted window, against the plan's 300 ms. That figure includes LaunchServices resolving the
bundle and dyld loading it, neither of which the app controls, and it was not isolated from them —
so it is reported as what it is rather than being explained away. The targets that *were* isolated,
in Phases 5, 6, 8 and 9, are met.

## D41 — History refreshes when the app becomes active

**What.** `applicationDidBecomeActive` asks `AppState.refreshHistoryIfChanged()`, which compares a
directory count and re-reads only when it has moved.

**Why.** Phase 11 promises that what an agent does "shows up in the app". It did not: the app read
history once at launch, so sends the CLI made while the app sat open were on disk and invisible
until a relaunch. Found by doing exactly what the feature is for — running three `postfrau send`
commands from a terminal beside the running app. Coming back from that terminal is precisely the
moment the sidebar is most likely to be stale, which is why activation is the trigger; a directory
listing is far cheaper than decoding every entry, so the common case costs nothing.

## D42 — The send pipeline is shared where it matters, not wholesale

**What.** `HistoryRecorder` in Core turns a finished exchange into a redacted `HistoryEntry`, and
both `SendController` (the app) and `CommandRunner` (the CLI) call it. The app still owns its own
send path — cancellation, tab state, the response landing on the right tab.

**Why.** R3 asked for `Commands/SendRequest` with `SendController` reduced to a thin wrapper.
Phase 11 built the Core command and the CLI uses it, but migrating the app's send path wholesale
would have reworked UI that was finished, tested and working, for nothing a user could see — and
the plan itself says not to do that.

What genuinely could not stay duplicated is the recording: two copies of the redaction rules, the
level handling and the body caps are two places to fix a leak, and only one of them gets fixed.
Before this, the app and the CLI each had their own — and they had already drifted, the app
collecting credentials one way and the CLI another. That is now one function with one set of
tests behind it.

**What is left.** The app builds and sends its own requests. If a third caller ever appears, that
is the moment to finish the extraction rather than guess at it now.

## D43 — Tests wait on a killed child by polling, not `waitUntilExit()`

**What.** `CrashSafetyTests` polls `Process.isRunning` with a deadline instead of calling
`waitUntilExit()`.

**Why.** `waitUntilExit()` goes through Foundation's termination handling, which sat forever
whenever another thread in the test process was blocked inside the Security framework — which is
exactly what `KeychainProbe` does on a Mac whose keychain wants an authorization nobody can give.
The suite hung for fourteen minutes at a line that had passed in a second and a half an hour
earlier. Polling asks the kernel directly and cannot deadlock against anything.

The writer script is bounded too, for a related reason: an unbounded `while true` loop spawns `mv`
faster than the system reaps it, and the wait then queues behind thousands of orphans. Four
hundred writes land the kill just as unpredictably and always terminate.

## D44 — OpenAPI import reads JSON only, and builds sendable requests

**What.** `Transfer/OpenAPI.swift` imports OpenAPI 3.0 and 3.1 documents. It is offered by
File ▸ Import, the sidebar drop target and `postfrau import`, all through the same sniffing that
already told Postman collections from environments from cURL.

**JSON only.** OpenAPI is as often YAML, and a YAML parser is a third-party dependency (§0
forbids them). The subset needed is not small enough to hand-roll honestly — anchors, block
scalars and flow style are where a naive parser quietly gets it wrong. A YAML document is
therefore *detected* and told what to do about it (`yq -o=json`) rather than failing as "not
JSON".

**A collection you can send from, not a transcription.** A spec describes what an endpoint
accepts; a request has to carry something concrete. So:

- `servers[0]` becomes `{{baseUrl}}`, with its own `{template}` variables filled from their
  declared defaults, so one variable repoints the whole collection.
- Path templates become `{{petId}}` — Postfrau variables the user can fill in, rather than braces
  that would be sent literally.
- Tags become folders in the order the document declares them, which is the order its authors
  chose and the order every other OpenAPI tool shows. A document with no tags at all falls back
  to grouping by first path segment; mixing the two would give a mostly-tagged document one odd
  folder named after a path.
- A required parameter is enabled, an optional one is not, so the first send is the minimal one
  that ought to work.
- Bodies come from `example`, then `examples`, then are synthesised from the schema. An empty
  body is far less use than a shaped one to edit.

**Two things the first real run caught.** The "N requests have path variables" warning counted
every request, because every URL contains `{{baseUrl}}`. And a self-referential schema (`Pet.friend`
is a `Pet`) expanded to the depth limit — six nested copies. Example synthesis now tracks the
`$ref` chain and stops the second time it sees one, giving exactly one readable level.

**Local `$ref` only.** A remote or file reference would mean fetching something the user did not
ask us to fetch, from a URL inside a file they may have been handed. That is their decision.

## D45 — The app icon is a drawn figure, generated by a script in the repo

**What.** `Postfrau/Resources/Postfrau.icon` now shows a postwoman in flight carrying a letter,
white on the purple gradient, generated by `Tools/make-icon-glyph.swift`.

**Why it changed.** The first glyph was an envelope, and an envelope on a purple gradient is a
mail client. The name is the joke — a *Postfrau* delivers the request — so the mark should be her,
not her cargo.

**Why a script and not an image.** The shape took a dozen rounds of render-look-adjust. Keeping
the geometry in Swift makes the next round an edit rather than a redraw, and the two things that
kept going wrong are now enforced rather than remembered:

- The figure is drawn **upright** — feet at y = 0, head at the top — and the whole frame is then
  rotated into the climb. Drawing her already-diagonal turned every limb into guesswork, and the
  results read as a blob or an animal.
- Framing is **measured**: a first pass renders small and centred, its alpha bounding box is read
  back, and the scale and offset that centre her in the icon's safe area are computed from it. A
  `precondition` fails the run if that probe pass clips, because a clipped probe reports the
  canvas as the bounding box and silently produces a cropped icon — which is exactly what
  happened.

**Transparent, and not translucent.** The old glyph baked the purple background into an opaque
PNG, so `icon.json`'s gradient was doing nothing and macOS could not derive the tinted or clear
appearances. The new one is white on transparent. `translucency` is also turned off: at the
default 0.5 the system's glass treatment thinned the figure to a ghost at Dock size.

## D46 — Editor sections are built once and kept, not rebuilt on every click

**The report.** "I see a very huge lag when I click between Params, Headers." A first attempt in
v1.2 cached the derived warnings and header list, which was a real fix for a real cost — but the
lag survived it, and a later report added the decisive detail: *clicking* a section was much
slower than ⌘1/⌘2.

**What it actually was.** Every section was a separate branch of a `switch`, so SwiftUI tore the
old subtree down and built the new one on every click. Those subtrees are full of AppKit-backed
controls, and `HeadersTab` contained a `VSplitView` — an `NSSplitView` — built and destroyed each
time. Measured on the main thread, one click cost **~150 ms**.

Sections are now built lazily on first visit and then kept, with only the selected one shown; a
hidden section is `disabled`, not merely transparent, so its text fields leave the window's
key-view loop and ⇥ cannot walk into a section nobody can see. `VSplitView` became the app's own
`ResizableSplit`. Together the main thread goes from **66% busy to 16%** — about **200 ms to
50 ms per click**, a 4.2× cut — against a floor of 10.4% (~30 ms) measured with the whole section
replaced by a single `Text`. Replacing the split alone got to 30%; the rest is the kept sections.

Per-click figures are the busy share spread over the run, not a stopwatch: `sample` was asked for
1 ms and actually managed about 1.3, so treat the ratios as solid and the milliseconds as round
numbers.

**Two hypotheses that were wrong, and how.** Both looked well-supported in a profile and both cost
time, so they are worth recording:

1. *"The toolbar is being rebuilt."* `NSToolbarView` was 26% of the busy tree. But instrumenting
   the bodies showed `MainWindow` and `EnvironmentPicker` evaluating **zero** times across six
   clicks, and `RequestEditor` exactly six. SwiftUI's invalidation was already minimal; the
   toolbar was being *laid out* as part of the window's layout pass, not rebuilt. Sample counts
   under a subtree say where time went, not what caused it.
2. *"`ResizableSplit`'s `GeometryReader` cascades."* Plausible, and `GeometryReaderLayout` was 12%
   of the tree — but rewriting it as a `Layout` moved the number from 66.3% to 65.6%, which is
   noise. The rewrite was kept for an unrelated reason (see that file), not because it helped.

**Measure the harness before the app.** Two full profiles were of the measurement, not the
program. Driving the switch with ⌘1/⌘2 spent 20% of the main thread inside
`NSMENU_IS_THROTTLING_REPEATED_MENU_ITEM_INVOCATIONS` — AppKit deliberately sleeping because a
menu shortcut was being repeated. Driving it with the accessibility press action made
`NSSegmentedCell` spin a nested event loop waiting for a mouse-up. Only real HID events measure
what a person experiences. `Tools/measure-clicks.sh` posts those, and the controls that made the
result trustworthy were: idle with no input (0.1% busy), moving the mouse without clicking (0.5%),
and clicking inert space in the same table (1.7%) — against 66.3% for clicking a section.

**The cost of keeping sections alive.** Hidden sections still take part in layout, so window
resizing does slightly more work, and a request that has had every tab opened holds five subtrees
instead of one. That is the right trade for an interaction the user performs constantly, and
laziness keeps a request that only ever shows Params paying for Params alone.
