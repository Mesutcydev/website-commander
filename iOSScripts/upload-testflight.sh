#!/usr/bin/env bash
# upload-testflight.sh — archive, export, and upload SiteAgent to TestFlight.
#
# Run on your Mac (this cloud agent is Linux and cannot invoke Xcode).
#
# Prerequisites:
#   - Xcode 26 at ~/Downloads/Xcode.app (App Store / Release archive)
#     OR Xcode 27 beta at ~/Desktop/Xcode-beta.app (PCC TestFlight)
#   - xcodegen (`brew install xcodegen`)
#   - App Store Connect API key (.p8) — default: ~/Downloads/AuthKey_*.p8
#   - Configuration/Developer.xcconfig with DEVELOPMENT_TEAM set
#
# Usage:
#   ./Scripts/upload-testflight.sh                 # App Store config → TestFlight
#   ./Scripts/upload-testflight.sh --pcc           # PCC-TestFlight config (needs Xcode 27)
#   ./Scripts/upload-testflight.sh --key ~/Downloads/AuthKey_XXXXXX.p8
#   ASC_KEY_ID=XXXXXX ASC_ISSUER_ID=yyyy ./Scripts/upload-testflight.sh
#
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

VARIANT="appstore"          # appstore | pcc
P8_PATH=""
GROUP_NAME="${TESTFLIGHT_GROUP:-Mesut Can}"
APP_ID="${ASC_APP_ID:-6780267869}"
DERIVED="${DERIVED_DATA_PATH:-$ROOT/Build/DerivedData}"
ARCHIVE_DIR="$ROOT/Build"
EXPORT_PLIST="$ROOT/.asc/ExportOptions-ipa.plist"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --pcc) VARIANT="pcc"; shift ;;
    --key) P8_PATH="$2"; shift 2 ;;
    --group) GROUP_NAME="$2"; shift 2 ;;
    --help|-h)
      sed -n '2,20p' "$0"; exit 0 ;;
    *) echo "Unknown arg: $1" >&2; exit 1 ;;
  esac
done

# --- Locate .p8 ----------------------------------------------------------------
if [[ -z "$P8_PATH" ]]; then
  if [[ -n "${ASC_KEY_PATH:-}" && -f "$ASC_KEY_PATH" ]]; then
    P8_PATH="$ASC_KEY_PATH"
  else
    # Prefer Downloads AuthKey_*.p8 (newest).
    P8_PATH="$(ls -t "$HOME"/Downloads/AuthKey_*.p8 2>/dev/null | head -1 || true)"
  fi
fi
if [[ -z "$P8_PATH" || ! -f "$P8_PATH" ]]; then
  echo "❌ No App Store Connect .p8 found."
  echo "   Put AuthKey_XXXXXX.p8 in ~/Downloads or pass --key /path/to/AuthKey_XXXXXX.p8"
  exit 1
fi

KEY_ID="${ASC_KEY_ID:-}"
if [[ -z "$KEY_ID" ]]; then
  # AuthKey_<KEYID>.p8
  BASE="$(basename "$P8_PATH")"
  KEY_ID="$(echo "$BASE" | sed -E 's/^AuthKey_([A-Z0-9]+)\.p8$/\1/')"
fi
ISSUER_ID="${ASC_ISSUER_ID:-}"
if [[ -z "$ISSUER_ID" ]]; then
  # Optional sidecar next to the key (gitignored): AuthKey_XXXXXX.issuer
  SIDE="${P8_PATH%.p8}.issuer"
  if [[ -f "$SIDE" ]]; then
    ISSUER_ID="$(tr -d '[:space:]' < "$SIDE")"
  fi
