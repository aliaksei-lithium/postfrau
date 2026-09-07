# Postfrau — Execution Plan

Postfrau is a free, personal, native macOS HTTP client in the spirit of Postman: send HTTP
requests, organize them into collections, switch environments. No collaboration, no cloud, no
load testing, no accounts. Fast, responsive, good UX. No Node.js anywhere in the stack.

**Revision log** (re-read the affected sections when a new entry appears):
- R1 — retargeted to macOS 26 only (§0, §5, Phase 0/3/5, Polish).
- R2 — sync via user-chosen data folder (§0, §4, Phase 9).
- R3 (2026-09-07, during Phase 3) — AI-native: `postfrau` CLI + skill as the agent interface, per-entry history files with recording levels and attribution, `Commands` layer in Core. Touches §0, §1, §2, §3, §4, §5, Phase 3 (one new item), Phase 8 (rewritten), new Phase 11, Polish is now Phase 12, §7, §8, §9.

This document is the contract for the agent that builds it. Work phase by phase, in order.
Every phase ends with a green `make test`, a manual check of its acceptance criteria, and one
git commit. Tick the checkboxes in this file as you go so progress survives context loss.

---

## 0. Decisions already made (do not re-litigate)

| Topic | Decision | Why |
|---|---|---|
| Language / UI | Swift 6.3, SwiftUI app shell, AppKit (`NSViewRepresentable`) where SwiftUI is weak (text editors, response viewer) | Truly native, fastest startup, no runtime to ship |
| Min macOS | **26.0 (Tahoe)** — macOS 26 only, no back-compat shims | Owner's call. Unlocks Liquid Glass, SwiftUI `WebView`, `Observations`, Swift 6.2+ approachable concurrency, Icon Composer icons. Dev machine is macOS 26.6 / Xcode 26.6 |
| Design language | Liquid Glass where the system puts it (toolbar, sidebar, floating panels, prominent buttons); flat, opaque surfaces for content (editors, tables, response body) | Looks like a 2025+ Mac app; glass over dense text hurts legibility, so it stays on chrome only |
| Project generation | XcodeGen `project.yml` → `Postfrau.xcodeproj` (generated, git-ignored) | Text-based, deterministic, agent-friendly. `xcodegen` is installed at `/opt/homebrew/bin/xcodegen` |
| Concurrency defaults | App target: `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`, `SWIFT_APPROACHABLE_CONCURRENCY = YES`. Core package: `nonisolated` default, strict concurrency complete | UI code is main-actor by default with zero annotations; Core stays explicit and portable |
| Code split | Local SPM package `Packages/PostfrauCore` (pure Swift, Foundation only, zero UI) + app target `Postfrau` | Core is testable with plain `swift test` in seconds; UI stays thin |
| Third-party deps | None in v1 | Fewer moving parts. Revisit only with a written justification in this file |
| Persistence | JSON files (collections, environments, globals) in a **user-selectable data folder** + Keychain for secrets + local-only JSONL history and UI state in Application Support | Human-readable, one file per collection, sync-friendly, trivial to back up. No SwiftData/CoreData |
| Sync | **Data folder** the user points at iCloud Drive / Google Drive / Dropbox / a git repo. Postfrau watches the folder and reloads external changes, writes conflict copies instead of clobbering. Secrets ride iCloud Keychain (`kSecAttrSynchronizable`), never the folder | Works with any sync client, zero servers, no Apple Developer Program needed. A native iCloud (ubiquity) container needs the iCloud entitlement → paid Developer Program and a signed build; deferred to §9 |
| Networking | `URLSession` with a delegate (TLS override, redirect control, `URLSessionTaskMetrics`) | HTTP/1.1, HTTP/2, HTTP/3, system proxies, for free |
| Concurrency | Swift 6 strict concurrency, `async/await`, actors for executor and persistence; `@concurrent` for CPU-heavy work (pretty-print, highlight, import) | Correctness by construction |
| Sandbox | App Sandbox ON with `network.client` + `files.user-selected.read-write` | Keeps App Store / notarization path open; costs nothing now |
| Bundle ID | `com.postfrau.Postfrau` | Placeholder, change freely |
| License | MIT | "free" |
| Agent interface | A `postfrau` **CLI** built from `PostfrauCore` (same package, second executable target), operating on the same data folder and history; a bundled **skill** (`skills/postfrau/SKILL.md`) teaches Claude Code to drive it. MCP is not required; a `postfrau mcp` stdio adapter over the same `Commands` layer is a §9 option | Agents get the whole engine (resolver, executor, history) with zero duplication and no dependency on the app running; skills work in environments where MCP is not allowed |
| Scripts (pre-request/tests) | Out of v1. When added, use **JavaScriptCore** (ships with macOS), never Node | Honors the no-Node constraint |
| GraphQL / WebSocket | Out of v1; extension points reserved (see §9) | User explicitly wants GraphQL later |

## 1. Scope

