#!/bin/bash
# Captures Postfrau's main window to a PNG so the agent (or a human) can eyeball the UI.
#
#   Scripts/screenshot.sh [output.png]
#
# The app must already be running (`make run`). The window is captured by id rather than by
# screen region, so it works even when something else is in front of it — which is the normal
# case when another app is full-screen on its own Space.
set -euo pipefail
OUT="${1:-/tmp/postfrau.png}"

if ! pgrep -x Postfrau >/dev/null 2>&1; then
  echo "Postfrau is not running; start it with 'make run' first." >&2
  exit 1
fi

sleep 1

CGID=$(cat <<'SWIFT' | xcrun swift - 2>/dev/null || true
import CoreGraphics
import Foundation
// `.optionAll`, not `.optionOnScreenOnly`: an occluded or off-Space window is still capturable
// by id, and that is exactly when a screenshot is hardest to get any other way.
let list = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID)
    as? [[String: Any]] ?? []
// Pick by shape and size, not by width alone. The app also owns several screen-wide strips 33
// points tall (backing windows for the menu bar) which are layer 0 like any other, and the
// Environments and Settings windows may be open at the same time.
//
// Apostrophes are avoided in this block on purpose: bash tracks quotes while looking for the
// closing paren of the surrounding command substitution, and one stray quote breaks the script.
func size(_ window: [String: Any]) -> (width: Double, height: Double) {
    let bounds = window[kCGWindowBounds as String] as? [String: Any] ?? [:]
    return (bounds["Width"] as? Double ?? 0, bounds["Height"] as? Double ?? 0)
}
// The largest one is the main window: Environments and Settings are both smaller, and the
// menu-bar strips have almost no area at all.
let match = list
    .filter {
        ($0[kCGWindowOwnerName as String] as? String) == "Postfrau"
            && (($0[kCGWindowLayer as String] as? Int) ?? -1) == 0
            && size($0).height > 400
    }
    .max { size($0).width * size($0).height < size($1).width * size($1).height }
if let number = match?[kCGWindowNumber as String] as? Int { print(number) }
SWIFT
)

if [ -n "${CGID:-}" ]; then
  screencapture -x -o -l "$CGID" "$OUT"
else
  echo "Could not resolve Postfrau's main window id." >&2
  exit 1
fi

echo "$OUT"
