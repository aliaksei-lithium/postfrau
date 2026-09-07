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
