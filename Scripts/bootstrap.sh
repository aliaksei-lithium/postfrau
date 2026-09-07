#!/bin/bash
# Prepares a fresh clone: installs xcodegen if missing, then generates the Xcode project.
set -euo pipefail
cd "$(dirname "$0")/.."

if ! command -v xcodegen >/dev/null 2>&1 && [ ! -x /opt/homebrew/bin/xcodegen ]; then
  echo "xcodegen not found; installing with Homebrew…"
  brew install xcodegen
fi

XCODEGEN=$(command -v xcodegen || echo /opt/homebrew/bin/xcodegen)
"$XCODEGEN" generate
echo "Ready. Try: make test && make run"
