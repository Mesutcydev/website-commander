#!/bin/bash
# SiteAgent TestFlight upload — adapted from CoreAIStudio release-build-52 script.
#
# Flow:
#   App Store (default): archive + upload with Xcode 26
#   --pcc:               archive with Xcode 27 beta, upload with Xcode 26
#
# Usage (from the local project folder):
#   cd /Users/m/Desktop/SiteAgent
#   BUILD_NUMBER=2026071205 ./Scripts/release-build-siteagent.sh
#   BUILD_NUMBER=2026071206 ./Scripts/release-build-siteagent.sh --pcc
#
# Xcode paths (Golden Gate defaults):
#   Xcode 26  → ~/Downloads/Xcode.app
#   Xcode 27β → ~/Desktop/Xcode-beta.app
#   Override: RELEASE_XCODE=…/Contents/Developer  BETA_XCODE=…/Contents/Developer
#
set -euo pipefail

# Resolve an Xcode Developer dir from env override or a list of .app candidates.
# Prints the Contents/Developer path, or empty if none exist.
resolve_xcode_developer() {
  local override="${1:-}"
  shift || true
  if [[ -n "$override" && -d "$override" ]]; then
    echo "$override"
    return 0
  fi
  # If override looks like …/Xcode.app (not …/Contents/Developer), accept it.
  if [[ -n "$override" && -d "${override%/}/Contents/Developer" ]]; then
    echo "${override%/}/Contents/Developer"
    return 0
  fi
  local app
  for app in "$@"; do
    if [[ -d "$app/Contents/Developer" ]]; then
      echo "$app/Contents/Developer"
      return 0
    fi
  done
  echo ""
  return 1
}

# Golden Gate layout: Xcode 26 lives in Downloads; Xcode 27 beta on Desktop.
# Env overrides (RELEASE_XCODE / BETA_XCODE) still win when set.
RELEASE_XCODE="$(resolve_xcode_developer "${RELEASE_XCODE:-}" \
  "${HOME}/Downloads/Xcode.app" \
  "${HOME}/Downloads/Xcode-26.app" \
  "${HOME}/Downloads/Xcode_26.app" \
  "/Applications/Xcode.app" \
  "/Applications/Xcode-26.app" \
  || true)"
BETA_XCODE="$(resolve_xcode_developer "${BETA_XCODE:-}" \
  "${HOME}/Desktop/Xcode-beta.app" \
  "${HOME}/Desktop/Xcode.app" \
  "/Applications/Xcode-beta.app" \
  || true)"

# Project root = parent of Scripts/.
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"

VARIANT="appstore"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --pcc) VARIANT="pcc"; shift ;;
    --help|-h)
      sed -n '2,16p' "$0"; exit 0 ;;
    *) echo "Unknown arg: $1" >&2; exit 1 ;;
  esac
done

# Must be higher than the last App Store–approved CFBundleShortVersionString
# (currently 1.10). ASC rejects closed trains (e.g. 1.7) and anything ≤ approved.
MARKETING_VERSION="${MARKETING_VERSION:-2.0}"
# Distinct build number per upload under the same marketing version.
BUILD_NUMBER="${BUILD_NUMBER:-1}"
DEVELOPMENT_TEAM="${DEVELOPMENT_TEAM:-PUH4GMFV56}"

# Prefer the credentials managed by Blitz, while keeping the legacy Downloads
# location as a fallback for machines that have not configured Blitz yet.
BLITZ_ASC_DIR="${HOME}/.blitz/asc-agent"
BLITZ_ASC_CONFIG="${BLITZ_ASC_DIR}/config.json"
if [[ -f "${BLITZ_ASC_DIR}/AuthKey_BlitzKey.p8" ]]; then
  DEFAULT_KEY_PATH="${BLITZ_ASC_DIR}/AuthKey_BlitzKey.p8"
else
  DEFAULT_KEY_PATH="${HOME}/Downloads/AuthKey_B7AYY3B2FT.p8"
