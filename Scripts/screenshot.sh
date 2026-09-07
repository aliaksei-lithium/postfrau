#!/bin/bash
# Captures Postfrau's main window to a PNG so the agent (or a human) can eyeball the UI.
#
#   Scripts/screenshot.sh [output.png]
#
# The app must already be running (`make run`). Falls back to a full-screen capture if the
# window id cannot be resolved.
set -euo pipefail
OUT="${1:-/tmp/postfrau.png}"

if ! pgrep -x Postfrau >/dev/null 2>&1; then
  echo "Postfrau is not running; start it with 'make run' first." >&2
  exit 1
fi

# Give the window server a moment in case the app was just launched.
sleep 1

WINDOW_ID=$(osascript -e 'tell application "System Events" to tell process "Postfrau" to get value of attribute "AXIdentifier" of window 1' 2>/dev/null || true)

# AXIdentifier is not a CGWindowID; use the Quartz window list via a tiny Swift snippet instead.
CGID=$(cat <<'SWIFT' | xcrun swift - 2>/dev/null || true
import CoreGraphics
import Foundation
let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
let match = list.first { ($0[kCGWindowOwnerName as String] as? String) == "Postfrau" && (($0[kCGWindowLayer as String] as? Int) ?? 1) == 0 }
if let n = match?[kCGWindowNumber as String] as? Int { print(n) }
SWIFT
)

if [ -n "${CGID:-}" ]; then
  screencapture -x -o -l "$CGID" "$OUT"
else
  echo "Could not resolve Postfrau's window id; capturing the whole screen." >&2
  screencapture -x "$OUT"
fi

echo "$OUT"