### In scope (v1)
1. Request composer: method, URL, query params, headers, auth, body (raw / form-data / urlencoded / binary / none), per-request settings.
2. Send / cancel, response viewer (pretty JSON/XML, raw, HTML preview via the macOS 26 SwiftUI `WebView`, headers, cookies), status/time/size, timing breakdown, search in body, copy, save body to file.
3. Collections with nested folders; create/rename/duplicate/move/delete; drag-and-drop reorder; collection- and folder-level auth and variables (inherited).
4. Tabs for open requests with dirty state, unsaved-changes prompt, restore on relaunch.
5. Environments + globals; `{{variable}}` substitution everywhere; secret variables stored in Keychain; unresolved variables visibly flagged; dynamic variables (`{{$guid}}`, `{{$timestamp}}`, `{{$isoTimestamp}}`, `{{$randomInt}}`).
6. History (auto-recorded, searchable, capped, reopenable) with a **recording level** setting — off / metadata / headers / full bodies — redaction of secrets, and **attribution** (app, CLI, or a named agent).
7. Import/export: Postman Collection v2.1, Postman Environment JSON, cURL (paste to import, copy as cURL).
8. Quick open (⌘K) fuzzy finder over all requests.
9. Settings window; keyboard-first workflow; full menu bar.
10. Handles big data gracefully: 5 000-request collections, 50 MB responses.
11. Sync across Macs by choosing a data folder inside iCloud Drive / Google Drive / Dropbox (Settings ▸ Data), with external-change detection and conflict copies. Secrets sync via iCloud Keychain, opt-in.
12. `postfrau` command-line tool: list/inspect/add/edit requests and environments, run requests (single, folder, dry-run, capture values into an environment), ad-hoc send, read history, print the JSON schema — every command with `--json`. Ships inside the app bundle with an "Install command line tool" action, plus a skill file for Claude Code.

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
│       ├── Package.swift       (swift-tools-version 6.2, platforms: .macOS(.v26))
│       ├── Sources/PostfrauCore/
│       │   ├── Model/          RequestCollection, Folder, RequestItem, RequestEnvironment, Variable, Auth, RequestBody, HistoryEntry, JSONValue
│       │   ├── Resolve/        VariableResolver, VariableScope, DynamicVariables, AuthResolver
│       │   ├── HTTP/           HTTPExecutor (actor), RequestBuilder, HTTPResponse, Timing, SessionDelegate
│       │   ├── Commands/       Command structs + CommandRunner: SendRequest, RunFolder, AddRequest, UpdateRequest, MoveItem, SetVariable… (shared by app, CLI, future MCP)
│       │   ├── Persistence/    WorkspaceStore (actor), DataFolder, AtomicFile, CoordinatedFile, FolderWatcher, ConflictResolver, HistoryStore (per-entry files; replaces HistoryLog in Phase 8), Keychain, Migrations
│       │   ├── Interop/        PostmanV21Importer/Exporter, PostmanEnvironment, CurlParser, CurlFormatter
│       │   ├── Text/           JSONPrettyPrinter, XMLPrettyPrinter, ContentTypeSniffer, SyntaxHighlighter + JSON/XML highlighters
│       │   └── Util/           FuzzyMatcher, ByteCount, Debouncer
│       ├── Sources/postfrau/           ← CLI executable target (Phase 11): ArgumentParser-free hand-rolled parser, Output (human/json), Commands mapping
│       └── Tests/PostfrauCoreTests/
│           ├── Fixtures/       postman-*.json, curl-*.txt
│           └── *Tests.swift    (Swift Testing, `@Test`)
├── skills/postfrau/SKILL.md    ← Claude Code skill: CLI reference + workflows (Phase 11); `postfrau skill install` copies it
├── Postfrau/                   ← app target
│   ├── App/                    PostfrauApp.swift, AppDelegate.swift, AppCommands.swift (menus), Shortcuts.swift
│   ├── State/                  AppState (@Observable, root), TabsState, SelectionState, SendController
│   ├── Views/
│   │   ├── Shell/              MainWindow, SidebarView, ContentSplit, StatusBar
│   │   ├── Sidebar/            CollectionsTree, HistoryList, EnvironmentPicker, SidebarSearch
│   │   ├── Tabs/               TabBar, TabItem
│   │   ├── Request/            RequestEditor, URLBar, MethodPicker, ParamsTab, HeadersTab, AuthTab, BodyTab, SettingsTab, KeyValueEditor
│   │   ├── Response/           ResponsePane, ResponseBodyView, ResponsePreview (SwiftUI WebView), ResponseHeadersView, CookiesView, TimingPopover, FindBar
│   │   ├── Environments/       EnvironmentsWindow, VariablesEditor
│   │   ├── QuickOpen/          QuickOpenPanel
│   │   ├── Settings/           SettingsView, DataLocationPane, SyncStatusBanner
│   │   └── Components/         CodeTextView (NSTextView wrapper), TokenTextField (URL field w/ {{var}} highlighting), Badge, EmptyState
│   ├── Highlighting/           Theme (kind → NSColor). The tokenizers live in Core/Text — see docs/decisions.md D19
│   ├── Resources/              Assets.xcassets, Postfrau.icon (Icon Composer bundle), SampleCollection.json, Postfrau.entitlements, Info.plist
│   └── Support/                Pasteboard, FileDialogs, KeychainBridge
├── PostfrauUITests/            ← minimal XCUITest smoke (Phase 12)
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

Four types are renamed from the sketch below so they do not shadow `Swift.Collection`,
`SwiftUI.Environment`, `View.Body`, or anything as generic as `Item`: they are
`RequestCollection`, `RequestEnvironment`, `RequestBody` and `CollectionItem`
(see `docs/decisions.md` D5).