fi
config_value() {
  local key="$1"
  local fallback="$2"
  local value=""
  if [[ -f "$BLITZ_ASC_CONFIG" ]]; then
    value="$(plutil -extract "$key" raw "$BLITZ_ASC_CONFIG" 2>/dev/null || true)"
  fi
  echo "${value:-$fallback}"
}
KEY_PATH="${KEY_PATH:-$DEFAULT_KEY_PATH}"
KEY_ID="${ASC_KEY_ID:-$(config_value key_id B7AYY3B2FT)}"
ISSUER_ID="${ASC_ISSUER_ID:-$(config_value issuer_id 5ddc2a8a-c374-4f06-b9bd-916f198652be)}"
# TestFlight "What to Test" text attached after upload (override with WHATS_NEW_FILE=…).
WHATS_NEW_FILE="${WHATS_NEW_FILE:-$PROJECT_DIR/Documentation/WhatsNew.txt}"

if [[ "$VARIANT" == "pcc" ]]; then
  SCHEME="SiteAgent-PCC"
  CONFIG="PCC-TestFlight"
  ARCHIVE_NAME="SiteAgent-PCC-${BUILD_NUMBER}"
  # PCC needs iOS 27 SDK / FoundationModels — Xcode 27 beta.
  ARCHIVE_XCODE="${BETA_XCODE}"
else
  SCHEME="SiteAgent"
  CONFIG="AppStore"
  ARCHIVE_NAME="SiteAgent-${BUILD_NUMBER}"
  # Clean App Store binary: archive with stable Xcode 26 (avoids beta CoreSimulator
  # / plugin quirks; matches Documentation/PCC_Release_Method.md).
  ARCHIVE_XCODE="${RELEASE_XCODE}"
fi

ARCHIVE_PATH="$PROJECT_DIR/build/${ARCHIVE_NAME}.xcarchive"
EXPORT_PATH="$PROJECT_DIR/build/export-${BUILD_NUMBER}"
LOG_PATH="$PROJECT_DIR/build/release-${BUILD_NUMBER}.log"
EXPORT_PLIST="$PROJECT_DIR/build/ExportOptions.plist"
DERIVED="$PROJECT_DIR/build/DerivedData-${VARIANT}-${BUILD_NUMBER}"

cd "$PROJECT_DIR"
mkdir -p "$DERIVED" "$EXPORT_PATH"

# Sanity: must be the complete SiteAgent project
test -d SiteAgent/Assets.xcassets/AppIcon.appiconset
test -f project.yml
test -f Scripts/verify-app-store-build.sh

if ! command -v xcodegen >/dev/null 2>&1; then
  echo "❌ xcodegen required. brew install xcodegen"
  exit 1
fi
if [[ -z "${ARCHIVE_XCODE:-}" || ! -d "$ARCHIVE_XCODE" ]]; then
  echo "❌ Archive Xcode not found."
  if [[ "$VARIANT" == "pcc" ]]; then
    echo "   Expected beta at ~/Desktop/Xcode-beta.app (or set BETA_XCODE=…/Contents/Developer)"
  else
    echo "   Expected Xcode 26 at ~/Downloads/Xcode.app (or set RELEASE_XCODE=…/Contents/Developer)"
    echo "   (Finder may say incompatible — CLI still works via DEVELOPER_DIR)"
  fi
  exit 1
fi
if [[ -z "${RELEASE_XCODE:-}" || ! -d "$RELEASE_XCODE" ]]; then
  echo "❌ Xcode 26 not found (needed for upload)."
  echo "   Put Xcode.app in ~/Downloads or set RELEASE_XCODE=…/Contents/Developer"
  exit 1
fi
echo "    RELEASE_XCODE=$RELEASE_XCODE"
if [[ -n "${BETA_XCODE:-}" ]]; then
  echo "    BETA_XCODE=$BETA_XCODE"
fi
if [[ ! -f "$KEY_PATH" ]]; then
  echo "❌ API key not found: $KEY_PATH"
  exit 1
fi

# Generate .xcodeproj from project.yml (not committed).
echo "==> Generating SiteAgent.xcodeproj…"
xcodegen generate
test -f SiteAgent.xcodeproj/project.pbxproj

