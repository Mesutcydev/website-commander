import StoreKit
import SwiftUI

@MainActor
class IAPManager: ObservableObject {
    static let shared = IAPManager()

    /// Private testing and explicitly marked sideload builds include Super for
    /// the lifetime of the installed build. App Store builds omit the marker
    /// and still require a verified StoreKit entitlement.
    private static var includesBundledProEntitlement: Bool {
        #if PCC_SUPER_UNLOCKED || PCC_TESTFLIGHT_BUILD
        true
        #else
        Bundle.main.object(forInfoDictionaryKey: "SiteAgentSideloadUnlocked") as? Bool == true
        #endif
    }

    enum ProductID {
        // monthly/yearly are auto-renewable subscriptions (the `pro.monthly` id was
        // permanently burned by a mis-typed consumable, so the subs use `sub.*`).
        static let monthly = "uk.mesut.SiteAgent.sub.monthly"
        static let yearly = "uk.mesut.SiteAgent.sub.yearly"
        static let lifetime = "uk.mesut.SiteAgent.pro.lifetime"
    }

    /// The single user-facing name for the paid tier. Internally the entitlement
    /// is `isPro` and the SKUs are `…pro.*`, but users only ever see "Super".
    /// Route any user-visible mention of the tier through this so the brand can't
    /// diverge again (the docs once said "Pro", the app said "Super").
    static let tierDisplayName = "Super"

    /// Free remote agent sessions granted per calendar month.
    static let freeSessionLimit = 8
    
    @Published var products: [Product] = []
    @Published private(set) var isLoadingProducts = false
    @Published var lastPurchaseError: String?
    // private(set): entitlement is mutated only by StoreKit verification inside
    // this class — no view can flip a user to Super.
    @Published private(set) var isPro: Bool = IAPManager.includesBundledProEntitlement {
        didSet {
            // Upgrading resolves every conversion nudge — clear them so an
            // upgraded user never gets "your trial ends" / "free builds back".
            if isPro && !oldValue { NotificationManager.cancel(NotificationManager.Nudge.all) }
        }
    }
    /// Which SKU currently grants entitlement (nil = free). Lets us offer monthly
    /// subscribers the cheaper yearly switch.
    @Published private(set) var activeProductID: String? = nil
    var isMonthlySubscriber: Bool { activeProductID == ProductID.monthly }
    private var updatesTask: Task<Void, Never>? = nil
    
    @AppStorage("freeSessionsUsedThisMonth") var freeSessionsUsedThisMonth: Int = 0
    @AppStorage("lastSessionUsageResetDate") var lastSessionUsageResetDate: Double = Date().timeIntervalSince1970
    
    #if DEBUG
    @AppStorage("mockProEntitlement") var mockProEntitlement: Bool = false
    #endif
    
    let productIDs = [ProductID.monthly, ProductID.yearly, ProductID.lifetime]
    
    #if DEBUG
    /// Debug-only: simulate a successful purchase when StoreKit has no products
    /// loaded (previews / missing StoreKit config). Compiled out of release, so
    /// the entitlement still can't be flipped from outside in shipping builds.
    func grantMockProForDebug() {
        mockProEntitlement = true
        isPro = true
    }
    
    func toggleMockProForDebug() {
        mockProEntitlement.toggle()
        isPro = mockProEntitlement
    }
    
    func setProForDebug(_ pro: Bool) {
        mockProEntitlement = pro
        isPro = pro
    }
    #endif

    func product(for id: String) -> Product? {
        products.first { $0.id == id }
    }

    func checkAndResetMonthlySessions() {
        let now = Date()
        let lastReset = Date(timeIntervalSince1970: lastSessionUsageResetDate)
        if let monthDifference = Calendar.current.dateComponents([.month], from: lastReset, to: now).month, monthDifference >= 1 {
            freeSessionsUsedThisMonth = 0
            lastSessionUsageResetDate = now.timeIntervalSince1970
        }
    }
    
    var canRunAgentLoop: Bool {
        if isPro { return true }
        checkAndResetMonthlySessions()
        return freeSessionsUsedThisMonth < Self.freeSessionLimit
    }

    /// Free remote sessions left this month (0 when at the wall). Resets lazily.
    var freeSessionsRemaining: Int {
        checkAndResetMonthlySessions()
        return max(0, Self.freeSessionLimit - freeSessionsUsedThisMonth)
    }

    /// When the monthly free-session allowance next refills — surfaced at the wall
    /// so "limit reached" reads as "resets on <date>", not a permanent dead end.
    var freeSessionsResetDate: Date {
        let last = Date(timeIntervalSince1970: lastSessionUsageResetDate)
        return Calendar.current.date(byAdding: .month, value: 1, to: last) ?? last
    }
    
    func incrementSessionUsage() {
        guard !isPro else { return }
        checkAndResetMonthlySessions()
        freeSessionsUsedThisMonth += 1
        if freeSessionsUsedThisMonth >= Self.freeSessionLimit {
            // Hit the wall — invite them back the day the allowance refills.
            NotificationManager.schedule(
                id: NotificationManager.Nudge.monthlyReset,
                title: "Your free builds are back",
                body: "\(Self.freeSessionLimit) new agent runs are ready. What will you ship today?",
                at: freeSessionsResetDate)
        }
    }

    // MARK: - On-Device free trial
    //
    // Local models are free to try for 3 days from first real use, then require
    // Super (lifetime or subscription). The clock starts the first time a local
    // generation actually runs (stamped by OnDeviceProvider), not when the
    // feature is merely browsed.

    @AppStorage("onDeviceTrialStart") var onDeviceTrialStart: Double = 0
    private let onDeviceTrialDays: Double = 3

