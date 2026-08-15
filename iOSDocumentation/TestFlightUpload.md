# TestFlight upload (Mac)

The cloud agent runs on Linux and **cannot** archive or upload iOS builds.
Use this on your Mac (Golden Gate) where Xcode 26 + Xcode 27 beta are installed.

## One-time setup

```bash
cd /path/to/SiteAgent
cp Configuration/Developer.xcconfig.example Configuration/Developer.xcconfig
# Edit DEVELOPMENT_TEAM = YOURTEAMID

# App Store Connect API key (from Downloads):
ls ~/Downloads/AuthKey_*.p8
# Issuer ID: https://appstoreconnect.apple.com/access/integrations/api
export ASC_KEY_ID=XXXXXXXXXX          # from AuthKey_XXXXXXXXXX.p8 filename
export ASC_ISSUER_ID=xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx

# Optional: write issuer next to the key so the script finds it next time
echo "$ASC_ISSUER_ID" > ~/Downloads/AuthKey_${ASC_KEY_ID}.issuer

brew install xcodegen
```

On Golden Gate, **Xcode 26 is in Downloads** and **Xcode 27 beta is on the
Desktop**. Finder may show Xcode 26 as “incompatible” — launch via
`DEVELOPER_DIR` (the upload script does this for you):

```bash
export DEVELOPER_DIR="$HOME/Downloads/Xcode.app/Contents/Developer"
xcodebuild -version
```

### Metal Toolchain (required for mlx-swift)

Xcode 26 ships Metal as an optional component. Without it, archive fails at
`CompileMetalFile` inside `mlx-swift_Cmlx` (`random.metal`, `rope.metal`, …).

The release script installs/registers Metal automatically. If it still fails,
run these lines one at a time (do not paste comment lines into the shell):

```bash
export DEVELOPER_DIR="$HOME/Downloads/Xcode.app/Contents/Developer"
xcodebuild -downloadComponent MetalToolchain
xcrun metal -help
```

Or open Xcode → Settings → Components → Metal Toolchain.

If `xcrun metal -help` still says “missing Metal Toolchain”, re-run
`./Scripts/release-build-siteagent.sh` — it applies Apple’s export → patch
`buildUpdateVersion` → import workaround.

## Upload (recommended — same flow as CoreAIStudio)

App Store: archive + upload with Xcode 26. PCC: archive with Xcode 27 beta,
upload with Xcode 26 + your `.p8`.

```bash
cd /Users/air/SiteAgent
git checkout cursor/security-remediation-c7e1 && git pull

BUILD_NUMBER=2026070907 ./Scripts/release-build-siteagent.sh
# optional PCC (use a different BUILD_NUMBER):
# BUILD_NUMBER=2026070908 ./Scripts/release-build-siteagent.sh --pcc
```

Defaults: marketing **1.11** (must be > last approved App Store version **1.10**),
`AuthKey_B7AYY3B2FT.p8`, team `PUH4GMFV56`, Xcode 26 at `~/Downloads/Xcode.app`,
beta at `~/Desktop/Xcode-beta.app`. Override with `MARKETING_VERSION`,
`RELEASE_XCODE` / `BETA_XCODE` if needed.

### What's New (TestFlight “What to Test”)

Edit `Documentation/WhatsNew.txt` before uploading. The release script attaches it
to the build after export via App Store Connect API. To re-attach later:

```bash
./Scripts/set-testflight-whatsnew.sh --build 2026070908 --notes Documentation/WhatsNew.txt
```

## Alternate: upload-testflight.sh (Xcode 26 only)

```bash
./Scripts/upload-testflight.sh --key ~/Downloads/AuthKey_${ASC_KEY_ID}.p8
```

This:
1. Runs `xcodegen generate`
2. Archives `-configuration AppStore`
3. Runs `./Scripts/verify-app-store-build.sh` (PCC leakage gate)
4. Exports IPA + uploads to TestFlight (app id `6780267869`)

## Upload PCC TestFlight build (Xcode 27 beta)

```bash
./Scripts/upload-testflight.sh --pcc --key ~/Downloads/AuthKey_${ASC_KEY_ID}.p8
```

Bump `CURRENT_PROJECT_VERSION` in `project.yml` between App Store and PCC uploads
(they must be distinct under the same marketing version).

## Pin SPM lockfile (after first successful resolve)

```bash
export DEVELOPER_DIR="$HOME/Downloads/Xcode.app/Contents/Developer"
xcodegen generate
xcodebuild -resolvePackageDependencies -project SiteAgent.xcodeproj -scheme SiteAgent
git add Package.resolved
git commit -m "Pin SPM dependencies"
```

## Build numbers

`project.yml` → `CURRENT_PROJECT_VERSION` uses `2026MMDDNN`. Current ship build:
**1.11 (2026071102)** — Clear Glass surface style (authentic iOS 26 Liquid Glass).
Build 2026071101 (tinted-glass variant) is superseded; ignore it in TestFlight.
(ASC rejected 1.7 because 1.10 is already approved.)
On this Mac the ASC key lives at `~/.blitz/asc-agent/AuthKey_BlitzKey.p8`
(`ASC_KEY_ID=6BYCN78KB9`); pass `KEY_PATH`/`ASC_KEY_ID` to the release script.
Detach long release runs with `nohup … &` (macOS has no `setsid`; a harness
timeout otherwise kills the upload mid-flight).
See also `Documentation/AfterAuditsAudit.md` for the post-remediation audit (all in-repo AA items fixed).