# Write Developer.xcconfig if missing so signing has a team.
if [[ ! -f Configuration/Developer.xcconfig ]]; then
  cat > Configuration/Developer.xcconfig <<EOF
// Auto-written by release-build-siteagent.sh (gitignored).
DEVELOPMENT_TEAM = ${DEVELOPMENT_TEAM}
EOF
  echo "Wrote Configuration/Developer.xcconfig (team=$DEVELOPMENT_TEAM)"
fi

cat > "$EXPORT_PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>method</key>
	<string>app-store-connect</string>
	<key>destination</key>
	<string>upload</string>
	<key>signingStyle</key>
	<string>automatic</string>
	<key>teamID</key>
	<string>${DEVELOPMENT_TEAM}</string>
	<key>uploadSymbols</key>
	<true/>
	<key>manageAppVersionAndBuildNumber</key>
	<false/>
</dict>
</plist>
EOF

# mlx-swift ships a CudaBuild package plugin; CLI archives fail with
# "Validate plug-in CudaBuild" unless we skip the interactive trust prompt.
# Also skip macro fingerprint validation for the same reason.
defaults write com.apple.dt.Xcode IDESkipPackagePluginFingerprintValidatation -bool YES 2>/dev/null || true
defaults write com.apple.dt.Xcode IDESkipMacroFingerprintValidation -bool YES 2>/dev/null || true

echo "==> [1/2] Archive $SCHEME ($CONFIG) build $BUILD_NUMBER (v$MARKETING_VERSION)…"
echo "    PROJECT_DIR=$PROJECT_DIR"
echo "    DEVELOPER_DIR=$ARCHIVE_XCODE"
export DEVELOPER_DIR="$ARCHIVE_XCODE"
"$DEVELOPER_DIR/usr/bin/xcodebuild" -version | tee "$LOG_PATH"

# Xcode 26+ splits the Metal shader compiler into an optional component.
# Without it, mlx-swift's CompileMetalFile steps fail during archive
# (random.metal, rope.metal, steel_attention.metal, …).
#
# Known Xcode 26 bug: Components UI / -downloadComponent can report success
# while `xcrun metal` still says "missing Metal Toolchain". The reliable fix
# is export → patch buildUpdateVersion → import (Apple release-notes workaround).
# `xcrun --find metal` is NOT enough — it can succeed while the tool still
# refuses to run. Probe with a real invocation (nounset-safe; no nested locals).
metal_works() {
  local out
  out="$(xcrun metal -help 2>&1 || true)"
  if echo "$out" | grep -qiE 'missing Metal Toolchain|cannot execute tool .metal'; then
    return 1
  fi
  xcrun --find metal >/dev/null 2>&1
}

