# Postfrau — Execution Plan

Postfrau is a free, personal, native macOS HTTP client in the spirit of Postman: send HTTP
requests, organize them into collections, switch environments. No collaboration, no cloud, no
load testing, no accounts. Fast, responsive, good UX. No Node.js anywhere in the stack.

This document is the contract for the agent that builds it. Work phase by phase, in order.
Every phase ends with a green `make test`, a manual check of its acceptance criteria, and one
git commit. Tick the checkboxes in this file as you go so progress survives context loss.

---

## 0. Decisions already made (do not re-litigate)

| Topic | Decision | Why |
|---|---|---|
| Language / UI | Swift 6.3, SwiftUI app shell, AppKit (`NSViewRepresentable`) where SwiftUI is weak (text editors, response viewer) | Truly native, fastest startup, no runtime to ship |
| Min macOS | 15.0 (Sequoia) | Modern SwiftUI (`@Observable`, `Table`, `NavigationSplitView`) without Liquid-Glass-only APIs; dev machine is macOS 26 |
| Project generation | XcodeGen `project.yml` → `Postfrau.xcodeproj` (generated, git-ignored) | Text-based, deterministic, agent-friendly. `xcodegen` is installed at `/opt/homebrew/bin/xcodegen` |
| Code split | Local SPM package `Packages/PostfrauCore` (pure Swift, Foundation only, zero UI) + app target `Postfrau` | Core is testable with plain `swift test` in seconds; UI stays thin |
| Third-party deps | None in v1 | Fewer moving parts. Revisit only with a written justification in this file |
| Persistence | JSON files (collections, environments, globals, UI state) in Application Support + Keychain for secrets + capped JSONL for history | Human-readable, git/iCloud-friendly, trivial to back up. No SwiftData/CoreData |
| Networking | `URLSession` with a delegate (TLS override, redirect control, `URLSessionTaskMetrics`) | HTTP/1.1, HTTP/2, HTTP/3, system proxies, for free |
| Concurrency | Swift 6 strict concurrency, `async/await`, actors for executor and persistence | Correctness by construction |
| Sandbox | App Sandbox ON with `network.client` + `files.user-selected.read-write` | Keeps App Store / notarization path open; costs nothing now |
| Bundle ID | `com.postfrau.Postfrau` | Placeholder, change freely |
| License | MIT | "free" |
| Scripts (pre-request/tests) | Out of v1. When added, use **JavaScriptCore** (ships with macOS), never Node | Honors the no-Node constraint |
| GraphQL / WebSocket | Out of v1; extension points reserved (see §9) | User explicitly wants GraphQL later |

## 1. Scope

### In scope (v1)
1. Request composer: method, URL, query params, headers, auth, body (raw / form-data / urlencoded / binary / none), per-request settings.
2. Send / cancel, response viewer (pretty JSON/XML, raw, headers, cookies), status/time/size, timing breakdown, search in body, copy, save body to file.
3. Collections with nested folders; create/rename/duplicate/move/delete; drag-and-drop reorder; collection- and folder-level auth and variables (inherited).
4. Tabs for open requests with dirty state, unsaved-changes prompt, restore on relaunch.
5. Environments + globals; `{{variable}}` substitution everywhere; secret variables stored in Keychain; unresolved variables visibly flagged; dynamic variables (`{{$guid}}`, `{{$timestamp}}`, `{{$isoTimestamp}}`, `{{$randomInt}}`).
6. History (auto-recorded, searchable, capped, reopenable).
7. Import/export: Postman Collection v2.1, Postman Environment JSON, cURL (paste to import, copy as cURL).
8. Quick open (⌘K) fuzzy finder over all requests.
9. Settings window; keyboard-first workflow; full menu bar.
10. Handles big data gracefully: 5 000-request collections, 50 MB responses.

### Out of scope (v1)
Collaboration, sync, accounts, workspaces, mock servers, monitors, load tests, scripting, GraphQL,
WebSocket/gRPC/SSE, code-snippet generation, OpenAPI import, cookie-jar editor, proxy configuration
UI (system proxy is used automatically), client certificates, Windows/Linux.

---

## 2. Repository layout

