#!/usr/bin/env bash
# Resize the WebsiteCommander window and capture it by window ID, so z-order
# and other apps cannot corrupt the shot.
#
#   capture-agent.sh <width> <height> <output.png> [clickX clickY ...]
#
# Optional click pairs are window-relative logical points, clicked (in order)
# before the capture — used to drive the sidebar toggle and pane switches.
set -euo pipefail

W="$1"; H="$2"; OUT="$3"; shift 3

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
HELPER="$SCRIPT_DIR/.window-id"
if [ ! -x "$HELPER" ] || [ "$SCRIPT_DIR/window-id.swift" -nt "$HELPER" ]; then
  swiftc -O -o "$HELPER" "$SCRIPT_DIR/window-id.swift"
fi

# SwiftUI keeps a hidden anchor window around once a popover has been shown, and
# it can sort ahead of the real one — so target the standard window explicitly.
osascript <<EOF >/dev/null
tell application "System Events" to tell application process "WebsiteCommander"
  set win to first window whose subrole is "AXStandardWindow"
  set position of win to {20, 40}
  set size of win to {$W, $H}
end tell
EOF
sleep 1

# Window-relative logical point -> screen point (origin is set above).
while [ "$#" -ge 2 ]; do
  osascript -e "tell application \"System Events\" to click at {$((20 + $1)), $((40 + $2))}" >/dev/null
  shift 2
  sleep 1.2
done

WID=$("$HELPER" WebsiteCommander "$W" "$H") || { echo "no window found" >&2; exit 1; }
screencapture -x -o -l"$WID" "$OUT"
echo "captured $(sips -g pixelWidth -g pixelHeight "$OUT" | tr '\n' ' ' | sed 's|.*pixelWidth|w|') -> $OUT"
