# PCC Release Process

This document describes how to archive and verify production App Store builds and PCC TestFlight builds.

## 1. Archiving the Production App Store Build

Production builds must be built with **stable Xcode 26** and the shipping stable iOS SDK.

1. Select **Xcode 26** in your developer environment:
   ```sh
   sudo xcode-select -s /Applications/Xcode.app/Contents/Developer
   ```
2. Clean and archive using the default **SiteAgent** scheme under the **Release** (or **AppStore**) configuration:
   ```sh
   xcodebuild -scheme SiteAgent -configuration Release -archivePath Build/SiteAgent.xcarchive archive
   ```
3. This configuration resolves `CODE_SIGN_ENTITLEMENTS` to `SiteAgent/Production.entitlements` (excluding the PCC entitlement) and does **not** compile the `IOS27_PCC_EXPERIMENTAL` condition.

---

## 2. Archiving the PCC TestFlight Build

PCC TestFlight builds require the **Xcode 27 beta** and the iOS 27 beta SDK.

1. Select **Xcode 27 beta** in your developer environment:
   ```sh
   sudo xcode-select -s /Applications/Xcode-beta.app/Contents/Developer
   ```
2. Clean and archive using the **SiteAgent-PCC** scheme under the **PCC-TestFlight** configuration:
   ```sh
   xcodebuild -scheme SiteAgent-PCC -configuration PCC-TestFlight -archivePath Build/SiteAgent-PCC.xcarchive archive
   ```
3. This configuration resolves `CODE_SIGN_ENTITLEMENTS` to `SiteAgent/PCC.entitlements` (including the `com.apple.developer.private-cloud-compute` entitlement) and compiles the PCC models via `IOS27_PCC_EXPERIMENTAL`.

---

## 3. Running the Archive Verification Script

Before submitting the production App Store archive, run the verification script to ensure no PCC leakage occurs:

```sh
./Scripts/verify-app-store-build.sh Build/SiteAgent.xcarchive/Products/Applications/SiteAgent.app
```

The script will fail with a non-zero exit code if:
- `IOS27_PCC_EXPERIMENTAL` compilation flag is detected.
- The signed app bundle contains the `com.apple.developer.private-cloud-compute` entitlement.
- The executable contains any binary string references to `PrivateCloudComputeLanguageModel`.
- The minimum deployment target was raised above `17.0`.

---

## 4. Xcode simulated availability/quota testing

During development using the `Debug-PCC` configuration with Xcode 27, you can simulate different Apple Foundation Model and Private Cloud Compute availability/quota states:

- Set environment variables or runtime overrides to toggle Xcode's local simulation of `SystemLanguageModel` downloading and PCC quota limits.
- The UI will dynamically display approaching limit warnings or completely disable query buttons based on the mocked `PrivateCloudComputeFeatureGate` states.

---

## 5. Enable PCC for Production in the Future

Once Apple officially accepts Xcode 27 builds for production App Store distribution:

1. Add the approved PCC entitlement to the production entitlements.
2. Define a deliberate production compilation flag (e.g., `IOS27_PCC_PRODUCTION`).
3. Add the flag to `AppStore.xcconfig`:
   ```make
   SWIFT_ACTIVE_COMPILATION_CONDITIONS = $(inherited) APPSTORE_BUILD IOS27_PCC_PRODUCTION
   ```
4. Update the archive validation script to permit the entitlement only when the production release flag is active.