```
postfrau/
├── PLAN.md                     ← this file
├── CLAUDE.md                   ← agent conventions (write in Phase 0, keep short)
├── README.md
├── LICENSE                     ← MIT
├── Makefile                    ← gen / build / test / run / clean / release
├── project.yml                 ← XcodeGen spec
├── .gitignore                  ← *.xcodeproj, DerivedData, .build, xcuserdata, .DS_Store
├── Packages/
│   └── PostfrauCore/
│       ├── Package.swift       (swift-tools-version 6.0, platforms: .macOS(.v15))
│       ├── Sources/PostfrauCore/
│       │   ├── Model/          Collection, Folder, RequestItem, Environment, Variable, Auth, Body, HistoryEntry, Ids
│       │   ├── Resolve/        VariableResolver, Scope, DynamicVariables
│       │   ├── HTTP/           HTTPExecutor (actor), RequestBuilder, HTTPResponse, Timing, SessionDelegate
│       │   ├── Persistence/    WorkspaceStore (actor), AtomicFile, HistoryLog, Keychain, Migrations
│       │   ├── Interop/        PostmanV21Importer/Exporter, PostmanEnvironment, CurlParser, CurlFormatter
│       │   ├── Text/           JSONPrettyPrinter, XMLPrettyPrinter, ContentTypeSniffer
│       │   └── Util/           FuzzyMatcher, ByteCount, Debouncer
│       └── Tests/PostfrauCoreTests/
│           ├── Fixtures/       postman-*.json, curl-*.txt
│           └── *Tests.swift    (Swift Testing, `@Test`)
├── Postfrau/                   ← app target
│   ├── App/                    PostfrauApp.swift, AppDelegate.swift, AppCommands.swift (menus), Shortcuts.swift
│   ├── State/                  AppState (@Observable, root), TabsState, SelectionState, SendController
│   ├── Views/
│   │   ├── Shell/              MainWindow, SidebarView, ContentSplit, StatusBar
│   │   ├── Sidebar/            CollectionsTree, HistoryList, EnvironmentPicker, SidebarSearch
│   │   ├── Tabs/               TabBar, TabItem
│   │   ├── Request/            RequestEditor, URLBar, MethodPicker, ParamsTab, HeadersTab, AuthTab, BodyTab, SettingsTab, KeyValueEditor
│   │   ├── Response/           ResponsePane, ResponseBodyView, ResponseHeadersView, CookiesView, TimingPopover, FindBar
│   │   ├── Environments/       EnvironmentsWindow, VariablesEditor
│   │   ├── QuickOpen/          QuickOpenPanel
│   │   ├── Settings/           SettingsView
│   │   └── Components/         CodeTextView (NSTextView wrapper), TokenTextField (URL field w/ {{var}} highlighting), Badge, EmptyState
│   ├── Highlighting/           SyntaxHighlighter protocol, JSONHighlighter, XMLHighlighter, Theme
│   ├── Resources/              Assets.xcassets (AppIcon), SampleCollection.json, Postfrau.entitlements, Info.plist
│   └── Support/                Pasteboard, FileDialogs, KeychainBridge
├── PostfrauUITests/            ← minimal XCUITest smoke (Phase 10)
├── Scripts/
│   ├── bootstrap.sh            (brew install xcodegen if missing; xcodegen generate)
│   ├── screenshot.sh           (launch app, capture main window to /tmp for visual checks)
│   └── release.sh              (archive, sign, hdiutil DMG)
└── docs/
    ├── data-format.md          (on-disk JSON schema, versioning)
    └── decisions.md            (ADR-style log; append when deviating from PLAN.md)
```

### Makefile targets (write in Phase 0)
```
make gen      # xcodegen generate
make build    # xcodebuild -project Postfrau.xcodeproj -scheme Postfrau -configuration Debug build | tail
make test     # (cd Packages/PostfrauCore && swift test) && xcodebuild test -scheme Postfrau -destination 'platform=macOS'
make core-test# cd Packages/PostfrauCore && swift test      (fast loop, use constantly)
make run      # build then open the built .app from DerivedData
make clean
make release  # Scripts/release.sh
```
`xcodebuild` output is noisy: pipe through `xcbeautify` if available, otherwise `grep -E "error|warning: |BUILD"`.

---

## 3. Domain model (PostfrauCore/Model)

All types are `Codable`, `Sendable`, `Hashable`, `Identifiable` with `UUID` ids. Every persisted root
document carries `schemaVersion: Int` (start at 1). Use explicit `CodingKeys`; never rely on
synthesized keys for persisted types so renames don't break files.

