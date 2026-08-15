#!/bin/bash
# Build the paywall-free, legacy-format IPA used for direct sideloading.
#
# This is intentionally separate from the App Store/TestFlight release script.
# The resulting app includes SiteAgentSideloadUnlocked and the memory
# entitlements used by the known-good legacy sideload build.
#
# Usage:
#   ./iOSScripts/build-sideload-ipa.sh
#   MARKETING_VERSION=2.0 BUILD_NUMBER=2 ./iOSScripts/build-sideload-ipa.sh

set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="$PROJECT_DIR/build"
MARKETING_VERSION="${MARKETING_VERSION:-2.0}"
BUILD_NUMBER="${BUILD_NUMBER:-1}"
DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
XCODE_PROJECT="$PROJECT_DIR/WebsiteCommander.xcodeproj"
ENTITLEMENTS="$PROJECT_DIR/iOSConfiguration/SideloadMemory.entitlements"
OUTPUT_IPA="$BUILD_DIR/WebsiteCommander-${MARKETING_VERSION}-build-${BUILD_NUMBER}.ipa"

cd "$PROJECT_DIR"
mkdir -p "$BUILD_DIR"

test -f project.yml
test -f "$ENTITLEMENTS"
test -d "$XCODE_PROJECT"
command -v xcodegen >/dev/null
command -v xcodebuild >/dev/null
command -v codesign >/dev/null
command -v zip >/dev/null
command -v unzip >/dev/null
command -v rg >/dev/null

echo "==> Generating Xcode project"
xcodegen generate

# Use unique generated working directories so a failed archive can never be
# mistaken for a completed one and no prior build needs to be overwritten.
ARCHIVE_WORK="$({ mktemp -d "$BUILD_DIR/sideload-archive.XXXXXX"; })"
DERIVED_WORK="$({ mktemp -d "$BUILD_DIR/sideload-derived.XXXXXX"; })"
STAGING_WORK="$({ mktemp -d /tmp/SiteAgentSideload.XXXXXX; })"
ARCHIVE_PATH="$ARCHIVE_WORK/SiteAgent.xcarchive"
APP_PATH="$STAGING_WORK/Payload/SiteAgent.app"

echo "==> Archiving SiteAgent $MARKETING_VERSION ($BUILD_NUMBER)"
DEVELOPER_DIR="$DEVELOPER_DIR" xcodebuild \
  -project "$XCODE_PROJECT" \
  -scheme SiteAgent \
  -configuration Sideload \
  -destination 'generic/platform=iOS' \
  -derivedDataPath "$DERIVED_WORK" \
  -archivePath "$ARCHIVE_PATH" \
  -skipPackagePluginValidation \
  -skipMacroValidation \
  clean archive \
  CURRENT_PROJECT_VERSION="$BUILD_NUMBER" \
  MARKETING_VERSION="$MARKETING_VERSION" \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO \
  AD_HOC_CODE_SIGNING_ALLOWED=NO \
  ENABLE_USER_SCRIPT_SANDBOXING=NO

SOURCE_APP="$ARCHIVE_PATH/Products/Applications/SiteAgent.app"
test -d "$SOURCE_APP"
mkdir -p "$STAGING_WORK/Payload"
ditto "$SOURCE_APP" "$APP_PATH"

# Xcode 26 emits the shortcut metadata as extract.actionsdata/version.json,
# while the known-good sideload bundle also carries root.ssu.yaml. Preserve
# that legacy resource layout for direct installation compatibility.
SHORTCUT_METADATA="$PROJECT_DIR/iOSConfiguration/Metadata.appintents/root.ssu.yaml"
test -f "$SHORTCUT_METADATA"
mkdir -p "$APP_PATH/Metadata.appintents"
ditto "$SHORTCUT_METADATA" "$APP_PATH/Metadata.appintents/root.ssu.yaml"