ensure_metal_toolchain() {
  local xb="${DEVELOPER_DIR}/usr/bin/xcodebuild"
  local export_root="${METAL_EXPORT_PATH:-/tmp/SiteAgentMetalToolchain}"
  local xcode_build=""
  local bundle=""
  local dmg=""

  echo "==> Ensuring Metal Toolchain is installed for ${ARCHIVE_XCODE}…"
  "$xb" -downloadComponent MetalToolchain 2>&1 | tee -a "$LOG_PATH" || true

  # Prefer showComponent when available (Xcode 26+).
  if "$xb" -showComponent metalToolchain >/dev/null 2>&1; then
    echo "✓ xcodebuild reports metalToolchain installed"
  else
    echo "⚠ xcodebuild -showComponent metalToolchain not ready; continuing with export/import…"
  fi

  if metal_works; then
    echo "✓ metal ready: $(xcrun --find metal)"
    return 0
  fi

  echo "⚠ metal not usable yet — applying export/import workaround…"
  rm -rf "$export_root"
  mkdir -p "$export_root"
  # Case variants differ across Xcode builds.
  "$xb" -downloadComponent metalToolchain -exportPath "$export_root" 2>&1 | tee -a "$LOG_PATH" \
    || "$xb" -downloadComponent MetalToolchain -exportPath "$export_root" 2>&1 | tee -a "$LOG_PATH" \
    || true

  bundle="$(find "$export_root" -maxdepth 1 -name 'MetalToolchain-*.exportedBundle' | head -1 || true)"
  if [[ -z "$bundle" || ! -d "$bundle" ]]; then
    echo "❌ Could not download Metal Toolchain export bundle."
    echo "   Open Xcode → Settings → Components → download “Metal Toolchain”,"
    echo "   then re-run. Or:"
    echo "     DEVELOPER_DIR=\"${ARCHIVE_XCODE}\" sudo xcodebuild -downloadComponent MetalToolchain"
    return 1
  fi

  xcode_build="$("$xb" -version | awk '/Build version/ {print $3}')"
  echo "    Xcode build: ${xcode_build:-unknown}"
  echo "    Bundle: $bundle"
  if [[ -n "$xcode_build" && -f "$bundle/ExportMetadata.plist" ]]; then
    # Force buildUpdateVersion to match this Xcode (known mismatch bug).
    if /usr/libexec/PlistBuddy -c "Print :buildUpdateVersion" "$bundle/ExportMetadata.plist" >/dev/null 2>&1; then
      /usr/libexec/PlistBuddy -c "Set :buildUpdateVersion $xcode_build" "$bundle/ExportMetadata.plist"
    else
      /usr/libexec/PlistBuddy -c "Add :buildUpdateVersion string $xcode_build" "$bundle/ExportMetadata.plist"
    fi
    echo "    ExportMetadata.buildUpdateVersion → $xcode_build"
  fi

  "$xb" -importComponent metalToolchain -importPath "$bundle" 2>&1 | tee -a "$LOG_PATH" \
    || "$xb" -importComponent MetalToolchain -importPath "$bundle" 2>&1 | tee -a "$LOG_PATH" \
    || true

  # Last-resort: mount the MobileAsset MetalToolchain DMG (survives some installs
  # that still leave metal unregistered until reboot/mount).
  if ! metal_works; then
    dmg="$(find /System/Library/AssetsV2/com_apple_MobileAsset_MetalToolchain \
      -path '*/AssetData/Restore/*.dmg' 2>/dev/null | head -1 || true)"
    if [[ -n "$dmg" && -f "$dmg" ]]; then
      echo "⚠ Trying to mount MetalToolchain asset: $dmg"
      hdiutil attach "$dmg" -nobrowse 2>&1 | tee -a "$LOG_PATH" || true
    fi
  fi

  if ! metal_works; then
    echo "❌ 'metal' still cannot run (mlx-swift archive will fail CompileMetalFile)."
    echo "   Manual fix (run once for this Xcode):"
    echo "     export DEVELOPER_DIR=\"${ARCHIVE_XCODE}\""
    echo "     sudo xcodebuild -downloadComponent metalToolchain -exportPath /tmp/SiteAgentMetalToolchain"
    echo "     # patch ExportMetadata.plist buildUpdateVersion to: ${xcode_build:-<xcode build>}"
    echo "     xcodebuild -importComponent metalToolchain -importPath /tmp/SiteAgentMetalToolchain/MetalToolchain-*.exportedBundle"
    echo "   Or: Xcode → Settings → Components → Metal Toolchain, then re-run this script."
    echo "   Probe output:"
    xcrun metal -help 2>&1 | tee -a "$LOG_PATH" || true
    return 1
  fi

  echo "✓ metal ready after workaround: $(xcrun --find metal)"
  return 0
}

ensure_metal_toolchain

rm -rf "$ARCHIVE_PATH"
set -o pipefail
"$DEVELOPER_DIR/usr/bin/xcodebuild" \
  -project SiteAgent.xcodeproj \
  -scheme "$SCHEME" \
  -configuration "$CONFIG" \
  -destination 'generic/platform=iOS' \
  -derivedDataPath "$DERIVED" \
  -archivePath "$ARCHIVE_PATH" \
  -skipPackagePluginValidation \
  -skipMacroValidation \
  CURRENT_PROJECT_VERSION="$BUILD_NUMBER" \
  MARKETING_VERSION="$MARKETING_VERSION" \
  DEVELOPMENT_TEAM="$DEVELOPMENT_TEAM" \
  CODE_SIGN_STYLE=Automatic \
  ENABLE_USER_SCRIPT_SANDBOXING=NO \
  -allowProvisioningUpdates \
  archive 2>&1 | tee -a "$LOG_PATH"