```swift
struct Workspace { var collections: [Collection]; var environments: [Environment]; var globals: [Variable]; var activeEnvironmentID: UUID? }

struct Collection { id, name, description: String?, auth: Auth /* .none | .inherit not allowed at root */, variables: [Variable], items: [Item], createdAt, updatedAt }
enum Item { case folder(Folder), request(RequestItem) }      // ordered; encode with a "type" discriminator
struct Folder { id, name, description, auth: Auth /* default .inherit */, variables: [Variable], items: [Item] }

struct RequestItem { id, name, method: HTTPMethod, url: String /* raw, may contain {{vars}} */,
                     params: [KeyValue], headers: [KeyValue], auth: Auth, body: Body, settings: RequestSettings, description }
struct KeyValue { id, key: String, value: String, enabled: Bool, description: String? }
enum HTTPMethod: String, CaseIterable { GET, POST, PUT, PATCH, DELETE, HEAD, OPTIONS; plus .custom(String) via rawValue fallback }

enum Auth { case inherit, none, basic(username, password), bearer(token), apiKey(key, value, in: .header|.query) }
enum Body { case none, raw(text: String, language: RawLanguage /* json, text, xml, html, javascript */),
            formData([FormField]), urlEncoded([KeyValue]), binary(fileBookmark: Data?) }
struct FormField { id, key, enabled, value: FormValue /* .text(String) | .file(bookmark: Data, displayName: String) */ }
struct RequestSettings { followRedirects = true, maxRedirects = 10, timeoutSeconds = 30, verifyTLS = true, sendCookies = true, encodeURL = true }

struct Environment { id, name, variables: [Variable] }
struct Variable { id, key, value: String /* empty on disk if secret */, enabled, isSecret: Bool }

struct HistoryEntry { id, sentAt: Date, method, resolvedURL, statusCode: Int?, durationMs, responseBytes, requestSnapshot: RequestItem, error: String? }

struct HTTPResponse { statusCode, reasonPhrase, headers: [(String,String)] /* ordered, duplicates allowed */,
                      body: ResponseBody /* .inMemory(Data) | .onDisk(URL, byteCount) */, mimeType, textEncoding,
                      timing: Timing, redirects: [RedirectHop], finalURL, cookies: [HTTPCookie-like struct] }
struct Timing { total, dns, connect, tls, request, ttfb, download: TimeInterval? }
```

**Variable resolution precedence (highest wins):** active environment → folder chain (innermost first) →
collection → globals. Dynamic `{{$...}}` variables are evaluated last and never shadowed. Resolution is
recursive (a value may reference another variable) with depth limit 10; cycles resolve to the literal
text and are reported. Resolver returns both the resolved string and a list of unresolved names so the
UI can flag them. Secrets are fetched from Keychain at resolve time, never held in the JSON model.

**Auth inheritance:** `.inherit` walks up folder → collection; root collection `.inherit` means `.none`.
Auth is applied at send time as headers/query, and shown in the UI as "will send `Authorization: Bearer …`"
without mutating the user's header list. A user-defined `Authorization` header always wins over auth helpers.

**URL ↔ params sync:** the URL string is the source of truth for the path; the params table is the
source of truth for the query. Editing either re-derives the other. Disabled params are kept in the
table but dropped from the URL. Unencoded `{{vars}}` inside the query survive round-trips untouched.

---

## 4. On-disk format (docs/data-format.md — write it in Phase 1)

```
~/Library/Containers/com.postfrau.Postfrau/Data/Library/Application Support/Postfrau/
├── collections/<collectionUUID>.json      one file per collection (whole tree inside)
├── environments/<environmentUUID>.json
├── globals.json
├── ui-state.json                          open tabs (ids + unsaved drafts), selection, sidebar width, window frame, active env
├── history.jsonl                          one HistoryEntry per line, newest appended; pruned to `maxHistoryEntries` (default 1000) on launch and every 100 writes
└── settings.json
```
Rules: all writes atomic (write temp in same dir, `rename`). Debounced autosave (300 ms) after any
model mutation; explicit flush on quit and on window close. Reads tolerate unknown keys. A
`schemaVersion` bump requires a migration function in `Migrations.swift` and a fixture test.
Keychain: service `com.postfrau.secrets`, account `"\(environmentID).\(variableKey)"`, `kSecAttrAccessibleAfterFirstUnlock`.
Deleting a variable or environment deletes its Keychain items.

---

## 5. UI specification

```
┌─────────────────────────────────────────────────────────────────────────────────────────┐
│ ● ● ●   [Sidebar ⌄]                Postfrau                       [Env: Staging ⌄] [⚙]  │  toolbar
├───────────────┬─────────────────────────────────────────────────────────────────────────┤
│ 🔍 Filter     │ [GET users ×] [POST login •] [+]                                         │  tab bar
│ ▸ Collections │─────────────────────────────────────────────────────────────────────────│
│  ▾ Acme API   │ [GET ⌄] [ {{baseUrl}}/users?limit=10                        ] [Send ⌘↩] │  URL bar
│    ▾ Users    │ Params (1)  Headers (3)  Auth  Body  Settings                            │  request tabs
│      GET list │ ┌───────────────────────────────────────────────────────────────────────┐│
│      POST new │ │  ☑ limit        10                         description                ││  key-value editor
│  ▸ Other      │ │  ☐ offset       0                                                     ││
│ ▸ History     │ └───────────────────────────────────────────────────────────────────────┘│
│   Today       │═════════════════════════ draggable divider ═════════════════════════════│
│   GET /users  │ 200 OK   142 ms   2.3 KB                        Pretty Raw Headers(12) Cookies │  response header
│   …           │ {                                                                        │
│               │   "users": [ … ]              ← syntax highlighted, monospace, find bar   │  response body
├───────────────┴─────────────────────────────────────────────────────────────────────────┤
│ 3 collections · 42 requests · history 118                     Saved ✓  |  Staging       │  status bar
└─────────────────────────────────────────────────────────────────────────────────────────┘
```

