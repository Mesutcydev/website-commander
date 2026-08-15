# Apple Foundation Models + Private Cloud Compute — Setup

SiteAgent integrates Apple's on-device Foundation Model and Private Cloud Compute
(PCC) as two `LLMProvider`s. The integration is **gated behind the `APPLE_FM`
compile flag and the `AppleFM` build configuration**, so the app continues to
build and ship on the release Xcode (26.x) with zero impact — the Apple code is
only compiled when you build the `AppleFM` config with **Xcode 27**.

## What's in the app

| Provider | id | API | Availability |
|---|---|---|---|
| Apple On-Device | `apple-ondevice` | `SystemLanguageModel` / `LanguageModelSession` | iOS/macOS 27 |
| Apple Private Cloud | `apple-pcc` | `PrivateCloudComputeLanguageModel` | iOS/macOS 27 |

- They appear in the normal model picker when available (`AppleModels.onDeviceAvailable` / `privateCloudAvailable`).
- **Reasoning** (PCC): the picker's model entries `Automatic / Light / Moderate / Deep` map to `ContextOptions.ReasoningLevel` (Automatic → framework default).
- **Quota / availability** surfaced via `AppleModels.privateCloudStatus` (reads `PrivateCloudComputeLanguageModel.quotaUsage.status` → `.belowLimit` / `.limitReached`).
- **Free / unmetered**: both are in `AgentEngine.localProviderIDs`, so they don't consume the monthly free-remote-session budget and aren't blocked by the wall. *(Product toggle: add the two ids to `AgentEngine.proOnlyProviderIDs` to require Super instead.)*
- **No API key, no developer backend.** Code is `@available(iOS 27)`-gated; the app's iOS 17 floor is unaffected.

## Known limitation — tools

Apple models answer from the **conversation context in a single turn**; they do
**not** drive SiteAgent's multi-step tool loop (file reads/edits). The framework
owns its own `Tool` loop (compile-time `Arguments`) which can't bind to
SiteAgent's dynamic, runtime-defined tools without threading a tool executor
through `LLMProvider` — a larger refactor. So Apple models are ideal for their
positioned light tasks (commit messages, summaries, explanations, ASK with
attached context); multi-step editing stays on the tool-using providers
(Claude/Copilot/etc.). Upgrade path: pass an executor into `LLMProvider.stream`
and wrap each `ToolSpec` as a dynamic FoundationModels `Tool`.

## Building the Apple-Intelligence variant

```sh
# Release pipeline (unchanged) — release Xcode, no Apple FM:
xcodebuild -scheme SiteAgent -configuration Debug ...     # or Release
#   → builds on Xcode 26.x, Apple providers excluded.

# Apple-Intelligence variant — Xcode 27 + AppleFM config:
DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer \
  xcodebuild -scheme SiteAgent -configuration AppleFM ...
#   → APPLE_FM defined (scoped to the app target only, never to SwiftPM deps).
```

Both paths are verified to build (iphonesimulator). Use a **separate
`-derivedDataPath`** for the Xcode 27 build so SwiftPM artifacts don't clash with
the release Xcode's (swift-crypto fails to resolve if the two toolchains share
one DerivedData).

## Private Cloud Compute capability — nothing to add (verified)

I searched Xcode 27 beta's **authoritative** capability list
(`DVTPortal.framework/.../DVTPortalCachedPortalCapabilities.json`), the SDK, and
the framework. There is **no Private Cloud Compute client entitlement** for
third-party apps. The only Foundation-Models entitlement is
`com.apple.developer.foundation-model-adapter`, which is for **custom model
adapters** (request-gated via Apple) — NOT for using the built-in PCC model.

Conclusion: **no entitlement/plist key needs adding** to use
`PrivateCloudComputeLanguageModel`. PCC access is gated by your **account
approval** ("Access to models on Private Cloud Compute", which you have) +
device/OS eligibility, enforced at runtime — not by a client entitlement. The
code compiles and runs with the project's existing entitlements untouched.

A fabricated PCC key was deliberately **not** added — a wrong key would break
code signing (including the release pipeline) and there is no real key to use.

If a later Xcode 27 beta introduces a PCC capability, add it in **Xcode → Signing
& Capabilities** on the iOS (and, if used, Mac Catalyst) app target only, into a
**separate `SiteAgent-AppleFM.entitlements`** wired to the `AppleFM` config's
`CODE_SIGN_ENTITLEMENTS` — keep it out of the shared `SiteAgent.entitlements` so
release signing stays untouched. As of 27.0 (27A5194q), this step is not needed.

## Physical-device testing (not done here — requires your devices)

The simulator/headless build cannot exercise the models. On your iOS 27 / macOS 27
devices, verify: on-device availability + a response; PCC availability + a
response; each reasoning level; quota status display; offline → on-device;
quota-reached → graceful error; model attribution shows the actual model.

## Beta caveats

- Foundation Models beta API signatures can shift between Xcode 27 betas; the
  code is written against the SDK in `Xcode-beta.app` (27.0, 27A5194q). Re-verify
  on SDK updates.
- The App Store accepts release-SDK builds; the `AppleFM` variant ships once
  iOS 27 is GA (use TestFlight/development in the meantime).
