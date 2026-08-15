# PCC Production Enablement Checklist

Use this checklist to verify readiness before enabling the Private Cloud Compute (PCC) feature in the production App Store build.

## Pre-Flight Requirements

- [ ] **Apple Platform Eligibility:** Apple officially permits Xcode 27 App Store submissions for production.
- [ ] **Entitlement Approval:** The `com.apple.developer.private-cloud-compute` entitlement is active and matches the production App ID.
- [ ] **Provisioning Profiles:** The App Store Distribution provisioning profile is updated on developer.apple.com to include the PCC entitlement.
- [ ] **Archive Verification:** The production build compiles cleanly and passes `./Scripts/verify-app-store-build.sh` (once updated to allow the entitlement).

## App Store Submission Readiness

- [ ] **App Review Access:** Ensure App Review can access and test the feature in their sandbox environment.
- [ ] **App Store Metadata:** The description and what's new fields reflect the addition of Apple Intelligence / PCC.
- [ ] **Privacy Policy & Nutrition Labels:** Privacy Policy answers on App Store Connect and in the policy document are updated to declare prompt handling on Apple's Private Cloud Compute.

## Rollback Readiness

- [ ] **Operational Switch:** Verify that disabling the `IOS27_PCC_PRODUCTION` compilation condition cleanly rolls back the app to the stable on-device fallback with zero crashes.
- [ ] **TestFlight Regression:** Run full TestFlight regression testing on a mix of iOS 17, iOS 18, and iOS 27 devices.

---

## App Review Notes Template (Future Use)

Include the following text in the "App Review Notes" section of App Store Connect when submitting the first build containing the active PCC integration:

```text
Apple Private Cloud Compute integration

This version includes an optional Apple Foundation Models Private Cloud Compute provider. The integration uses Apple’s public Foundation Models framework and the approved com.apple.developer.private-cloud-compute entitlement.

Access steps:
1. Launch the app.
2. Go to Settings -> Active Provider.
3. Select "Apple Private Cloud — Beta".
4. Choose any reasoning level (Automatic, Light, Moderate, or Deep).
5. Enter a prompt in the chat input and send it.

Requirements:
- iOS 27 or later
- Apple Intelligence-supported device
- Apple Intelligence available and enabled
- Network connectivity
- Available per-user PCC quota

When PCC is unavailable (e.g. offline or over quota), the app displays the specific availability state and automatically offers the standard local On-Device fallback model. The app does not send any user content to PCC unless the user explicitly selects or invokes the relevant Apple Intelligence features.

There is no reviewer-specific, account-specific, date-based, or hidden activation behavior.
```
