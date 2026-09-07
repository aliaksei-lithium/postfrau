You are implementing Postfrau, a free native macOS 26 HTTP client (a personal Postman replacement) in Swift. The complete specification is in `PLAN.md` at the repository root. Read it fully before doing anything else; it is the contract. This prompt only tells you how to work.

## Mission

Execute `PLAN.md` from Phase 0 through Phase 11, in order, autonomously. Deliver a working app, not a partial one. I will not be watching in real time, so make decisions yourself, keep going, and leave a trail I can audit.

## How to work

1. **Phase loop.** For each phase: read its checklist and acceptance criteria → implement → `make core-test` continuously and `make test` before finishing → run the app and verify every acceptance item yourself (build it, launch it, exercise it, take a screenshot with `Scripts/screenshot.sh` and look at it) → tick the checkboxes in `PLAN.md` → commit as `Phase N: <summary>`. Never start phase N+1 on a red build or with unticked boxes you silently skipped.
2. **Commit often.** At least one commit per phase; more for large phases. Conventional messages. Keep generated files out of git.
3. **Verify, don't assume.** Every SwiftUI or Foundation API you use on macOS 26 must exist in the local Xcode 26.6 SDK. When unsure, check the headers under `xcrun --show-sdk-path` or write a two-line compile probe. If an API from your memory doesn't exist, find the shipping equivalent and note it in `docs/decisions.md`.
4. **Deviation protocol.** You may deviate from `PLAN.md` when the plan is wrong, an API is missing, or a simpler approach is clearly better. Every deviation gets an entry in `docs/decisions.md` (what, why, what changed) and a matching edit to `PLAN.md` so the plan stays true. Do not deviate on the fixed decisions in PLAN.md §0 (Swift-only, macOS 26 only, no third-party packages, no Node, sandboxed, JSON-file persistence, folder-based sync).
5. **Do not ask me questions** unless you are genuinely blocked on something only I can provide: an Apple Developer identity, a real Postman export for testing, or a choice that would throw away work already done. Everything else: pick the option a careful senior macOS engineer would pick, write it down, move on. If you must stop, write `STATUS.md` with exactly what is blocked and what you did instead, then continue with any work that doesn't depend on it.
6. **Quality bar.** Strict concurrency with no warnings, tests for every parser/resolver/formatter in Core before UI wiring, no main-thread blocking, keyboard-first UI, both light and dark mode checked, Reduce Transparency checked once. UI should feel like a 2025 Mac app: system toolbar and sidebar, Liquid Glass on chrome only, flat surfaces for content.
7. **Performance is a feature.** Measure the things the plan sets numbers on (launch time, 5 000-request collection, 20 MB response) before ticking those boxes. Use the debug "Generate stress collection" menu item for scale tests.
8. **Testing tools.** `python3` is allowed for local test servers and fixture generation only, never in the app or the build. `httpbin.org` may be used for manual checks; automated tests use `URLProtocol` mocks or an in-process listener.
9. **Keep me informed asynchronously.** Maintain `STATUS.md` at the repo root: current phase, what works, what's next, known issues, decisions taken. Update it at every commit. That file plus `git log` is how I'll catch up.

## Environment facts

- macOS 26.6, Xcode 26.6, Swift 6.3, `xcodegen` at `/opt/homebrew/bin/xcodegen`. No swiftlint/swiftformat installed; don't add them.
- The repo has `PLAN.md`, `KICKOFF.md` (this file), and git history. Nothing else exists yet; Phase 0 creates the scaffolding.
- No Apple Developer identity is configured. Build and run ad-hoc signed. `Scripts/release.sh` must work without one and use `CODESIGN_IDENTITY` only if set.
- Sandboxed app: data lives under `~/Library/Containers/com.postfrau.Postfrau/`. To reset state for a fresh-launch test, delete that container.

## Definition of done

`PLAN.md` §10 is satisfied, every phase checkbox is ticked, `make test` is green, `Scripts/release.sh` produces a DMG, `STATUS.md` says "v1 complete" with a short list of known limitations, and `README.md` has real screenshots. Finish with a summary of what was built, what deviated from the plan and why, and what you'd tackle first in v1.1.

Start now with Phase 0.