PLIST="$APP_PATH/Info.plist"
VERSION="$(plutil -extract CFBundleShortVersionString raw "$PLIST")"
BUILD="$(plutil -extract CFBundleVersion raw "$PLIST")"
UNLOCKED="$(plutil -extract SiteAgentSideloadUnlocked raw "$PLIST")"
[[ "$VERSION" == "$MARKETING_VERSION" ]]
[[ "$BUILD" == "$BUILD_NUMBER" ]]
[[ "$UNLOCKED" == "1" || "$UNLOCKED" == "true" || "$UNLOCKED" == "YES" ]]

echo "==> Applying legacy ad-hoc sideload signature"
# Sign nested code first, then sign the application itself with the exact
# entitlements used by the legacy IPA. This keeps the outer bundle's structure
# deterministic while retaining valid nested signatures.
codesign --force --deep --sign - --timestamp=none "$APP_PATH"
codesign --force --sign - --entitlements "$ENTITLEMENTS" --timestamp=none "$APP_PATH"

codesign --verify --deep --strict "$APP_PATH"
ENTITLEMENTS_DUMP="$STAGING_WORK/entitlements.plist"
codesign -d --entitlements :- "$APP_PATH" 2>&1 \
  | awk 'BEGIN { capture = 0 } /<\?xml/ { capture = 1 } capture { print }' \
  > "$ENTITLEMENTS_DUMP"
plutil -p "$ENTITLEMENTS_DUMP" \
  | rg '"com\.apple\.developer\.kernel\.extended-virtual-addressing" => true' >/dev/null
plutil -p "$ENTITLEMENTS_DUMP" \
  | rg '"com\.apple\.developer\.kernel\.increased-memory-limit" => true' >/dev/null

echo "==> Packaging $OUTPUT_IPA"
(
  cd "$STAGING_WORK"
  zip -qry "$OUTPUT_IPA" Payload
)
unzip -tq "$OUTPUT_IPA"

# Verify the packaged archive, not just the pre-zip staging directory. A valid
# sideload IPA has exactly one app directly under Payload and keeps the app's
# internal bundle name stable for existing installs.
VERIFY_WORK="$({ mktemp -d /tmp/WebsiteCommanderIPA.XXXXXX; })"
unzip -q "$OUTPUT_IPA" -d "$VERIFY_WORK"
test -d "$VERIFY_WORK/Payload/SiteAgent.app"
test -f "$VERIFY_WORK/Payload/SiteAgent.app/Info.plist"
EXECUTABLE="$(plutil -extract CFBundleExecutable raw "$VERIFY_WORK/Payload/SiteAgent.app/Info.plist")"
test -f "$VERIFY_WORK/Payload/SiteAgent.app/$EXECUTABLE"
if unzip -Z1 "$OUTPUT_IPA" | rg -v '^Payload/' >/dev/null; then
  echo "Unexpected files outside Payload in $OUTPUT_IPA" >&2
  exit 1
fi
codesign --verify --deep --strict "$VERIFY_WORK/Payload/SiteAgent.app"
VERIFY_ENTITLEMENTS="$VERIFY_WORK/entitlements.plist"
codesign -d --entitlements :- "$VERIFY_WORK/Payload/SiteAgent.app" 2>&1 \
  | awk 'BEGIN { capture = 0 } /<\?xml/ { capture = 1 } capture { print }' \
  > "$VERIFY_ENTITLEMENTS"
plutil -p "$VERIFY_ENTITLEMENTS" \
  | rg '"com\.apple\.developer\.kernel\.extended-virtual-addressing" => true' >/dev/null
plutil -p "$VERIFY_ENTITLEMENTS" \
  | rg '"com\.apple\.developer\.kernel\.increased-memory-limit" => true' >/dev/null
PACKAGED_NAME="$(plutil -extract CFBundleDisplayName raw "$VERIFY_WORK/Payload/SiteAgent.app/Info.plist")"
[[ "$PACKAGED_NAME" == "Website Commander" ]]

HASH="$(shasum -a 256 "$OUTPUT_IPA" | awk '{print $1}')"

echo "Built: $OUTPUT_IPA"
echo "Version: $VERSION ($BUILD)"
echo "Display name: $PACKAGED_NAME"
echo "Sideload unlock: $UNLOCKED"
echo "SHA-256: $HASH"