fi
if [[ -z "$KEY_ID" || -z "$ISSUER_ID" ]]; then
  echo "❌ Need ASC_KEY_ID and ASC_ISSUER_ID (or a .issuer sidecar next to the .p8)."
  echo "   Key file: $P8_PATH"
  echo "   Parsed KEY_ID: ${KEY_ID:-<empty>}"
  echo "   Export example:"
  echo "     export ASC_KEY_ID=$KEY_ID"
  echo "     export ASC_ISSUER_ID=<uuid-from-appstoreconnect.apple.com/access/integrations/api>"
  exit 1
fi

# --- Pick Xcode ----------------------------------------------------------------
# Golden Gate: Xcode 26 in Downloads; Xcode 27 beta on Desktop.
pick_xcode_app() {
  local override="${1:-}"
  shift || true
  if [[ -n "$override" && -d "$override" ]]; then
    echo "$override"
    return 0
  fi
  local app
  for app in "$@"; do
    if [[ -d "$app/Contents/Developer" ]]; then
      echo "$app"
      return 0
    fi
  done
  echo ""
  return 1
}

if [[ "$VARIANT" == "pcc" ]]; then
  XCODE_APP="$(pick_xcode_app "${XCODE_BETA:-}" \
    "${HOME}/Desktop/Xcode-beta.app" \
    "${HOME}/Desktop/Xcode.app" \
    "/Applications/Xcode-beta.app" \
    || true)"
  SCHEME="SiteAgent-PCC"
  CONFIG="PCC-TestFlight"
  ARCHIVE_PATH="$ARCHIVE_DIR/SiteAgent-PCC.xcarchive"
  IPA_PATH="$ARCHIVE_DIR/SiteAgent-PCC.ipa"
else
  # Prefer stable Xcode 26 even if Finder says "incompatible" — launch via DEVELOPER_DIR.
  XCODE_APP="$(pick_xcode_app "${XCODE_STABLE:-}" \
    "${HOME}/Downloads/Xcode.app" \
    "${HOME}/Downloads/Xcode-26.app" \
    "${HOME}/Downloads/Xcode_26.app" \
    "/Applications/Xcode.app" \
    "/Applications/Xcode-26.app" \
    || true)"
  SCHEME="SiteAgent"
  CONFIG="AppStore"
  ARCHIVE_PATH="$ARCHIVE_DIR/SiteAgent.xcarchive"
  IPA_PATH="$ARCHIVE_DIR/SiteAgent.ipa"
fi

if [[ -z "${XCODE_APP:-}" || ! -d "$XCODE_APP/Contents/Developer" ]]; then
  echo "❌ Xcode not found."
  echo "   App Store: put Xcode 26 at ~/Downloads/Xcode.app (or set XCODE_STABLE=…)"
  echo "   PCC: put Xcode-beta.app on ~/Desktop (or set XCODE_BETA=…)"
  exit 1
fi
export DEVELOPER_DIR="$XCODE_APP/Contents/Developer"
echo "Using DEVELOPER_DIR=$DEVELOPER_DIR"
xcodebuild -version

# --- Developer.xcconfig --------------------------------------------------------
if [[ ! -f Configuration/Developer.xcconfig ]]; then
  echo "❌ Missing Configuration/Developer.xcconfig (gitignored)."
  echo "   cp Configuration/Developer.xcconfig.example Configuration/Developer.xcconfig"
  echo "   # then set DEVELOPMENT_TEAM = YOURTEAMID"
  exit 1
fi

# --- Tools ---------------------------------------------------------------------
if ! command -v xcodegen >/dev/null 2>&1; then
  echo "❌ xcodegen not installed. brew install xcodegen"
  exit 1
fi

mkdir -p "$ARCHIVE_DIR" "$HOME/.appstoreconnect/private_keys"
# altool / notary look for AuthKey_<id>.p8 under ~/.appstoreconnect/private_keys
cp -f "$P8_PATH" "$HOME/.appstoreconnect/private_keys/AuthKey_${KEY_ID}.p8"
chmod 600 "$HOME/.appstoreconnect/private_keys/AuthKey_${KEY_ID}.p8"

