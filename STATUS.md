# Postfrau — status

**Current phase:** 1 (Core models, persistence, resolver) — starting
**Last completed:** Phase 0 — Bootstrap
**Build:** green (`make test` passes: Core + app unit tests + UI smoke test)

## What works

- `make gen` / `make build` / `make test` / `make core-test` / `make run` / `make screenshot` / `make release`.
- `Packages/PostfrauCore` builds under Swift 6 language mode with strict concurrency; one placeholder test.
- The app launches: `NavigationSplitView` sidebar + vertical split detail, system toolbar. Liquid Glass
  comes from the system components with no custom styling, as intended.
- `Postfrau.icon` (hand-written Icon Composer bundle) compiles to a proper Tahoe layered app icon.
- Ad-hoc signing throughout; no Apple Developer identity needed.

## Next

Phase 1: the domain model from `PLAN.md` §3, `WorkspaceStore`, `Keychain`, `HistoryLog`,
`VariableResolver`, `AuthResolver`, and `docs/data-format.md`. Target ≥ 40 unit tests.

## Known issues / limitations

- App icon is a placeholder mark (envelope on a gradient); the real one lands in Phase 11.
- Hardened runtime is off in the generated project and only enabled by `Scripts/release.sh` — see
  `docs/decisions.md` D3.

## Decisions taken

See `docs/decisions.md`. So far: D1 hand-written `.icon` bundle, D2 `SWIFT_VERSION` spelling,
D3 hardened runtime placement, D4 UI-test actor isolation.
