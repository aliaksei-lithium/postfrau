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
let match = list.first {
    ($0[kCGWindowOwnerName as String] as? String) == "Postfrau"
        && ((($0[kCGWindowBounds as String] as? [String: Any])?["Width"] as? Double) ?? 0) > 800
}
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
