#!/bin/bash
# Install (and optionally debug) the Debug-PCC build on the device, bypassing
# Xcode 27 beta's broken enablePersonalizedDDI install worker — CoreDeviceError
# 4000 for PCC-entitled apps (Radar component 985505). Build first in Xcode
# (⌘B, SiteAgent-PCC scheme), then:
#   Scripts/run-device-pcc.sh            # install + launch
#   Scripts/run-device-pcc.sh --debug    # install + launch suspended + lldb attach
# Delete this script when a newer Xcode/iOS beta fixes plain Run.
set -euo pipefail

# ponytail: device ID hardcoded (iPhone "M#"); parse `devicectl list devices`
# for the first available physical device if a second phone ever matters.
DEVICE=9FDBC7DA-28A0-5D84-8866-63825706079C
BUNDLE_ID=uk.mesut.SiteAgent

APP=$(ls -td "$HOME"/Library/Developer/Xcode/DerivedData/SiteAgent-*/Build/Products/Debug-PCC-iphoneos/SiteAgent.app 2>/dev/null | head -1)
[[ -n "$APP" ]] || { echo "No Debug-PCC build found — build the SiteAgent-PCC scheme in Xcode first (⌘B)." >&2; exit 1; }

echo "Installing $APP"
xcrun devicectl device install app --device "$DEVICE" "$APP"

if [[ "${1:-}" == "--debug" ]]; then
  echo "Launching suspended…"
  PID=$(xcrun devicectl device process launch --start-stopped --json-output - --device "$DEVICE" "$BUNDLE_ID" 2>/dev/null \
    | python3 -c 'import json,sys; print(json.load(sys.stdin)["result"]["process"]["processIdentifier"])')
  echo "Attaching lldb to pid $PID (local symbols from $APP)…"
  exec xcrun lldb \
    -o "target create \"$APP\"" \
    -o "device select $DEVICE" \
    -o "device process attach --pid $PID" \
    -o "continue"
else
  xcrun devicectl device process launch --device "$DEVICE" "$BUNDLE_ID" \
    || echo "Launch channel flaky — installed fine, tap the SiteAgent icon on the phone."
fi
