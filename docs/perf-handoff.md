# Handoff: sidebar and tab clicks must feel instant

## What you are being asked to do

**Analyse and report. Do not change code, do not commit, do not release.**

Produce a written diagnosis: the root cause of the perceived lag, the evidence for it, and
specific instructions someone else can follow to fix it. If you cannot get to a root cause, say
what you ruled out and what you would need.

**Goal:** clicking a request in the sidebar, and clicking a tab, should feel instant — one frame,
~16 ms from click to painted result.

## The central problem, stated honestly

The user reports a **HUGE lag** on both interactions, in the current build.

Every measurement I took says the main thread is busy for **28 ms** on a sidebar selection and
**47 ms** on a tab switch. Those numbers do not describe a huge lag.

**Explaining that gap is the job.** One of these is true and you need to find out which:

1. **My metric is the wrong one.** I measured *main-thread CPU busy time* by sampling. That is not
   the same as *click-to-paint latency*. A click can take 500 ms of wall clock while the main
   thread is only busy 30 ms of it — if there is an await, a debounce, a disk read, an animation,
   or a dropped frame in between. **I never measured latency. Start here.**
2. **My harness does not reproduce real clicking.** I drove everything with synthetic
   `CGEvent` HID clicks. Real clicking involves hover tracking, focus changes, momentum, and
   double-click timing that my driver may not exercise.
3. **My test state was not the user's state.** See the untested hypotheses below — particularly
   that **every tab I measured had no response loaded**.

## How to measure latency (the thing I did not do)

Sampling tells you where CPU went, not how long the user waited. Suggested approaches:

- `os_signpost` intervals from the click handler to the next display flush, read with
  `xctrace`/Instruments if it can be driven here (note: Instruments has historically not been
  drivable in this environment — see `docs/decisions.md` D40).
- Cheaper and quite effective: screen-record at 60 fps with `screencapture -V` or a
  `CGDisplayStream`, click, and count frames between the mouse-down and the first painted change.
  That gives a real latency number in frames.
- Or instrument the app: record `CACurrentMediaTime()` in the tap handler and again in a
  `CADisplayLink`/display-cycle callback after the change is committed, and log the delta.

## What has already been fixed — do not redo these

| Change | Effect |
|---|---|
| Sidebar rows swallowed the single click entirely (`onTapGesture` and `simultaneousGesture` both consume it on a `List` row) | Clicks did nothing at all. Rows now set `sidebarSelection` themselves via the two-tap form |
| Tab strip ran `withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(id, anchor: .center) }` on every selection change | Tab switch 123 ms → 47 ms of main-thread busy |
| `MainWindow.body` read `state.selectedTab`, so every switch rebuilt the toolbar, sheets and split | Part of the above; detail column now lives in `DetailPane` |
| Method badge unreadable on a selected row | Cosmetic only |

Details and reasoning: `docs/decisions.md` **D46, D50, D51**.

## Where the remaining main-thread time goes

Measured by stubbing one component at a time and re-measuring (Release build, real HID clicks).

**Tab switch — 47 ms total:**

- ~32 ms building the newly selected tab's editor sections (`KeyValueEditor` — a `ScrollView` +
  `LazyVStack` of rows, each row three `SuggestingTextField`s and a checkbox)
- ~15 ms the segmented `Picker` in `RequestEditor`
- ~8 ms the response pane
- ~5 ms the URL bar (`TokenTextField`, an `NSTextView`)

**Sidebar selection — 28 ms total:**

- `SidebarView.body` re-evaluates on every selection, because `List(selection: $state.sidebarSelection)`
  makes that body depend on the selection. It then rebuilds all ~40 rows.
- Confirmed in the profile: `SidebarView.body.getter` is the top of our own frames.

Neither breakdown adds up to a "huge" lag, which is why I think the metric is wrong.

## Untested hypotheses, ranked

1. **Responses.** Every tab I measured showed *"No response yet"*. The user's tabs will hold real
   responses. Switching to a tab with a large pretty-printed, syntax-highlighted JSON body may
   cost far more than 47 ms. **This is the first thing I would test** — send a request in two tabs,
   then measure switching between them, and compare against the empty-response number.
2. **Latency without CPU.** `state.draftChanged(tab)` and friends feed a debounced autosave
   (there is a 200 ms debounce in the codebase). Check whether anything on the click path awaits
   an actor, touches the disk, or defers work in a way that delays the first painted frame.
3. **Collection size.** The user's imported collection is 33 requests / 9 folders / **121 KB** —
   the OpenAPI descriptions are long (one request has an 878-character description). Row rendering
   reads those. A larger import may scale badly.
4. **Number of open tabs.** I measured with ~6 tabs. `TabBar` rebuilds `TabItem`s on every switch.
5. **The user's machine and mine may differ** — confirm which machine the report is from. There is
   a personal Mac and a work Mac in play.

## The measurement harness

`Tools/measure-clicks.sh <x1> <y1> <x2> <y2> [clicks] [seconds]` — posts real HID mouse events and
reports the share of main-thread samples that were not idle. **It reports CPU busy, not latency.**

### Three traps that produced confidently wrong answers

These cost me hours; do not repeat them.

1. **Do not drive with menu key equivalents.** AppKit throttles repeated menu-item invocations by
   *sleeping* (`NSMENU_IS_THROTTLING_REPEATED_MENU_ITEM_INVOCATIONS`). Driving tab switches with
   ⌘⇧] put 20% of the main thread in that sleep and it looked like the app was blocked.
2. **Do not drive with the accessibility press action.** `NSSegmentedCell` then spins a nested
   event loop waiting for a mouse-up that never arrives, which dominates the profile.
3. **Always verify the clicks actually landed.** I twice measured a UI that was ignoring my
   clicks, and reported the resulting low numbers as "fast". Screenshot the app after a run and
   confirm the state changed. Better: log the state change (I logged every write to the selection
   binding — eight clicks produced zero writes, which is how the dead-click bug was finally found).

Always take the controls: idle with no input, mouse movement without clicking, and clicking inert
space. On this machine those are 0.1%, 0.5% and 1.7% busy respectively.

Note: **this sandbox cannot open listening sockets** and `sample` must be pointed at a PID; the app
must be launched via LaunchServices (`open -a`), not as a child of the shell, or it inherits the
sandbox.

## Entry points

- `Postfrau/Views/Shell/SidebarView.swift` — the `List` and its selection binding
- `Postfrau/Views/Sidebar/CollectionsTree.swift` — `CollectionRow`, `FolderRow`, `RequestRow`
- `Postfrau/Views/Tabs/TabBar.swift` — the strip and `TabItem`
- `Postfrau/Views/Shell/MainWindow.swift` — `DetailPane`, the split
- `Postfrau/Views/Request/RequestEditor.swift` — sections, kept alive per tab (D46)
- `Postfrau/Views/Request/KeyValueEditor.swift` — the params/headers table
- `Postfrau/Views/Response/ResponsePane.swift` — the response side

Build and test: `make build`, `make test`. Release builds matter for timing — Debug SwiftUI is far
slower and will mislead you.

## What "done" looks like

A written answer to: **why does a click that costs 28–47 ms of main-thread time feel like a huge
lag?** With evidence, and with specific instructions for the fix — not the fix itself.