- `NavigationSplitView` with sidebar (min 220, default 260) and detail. Detail is a vertical
  `HSplitView`/`VSplitView` (user can toggle horizontal vs vertical response layout in Settings).
- Sidebar has two sections in one `List`: Collections (outline, expandable) and History (grouped by day).
  A segmented control at the top switches between them if the list gets long; filter field filters both.
- Tab bar is custom SwiftUI (no `TabView`): scrollable, middle-click/⌘W closes, unsaved dot, drag to reorder,
  double-click empty area = new request. Tabs persist across relaunch.
- URL bar: custom `TokenTextField` (AppKit `NSTextField` subclass or `NSTextView` single-line) that
  colors `{{resolved}}` green, `{{unresolved}}` red, and shows the resolved value on hover. Pasting a
  string that starts with `curl ` offers "Import as request" (or just does it, with an undoable toast).
- Method picker: popup with color-coded methods (GET green, POST orange, PUT blue, PATCH violet, DELETE red).
- Key-value editor: custom rows (checkbox, key TextField, value TextField, description, delete on hover),
  always one trailing empty row, tab between cells, ⌘⌫ deletes row, drag handle to reorder. Header key
  field autocompletes common header names; Content-Type value autocompletes MIME types.
- Body tab: mode picker; raw uses `CodeTextView` with language highlighting + "Beautify" button for JSON;
  form-data rows can be Text or File (file picker via `NSOpenPanel`, stored as security-scoped bookmark).
- Response body: `CodeTextView` (NSTextView, TextKit 2, non-editable, line numbers optional). Pretty
  mode pretty-prints JSON/XML; Raw shows bytes as text; if body > 5 MB show first 1 MB with a
  "Load full" button; if not text, show hex-dump preview + "Save to file". Find bar (⌘F) with match count.
  Word-wrap toggle. Copy button. Status line shows status code with color, total time, size; clicking
  time opens Timing popover (DNS / connect / TLS / TTFB / download bars).
- Send button becomes Cancel while in flight; a thin progress bar under the URL bar; ⌘↩ sends,
  Esc cancels. Errors (DNS failure, timeout, TLS) render in the response pane as a friendly card
  with the underlying `NSError` description and a "Retry" button, not as an alert.
- Environment picker in toolbar: "No environment" + list + "Manage…". Eye icon shows a quick-look
  popover of the resolved variables (secrets masked, click to reveal).
- Quick open (⌘K): floating panel, fuzzy match over `collection / folder / request name` and URL; ↑↓ Enter.
- Empty states: no collections → hint + "Import" and "New request" buttons; no response yet → hint "⌘↩ to send".
- Dark/light follows system; monospace font SF Mono, size from Settings (default 12).
- Every interactive element has an accessibility label (needed for XCUITest and VoiceOver).

