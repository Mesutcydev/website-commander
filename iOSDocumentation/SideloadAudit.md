# Sideload Audit

**Recovered** from Claude CLI session `85d85935` (2026-08-15 18:18). Prompt: *"when app is sideloaded some functions are problematic make an audit"*.

Ground truth from the project config and the shipped sideload IPA (`Build/SiteAgent-2.0-build-1-correct6.ipa`, codesign verified) — its signed entitlements are exactly `extended-virtual-addressing` + `increased-memory-limit`, signature is **ad-hoc, no embedded profile**, so the real install goes through a re-sign (AltStore/Sideloadly/free account).

## Sideload audit — what breaks

| # | Sev | Function | What happens sideloaded | Evidence |
|---|-----|----------|------------------------|----------|
| 1 | **High** | Keychain secrets (GitHub, Copilot, LLM keys, deploy tokens) | Store build pins access group `<store-team>.uk.mesut.SiteAgent`; Sideload entitlements omit `keychain-access-groups` entirely → items land under the sideloader's team. All saved credentials from the store build are **invisible** → silent full logout. Same in reverse when they go back. No cross-team migration possible (OS wall). | `Production.entitlements`, `SideloadMemory.entitlements`, `Keychain.swift:79-93` |
| 2 | **High** | StoreKit / Super | Own Sideload config is fine: `SiteAgentSideloadUnlocked` unlocks Super and `checkPurchaseStatus` preserves it (`IAPManager.swift:293`). But if the **App Store IPA itself** is resigned/sideloaded, the marker is absent → products never load, purchases/restores always fail, and paying subscribers lose Super (no valid receipt for `Transaction.currentEntitlements`). Paywall degrades to an endless retry button. | `IAPManager.swift:11-17`, `ProPaywall.swift:548-554` |
| 3 | **Medium** | On-device MLX models | The two kernel memory entitlements in the IPA are stripped by free-account re-signing (not in free profiles) → jetsam headroom gone. Already mitigated hard: 20MB MLX cache, 32-token prefill chunks, 8K KV cap, RAM-tier gating. No runtime way to detect the stripped entitlement. | `MLXTextEngine.swift:21-40`, `OnDeviceCapability.swift` |
| 4 | Low | PCC / Apple Intelligence | Sideload config compiles out all Apple FM providers (`AgentEngine.swift:594-603`) — correctly absent. Dead code: `IntelligenceAvailability.entitlementMissing` is never produced anywhere. Sideloading the PCC-TestFlight build would strip `private-cloud-compute` and fail at runtime. | `IntelligenceProvider.swift:9,32` |
| 5 | Info | Build artifacts | `Build/*.ipa` are ad-hoc signed, not directly installable — the re-sign step is where #1 and #3 bite. | codesign on shipped IPA |

## Verified fine sideloaded

Local notifications, `beginBackgroundTask`, custom-scheme OAuth (`siteagent://` + GitHub/Copilot device flows), Sign in with Apple, AppIntents — no push, no widgets/extensions, no App Groups, no background modes. Keychain already falls back iCloud-sync → local gracefully (`Keychain.swift:49-63`).

## Fixes applied (2026-08-15)

1. **Paywall dead-end (#2) — DONE.** `ProPaywall.swift`: when `products.isEmpty` and there is no App Store receipt on disk (`Bundle.main.appStoreReceiptURL` missing → resigned/sideloaded App Store IPA), it now shows a terminal *"Purchases aren't available in this installation."* instead of an endless retry button. Genuine App Store/TestFlight builds (receipt present) keep the flaky-network retry. Restore Purchases stays available in the footer either way.
2. **Runtime entitlements check (new, goes beyond the audit) — DONE.** `OnDeviceCapability.swift`: added `hasIncreasedMemoryLimitEntitlement`, a `SecTaskCopyValueForEntitlement` ABI bridge (ported from OnDeviceLAS `CoreAIDebuggerServices.swift`) that reads the *running* signature, not the source `.entitlements`. The live `tier` now caps at `.pro` when the entitlement is absent, so a free-account re-sign that strips the memory entitlement no longer recommends `.max`-tier models it would OOM on. This is the runtime detection the audit said didn't exist for #3. Genuine builds (Production/PCC/Sideload entitlements all carry the key) are unaffected.
3. **Dead `entitlementMissing` case (#4) — DONE.** Removed from `IntelligenceProvider.swift` (declaration + description). Confirmed no producers anywhere in the repo.

### Not fixed (nothing to fix)
- **Keychain #1** — OS wall (cross-team keychain migration is impossible by design). The only option was a cosmetic Settings hint when the team prefix changes; skipped as not worth the surface area.
- **MLX #3 base mitigations** — already hard-mitigated (20MB cache, 32-token prefill, 8K KV, RAM gating); the new tier cap above is the incremental improvement.
