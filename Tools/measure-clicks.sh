#!/bin/bash
# Measures how much main-thread time a repeated click costs, by sampling the running app.
#
#   Tools/measure-clicks.sh <x1> <y1> <x2> <y2> [clicks] [seconds]
#
# Screen coordinates, origin top-left; the two points are clicked alternately. Prints the share of
# main-thread samples that were *not* idle. Postfrau must already be running and frontmost.
#
# Why this rather than Instruments: Instruments needs a UI this environment cannot drive (see
# `docs/decisions.md` D40), while `sample` works headlessly and is enough to separate "blocked",
# "idle" and "burning the main thread".
#
# Two traps, both of which produced confidently wrong answers before they were noticed:
#
#   * Do not drive this with menu key equivalents. AppKit throttles repeated menu-item invocations
#     (`NSMENU_IS_THROTTLING_REPEATED_MENU_ITEM_INVOCATIONS`) by sleeping, and the sleep swamps the
#     profile.
#   * Do not drive it with the accessibility API's press action. `NSSegmentedCell` then spins a
#     nested event loop waiting for a mouse-up that never arrives.
#
# So this posts real HID mouse events. Always take the two controls too — a run with no clicks at
# all, and a run clicking somewhere inert — or you cannot tell the cost of the thing you are
# measuring from the cost of measuring it.
set -euo pipefail

X1=${1:?first x}; Y1=${2:?first y}; X2=${3:?second x}; Y2=${4:?second y}
CLICKS=${5:-26}; SECONDS_TO_SAMPLE=${6:-8}

PID=$(pgrep -x Postfrau | head -1)
[ -n "$PID" ] || { echo "Postfrau is not running." >&2; exit 1; }

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

cat > "$WORK/clicker.swift" <<'SWIFT'
import CoreGraphics
import Foundation
let a = CommandLine.arguments
let points = [CGPoint(x: Double(a[1])!, y: Double(a[2])!),
              CGPoint(x: Double(a[3])!, y: Double(a[4])!)]
for round in 0..<Int(a[5])! {
    let p = points[round % 2]
    for type in [CGEventType.mouseMoved, .leftMouseDown, .leftMouseUp] {
        CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: p, mouseButton: .left)?
            .post(tap: .cghidEventTap)
        usleep(type == .mouseMoved ? 12000 : 24000)
    }
    usleep(180000)
}
SWIFT
xcrun swiftc -O "$WORK/clicker.swift" -o "$WORK/clicker"

sample "$PID" "$SECONDS_TO_SAMPLE" 1 -file "$WORK/sample.txt" >/dev/null 2>&1 &
SAMPLER=$!
sleep 0.4
"$WORK/clicker" "$X1" "$Y1" "$X2" "$Y2" "$CLICKS"
wait $SAMPLER

python3 - "$WORK/sample.txt" "$CLICKS" <<'PY'
import re, sys
lines = open(sys.argv[1], errors="replace").read().split("\n")
graph = next(i for i, l in enumerate(lines) if l.startswith("Call graph"))
head = next(i for i in range(graph, len(lines)) if re.match(r'^\s+\d+ Thread_', lines[i]))
end = next(j for j in range(head + 1, len(lines))
           if re.match(r'^\s*\d+ Thread_', lines[j]) or lines[j].startswith("Binary Images"))

frames = []
for line in lines[head + 1:end]:
    m = re.search(r'(\d+) (\S.*)$', line)
    if m:
        frames.append((m.start(1), int(m.group(1)), m.group(2).strip()))

# A frame is a leaf when the next line is not deeper, and leaves are where the time actually went.
leaves = {}
for i, (depth, n, name) in enumerate(frames):
    if i + 1 >= len(frames) or frames[i + 1][0] <= depth:
        leaves[name] = leaves.get(name, 0) + n

idle_markers = ("mach_msg2_trap", "semwait", "kevent", "__psynch")
total = sum(leaves.values())
idle = sum(n for name, n in leaves.items() if any(m in name for m in idle_markers))
busy = total - idle
clicks = int(sys.argv[2])
print(f"main thread: {total} samples, {busy} busy ({100 * busy / total:.1f}%)")
print(f"≈ {busy / clicks:.0f} ms of main-thread work per click")
PY