**Keyboard shortcuts (register in `AppCommands.swift`, all shown in menus):**
⌘↩ send · Esc cancel · ⌘S save request · ⌘N new request · ⌘⇧N new collection · ⌘T new tab ·
⌘W close tab · ⌘⇧] / ⌘⇧[ next/prev tab · ⌘K quick open · ⌘L focus URL · ⌘F find in response ·
⌘⇧C copy as cURL · ⌘E manage environments · ⌘, settings · ⌘⇧I import · ⌘⇧E export ·
⌘1..⌘5 request sub-tabs (Params/Headers/Auth/Body/Settings) · ⌘⌥R toggle response layout.

---

## 6. Phases

Each phase: implement → `make core-test` / `make test` green → run app and verify acceptance list →
update checkboxes here → `git commit -m "Phase N: …"`. Never start phase N+1 with a red build.

### Phase 0 — Bootstrap  ☐
- [ ] `git init`, `.gitignore`, `LICENSE` (MIT), `README.md` (one paragraph + build instructions).
- [ ] `Packages/PostfrauCore/Package.swift` with library + test target, Swift Testing. One trivial test.
- [ ] `project.yml`: app target `Postfrau` (macOS 15.0, SwiftUI lifecycle, `SWIFT_STRICT_CONCURRENCY=complete`,
      `SWIFT_VERSION=6`), depends on local package `PostfrauCore`, entitlements (sandbox + network client +
      user-selected files r/w), Info.plist with `LSMinimumSystemVersion`, `CFBundleDisplayName`, document
      types for `.json` import via drag (Phase 9), unit-test target `PostfrauTests`, UI-test target stub.
- [ ] `Makefile`, `Scripts/bootstrap.sh`, `Scripts/screenshot.sh`
      (`open` the app, `sleep 2`, `screencapture -l $(osascript … window id)` or simply `screencapture -x /tmp/postfrau.png` of the full screen; good enough for the agent to eyeball).
- [ ] `PostfrauApp.swift` opens a window with placeholder three-pane layout and "Postfrau" text.
- [ ] `CLAUDE.md`: 15 lines max — build/test commands, "Core has no UI imports", "strict concurrency",
      "no third-party deps", "update PLAN.md checkboxes", "commit per phase".
- Acceptance: `make gen && make test && make run` all succeed from a clean clone; window appears.

### Phase 1 — Core models, persistence, resolver  ☐
- [ ] All model types from §3 with explicit `CodingKeys` and `schemaVersion`.
- [ ] `Item` enum encoding with `"type": "folder" | "request"` discriminator; tests for round-trip.
- [ ] `WorkspaceStore` actor: `load()` → `Workspace`, `save(collection:)`, `delete(collectionID:)`,
      same for environments, `saveGlobals`, `saveUIState`, `saveSettings`. Directory injectable for tests
      (use a temp dir). Atomic writes. Debounced batching lives in the app layer, not here.
- [ ] `Keychain` wrapper (Security framework): get/set/delete generic password; tests run against a
      test service name and clean up after themselves (skip gracefully if Keychain is unavailable in CI).
- [ ] `HistoryLog`: append(entry), load(limit:), clear(), prune(to:). JSONL, tolerant of a corrupt last line.
- [ ] `VariableResolver` per §3 with `ResolveResult { text, unresolved: [String], cycles: [String] }`.
      Dynamic variables. Tests: precedence, nesting, cycles, unresolved, `{{ spaced }}` trimmed keys,
      escaped `\{{` left alone.
- [ ] `AuthResolver`: computes effective auth for a request given its folder chain.
- [ ] `docs/data-format.md`.
- Acceptance: ≥ 40 unit tests, `make core-test` < 10 s.

### Phase 2 — HTTP executor  ☐
- [ ] `RequestBuilder`: `RequestItem` + resolved scope → `URLRequest` (+ `Body payload` as `Data` or
      streamed file). Handles: query merge & encoding (respect `encodeURL`), multipart/form-data with
      generated boundary and file parts, urlencoded, raw with correct `Content-Type` default per language
      (only if user didn't set one), auth application, `User-Agent: Postfrau/<version>` default, `Accept: */*` default,
      `Content-Length`. Tests for each body mode (inspect built request bytes).
- [ ] `HTTPExecutor` actor: `send(_:settings:) async throws -> HTTPResponse`, cancellable via Task
      cancellation. One `URLSession` per settings profile (TLS verify on/off, redirects on/off, cookies on/off)
      cached in a dictionary; delegate implements `urlSession(_:didReceive challenge:)` (accept any cert only
      when `verifyTLS == false`), redirect interception (record hops, stop when disabled or `maxRedirects` hit),
      `didFinishCollecting metrics` → `Timing`. Body collected via `bytes(for:)` streaming; spill to a temp
      file above 20 MB; hard cap 200 MB (fail with a clear error).
- [ ] Reason phrase table for common status codes (URLSession doesn't give one).
- [ ] Cookie extraction from `Set-Cookie` headers (parse manually; don't rely on the shared cookie storage).
- [ ] Tests via a custom `URLProtocol` mock for: headers/body correctness, redirect recording, timeouts,
      cancellation, large body spill, error mapping. Plus one opt-in live test against `https://httpbin.org`
      guarded by env var `POSTFRAU_LIVE_TESTS=1`.
- Acceptance: `swift test` green; executing a GET to `https://example.com` from a throwaway CLI test prints
  200 + timing (verify manually once).

### Phase 3 — App shell & first end-to-end send  ☐
- [ ] `AppState` (`@Observable`, `@MainActor`): owns `Workspace`, `WorkspaceStore`, `HistoryLog`, tabs,
      selection, settings; every mutation goes through methods that schedule a debounced save.
- [ ] Three-pane layout per §5 with `NavigationSplitView` + split for request/response; divider persisted.
- [ ] Sidebar: collections outline (read-only for now, from loaded data), select → opens tab.
- [ ] Tab bar with open/close/dirty/reorder; state persisted in `ui-state.json`.
- [ ] URL bar (plain `TextField` for now), method picker, Send/Cancel, progress bar.
- [ ] `SendController`: takes current tab's draft, resolves variables (active env + chain + globals),
      calls executor, stores `HTTPResponse` on the tab, appends history entry.
- [ ] Response pane: status/time/size line, raw body in a `CodeTextView` (NSTextView wrapper, non-editable,
      monospaced, no highlighting yet), headers list.
- [ ] Environment picker in toolbar (switching only; management UI is Phase 7).
- [ ] First-run: if no collections exist, load `SampleCollection.json` (3–4 requests to `httpbin.org`).
- Acceptance: launch → select sample "GET /get" → ⌘↩ → 200 with body and headers visible; cancel works
  on a `https://httpbin.org/delay/10`; relaunch restores tabs.

### Phase 4 — Request editor complete  ☐
- [ ] `KeyValueEditor` component per §5 (used by Params, Headers, urlencoded body, form-data, variables).
- [ ] Params tab ↔ URL two-way sync (§3 rule), with tests in Core for the parse/compose function.
- [ ] Headers tab with autocomplete; computed "auto headers" section (greyed, non-editable) showing what
      Postfrau will add (Content-Type, Authorization from auth helper, User-Agent, Content-Length).
- [ ] Auth tab: Inherit (shows the effective inherited auth read-only), None, Basic, Bearer, API Key.
      Secret-ish fields use `SecureField` with reveal toggle.
- [ ] Body tab: all modes; raw editor is `CodeTextView` editable with JSON/XML highlighting (Phase 5's
      highlighter—stub it now, real one next phase), language picker, Beautify (JSON), file picker for
      binary and form-data files with security-scoped bookmarks.
- [ ] Settings tab: follow redirects, max redirects, timeout, verify TLS, send cookies, encode URL.
- [ ] `TokenTextField` URL bar with `{{var}}` coloring and hover-to-resolve; ⌘L focuses it.
- [ ] Dirty tracking: draft vs saved copy diff; ⌘S saves; closing a dirty tab prompts Save / Don't Save / Cancel.
- [ ] Rename request inline from tab (double-click) and from sidebar.
- Acceptance: build a POST with JSON body + bearer token + 2 params against httpbin `/anything`, response
  echoes everything correctly; form-data with a file upload echoes file name; changing params rewrites URL and vice-versa.

### Phase 5 — Response viewer  ☐
- [ ] `SyntaxHighlighter` protocol + `JSONHighlighter` (hand-written tokenizer, O(n), no regex over the
      whole document) + `XMLHighlighter` (tags/attrs/text); `Theme` with light/dark palettes reading system accent.
      Highlighting runs on a background task for bodies > 256 KB and is applied when ready; never blocks the main thread.
- [ ] Pretty / Raw / Headers / Cookies segmented tabs. Pretty = `JSONPrettyPrinter` (preserves key order and
      big-number precision: pretty-print via tokenizer, NOT via `JSONSerialization`) / `XMLPrettyPrinter`;
      falls back to Raw with a hint if the body isn't JSON/XML. Content type sniffed from header, then from bytes.
- [ ] Large-body policy from §5; binary → hex preview + Save.
- [ ] Find bar with next/prev/count, wrap toggle, line numbers toggle, copy body, save body (`NSSavePanel`).
- [ ] Timing popover; redirect chain list (each hop: status, URL) when redirects occurred.
- [ ] Error card for transport failures with Retry.
- [ ] Headers tab: table with copy-on-click; Cookies tab: name/value/domain/path/expires/flags.
- Acceptance: 20 MB JSON response (httpbin `/bytes` won't do; use `https://httpbin.org/stream/…` or a local
  python `http.server` serving a generated file — python3 is allowed for *testing* only) stays responsive: scroll,
  find, switch tabs without beachball; pretty-print of a 2 MB JSON completes < 1 s.

### Phase 6 — Collections management  ☐
- [ ] Sidebar outline: create collection/folder/request (context menu + toolbar + shortcuts), rename inline,
      duplicate (deep copy with new ids), delete with confirmation (⌫), move via drag-and-drop between folders
      and collections, reorder siblings via drag. Expansion state persisted.
- [ ] Collection & folder "editor" tab (opened by double-click / context menu): name, description (markdown-ish
      plain text), Auth (same AuthTab, no Inherit at collection root), Variables (KeyValueEditor with secret toggle).
- [ ] Sidebar filter matches name and URL, keeps ancestors visible, highlights matches.
- [ ] Quick open ⌘K with `FuzzyMatcher` (subsequence match with scoring; tests in Core).
- [ ] Sidebar shows method badge per request; request count per collection in status bar.
- [ ] Undo/redo for structural sidebar operations via `UndoManager` (rename, delete, move) — keep it simple:
      snapshot the affected collection before/after.
- Acceptance: create a 3-level tree, drag a request across collections, rename, delete, undo the delete;
  everything persists across relaunch; a generated 5 000-request collection (write a debug menu item
  "Generate stress collection") scrolls and filters without lag.

### Phase 7 — Environments, globals, secrets  ☐
- [ ] Environments window (⌘E): list on the left (add, duplicate, delete, rename), variables editor on the
      right (key, value, enabled, secret toggle); Globals as a pinned first entry.
- [ ] Secret variables: value stored in Keychain, masked in UI with reveal, never written to JSON, excluded
      from export unless user checks "include secrets" (warning shown).
- [ ] Toolbar picker + quick-look popover of resolved values; unresolved-variable warning badge on the
      Send button tooltip listing names; red tokens in URL bar / headers / body (body: only in the gutter
      or via a count badge—don't slow the editor).
- [ ] Variables inherited from collection/folder visible in the popover with their source labeled.
- Acceptance: request using `{{baseUrl}}` switches target when env changes; secret token shows as ••• and
  is sent correctly; relaunch keeps secrets (Keychain), JSON on disk has empty value.

### Phase 8 — History  ☐
- [ ] Sidebar History section grouped by day, showing method, status color, URL path, relative time.
- [ ] Click opens a tab with the snapshot (unsaved, titled "History · GET /users"); "Save to collection…" action.
- [ ] Search/filter; clear all; delete single entry; cap configurable in Settings (default 1000).
- [ ] History records failed sends too (with the error).
- Acceptance: 1 000 entries load in < 200 ms at launch; filter is instant.

### Phase 9 — Import / Export  ☐
- [ ] `PostmanV21Importer`: `info`, nested `item[]`, `request.url` as string OR object (`raw`, `host[]`,
      `path[]`, `query[]`, `variable[]`), `header[]`, `body` modes (`raw` + `options.raw.language`,
      `formdata` incl. `type: file` (record src path as display name only), `urlencoded`, `file`, none),
      `auth` (`noauth`, `basic`, `bearer`, `apikey`; anything else → `.none` + warning), `variable[]`,
      `disabled` flags, descriptions. Unknown fields (`event[]` scripts, `protocolProfileBehavior`) are
      preserved as an opaque `extras: [String: JSONValue]` on the model so export round-trips them.
      Importer returns `(Collection, warnings: [String])`; UI shows warnings in a sheet.
- [ ] `PostmanV21Exporter`: inverse; export one collection to a file. Round-trip tests with fixtures
      (build 3–4 realistic fixtures by hand covering all body modes and nesting).
- [ ] Postman Environment import/export (`{name, values:[{key,value,enabled,type:"secret"|"default"}]}`).
- [ ] `CurlParser`: `-X/--request`, `-H/--header`, `-d/--data/--data-raw/--data-binary/--data-urlencoded`,
      `-F/--form`, `-u/--user`, `-b/--cookie`, `-L`, `-k/--insecure`, `--url`, `-A`, quoted args (single/double,
      backslash-newline continuation, `$'…'`), unknown flags ignored with a warning. Tests with 15+ real-world curls.
- [ ] `CurlFormatter`: request → multi-line `curl` with resolved or raw variables (user chooses).
- [ ] UI: File ▸ Import… (auto-detects collection vs environment vs cURL text file), drag `.json` onto the
      sidebar, paste cURL into URL bar, File ▸ Export Collection…, Export Environment…, ⌘⇧C copy as cURL.
- Acceptance: import a real exported Postman collection (ask the user for one or use fixtures), send a
  request from it successfully; export → re-import yields an identical model (test asserts equality
  modulo ids/timestamps).

### Phase 10 — Polish & release  ☐
- [ ] Full menu bar (File/Edit/View/Request/Window/Help) with every shortcut from §5; Help ▸ Keyboard Shortcuts sheet.
- [ ] Settings window: font size, response layout (vertical/horizontal), default timeout, default verify TLS,
      max history, "Reveal data folder", "Reset sample collection".
- [ ] Window/state restoration, multiple windows not required (single window app; ⌘N when window is closed reopens it).
- [ ] App icon (simple, generated as SVG → PNG set via `sips`/`iconutil`; no external tools), About window with version + license.
- [ ] Accessibility pass: labels on everything; VoiceOver can operate URL bar, Send, tabs.
- [ ] Performance pass with Instruments (Time Profiler + Allocations): launch < 300 ms to interactive with 50 collections; no main-thread hitch > 16 ms on send/response render for typical (< 1 MB) responses; memory < 150 MB with a 50 MB response open.
- [ ] Crash-safety: simulate kill -9 during autosave, verify files intact (atomic writes) — write a test.
- [ ] `PostfrauUITests`: smoke test — launch, ⌘N, type URL to a local mock server (spin up an in-process
      `NWListener` HTTP responder inside the UI-test host or use `URLProtocol` via launch argument), send, assert status label.
- [ ] `Scripts/release.sh`: `xcodebuild archive`, export with Developer ID if `CODESIGN_IDENTITY` env set, else ad-hoc;
      `hdiutil` DMG; optional `notarytool` step guarded by env vars. Version from `MARKETING_VERSION` in project.yml.
- [ ] README: screenshots (from `Scripts/screenshot.sh`), features, build, roadmap link to §9.
- Acceptance: DMG builds; fresh user account (or wiped container: `rm -rf ~/Library/Containers/com.postfrau.Postfrau`)
  launches with sample collection; entire §5 shortcut list works.

---

## 7. Engineering rules for the executing agent

1. **Core has zero UI.** `PostfrauCore` imports only Foundation/Security. If you need AppKit in Core, you're in the wrong layer.
2. **Strict concurrency, no `@unchecked Sendable`** without a comment explaining why. UI state is `@MainActor`.
3. **No third-party packages.** If a problem genuinely needs one (e.g. a text editor), stop, write the trade-off in `docs/decisions.md`, and prefer writing 300 lines yourself.
4. **Never block the main thread:** network, file IO, pretty-printing, highlighting > 256 KB, import parsing all run off-main.
5. **AppKit where SwiftUI hurts:** editors (`NSTextView`/TextKit 2), the URL token field, large outline performance if `List` proves slow (measure first).
6. **Persist through one door:** every model mutation goes through `AppState` methods that mark dirty and schedule save. No view writes files.
7. **Tests first for Core:** every parser/formatter/resolver gets tests before wiring into UI. Fixtures live in `Tests/.../Fixtures`.
8. **Verify visually:** after UI phases run `make run` then `Scripts/screenshot.sh` and look at the PNG (Read tool). Fix what looks wrong before declaring done.
9. **Commit per phase** (or sub-phase if large) with message `Phase N: <summary>`. Keep `git status` clean of generated files.
10. **Deviations from this plan** are allowed when justified; record them in `docs/decisions.md` and update this file so the plan stays truthful.
11. **Warnings are errors** in the app target (`SWIFT_TREAT_WARNINGS_AS_ERRORS=YES`) once Phase 3 compiles clean; keep it that way.
12. **Keep the UI keyboard-first and un-cluttered.** When in doubt, mirror Postman's layout (users know it) but with native macOS controls and spacing.

## 8. Risks & mitigations

| Risk | Mitigation |
|---|---|
| SwiftUI `List`/outline lags with thousands of rows or drag-drop is flaky | Measure in Phase 6 with the stress generator; fallback is `NSOutlineView` via `NSViewRepresentable` (budget: 1 day) |
| `TextEditor` unusable for code | Never use it; `CodeTextView` (NSTextView) from Phase 3 onward |
| Sandbox blocks reading files chosen for form-data/binary after relaunch | Store security-scoped bookmarks; call `startAccessingSecurityScopedResource` around reads |
| Keychain prompts / failures in tests | Isolate with test service name; skip tests when `SecItemAdd` returns `errSecInteractionNotAllowed` |
| `URLSession` shares cookies globally across "profiles" | Use `URLSessionConfiguration.ephemeral` per profile with its own `HTTPCookieStorage`; `sendCookies=false` → `httpShouldSetCookies=false` |
| Postman format edge cases | Preserve unknown JSON as `extras`; surface warnings instead of failing the import |
| Big responses blow memory | Spill > 20 MB to temp file; viewer shows a window into the file; hard cap 200 MB |
| Precision loss pretty-printing JSON numbers | Tokenizer-based pretty printer; never round-trip through `JSONSerialization`/`Double` |

## 9. Future extension points (design for, don't build)

- **GraphQL:** add `Body.graphql(query:, variables:, operationName:)`; a `GraphQLTab` with query editor,
  variables editor, and schema introspection (POST `__schema`) cached per collection for autocomplete.
  `RequestBuilder` already dispatches on `Body`, so this is additive. Postman import maps `body.mode == "graphql"`.
- **Scripting:** `JavaScriptCore` sandboxed context exposing `pm.environment.set/get`, `pm.response.json()`,
  `pm.test`. Pre-request and test hooks slot into `SendController` before/after `HTTPExecutor.send`.
  Imported `event[]` extras become editable.
- **WebSocket / SSE:** separate `Item` kind and a streaming response pane; `URLSessionWebSocketTask`.
- **Code generation:** `CurlFormatter` generalizes to a `SnippetGenerator` protocol (Swift/URLSession, Python/requests, JS/fetch…).
- **OpenAPI import:** new `Interop/OpenAPIImporter` producing a `Collection`.
- **Cookie jar UI:** expose the per-profile `HTTPCookieStorage`.

## 10. Definition of done for v1

- All Phase 0–10 boxes ticked; `make test` green; `Scripts/release.sh` produces a DMG that runs on a clean macOS 15 machine.
- A user coming from Postman can import their collection and environment, switch environment, send
  requests with auth and bodies, read responses comfortably, and never sees a beachball.