set +o pipefail
grep -q "ARCHIVE SUCCEEDED" "$LOG_PATH"

APP="$ARCHIVE_PATH/Products/Applications/SiteAgent.app"
echo "==> Verifying archive…"
ls -la "$APP" | tee -a "$LOG_PATH"
test -d "$APP"
if [[ -f "$APP/Assets.car" ]]; then
  echo "✓ Assets.car present"
else
  echo "⚠ Assets.car missing (icon may still be in asset catalog — check App Store Connect)"
fi
/usr/libexec/PlistBuddy -c 'Print :CFBundleIconName' "$APP/Info.plist" 2>/dev/null \
  || /usr/libexec/PlistBuddy -c 'Print :CFBundleIcons:CFBundlePrimaryIcon:CFBundleIconFiles' "$APP/Info.plist" 2>/dev/null \
  || true
plutil -extract ApplicationProperties.CFBundleVersion raw "$ARCHIVE_PATH/Info.plist"
plutil -extract ApplicationProperties.CFBundleShortVersionString raw "$ARCHIVE_PATH/Info.plist"

# App Store / clean builds must not carry PCC.
if [[ "$VARIANT" == "appstore" ]]; then
  echo "==> Verifying App Store binary is PCC-clean…"
  ./Scripts/verify-app-store-build.sh "$APP" | tee -a "$LOG_PATH"
fi

echo ""
echo "==> [2/2] Upload with Xcode 26 + API key…"
export DEVELOPER_DIR="$RELEASE_XCODE"
set -o pipefail
if ! "$DEVELOPER_DIR/usr/bin/xcodebuild" \
  -exportArchive \
  -archivePath "$ARCHIVE_PATH" \
  -exportPath "$EXPORT_PATH" \
  -exportOptionsPlist "$EXPORT_PLIST" \
  -authenticationKeyPath "$KEY_PATH" \
  -authenticationKeyID "$KEY_ID" \
  -authenticationKeyIssuerID "$ISSUER_ID" \
  -allowProvisioningUpdates 2>&1 | tee -a "$LOG_PATH"
then
  echo ""
  echo "❌ EXPORT/UPLOAD FAILED — archive is OK at:"
  echo "   $ARCHIVE_PATH"
  echo "   Common ASC errors:"
  echo "     - Invalid Pre-Release Train / must be > approved version"
    echo "       -> bump MARKETING_VERSION if the current train is closed (default: 1.16)"
  echo "       MARKETING_VERSION=1.16 BUILD_NUMBER=YYYYMMDDNN $0"
  echo "   Log: $LOG_PATH"
  exit 1
fi
set +o pipefail

# Attach What's New / "What to Test" on the uploaded build (ASC betaBuildLocalizations).
if [[ -f "$WHATS_NEW_FILE" ]]; then
  echo ""
  echo "==> Attaching What's New from ${WHATS_NEW_FILE}"
  if ! WHATS_NEW_FILE="$WHATS_NEW_FILE" KEY_PATH="$KEY_PATH" ASC_KEY_ID="$KEY_ID" ASC_ISSUER_ID="$ISSUER_ID" \
    "$PROJECT_DIR/Scripts/set-testflight-whatsnew.sh" --build "$BUILD_NUMBER" --notes "$WHATS_NEW_FILE" 2>&1 | tee -a "$LOG_PATH"
  then
    echo "Warning: What's New attach failed; build still uploaded. Re-run:"
    echo "   ./Scripts/set-testflight-whatsnew.sh --build $BUILD_NUMBER --notes \"$WHATS_NEW_FILE\""
  fi
else
  echo "Warning: No What's New file at ${WHATS_NEW_FILE} (skipped)"
fi

echo ""
echo "Done — SiteAgent build $BUILD_NUMBER (v$MARKETING_VERSION) [$VARIANT]"
echo "Log: $LOG_PATH"
echo "What's New: $WHATS_NEW_FILE"
echo "App Store Connect: https://appstoreconnect.apple.com/apps/6780267869/testflight/ios"
