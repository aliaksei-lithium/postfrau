# Postfrau — agent conventions

- Build: `make gen` (regenerate project), `make build`, `make run`. Test: `make core-test` (fast loop),
  `make test` before every commit. `Scripts/screenshot.sh` captures the main window for visual checks.
- `PLAN.md` is the contract. Tick its checkboxes as phases complete; keep `STATUS.md` current.
- `PostfrauCore` (Packages/) imports **only** Foundation and Security. No AppKit/SwiftUI in Core.
- Swift 6 strict concurrency everywhere; the app target defaults to `MainActor` isolation and treats
  warnings as errors. No `@unchecked Sendable` without a comment saying why.
- **No third-party packages.** No Node. `python3` is allowed for local test servers and fixtures only.
- macOS 26 only: no `if #available` ladders, no back-compat shims.
- Never block the main thread: network, file IO, pretty-printing, highlighting, import parsing go off-main.
- Every model mutation goes through `AppState`; views never touch the filesystem.
- Core parsers/resolvers/formatters get tests before they are wired into the UI.
- Deviations from `PLAN.md` are recorded in `docs/decisions.md` **and** reflected back into `PLAN.md`.
- Commit per phase: `Phase N: <summary>`. Generated files (`*.xcodeproj`, `.build`) stay out of git.
