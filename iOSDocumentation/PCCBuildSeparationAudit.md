# PCC Build Separation Audit

This audit documents the current state of Apple Foundation Models and Private Cloud Compute (PCC) integration in the SiteAgent project prior to refactoring.

## 1. API and Symbol References

The following references to iOS 27-only Apple Foundation Models and Private Cloud Compute APIs were identified in the codebase:

### `PrivateCloudComputeLanguageModel`
- [AppleFoundationProvider.swift](file:///Users/m/Desktop/Projects/SiteAgent/SiteAgent/Providers/AppleFoundationProvider.swift#L10) - Comment reference.
- [AppleFoundationProvider.swift](file:///Users/m/Desktop/Projects/SiteAgent/SiteAgent/Providers/AppleFoundationProvider.swift#L38) - Comment reference.
- [AppleFoundationProvider.swift](file:///Users/m/Desktop/Projects/SiteAgent/SiteAgent/Providers/AppleFoundationProvider.swift#L105) - Instantiation in `ApplePrivateCloudProvider`.
- [AppleFoundationProvider.swift](file:///Users/m/Desktop/Projects/SiteAgent/SiteAgent/Providers/AppleFoundationProvider.swift#L149) - Availability check in `AppleAutoProvider`.
- [AppleFoundationProvider.swift](file:///Users/m/Desktop/Projects/SiteAgent/SiteAgent/Providers/AppleFoundationProvider.swift#L155) - Model usage in `AppleAutoProvider`.
- [AppleFoundationProvider.swift](file:///Users/m/Desktop/Projects/SiteAgent/SiteAgent/Providers/AppleFoundationProvider.swift#L171) - Fallback model usage in `AppleAutoProvider`.
- [AppleFoundationProvider.swift](file:///Users/m/Desktop/Projects/SiteAgent/SiteAgent/Providers/AppleFoundationProvider.swift#L339) - Availability checks in helper properties.
- [AppleFoundationProvider.swift](file:///Users/m/Desktop/Projects/SiteAgent/SiteAgent/Providers/AppleFoundationProvider.swift#L348) - Instantiation for quota evaluation.
- [AppleFoundationProvider.swift](file:///Users/m/Desktop/Projects/SiteAgent/SiteAgent/Providers/AppleFoundationProvider.swift#L380) - Instantiation for status evaluation.

### `FoundationModels` (Framework import)
- [AppleFoundationProvider.swift](file:///Users/m/Desktop/Projects/SiteAgent/SiteAgent/Providers/AppleFoundationProvider.swift#L2-L4) - Conditional framework import.
- [AppleFoundationProvider.swift](file:///Users/m/Desktop/Projects/SiteAgent/SiteAgent/Providers/AppleFoundationProvider.swift#L187) - Protected conditional block.
- [AppleFoundationProvider.swift](file:///Users/m/Desktop/Projects/SiteAgent/SiteAgent/Providers/AppleFoundationProvider.swift#L400) - Protected conditional block.

### `LanguageModelSession`
- [AppleFoundationProvider.swift](file:///Users/m/Desktop/Projects/SiteAgent/SiteAgent/Providers/AppleFoundationProvider.swift#L18) - Comment reference.
- [AppleFoundationProvider.swift](file:///Users/m/Desktop/Projects/SiteAgent/SiteAgent/Providers/AppleFoundationProvider.swift#L209) - Session initialization in runner.

### `ContextOptions` / `reasoningLevel`
- [AppleFoundationProvider.swift](file:///Users/m/Desktop/Projects/SiteAgent/SiteAgent/Providers/AppleFoundationProvider.swift#L11) - Comment reference.
- [AppleFoundationProvider.swift](file:///Users/m/Desktop/Projects/SiteAgent/SiteAgent/Providers/AppleFoundationProvider.swift#L38) - Comment reference.
- [AppleFoundationProvider.swift](file:///Users/m/Desktop/Projects/SiteAgent/SiteAgent/Providers/AppleFoundationProvider.swift#L201) - Parameter in runner run function.
- [AppleFoundationProvider.swift](file:///Users/m/Desktop/Projects/SiteAgent/SiteAgent/Providers/AppleFoundationProvider.swift#L210) - Initialization in runner.
- [AppleFoundationProvider.swift](file:///Users/m/Desktop/Projects/SiteAgent/SiteAgent/Providers/AppleFoundationProvider.swift#L403) - Helper method mapping strings to `ContextOptions.ReasoningLevel`.

### `quotaUsage`
- [AppleFoundationProvider.swift](file:///Users/m/Desktop/Projects/SiteAgent/SiteAgent/Providers/AppleFoundationProvider.swift#L350) - Read `status` to determine if below quota.
- [AppleFoundationProvider.swift](file:///Users/m/Desktop/Projects/SiteAgent/SiteAgent/Providers/AppleFoundationProvider.swift#L383) - Read `status` to format user-facing description.

### `com.apple.developer.private-cloud-compute` entitlement
- [SiteAgent.entitlements](file:///Users/m/Desktop/Projects/SiteAgent/SiteAgent/SiteAgent.entitlements#L9) - Present in active app entitlements.

---

## 2. PCC-Related Components and Files

- **Swift File:** [AppleFoundationProvider.swift](file:///Users/m/Desktop/Projects/SiteAgent/SiteAgent/Providers/AppleFoundationProvider.swift) holds all references.
- **Provider Enum / Config:** `AppleModelID` constants.
- **Entitlement File:** [SiteAgent.entitlements](file:///Users/m/Desktop/Projects/SiteAgent/SiteAgent/SiteAgent.entitlements) (contains `com.apple.developer.private-cloud-compute`).
- **Build Setting:** `SWIFT_ACTIVE_COMPILATION_CONDITIONS = APPLE_FM` defined on `AppleFM` configuration in `project.yml`.
- **UI / Settings / App Intent:** None. Apple models dynamically append themselves to the `availableProviders` list when compiled.

---

## 3. Project Configuration and Build Lane Audit

- **Deployment Target:** iOS 17.0, macOS 14.0 (Catalyst).
- **Swift Version:** 5.0.
- **Build Configurations:**
  - `Debug` (does not define compilation flag)
  - `Release` (does not define compilation flag)
  - `AppleFM` (defines `APPLE_FM` flag on app target)
- **Schemes:**
  - `SiteAgent` (uses Debug/Release)
  - `SiteAgent-AppleFM` (uses AppleFM config)
- **CODE_SIGN_ENTITLEMENTS:** `SiteAgent/SiteAgent.entitlements` (iOS), `SiteAgent/SiteAgent-Catalyst.entitlements` (Catalyst).
- **Target Membership:** Shared `SiteAgent` application target.

---

## 4. Xcode 27 Upgrade Analysis

The project does not use static `.xcodeproj` configuration but instead leverages **XcodeGen** (`project.yml`). Opening and building with Xcode 27 does not permanently upgrade the binary project files as they are regenerated from the YAML spec. This provides a highly clean build lane separation because the project layout is fully declarative.