```swift
struct Workspace { var collections: [RequestCollection]; var environments: [RequestEnvironment]; var globals: Globals; var activeEnvironmentID: UUID? }

struct RequestCollection { id, name, description: String?, auth: Auth /* .none | .inherit not allowed at root */, variables: [Variable], items: [CollectionItem], createdAt, updatedAt, revision: Int }
enum CollectionItem { case folder(Folder), request(RequestItem) }  // ordered; encode with a "type" discriminator
struct Folder { id, name, description, auth: Auth /* default .inherit */, variables: [Variable], items: [CollectionItem] }

struct RequestItem { id, name, method: HTTPMethod, url: String /* raw, may contain {{vars}} */,
                     params: [KeyValue], headers: [KeyValue], auth: Auth, body: RequestBody,
                     settings: RequestSettings, description, extras: [String: JSONValue] }
struct KeyValue { id, key: String, value: String, enabled: Bool, description: String? }
enum HTTPMethod: String, CaseIterable { GET, POST, PUT, PATCH, DELETE, HEAD, OPTIONS; plus .custom(String) via rawValue fallback }

enum Auth { case inherit, none, basic(username, password), bearer(token), apiKey(key, value, in: .header|.query) }
enum RequestBody { case none, raw(text: String, language: RawLanguage /* json, text, xml, html, javascript */),
                   formData([FormField]), urlEncoded([KeyValue]), binary(FileReference) }
struct FormField { id, key, enabled, value: FormValue /* .text(String) | .file(bookmark: Data, displayName: String) */ }
struct RequestSettings { followRedirects = true, maxRedirects = 10, timeoutSeconds = 30, verifyTLS = true, sendCookies = true, encodeURL = true }

struct RequestEnvironment { id, name, variables: [Variable], updatedAt, revision: Int }
struct Globals { variables: [Variable], updatedAt, revision: Int }
struct Variable { id, key, value: String /* empty on disk if secret */, enabled, isSecret: Bool }

struct HistoryEntry { id, sentAt: Date, method, resolvedURL, statusCode: Int?, durationMs, responseBytes, requestSnapshot: RequestItem, error: String?,
                      source: HistorySource /* .app | .cli | .agent(name) */, recordLevel: HistoryRecordLevel /* off|metadata|headers|full */,
                      requestHeaders: [(String,String)]?, requestBody: RecordedBody?, responseHeaders: [(String,String)]?, responseBody: RecordedBody? }
struct RecordedBody { data: Data /* capped */, truncated: Bool, originalBytes: Int, mimeType: String? }
// Redaction before writing: values of secret variables, Authorization / Proxy-Authorization / Cookie / Set-Cookie header values, api-key auth values → "•••".

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

Two roots. **Synced data** lives in the *data folder*, which the user can relocate. **Local state** never leaves the machine.

```
DATA FOLDER  (default: ~/Library/Application Support/Postfrau/Data — relocatable, see Phase 9)
├── postfrau-workspace.json     marker: { schemaVersion, workspaceID, createdAt, createdBy: hostname, appVersion }
├── collections/<collectionUUID>.json      one file per collection (whole tree inside), carries `revision` + `updatedAt`
├── environments/<environmentUUID>.json    values of secret variables are "" on disk
└── globals.json

LOCAL  (~/Library/Containers/com.postfrau.Postfrau/Data/Library/Application Support/Postfrau/)
├── settings.json               includes data-folder security-scoped bookmark + plain `dataFolderPath` (read by the CLI), `historyRecording` level, `historyBodyCapBytes` (default 262144)
├── ui-state.json               open tabs (ids + unsaved drafts), selection, sidebar width, window frame, active env
├── history/<yyyy-MM-dd>/<HHmmss.SSS>-<uuid>.json   one file per entry (multi-writer safe: app and CLI append concurrently); pruned to `maxHistoryEntries` (default 1000) on launch and every 100 writes; day folders keep listing cheap
└── conflicts/                  copies produced by ConflictResolver, surfaced in the UI until dismissed
```
Rules: all writes atomic (write temp in same dir, `rename`) and, inside the data folder, wrapped in
`NSFileCoordinator` so iCloud Drive / Dropbox see complete files. Debounced autosave (300 ms) after any
model mutation; explicit flush on quit and on window close. Reads tolerate unknown keys. A
`schemaVersion` bump requires a migration function in `Migrations.swift` and a fixture test.
Every synced document carries `revision: Int` (incremented on each write) and `updatedAt`; the store
remembers the `(revision, mtime, sha256)` it last wrote per file to tell its own writes from foreign ones.
Keychain: service `com.postfrau.secrets`, account `"\(environmentID).\(variableKey)"`, `kSecAttrAccessibleAfterFirstUnlock`;
`kSecAttrSynchronizable` follows the "Sync secrets via iCloud Keychain" setting.
Deleting a variable or environment deletes its Keychain items.

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
│   GET /users  │ 200 OK   142 ms   2.3 KB                Pretty Raw Preview Headers(12) Cookies │  response header
│   …           │ {                                                                        │
│               │   "users": [ … ]              ← syntax highlighted, monospace, find bar   │  response body
├───────────────┴─────────────────────────────────────────────────────────────────────────┤
│ 3 collections · 42 requests · history 118                     Saved ✓  |  Staging       │  status bar
└─────────────────────────────────────────────────────────────────────────────────────────┘
```

