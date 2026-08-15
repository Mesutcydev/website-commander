# PCC Release Method — single branch, config-gated

Supersedes the old two-branch "strip & restore" guide (`PCC_Revert_Guide.md`).
That approach kept a PCC-stripped `master` and a PCC-bearing `pcc-development`
in sync by hand — 19 divergent files / ~1200 lines that drift and make every
general bug-fix a double-apply. It is **retired**.

## Principle

**One branch. The App Store build and the PCC TestFlight build differ only by
build *configuration* — never by source files or branch.**

Apple reviews the compiled **binary + entitlements**, not your source tree. So
`#if APPLE_FM` compile-gating plus a clean entitlements file is sufficient to keep
Private Cloud Compute out of the App Store binary. Deleting source files buys
nothing for review and costs you branch drift.

## How the separation works

| | App Store (`AppStore` / `Release`) | PCC TestFlight (`PCC-TestFlight`) |
|---|---|---|
| Compile flags | `APPSTORE_BUILD` (no `APPLE_FM`) | `APPLE_FM` `IOS27_PCC_EXPERIMENTAL` `PCC_TESTFLIGHT_BUILD` |
| Entitlements | `SiteAgent/Production.entitlements` (no PCC key) | `SiteAgent/PCC.entitlements` (`com.apple.developer.private-cloud-compute`) |
| PCC code (`AppleFoundationProvider.swift`, all `PrivateCloudComputeLanguageModel` refs) | compiled out by `#if APPLE_FM` → **0 symbols** | compiled in |
| Deployment target | iOS 17 | iOS 17 (PCC APIs are runtime `@available(iOS 27)`-gated) |
| Xcode | 26.x or newer | **27+ required** (FoundationModels iOS 27 SDK) |

Because all PCC API use is behind `if #available(iOS 27, *)`, the iOS 17 floor is
preserved in both configs — the App Store build installs on every supported
device, and the verify gate expects MinimumOSVersion `17.0`.

## The invariant (safety net)

Every App Store upload MUST pass:

```bash
./Scripts/verify-app-store-build.sh Build/SiteAgent.xcarchive/Products/Applications/SiteAgent.app
```

It fails the release if the binary carries the PCC entitlement, any
`PrivateCloudComputeLanguageModel` symbol, or a raised deployment target. This
gate is what makes a single branch safe: it *proves* the binary is clean instead
of trusting that files were deleted.

## Release commands

App ID: `6780267869`. Build numbers follow `2026MMDDNN` (NN per upload that day);
App Store and PCC uploads need **distinct** build numbers under the same
marketing version.

### App Store (clean) — buildable on Xcode 26.x

```bash
# 1. bump CURRENT_PROJECT_VERSION in project.yml, then:
xcodegen generate
xcodebuild -project SiteAgent.xcodeproj -scheme SiteAgent -configuration AppStore \
  -destination 'generic/platform=iOS' clean archive -archivePath Build/SiteAgent.xcarchive
# 2. GATE — must pass before upload:
./Scripts/verify-app-store-build.sh Build/SiteAgent.xcarchive/Products/Applications/SiteAgent.app
# 3. export + upload:
/Users/m/.blitz/bin/asc xcode export --archive-path Build/SiteAgent.xcarchive \
  --export-options .asc/ExportOptions-ipa.plist --ipa-path Build/SiteAgent.ipa
/Users/m/.blitz/bin/asc publish testflight --app 6780267869 --ipa Build/SiteAgent.ipa --group "Mesut Can" --wait
```

### PCC TestFlight — REQUIRES Xcode 27

```bash
# bump CURRENT_PROJECT_VERSION again (distinct build number), then:
xcodegen generate
xcodebuild -project SiteAgent.xcodeproj -scheme SiteAgent-PCC -configuration PCC-TestFlight \
  -destination 'generic/platform=iOS' clean archive -archivePath Build/SiteAgent-PCC.xcarchive
/Users/m/.blitz/bin/asc xcode export --archive-path Build/SiteAgent-PCC.xcarchive \
  --export-options .asc/ExportOptions-ipa.plist --ipa-path Build/SiteAgent-PCC.ipa
/Users/m/.blitz/bin/asc publish testflight --app 6780267869 --ipa Build/SiteAgent-PCC.ipa --group "<beta group>" --wait
```

The PCC archive cannot be built on Xcode 26.x — the `LanguageModel` /
`ContextOptions` / `PrivateCloudComputeLanguageModel` types only exist in the
iOS 27 FoundationModels SDK.

## Branch consolidation

`master` (PCC-stripped) is obsolete. Develop and release everything from a single
branch; the config matrix + verify gate above replace the strip/restore dance.
