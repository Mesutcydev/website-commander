#!/usr/bin/env bash
# Build Website Commander for distribution WITHOUT an Apple Developer ID.
#
# Produces an ad-hoc-signed .app, bundles the `wc` CLI inside it, and packages
# both a .dmg and a .zip with SHA-256 checksums you can publish on your website.
# Because the build is ad-hoc (not notarized), recipients must bypass Gatekeeper
# once on first launch — see README "Distributing without a Developer ID".
#
# Usage:  ./Scripts/build-release.sh
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
BUILD="$ROOT/build"
DD="$BUILD/DD"
APP="$BUILD/WebsiteCommander.app"
ENTITLEMENTS="$ROOT/WebsiteCommander/Resources/WebsiteCommander.entitlements"
VERSION="$(grep -m1 'MARKETING_VERSION:' "$ROOT/project.yml" | sed -E 's/.*"([^"]+)".*/\1/')"
VERSION="${VERSION:-1.0.0}"

# Signing identity. Default "-" = ad-hoc (no Developer ID needed). When your
# account is reinstated, build with a real identity and, optionally, notarize:
#   SIGN_IDENTITY="Developer ID Application: Your Name (TEAM)" NOTARIZE=1 \
#   APPLE_ID=you@me.com APP_PASSWORD=xxxx-xxxx-xxxx-xxxx TEAM=TEAMID \
#   ./Scripts/build-release.sh
# Checksums are PGP-signed automatically if `gpg`/`gpg2` is on PATH.
SIGN_IDENTITY="${SIGN_IDENTITY:--}"

echo "==> Generating Xcode project"
xcodegen generate >/dev/null

echo "==> Building app + CLI (Release, ad-hoc signed)"
ADHOC=(CODE_SIGN_IDENTITY="$SIGN_IDENTITY" CODE_SIGNING_REQUIRED=YES CODE_SIGNING_ALLOWED=YES \
       CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM=)
xcodebuild -project WebsiteCommander.xcodeproj -scheme WebsiteCommander \
  -configuration Release -derivedDataPath "$DD" -destination 'platform=macOS' \
  "${ADHOC[@]}" build >/dev/null
xcodebuild -project WebsiteCommander.xcodeproj -scheme wc \
  -configuration Release -derivedDataPath "$DD" -destination 'platform=macOS' \
  "${ADHOC[@]}" build >/dev/null

SRC_APP="$(find "$DD/Build/Products/Release" -maxdepth 1 -name 'WebsiteCommander.app' | head -1)"
WC_BIN="$(find "$DD/Build/Products/Release" -maxdepth 1 -name 'wc' -type f | head -1)"
[ -n "$SRC_APP" ] || { echo "app build not found"; exit 1; }
[ -n "$WC_BIN" ]  || { echo "wc build not found"; exit 1; }

echo "==> Assembling distributable bundle"
rm -rf "$APP"
cp -R "$SRC_APP" "$APP"
mkdir -p "$APP/Contents/SharedSupport"
cp "$WC_BIN" "$APP/Contents/SharedSupport/wc"

echo "==> Signing (recursive; identity: $SIGN_IDENTITY)"
# Ad-hoc ("-") cannot use a timestamp server; real identities should.
if [ "$SIGN_IDENTITY" = "-" ]; then TS=(--timestamp=none); else TS=(); fi
codesign --force --deep --sign "$SIGN_IDENTITY" --entitlements "$ENTITLEMENTS" "${TS[@]}" "$APP"
codesign --verify --verbose=2 "$APP"

# Optional notarization (only meaningful with a real Developer ID). Done BEFORE
# packaging so the stapled ticket is baked into the app inside the .dmg/.zip.
if [ "${NOTARIZE:-0}" = "1" ]; then
  if [ "$SIGN_IDENTITY" = "-" ]; then echo "NOTARIZE=1 needs a real SIGN_IDENTITY"; exit 1; fi
  for v in APPLE_ID APP_PASSWORD TEAM; do
    eval "val=\$$v"; [ -n "$val" ] || { echo "NOTARIZE=1 requires $v"; exit 1; }
  done
  echo "==> Notarizing (this can take a few minutes)"
  xcrun notarytool submit "$APP" --apple-id "$APPLE_ID" --password "$APP_PASSWORD" \
    --team-id "$TEAM" --wait
  xcrun stapler staple "$APP"
fi

echo "==> Packaging .dmg and .zip"
DMG="$BUILD/WebsiteCommander-$VERSION.dmg"
ZIP="$BUILD/WebsiteCommander-$VERSION.zip"
rm -f "$DMG" "$ZIP"
# hdiutil mis-parses absolute -srcfolder paths that contain spaces, so package
# from inside the build dir using relative names.
(
  cd "$BUILD"
  hdiutil create -volname "Website Commander" -srcfolder WebsiteCommander.app \
    -ov -format UDZO "WebsiteCommander-$VERSION.dmg" >/dev/null
  codesign --force --sign "$SIGN_IDENTITY" "${TS[@]}" "WebsiteCommander-$VERSION.dmg"
  ditto -c -k --sequesterRsrc --keepParent WebsiteCommander.app "WebsiteCommander-$VERSION.zip"
)

echo "==> Checksums (publish these on your website)"
shasum -a 256 "$DMG" "$ZIP" | tee "$BUILD/SHA256SUMS.txt"

# If GPG is available, detached-sign the checksum file so users can verify the
# download came from you (independent of codesign / notarization). Uses your
# default secret key; override with GPG_KEY="name-or-id".
GPG_BIN="$(command -v gpg2 || command -v gpg || true)"
if [ -n "$GPG_BIN" ]; then
  HAS_SECRET_KEY=0
  if [ -n "${GPG_KEY:-}" ]; then
    HAS_SECRET_KEY=1
  else
    if "$GPG_BIN" --batch --list-secret-keys --with-colons 2>/dev/null \
      | awk -F: '$1 == "sec" { found = 1 } END { exit !found }'; then
      HAS_SECRET_KEY=1
    fi
  fi
  if [ "$HAS_SECRET_KEY" = "1" ]; then
    echo "==> PGP-signing checksums with ${GPG_KEY:-default key}"
    if [ -n "${GPG_KEY:-}" ]; then
      "$GPG_BIN" --batch --yes --local-user "$GPG_KEY" --armor --detach-sign "$BUILD/SHA256SUMS.txt"
    else
      "$GPG_BIN" --batch --yes --armor --detach-sign "$BUILD/SHA256SUMS.txt"
    fi
    echo "    -> $BUILD/SHA256SUMS.txt.asc"
  else
    echo "==> No GPG secret key available; skipping optional PGP signature"
  fi
fi

NOTARIZED_NOTE="(ad-hoc; not notarized)"
[ "${NOTARIZE:-0}" = "1" ] && NOTARIZED_NOTE="(notarized + stapled)"

cat <<EOF

Done. Distribute from your website $NOTARIZED_NOTE:
  $DMG
  $ZIP
  $BUILD/SHA256SUMS.txt$([ -f "$BUILD/SHA256SUMS.txt.asc" ] && echo "  (+ .asc PGP signature)" || true)

First-launch note for users (Gatekeeper, expected for ad-hoc builds):
  Right-click the app -> Open -> Open, OR run once in Terminal:
    xattr -cr /Applications/WebsiteCommander.app
  To put the CLI on PATH:
    ln -sf "/Applications/WebsiteCommander.app/Contents/SharedSupport/wc" /usr/local/bin/wc
EOF
