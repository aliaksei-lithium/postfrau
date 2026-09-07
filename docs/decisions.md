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