    func beginOnDeviceTrialIfNeeded() {
        if onDeviceTrialStart == 0 {
            onDeviceTrialStart = Date().timeIntervalSince1970
            // Remind them ~24h before the trial lapses, while it's still useful.
            let warnAt = Date(timeIntervalSince1970: onDeviceTrialStart + (onDeviceTrialDays - 1) * 86_400)
            NotificationManager.schedule(
                id: NotificationManager.Nudge.trialEnding,
                title: "Your on-device trial ends tomorrow",
                body: "Keep running AI privately on your device — unlock Super to continue.",
                at: warnAt)
        }
    }

    /// True while the trial hasn't started yet, or is still within its window.
    var onDeviceTrialActive: Bool {
        guard onDeviceTrialStart > 0 else { return true }
        let elapsedDays = (Date().timeIntervalSince1970 - onDeviceTrialStart) / 86_400
        return elapsedDays < onDeviceTrialDays
    }

    var onDeviceTrialDaysRemaining: Int {
        guard onDeviceTrialStart > 0 else { return Int(onDeviceTrialDays) }
        let elapsedDays = (Date().timeIntervalSince1970 - onDeviceTrialStart) / 86_400
        return max(0, Int(ceil(onDeviceTrialDays - elapsedDays)))
    }

    /// On-device is usable when the user is Super or still within the free trial.
    var canUseOnDevice: Bool { isPro || onDeviceTrialActive }

    private init() {
        // Start listening to transaction updates as early as possible.
        updatesTask = Task { [weak self] in
            for await result in Transaction.updates {
                guard let self = self else { return }
                if case .verified(let transaction) = result {
                    await transaction.finish()
                    await self.checkPurchaseStatus()
                }
            }
        }
        
        // Run verification on start
        Task {
            await loadProducts()
            await checkPurchaseStatus()
        }
    }
    
    func loadProducts() async {
        isLoadingProducts = true
        defer { isLoadingProducts = false }
        do {
            products = try await Product.products(for: productIDs)
            lastPurchaseError = nil
        } catch {
            lastPurchaseError = "Purchases could not be loaded. Check your network connection and try again."
            #if DEBUG
            print("Product loading failed:", error)
            #endif
        }
    }
    
    @discardableResult
    func purchase(_ product: Product) async -> Bool {
        lastPurchaseError = nil
        do {
            let result = try await product.purchase()
            switch result {
            case .success(let verification):
                switch verification {
                case .verified(let transaction):
                    // Finish transaction first
                    await transaction.finish()
                    
                    // Immediately grant Super entitlement if this is a Super product
                    if productIDs.contains(transaction.productID) {
                        self.isPro = true
                    }
                    
                    await checkPurchaseStatus()
                    Haptics.success()
                    return true
                case .unverified(let transaction, let error):
                    #if DEBUG
                    print("Transaction unverified:", error)
                    #endif
                    lastPurchaseError = "Apple could not verify this purchase. Please try again or restore purchases."
                    // Always finish the transaction even if verification fails, but don't grant Super
                    await transaction.finish()
                    Haptics.error()
                    return false
                }
            case .userCancelled:
                #if DEBUG
                print("Purchase cancelled by user.")
                #endif
                return false
            case .pending:
                #if DEBUG
                print("Purchase pending approval.")
                #endif
                lastPurchaseError = "Purchase is pending approval. Website Commander Super will unlock automatically after Apple approves it."
                return false
            @unknown default:
                lastPurchaseError = "The purchase did not complete. Please try again."
                return false
            }
        } catch {
            Haptics.error()
            lastPurchaseError = "Purchase failed: \(error.localizedDescription)"
            #if DEBUG
            print("Purchase failed:", error.localizedDescription)
            #endif
            return false
        }
    }
    
    @discardableResult
    func restorePurchases() async -> Bool {
        lastPurchaseError = nil
        do {
            try await AppStore.sync()
            await checkPurchaseStatus()
            if isPro {
                Haptics.success()
                return true
            } else {
                lastPurchaseError = "No active Website Commander Super purchase was found for this Apple ID."
                Haptics.error()
                return false
            }
        } catch {
            Haptics.error()
            lastPurchaseError = "Restore failed: \(error.localizedDescription)"
            #if DEBUG
            print("Restore failed:", error.localizedDescription)
            #endif
            return false
        }
    }
    
    func checkPurchaseStatus() async {
        var activeIDs: Set<String> = []
        for await result in Transaction.currentEntitlements {
            if case .verified(let transaction) = result {
                if productIDs.contains(transaction.productID) && transaction.revocationDate == nil {
                    activeIDs.insert(transaction.productID)
                }
            }
        }
        // currentEntitlements has no stable order; a user can hold lifetime AND a
        // lingering monthly at once. Pick by precedence so a lifetime owner is
        // never mistaken for a monthly subscriber (which would upsell them a sub).
        self.activeProductID = [ProductID.lifetime, ProductID.yearly, ProductID.monthly]
            .first(where: activeIDs.contains)
        // A StoreKit refresh must never revoke the entitlement bundled into the
        // PCC testing variant. This is compile-time scoped; no UDID or persisted
        // device identifier is needed.
        self.isPro = Self.includesBundledProEntitlement || !activeIDs.isEmpty
        
        #if DEBUG
        if mockProEntitlement {
            self.isPro = true
            return
        }
        // Default to true in simulator/debug if there are no mock purchases yet,
        // but allow testing the real purchase flow if a StoreKit config is active.
        if products.isEmpty && activeIDs.isEmpty {
            self.isPro = true
        }
        #endif
    }
}
