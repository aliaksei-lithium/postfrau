#!/bin/bash
# Measures click-to-paint latency for the sidebar and the tab strip.
#
#   Tools/measure-latency.sh <tabs|sidebar> [clicks] ["target A" "target B"]
#
# With no targets it picks the two nearest the middle. Name them explicitly when comparing two
# builds: the cost of a switch depends on the request in the tab, and the strip's scroll position
# differs from launch to launch, so an automatic pick is not the same pair twice.
#
# Postfrau must already be running, built from this checkout, with POSTFRAU_CLICK_PROBE set:
#
#   POSTFRAU_CLICK_PROBE=1 open -n <path to Postfrau.app>
#
# Prints, per click, the two halves that have different causes and different fixes:
#
#   held   the hardware event to our handler — a wait, not work. A gesture that has to rule out
#          a second click sits here for the whole double-click interval (~400 ms).
#   paint  the handler to the run loop going idle — SwiftUI rebuilding bodies and Core Animation
#          committing. This one is work, and a profiler can attribute it.
#
# Use this rather than `measure-clicks.sh` for anything about *responsiveness*: that script (and
# `sample`, and Time Profiler) measure CPU busy time, and a click that is merely being waited on
# is 0% busy. Conflating the two produced two confidently wrong diagnoses before this existed.
#
# The window is moved to a fixed frame first, and every target is re-found by its accessibility
# label immediately before it is clicked: selecting a tab scrolls the strip, so a coordinate
# captured up front is stale by the second click.
set -euo pipefail

MODE=${1:-tabs}
CLICKS=${2:-14}
WANT_A=${3:-}
WANT_B=${4:-}
case "$MODE" in tabs|sidebar) ;; *) echo "usage: $0 <tabs|sidebar> [clicks]" >&2; exit 2 ;; esac
LABEL=$([ "$MODE" = tabs ] && echo tab || echo select)

pgrep -x Postfrau >/dev/null || { echo "Postfrau is not running." >&2; exit 1; }

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

cat > "$WORK/ax.swift" <<'SWIFT'
import ApplicationServices
import AppKit

// Reading and clicking through the accessibility API. Reading only: the API's own press action
// makes NSSegmentedCell spin a nested event loop waiting for a mouse-up that never arrives, so
// the clicks below are real HID events.
let pid = NSWorkspace.shared.runningApplications.first { $0.localizedName == "Postfrau" }!
    .processIdentifier
let app = AXUIElementCreateApplication(pid)

func copy(_ e: AXUIElement, _ a: String) -> CFTypeRef? {
    var v: CFTypeRef?
    return AXUIElementCopyAttributeValue(e, a as CFString, &v) == .success ? v : nil
}
func kids(_ e: AXUIElement) -> [AXUIElement] {
    (copy(e, kAXChildrenAttribute as String) as? [AXUIElement]) ?? []
}
func frame(_ e: AXUIElement) -> CGRect? {
    guard let p = copy(e, kAXPositionAttribute as String),
          let s = copy(e, kAXSizeAttribute as String) else { return nil }
    var pt = CGPoint.zero, sz = CGSize.zero
    AXValueGetValue(p as! AXValue, .cgPoint, &pt)
    AXValueGetValue(s as! AXValue, .cgSize, &sz)
    return CGRect(origin: pt, size: sz)
}
func label(_ e: AXUIElement) -> String {
    (copy(e, kAXDescriptionAttribute as String) as? String)
        ?? (copy(e, kAXTitleAttribute as String) as? String) ?? ""
}

/// Puts the window somewhere known, so a run is reproducible and a stray drag cannot spoil it.
func pin() {
    for w in (copy(app, kAXWindowsAttribute as String) as? [AXUIElement]) ?? [] {
        guard let f = frame(w), f.width > 700, f.height > 500 else { continue }
        var pos = CGPoint(x: 80, y: 80), size = CGSize(width: 1400, height: 900)
        AXUIElementSetAttributeValue(w, kAXPositionAttribute as CFString, AXValueCreate(.cgPoint, &pos)!)
        AXUIElementSetAttributeValue(w, kAXSizeAttribute as CFString, AXValueCreate(.cgSize, &size)!)
        return
    }
}

func scan(_ band: ClosedRange<Double>) -> [(String, CGRect)] {
    var out: [(String, CGRect)] = []
    func walk(_ e: AXUIElement, _ d: Int) {
        if d > 22 { return }
        let l = label(e)
        if !l.isEmpty, let f = frame(e), band.contains(f.midY), f.minX > 90, f.maxX < 1400 {
            out.append((l, f))
        }
        for c in kids(e) { walk(c, d + 1) }
    }
    walk(app, 0)
    return out
}

