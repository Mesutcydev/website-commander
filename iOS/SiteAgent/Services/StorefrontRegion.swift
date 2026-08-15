import StoreKit

/// Which App Store storefront the user's Apple ID is on — the signal Apple cares
/// about for region-specific compliance (NOT device locale).
enum StorefrontRegion {
    /// ISO 3166-1 alpha-3 storefront code (e.g. "CHN", "USA"). Synchronous
    /// best-effort read; nil only in the brief window before StoreKit populates
    /// it right after launch.
    // ponytail: SKPaymentQueue is the synchronous source; StoreKit 2's
    // Storefront.current is async and would force the provider list to be async.
    static var countryCode: String? {
        SKPaymentQueue.default().storefront?.countryCode
    }

    /// China mainland storefront. Per App Store Guideline 5 (Legal), ChatGPT/
    /// OpenAI generative-AI functionality needs an MIIT permit we don't hold, so
    /// the OpenAI provider is suppressed here. Defaults to false when unknown.
    static var isChinaMainland: Bool { countryCode == "CHN" }
}