- **Liquid Glass rules:** use the system toolbar (glass for free, `ToolbarSpacer` to group items), the standard
  `NavigationSplitView` sidebar (glass for free), `.glassEffect()` only on floating chrome (Quick Open panel,
  the in-flight progress capsule, environment quick-look popover), `.buttonStyle(.glassProminent)` on Send.
  Content surfaces (editors, key-value tables, response body) are opaque `.background(.background)`;
  scrolling content under the toolbar uses `.scrollEdgeEffectStyle(.soft, for: .top)`. Never put glass
  behind monospace text. Respect Reduce Transparency automatically (the system does; don't fight it).
- `NavigationSplitView` with sidebar (min 220, default 260) and detail. Detail is a vertical
  `HSplitView`/`VSplitView` (user can toggle horizontal vs vertical response layout in Settings).
- Sidebar has two sections in one `List`: Collections (outline, expandable) and History (grouped by day; entries from the CLI or an agent carry a small source badge and can be filtered).
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
- Response body: `CodeTextView` (NSTextView, TextKit 2, non-editable, line numbers optional). `TextEditor`
  gained rich text in macOS 26 but is still not a code editor; do not use it. Pretty
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

### Phase 0 — Bootstrap  ☑
- [x] `git init`, `.gitignore`, `LICENSE` (MIT), `README.md` (one paragraph + build instructions).
- [x] `Packages/PostfrauCore/Package.swift` with library + test target, Swift Testing. One trivial test.
- [x] `project.yml`: app target `Postfrau` (deployment target macOS 26.0, SwiftUI lifecycle, `SWIFT_VERSION=6`,
      `SWIFT_STRICT_CONCURRENCY=complete`, `SWIFT_DEFAULT_ACTOR_ISOLATION=MainActor`, `SWIFT_APPROACHABLE_CONCURRENCY=YES`,
      `SWIFT_UPCOMING_FEATURE_NONISOLATED_NONSENDING_BY_DEFAULT=YES`), depends on local package `PostfrauCore`, entitlements (sandbox + network client +
      user-selected files r/w), Info.plist with `LSMinimumSystemVersion`, `CFBundleDisplayName`, document
      types for `.json` import via drag (Phase 10), unit-test target `PostfrauTests`, UI-test target stub.
- [x] `Makefile`, `Scripts/bootstrap.sh`, `Scripts/screenshot.sh`
      (`open` the app, `sleep 2`, `screencapture -l $(osascript … window id)` or simply `screencapture -x /tmp/postfrau.png` of the full screen; good enough for the agent to eyeball).
- [x] `PostfrauApp.swift` opens a window with placeholder three-pane layout and "Postfrau" text; confirm the
      toolbar and sidebar render as Liquid Glass with no custom styling.
- [x] Placeholder `Postfrau.icon` created with Icon Composer (`/Applications/Xcode.app/Contents/Applications/Icon Composer.app`)
      or a minimal hand-written `.icon` bundle; verify it shows in the Dock in light, dark, and clear modes.
- [x] `CLAUDE.md`: 15 lines max — build/test commands, "Core has no UI imports", "strict concurrency",
      "no third-party deps", "update PLAN.md checkboxes", "commit per phase".
- Acceptance: `make gen && make test && make run` all succeed from a clean clone; window appears.

### Phase 1 — Core models, persistence, resolver  ☑
- [x] All model types from §3 with explicit `CodingKeys` and `schemaVersion`.
- [x] `Item` enum encoding with `"type": "folder" | "request"` discriminator; tests for round-trip.
- [x] `WorkspaceStore` actor: `load()` → `Workspace`, `save(collection:)`, `delete(collectionID:)`,
      same for environments, `saveGlobals`, `saveUIState`, `saveSettings`. Takes a `DataFolder` (synced root)
      and a local-state root, both injectable for tests (temp dirs). Atomic + coordinated writes. Records
      `(revision, mtime, sha256)` per written file. Debounced batching lives in the app layer, not here.
- [x] `Keychain` wrapper (Security framework): get/set/delete generic password; tests run against a
      test service name and clean up after themselves (skip gracefully if Keychain is unavailable in CI).
- [x] `HistoryLog`: append(entry), load(limit:), clear(), prune(to:). JSONL, tolerant of a corrupt last line.
      *(R3: superseded by `HistoryStore` in Phase 8 — JSONL is not safe for two writers once bodies are recorded.)*
- [x] `VariableResolver` per §3 with `ResolveResult { text, unresolved: [String], cycles: [String] }`.
      Dynamic variables. Tests: precedence, nesting, cycles, unresolved, `{{ spaced }}` trimmed keys,
      escaped `\{{` left alone.
- [x] `AuthResolver`: computes effective auth for a request given its folder chain.
- [x] `docs/data-format.md`.
- Acceptance: ≥ 40 unit tests, `make core-test` < 10 s.

### Phase 2 — HTTP executor  ☑
- [x] `RequestBuilder`: `RequestItem` + resolved scope → `URLRequest` (+ `Body payload` as `Data` or
      streamed file). Handles: query merge & encoding (respect `encodeURL`), multipart/form-data with
      generated boundary and file parts, urlencoded, raw with correct `Content-Type` default per language
      (only if user didn't set one), auth application, `User-Agent: Postfrau/<version>` default, `Accept: */*` default,
      `Content-Length`. Tests for each body mode (inspect built request bytes).
- [x] `HTTPExecutor` actor: `send(_:settings:) async throws -> HTTPResponse`, cancellable via Task
      cancellation. One `URLSession` per settings profile — `(verifyTLS, sendCookies)`, the settings that
      cannot vary per request — cached in a dictionary, each with its own cookie storage; a per-send task
      delegate implements `urlSession(_:task:didReceive challenge:)` (accept any cert only when
      `verifyTLS == false`), redirect interception (record hops, stop when disabled or `maxRedirects` hit),
      and `didFinishCollecting metrics` → `Timing`. Body collected via `download(for:delegate:)`, which
      streams to disk with flat memory use (`bytes(for:)` measured ~40x slower — see `docs/decisions.md`
      D9); bodies over 20 MB keep their file, smaller ones are read back into memory; hard cap 200 MB
      enforced mid-transfer (fail with a clear error).
- [x] Reason phrase table for common status codes (URLSession doesn't give one).
- [x] Cookie extraction from `Set-Cookie` headers (parse manually; don't rely on the shared cookie storage).
- [x] Tests via a custom `URLProtocol` mock for: headers/body correctness, redirect recording, timeouts,
      cancellation, large body spill, error mapping. Plus one opt-in live test against `https://httpbin.org`
      guarded by env var `POSTFRAU_LIVE_TESTS=1`.
- Acceptance: `swift test` green; executing a GET to `https://example.com` from a throwaway CLI test prints
  200 + timing (verify manually once).

### Phase 3 — App shell & first end-to-end send  ☑
- [x] `AppState` (`@Observable`, main-actor by default): owns `Workspace`, `WorkspaceStore`, `HistoryLog`, tabs,
      selection, settings; every mutation goes through methods that schedule a debounced save. Implement the
      debounce with the macOS 26 `Observations { }` async sequence over the dirty set rather than ad-hoc timers.
- [x] Three-pane layout per §5 with `NavigationSplitView` + split for request/response; divider persisted.
- [x] Sidebar: collections outline (read-only for now, from loaded data), select → opens tab.
- [x] Tab bar with open/close/dirty/reorder; state persisted in `ui-state.json`.
- [x] URL bar (plain `TextField` for now), method picker, Send/Cancel, progress bar.
- [x] `SendController`: takes current tab's draft, resolves variables (active env + chain + globals),
      calls executor, stores `HTTPResponse` on the tab, appends history entry.
- [ ] *(R3)* Put the send pipeline in Core as `Commands/SendRequest` (input: request + scope + settings + record level +
      source; output: `HTTPResponse` + the `HistoryEntry` it produced). `SendController` is a thin main-actor wrapper
      that adds cancellation and tab state. The CLI (Phase 11) calls the same command. If Phase 3 is already past
      this point, do the extraction at the start of Phase 11 instead — don't rework finished UI now.
      **Deferred to Phase 11**: R3 landed after Phase 3's UI was built and working, which is exactly the
      case this item describes. See `docs/decisions.md` D11.
- [x] Response pane: status/time/size line, raw body in a `CodeTextView` (NSTextView wrapper, non-editable,
      monospaced, no highlighting yet), headers list.
- [x] Environment picker in toolbar (switching only; management UI is Phase 7).
- [x] First-run: if no collections exist, load `SampleCollection.json` (3–4 requests to `httpbin.org`).
- Acceptance: launch → select sample "GET /get" → ⌘↩ → 200 with body and headers visible; cancel works
  on a `https://httpbin.org/delay/10`; relaunch restores tabs.
  *(All four are XCUITests in `PostfrauUITests/LaunchTests`, so they are checked on every `make test`
  rather than by eye. The sample request is named "Echo query"; `ScreenshotTests` captures the window
  in light and dark for review.)*

### Phase 4 — Request editor complete  ☑
- [x] `KeyValueEditor` component per §5 (used by Params, Headers, urlencoded body, form-data, variables).
- [x] Params tab ↔ URL two-way sync (§3 rule), with tests in Core for the parse/compose function.
- [x] Headers tab with autocomplete; computed "auto headers" section (greyed, non-editable) showing what
      Postfrau will add (Content-Type, Authorization from auth helper, User-Agent, Content-Length).
- [x] Auth tab: Inherit (shows the effective inherited auth read-only), None, Basic, Bearer, API Key.
      Secret-ish fields use `SecureField` with reveal toggle.
- [x] Body tab: all modes; raw editor is `CodeTextView` editable with JSON/XML highlighting (Phase 5's
      highlighter—stub it now, real one next phase), language picker, Beautify (JSON), file picker for
      binary and form-data files with security-scoped bookmarks.
      *(Beautify needed a real pretty printer, so `JSONPrettyPrinter` was written here rather than in
      Phase 5 — same component, earlier. See `docs/decisions.md` D16.)*
- [x] Settings tab: follow redirects, max redirects, timeout, verify TLS, send cookies, encode URL.
- [x] `TokenTextField` URL bar with `{{var}}` coloring and hover-to-resolve; ⌘L focuses it.
- [x] Dirty tracking: draft vs saved copy diff; ⌘S saves; closing a dirty tab prompts Save / Don't Save / Cancel.
- [x] Rename request inline from tab (double-click) and from sidebar.
- Acceptance: build a POST with JSON body + bearer token + 2 params against httpbin `/anything`, response
  echoes everything correctly; form-data with a file upload echoes file name; changing params rewrites URL and vice-versa.
  *(All three are XCUITests in `PostfrauUITests/RequestEditorTests`, driven through the real UI — the file
  upload really does go through `NSOpenPanel` and a security-scoped bookmark.)*

### Phase 5 — Response viewer  ☑
- [x] `SyntaxHighlighter` protocol + `JSONHighlighter` (hand-written tokenizer, O(n), no regex over the
      whole document) + `XMLHighlighter` (tags/attrs/text); `Theme` with light/dark palettes reading system accent.
      Highlighting runs on a background task for bodies > 256 KB and is applied when ready; never blocks the main thread.
- [x] Pretty / Raw / Headers / Cookies segmented tabs. Pretty = `JSONPrettyPrinter` (preserves key order and
      big-number precision: pretty-print via tokenizer, NOT via `JSONSerialization`) / `XMLPrettyPrinter`;
      falls back to Raw with a hint if the body isn't JSON/XML. Content type sniffed from header, then from bytes.
- [x] Preview tab: SwiftUI `WebView` (WebKit, macOS 26) rendering HTML bodies from a `WebPage` loaded with the
      response bytes + base URL; JavaScript and network loads disabled by default (toggle in Settings), so a
      preview can't phone home. Images (`image/*`) render via `Image(nsImage:)`; PDFs via `PDFKit`.
      *(`allowPreviewJavaScript` exists in settings and is honoured; its Settings-window toggle lands with
      the rest of that window in Phase 12.)*
- [x] Large-body policy from §5; binary → hex preview + Save.
- [x] Find bar with next/prev/count, wrap toggle, line numbers toggle, copy body, save body (`NSSavePanel`).
      *(The find bar is `NSTextView`'s own — same behaviour as every Mac app, see `docs/decisions.md` D21.)*
- [x] Timing popover; redirect chain list (each hop: status, URL) when redirects occurred.
- [x] Error card for transport failures with Retry.
- [x] Headers tab: table with copy-on-click; Cookies tab: name/value/domain/path/expires/flags.
- Acceptance: 20 MB JSON response (httpbin `/bytes` won't do; use `https://httpbin.org/stream/…` or a local
  python `http.server` serving a generated file — python3 is allowed for *testing* only) stays responsive: scroll,
  find, switch tabs without beachball; pretty-print of a 2 MB JSON completes < 1 s.
  *(Both verified: `PostfrauCoreTests` pretty-prints 2.2 MB in ~0.6 s, and
  `ResponseViewerTests.testALargeResponseStaysResponsive` drives a 22 MB response from a local
  `python3 -m http.server` — it skips when that server is not running. Finding and fixing a 30 s
  main-thread stall on that path is `docs/decisions.md` D20.)*

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
- [ ] `HistoryStore` (replaces `HistoryLog`): one JSON file per entry under `history/<day>/`, append = write one
      file, load = list newest-first with a limit, prune, delete, clear. Safe for the app and the CLI writing at the
      same time (no shared file is ever rewritten). One-time migration of an existing `history.jsonl`.
- [ ] Recording levels (`HistoryRecordLevel`): **off** (nothing written), **metadata** (default: method, URL, status,
      timing, size, request snapshot without body), **headers** (+ request/response headers), **full** (+ bodies capped
      at `historyBodyCapBytes`, `truncated` flag). Redaction per §3 applied before write, always. Level lives in
      Settings ▸ History; per-collection override (`historyRecording` on the collection, nil = inherit) for APIs you never want logged.
- [ ] Attribution: `source` on every entry — `.app`, `.cli`, `.agent(name)` (CLI reads `POSTFRAU_AGENT` / `--as`).
- [ ] Sidebar History section grouped by day: method, status color, URL path, relative time, source badge for
      non-app entries; filter by text and by source; "Agents only" toggle.
- [ ] Click opens a tab with the snapshot (unsaved, titled "History · GET /users"); when headers/bodies were recorded
      the response pane shows them read-only with a "recorded" banner. "Save to collection…" action.
- [ ] Clear all; delete single entry; cap configurable in Settings (default 1000).
- [ ] History records failed sends too (with the error).
- Acceptance: 1 000 entries load in < 200 ms at launch; filter is instant; switching to **full** records a body and
  the file on disk has the bearer token replaced by •••; two processes appending simultaneously lose nothing
  (test with a second `Process`).

### Phase 9 — Sync via data folder  ☐
Goal: pointing the data folder at `iCloud Drive/Postfrau` (or Google Drive, Dropbox, a git checkout) makes two Macs share collections and environments, without Postfrau ever running a server.
- [ ] `DataFolder`: resolves the current root from `settings.json` (security-scoped bookmark → `startAccessingSecurityScopedResource`),
      falls back to the default folder if the bookmark is stale, and exposes `status` (ok / missing / unreadable / stale bookmark).
- [ ] Settings ▸ Data pane: current path + provider badge (detect iCloud Drive `Mobile Documents/com~apple~CloudDocs`,
      Google Drive `CloudStorage/GoogleDrive-*`, Dropbox `CloudStorage/Dropbox`, plain folder), buttons:
      **Use iCloud Drive…** (opens `NSOpenPanel` at the iCloud Drive root with "Postfrau" pre-suggested, `canCreateDirectories`),
      **Choose Folder…**, **Reveal in Finder**, **Use Default Location**. Toggle: **Sync secrets via iCloud Keychain**.
- [ ] Relocation flow (sheet): if the chosen folder is empty → *Move data here*; if it already contains
      `postfrau-workspace.json` → *Use the data in this folder* (current local data is left in place and a
      backup zip of it is written next to it) or *Merge* (import collections/environments with ids not present;
      same-id conflicts keep the newer `revision` and write a conflict copy). Never delete the old folder.
- [ ] `FolderWatcher`: `NSFilePresenter` on the data folder (gets iCloud/coordinated change notices) plus a
      `DispatchSource` on the directory for plain folders; coalesces events for 500 ms, then diffs the folder:
      new / changed / removed files by `(mtime, sha256)` vs the store's last-written record.
- [ ] `ConflictResolver`: foreign change to a file with no unsaved local edits → reload in place (open tabs update,
      drafts untouched). Foreign change while the same collection has unsaved local edits → keep local, save the
      foreign version to `LOCAL/conflicts/<name>-<host>-<date>.json`, show a non-modal banner
      "Acme API changed on another Mac" with *Keep mine* / *Take theirs* / *Show both* (opens the copy as a read-only collection).
      Removed file → collection becomes "missing" in the sidebar with *Restore from memory* for one session.
- [ ] iCloud specifics: request download of `.icloud` placeholders on launch (`startDownloadingUbiquitousItem`),
      show a per-collection "downloading" spinner; ignore `NSFileVersion` conflict versions Apple creates (we make our own copies);
      never hold a coordinated read open across an await.
- [ ] Secrets: when the iCloud Keychain toggle changes, re-write all secret items with the new `kSecAttrSynchronizable`;
      confirm in a test on this machine that a synchronizable item is readable back (behavior differs for unsigned builds — record findings in `docs/decisions.md`).
- [ ] Status bar shows a sync-folder chip (provider icon, "watching", last external change time); clicking opens the Data pane.
- [ ] Tests (Core): watcher diff logic with a temp folder mutated by a second process (`Process` running `cp`/`rm`),
      conflict copy naming, merge rules, stale bookmark fallback. Manual: two app instances on one Mac
      (`open -n` with `POSTFRAU_LOCAL_ROOT` env override for the second) pointed at the same folder edit the same collection.
- Acceptance: choose an iCloud Drive folder; on a second Mac (or the second instance) the collection appears within
  a few seconds of iCloud finishing upload; editing on both sides produces one conflict banner and no lost data;
  removing the folder while running degrades gracefully to the "missing" status without a crash; secrets are present on
  the second machine when the Keychain toggle is on and absent (masked, empty) when off.

### Phase 10 — Import / Export  ☐
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

### Phase 11 — CLI & agent interface  ☐
Goal: an agent with only Bash and `skills/postfrau/SKILL.md` can inspect and edit collections, run requests, and read history, without the app running, and everything it does shows up in the app with attribution.
- [ ] `Commands` layer in Core (extract from app if Phase 3 didn't already): `SendRequest`, `RunFolder` (sequential, stops-on-error flag),
      `ListItems`, `GetRequest`, `AddRequest`, `UpdateRequest` (partial: url/method/headers/params/body/auth), `MoveItem`, `RemoveItem`,
      `DuplicateItem`, `ListEnvironments`, `SetVariable`, `UnsetVariable`, `UseEnvironment`, `ListHistory`, `ImportCurl`, `ExportCurl`.
      Each is a `Sendable` struct with a typed result; `CommandRunner` owns a `WorkspaceStore`, `HTTPExecutor`, `HistoryStore`, `Keychain`.
      Items are addressed by **path** (`Acme API/Users/list`, case-insensitive, `/` escaped as `\/`) or by UUID.
- [ ] `postfrau` executable target in `Packages/PostfrauCore/Sources/postfrau` (no ArgumentParser dependency; a small
      hand-rolled parser is fine — see §0 "no third-party deps"). Global flags: `--json`, `--data-dir`, `--env`, `--as <agent>`,
      `--record off|metadata|headers|full`, `--reveal` (secrets are `•••` in all output otherwise), `--quiet`. Exit codes:
      0 ok, 1 usage, 2 not found, 3 network/transport error, 4 HTTP status ≥ 400 with `--fail`, 5 data folder unavailable.
- [ ] Data folder discovery order: `--data-dir` → `POSTFRAU_DATA_DIR` → `dataFolderPath` in the app's `settings.json`
      inside the sandbox container → default folder. Local state root: `POSTFRAU_LOCAL_ROOT` → the container path.
- [ ] Commands: `ls [path] [--tree]`, `get <path>`, `add <folder-path> --name … (--from-curl '…' | --file req.json | --stdin | --url … --method …)`,
      `set <path> [--url] [--method] [--header k:v]… [--param k=v]… [--body @file|-] [--auth none|basic:u:p|bearer:t|apikey:k:v[:query]]`,
      `mv <path> <folder-path>`, `rm <path> [--yes]`, `dup <path>`,
      `run <path> [--all] [--var k=v]… [--max-body 64k] [--out file] [--dry-run] [--fail] [--capture name=$.json.path]…`,
      `send <METHOD> <url> [-H k:v]… [-d body|@file] [--save-to <folder-path> --name …]`,
      `env ls | env get <name> | env set <name> k=v [--secret] | env unset <name> k | env use <name>|none`,
      `history [--last N] [--agent x] [--since 2h] [--status 5xx]`, `history show <id>`,
      `import <file>` / `export <collection> [--out file]` (reuse Phase 10), `schema [collection|environment|history]`,
      `validate <file>`, `open <path>` (via `postfrau://` URL scheme registered by the app), `skill install [--to dir]`, `version`.
- [ ] `--dry-run` prints the fully built request (method, final URL, headers, body preview) and writes no history.
      `--capture name=$.path` evaluates a minimal JSONPath subset (`$.a.b[0].c`) on the response and stores it in the active environment (not as a secret unless `--secret`).
- [ ] Human output: aligned tables, colored method/status when stdout is a TTY. `--json` output is stable and documented in `SKILL.md`;
      `run` with `--all` emits NDJSON, one object per request.
- [ ] App side: register `postfrau://` URL scheme; Settings ▸ Advanced "Install command line tool" symlinks
      `Postfrau.app/Contents/MacOS/postfrau` into `/usr/local/bin` (ask for the folder via `NSOpenPanel` if not writable;
      never escalate privileges); `make install` for developers. The CLI is copied into the bundle by a build phase.
- [ ] Keychain from a second binary: document the one-time "Always allow" prompt; fall back to `POSTFRAU_SECRET_<KEY>`
      env vars when the item is unreadable; never print secret values without `--reveal`.
- [ ] `skills/postfrau/SKILL.md`: frontmatter (name, description with trigger words: "postfrau", "run request", "API collection"),
      the command reference, the `--json` shapes, exit codes, and three worked workflows: explore an API and save requests
      into a collection; run a request and inspect the response; log in with `--capture` and call an authenticated endpoint.
      Keep it under 300 lines; link to `postfrau schema` for the file format instead of pasting it.
- [ ] Tests: command layer unit tests with temp data folders; CLI end-to-end tests that spawn the built binary
      (`swift build` product) against a temp folder and a `URLProtocol`-free local listener; `schema` output validates the fixtures.
- Acceptance: with the app closed, `postfrau add … --from-curl`, `postfrau run … --json`, `postfrau history --agent claude` work
  and survive a second concurrent `run`; launch the app and the new request and the history entry are there with the agent badge;
  a fresh Claude Code session in a scratch directory with only the installed skill completes all three `SKILL.md` workflows without help.

### Phase 12 — Polish & release  ☐
- [ ] Full menu bar (File/Edit/View/Request/Window/Help) with every shortcut from §5; Help ▸ Keyboard Shortcuts sheet.
- [ ] Settings window: General (font size, response layout, default timeout, default verify TLS, max history),
      Data (the Phase 9 pane), History (recording level, body cap, "Clear history"), Advanced ("Install command line tool", "Reset sample collection", "Open local state folder").
- [ ] Window/state restoration, multiple windows not required (single window app; ⌘N when window is closed reopens it).
- [ ] Final app icon as an Icon Composer `.icon` bundle (layered glass, light/dark/clear/tinted variants), About window with version + license.
- [ ] Accessibility pass: labels on everything; VoiceOver can operate URL bar, Send, tabs; check Reduce Transparency and Increase Contrast renderings.
- [ ] Performance pass with Instruments (Time Profiler + Allocations + SwiftUI instrument in Xcode 26): launch < 300 ms to interactive with 50 collections; no main-thread hitch > 16 ms on send/response render for typical (< 1 MB) responses; memory < 150 MB with a 50 MB response open.
- [ ] Crash-safety: simulate kill -9 during autosave, verify files intact (atomic writes) — write a test.
- [ ] `PostfrauUITests`: smoke test — launch, ⌘N, type URL to a local mock server (spin up an in-process
      `NWListener` HTTP responder inside the UI-test host or use `URLProtocol` via launch argument), send, assert status label.
- [ ] `Scripts/release.sh`: `xcodebuild archive`, export with Developer ID if `CODESIGN_IDENTITY` env set, else ad-hoc;
      `hdiutil` DMG; optional `notarytool` step guarded by env vars. Version from `MARKETING_VERSION` in project.yml.
- [ ] README: screenshots (from `Scripts/screenshot.sh`), features, build, CLI quick start, skill install, roadmap link to §9.
- Acceptance: DMG builds; fresh user account (or wiped container: `rm -rf ~/Library/Containers/com.postfrau.Postfrau`)
  launches with sample collection on macOS 26; entire §5 shortcut list works.

---

## 7. Engineering rules for the executing agent

1. **Core has zero UI.** `PostfrauCore` imports only Foundation, Security and CryptoKit. If you need AppKit in Core, you're in the wrong layer.
2. **Strict concurrency, no `@unchecked Sendable`** without a comment explaining why. The app target is main-actor
   by default (build setting); mark off-main work `@concurrent` or put it in Core actors. Core is `nonisolated` by default.
3. **No third-party packages.** If a problem genuinely needs one (e.g. a text editor), stop, write the trade-off in `docs/decisions.md`, and prefer writing 300 lines yourself.
4. **Never block the main thread:** network, file IO, pretty-printing, highlighting > 256 KB, import parsing all run off-main.
5. **AppKit where SwiftUI hurts:** editors (`NSTextView`/TextKit 2), the URL token field, large outline performance if `List` proves slow (measure first).
6. **Persist through one door:** every model mutation goes through `AppState` methods that mark dirty and schedule save. No view writes files.
   Anything written to the data folder must be safe for a sync client to copy mid-way: atomic rename, coordinated, one document per file.
7. **Tests first for Core:** every parser/formatter/resolver gets tests before wiring into UI. Fixtures live in `Tests/.../Fixtures`.
8. **Verify visually:** after UI phases run `make run` then `Scripts/screenshot.sh` and look at the PNG (Read tool). Fix what looks wrong before declaring done.
9. **Commit per phase** (or sub-phase if large) with message `Phase N: <summary>`. Keep `git status` clean of generated files.
10. **Deviations from this plan** are allowed when justified; record them in `docs/decisions.md` and update this file so the plan stays truthful.
11. **Warnings are errors** in the app target (`SWIFT_TREAT_WARNINGS_AS_ERRORS=YES`) once Phase 3 compiles clean; keep it that way.
12. **Keep the UI keyboard-first and un-cluttered.** When in doubt, mirror Postman's layout (users know it) but with native macOS controls and spacing.
13. **macOS 26 only, and act like it.** No `if #available` ladders, no AppKit workarounds for things SwiftUI on 26 does natively. Use the glass API through system components first; hand-placed `.glassEffect()` needs a reason.
14. **Every capability goes through `Commands`.** If the app can do it and an agent might want it, it is a Core command first and a view second. The CLI must never grow logic the app doesn't share.

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
| Sync client delivers half-written or duplicated files (Dropbox "conflicted copy", iCloud placeholders, Google Drive renames) | Own-write fingerprinting, coordinated atomic writes, conflict copies instead of merges, ignore files that don't match `<uuid>.json` |
| Keychain items written by the sandboxed app are not readable by the CLI without a prompt | One-time "Always allow"; env-var fallback; never a hard failure — the request is sent with the variable unresolved and a warning |
| An agent runs destructive requests by mistake | `--dry-run` is documented first in `SKILL.md`; `rm` needs `--yes`; history attribution makes every agent action auditable |
| Two processes write history at once | One file per entry, never rewritten; prune only deletes files older than the cap |
| Sandbox loses access to the data folder (bookmark stale after the folder is moved) | `DataFolder.status` + banner with *Choose Folder…*; fall back to default folder read-only until resolved |
| Precision loss pretty-printing JSON numbers | Tokenizer-based pretty printer; never round-trip through `JSONSerialization`/`Double` |
| Liquid Glass over-applied → unreadable dense UI, or stale API names from pre-release docs | Glass on chrome only (§5); verify every SwiftUI 26 API against the local Xcode 26.6 SDK headers / docs before use; `docs/decisions.md` records any API that had to be swapped |
| Default MainActor isolation makes Core types accidentally main-actor when moved into the app | Keep all models in Core; app target only holds views and `AppState` |

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
- **MCP server:** `postfrau mcp` — stdio JSON-RPC over the same `Commands` layer, one tool per command; only if an environment allows MCP. No new logic.
- **App Intents:** expose `SendRequest` and `RunFolder` to Shortcuts/Spotlight; same command layer.
- **Native iCloud container:** if a paid Apple Developer Program membership becomes available, add the iCloud Documents
  entitlement and offer "Postfrau in iCloud" as a one-click data location (`url(forUbiquityContainerIdentifier:)`);
  `DataFolder` already abstracts the root, so this is a new provider, not a redesign. CloudKit is deliberately not planned: JSON files + Keychain cover the need.
- **On-device assistance (optional, macOS 26 Foundation Models):** "describe this request in words", "explain this error", generate a request from a sentence. Strictly local, strictly optional, never required for any core flow.

## 10. Definition of done for v1

- All Phase 0–12 boxes ticked; `make test` green; `Scripts/release.sh` produces a DMG that runs on a clean macOS 26 machine.
- A user coming from Postman can import their collection and environment, switch environment, send
  requests with auth and bodies, read responses comfortably, and never sees a beachball.