func click(_ p: CGPoint) {
    for t in [CGEventType.mouseMoved, .leftMouseDown, .leftMouseUp] {
        CGEvent(mouseEventSource: nil, mouseType: t, mouseCursorPosition: p, mouseButton: .left)?
            .post(tap: .cghidEventTap)
        usleep(t == .mouseMoved ? 15000 : 30000)
    }
}

let mode = CommandLine.arguments[1]
let rounds = Int(CommandLine.arguments[2])!
// The tab strip sits just under the toolbar; sidebar rows fill the column below the filter.
let band: ClosedRange<Double> = mode == "tabs" ? 130...170 : 250...800

pin()
usleep(1_200_000)

// Shape, not just position: the toolbar's search field also sits in the tab strip's band, and
// clicking it selects no tab at all — which reads as a 1 ms click and flatters the median.
var found = scan(band)
if mode == "tabs" {
    found = found.filter { (100...230).contains($0.1.width) && (24...40).contains($0.1.height) }
}
if mode == "sidebar" {
    found = found.filter { $0.0.hasPrefix("GET ") || $0.0.hasPrefix("POST ")
        || $0.0.hasPrefix("PUT ") || $0.0.hasPrefix("PATCH ") || $0.0.hasPrefix("DELETE ") }
}
// Nearest the middle first. Selecting a tab scrolls the strip by ~40 px, and a target picked at
// the edge slides out of the window on the first click — after which it is never found again,
// every other round is skipped, and the rounds that remain re-click what is already selected and
// report a millisecond.
let centre = mode == "tabs" ? 780.0 : 480.0
found.sort { abs($0.1.midX - centre) < abs($1.1.midX - centre) }
if mode == "sidebar" { found.sort { $0.1.midY < $1.1.midY } }
let names = found.map(\.0).reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
guard names.count >= 2 else {
    FileHandle.standardError.write("found \(names.count) targets in the \(mode) band\n".data(using: .utf8)!)
    exit(1)
}
// Two targets far enough apart that no click lands on what is already selected — re-selecting
// something changes nothing, costs a millisecond, and would flatter the median.
let asked = CommandLine.arguments.count > 4
    ? [CommandLine.arguments[3], CommandLine.arguments[4]].filter({ !$0.isEmpty }) : []
var pair = asked.count == 2 ? asked : (mode == "tabs"
    ? [names[0], names[1]]
    : [names[0], names[min(names.count - 1, max(2, names.count / 2))]])
if asked.count == 2 {
    let missing = pair.filter { label in !found.contains { $0.0 == label } }
    if !missing.isEmpty {
        FileHandle.standardError.write(
            "not on screen: \(missing.joined(separator: ", "))\navailable: \(names.joined(separator: " | "))\n"
                .data(using: .utf8)!)
        exit(1)
    }
}
FileHandle.standardError.write("targets: \(pair[0]) | \(pair[1])\n".data(using: .utf8)!)

for round in 0..<rounds {
    let want = pair[round % 2]
    guard let hit = scan(band).first(where: { $0.0 == want }) else { continue }
    click(CGPoint(x: hit.1.midX, y: hit.1.midY))
    usleep(700_000)   // clear of the double-click interval
}
SWIFT

xcrun swiftc -O "$WORK/ax.swift" -o "$WORK/ax"

osascript -e 'tell application "Postfrau" to activate' >/dev/null 2>&1 || true
sleep 1
/usr/bin/log stream --predicate 'subsystem == "com.postfrau.app" && category == "clicks"' \
    --style compact > "$WORK/log.txt" 2>&1 &
LOGGER=$!
trap 'kill $LOGGER 2>/dev/null || true; rm -rf "$WORK"' EXIT
sleep 2

"$WORK/ax" "$MODE" "$CLICKS" "$WANT_A" "$WANT_B"
sleep 1.5
kill $LOGGER 2>/dev/null || true
wait $LOGGER 2>/dev/null || true

grep -o "$LABEL-click held.*" "$WORK/log.txt" || true
echo
grep -o "$LABEL-click held.*" "$WORK/log.txt" \
  | sed 's/ |.*//; s/.*total //; s/ ms//' | sort -n \
  | awk '{v[NR]=$1}
         END {if (NR == 0) { print "no clicks landed"; exit 1 }
              printf "%s: n=%d  median %.1f ms  min %.1f  max %.1f\n",
                     "'"$MODE"'", NR, (NR%2 ? v[(NR+1)/2] : (v[NR/2]+v[NR/2+1])/2), v[1], v[NR]}'