# ExportOptions — create a minimal one if the private .asc copy is absent.
if [[ ! -f "$EXPORT_PLIST" ]]; then
  mkdir -p "$ROOT/.asc"
  TEAM_ID="$(grep -E '^DEVELOPMENT_TEAM' Configuration/Developer.xcconfig | awk -F= '{print $2}' | tr -d '[:space:]')"
  cat > "$EXPORT_PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>method</key><string>app-store-connect</string>
  <key>destination</key><string>export</string>
  <key>signingStyle</key><string>automatic</string>
  <key>teamID</key><string>${TEAM_ID}</string>
  <key>uploadSymbols</key><true/>
  <key>manageAppVersionAndBuildNumber</key><false/>
</dict>
</plist>
PLIST
  echo "Wrote $EXPORT_PLIST (team=$TEAM_ID)"
fi

echo "========================================="
echo "Variant:     $VARIANT"
echo "Scheme:      $SCHEME"
echo "Config:      $CONFIG"
echo "Build:       $(grep CURRENT_PROJECT_VERSION project.yml | head -1)"
echo "Key:         $P8_PATH (id=$KEY_ID)"
echo "App ID:      $APP_ID"
echo "========================================="

# --- Generate + archive --------------------------------------------------------
xcodegen generate

echo "→ Archiving…"
xcodebuild \
  -project SiteAgent.xcodeproj \
  -scheme "$SCHEME" \
  -configuration "$CONFIG" \
  -destination 'generic/platform=iOS' \
  -derivedDataPath "$DERIVED" \
  -archivePath "$ARCHIVE_PATH" \
  clean archive \
  CODE_SIGN_STYLE=Automatic \
  -allowProvisioningUpdates

APP_BUNDLE="$ARCHIVE_PATH/Products/Applications/SiteAgent.app"
if [[ "$VARIANT" == "appstore" ]]; then
  echo "→ Verifying App Store binary is PCC-clean…"
  ./Scripts/verify-app-store-build.sh "$APP_BUNDLE"
fi

echo "→ Exporting IPA…"
rm -f "$IPA_PATH"
xcodebuild -exportArchive \
  -archivePath "$ARCHIVE_PATH" \
  -exportOptionsPlist "$EXPORT_PLIST" \
  -exportPath "$ARCHIVE_DIR/export-$VARIANT" \
  -allowProvisioningUpdates
# Find the exported IPA (name may match PRODUCT_NAME)
EXPORTED_IPA="$(ls "$ARCHIVE_DIR/export-$VARIANT"/*.ipa | head -1)"
cp -f "$EXPORTED_IPA" "$IPA_PATH"
echo "IPA: $IPA_PATH ($(du -h "$IPA_PATH" | awk '{print $1}'))"

# Prefer the project's `asc` helper if present (as in PCC_Release_Method.md).
ASC_BIN=""
for c in "$HOME/.blitz/bin/asc" "$(command -v asc || true)"; do
  if [[ -n "$c" && -x "$c" ]]; then ASC_BIN="$c"; break; fi
done

if [[ -n "$ASC_BIN" ]]; then
  echo "→ Uploading via asc ($ASC_BIN)…"
  "$ASC_BIN" publish testflight \
    --app "$APP_ID" \
    --ipa "$IPA_PATH" \
    --group "$GROUP_NAME" \
    --wait \
    || "$ASC_BIN" publish testflight --app "$APP_ID" --ipa "$IPA_PATH" --wait
else
  echo "→ Uploading via altool…"
  xcrun altool --upload-app \
    --type ios \
    --file "$IPA_PATH" \
    --apiKey "$KEY_ID" \
    --apiIssuer "$ISSUER_ID"
fi

echo "✅ Upload submitted. Check App Store Connect → TestFlight for processing."
echo "   App: https://appstoreconnect.apple.com/apps/$APP_ID/testflight/ios"
