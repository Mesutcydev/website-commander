import SwiftUI
import StoreKit

/// Why the paywall was shown — lets the header echo the exact thing the user
/// reached for ("you're out of builds", "unlock every model"), which converts
/// far better than one generic pitch.
enum PaywallContext {
    case general, wall, onDevice, inspector, premiumModel, firstShip, switchToYearly

    var headline: String {
        switch self {
        case .general:        return "Unlock Website Commander Super".localized
        case .wall:           return "You're out of free builds".localized
        case .onDevice:       return "Keep AI on your device".localized
        case .inspector:      return "Debug live sites with AI".localized
        case .premiumModel:   return "Unlock every top AI model".localized
        case .firstShip:      return "Nice ship — go unlimited".localized
        case .switchToYearly: return "Switch to Yearly & save".localized
        }
    }

    var subheadline: String {
        switch self {
        case .general:
            return "Connect any static or headless site. Write in plain English, review side-by-side diffs, verify deploys go live, and undo any commit in a tap.".localized
        case .wall:
            return "You've used all your free changes this month. Go Super for unlimited builds, every top model, and live debugging.".localized
        case .onDevice:
            return "Run AI privately on-device — offline, unlimited, no API keys. Super keeps it going after your trial.".localized
        case .inspector:
            return "Inspect console, network and elements, then let the agent fix bugs on your live site. Included with Super.".localized
        case .premiumModel:
            return "Free uses GitHub Copilot only. Super auto-picks the best model — Claude, Gemini and more — for every task.".localized
        case .firstShip:
            return "You just deployed a change with AI. Unlock unlimited builds and every model to keep the momentum going.".localized
        case .switchToYearly:
            return "You're already Super on monthly. Move to yearly to keep everything you have for less — the App Store prorates the difference automatically.".localized
        }
    }

    /// Existing subscribers (switching plans) shouldn't see the free-vs-Super
    /// comparison grid — they already have Super.
    var showsComparisonGrid: Bool { self != .switchToYearly }
}

struct ProPaywall: View {
    var context: PaywallContext = .general
    @ObservedObject var iap = IAPManager.shared
    @Environment(\.dismiss) var dismiss
    @State private var loadingProduct: String? = nil
    /// Per-user intro-offer eligibility. Optimistically true until StoreKit
    /// answers, so first paint shows the trial; flips false if already used.
    @State private var introOfferEligible = true
    // Default to the plan we most want sold. The pre-selected plan is the strongest
    // anchor on the screen — defaulting to monthly steered users to the lowest-LTV,
    // highest-churn option.
    @State private var selectedProductID: String = IAPManager.ProductID.yearly
    @State private var loadingMockPurchase = false
    @State private var restoreBusy = false
    @State private var showSuccess = false
    @State private var ctaPulse = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// A resigned/sideloaded App Store IPA has no App Store receipt on disk, and
    /// StoreKit never vends products for it — so `products.isEmpty` is permanent,
    /// not a flaky-network blip, and a retry button just dead-ends the sale in a
    /// loop. Genuine App Store and TestFlight builds always ship a receipt, so
    /// they keep the retry affordance.
    private static var installCannotTransact: Bool {
        guard let receiptURL = Bundle.main.appStoreReceiptURL else { return true }
        return !FileManager.default.fileExists(atPath: receiptURL.path)
    }

    /// Reward the purchase before the sheet closes — the highest-value moment
    /// shouldn't vanish silently. (Haptic already fires in IAPManager.purchase.)
    private func celebrateAndDismiss() {
        withAnimation(Theme.spring) { showSuccess = true }
        Task {
            try? await Task.sleep(nanoseconds: 950_000_000)
            dismiss()
        }
    }

    private var monthlyProduct: Product? { iap.product(for: IAPManager.ProductID.monthly) }
    private var yearlyProduct: Product? { iap.product(for: IAPManager.ProductID.yearly) }
    private var lifetimeProduct: Product? { iap.product(for: IAPManager.ProductID.lifetime) }
    private var selectedProduct: Product? { iap.product(for: selectedProductID) }

    private var monthlyPriceString: String {
        if let p = monthlyProduct {
            return p.displayPrice
        }
        return "$1.99"
    }

    private var yearlyPriceString: String {
        yearlyProduct?.displayPrice ?? "$11.99"
    }
    
    private var lifetimePriceString: String {
        if let p = lifetimeProduct {
            return p.displayPrice
        }
        return "$19.99"
    }

    /// Human free-trial length read from the SKU's StoreKit intro offer (e.g.
    /// "7 days free"), or nil if the plan has no free trial configured. Surfacing
    /// the real duration beats vague "free trial if eligible" copy.
    private func freeTrialText(_ product: Product?) -> String? {
        // Never promise a trial the user can't claim — Apple silently charges
        // ineligible users full price, which reads as a bait-and-switch.
        guard introOfferEligible else { return nil }
        guard let offer = product?.subscription?.introductoryOffer,
              offer.paymentMode == .freeTrial else { return nil }
        let n = offer.period.value
        switch offer.period.unit {
        case .day:
            return n == 1 ? "1 day free".localized : String(format: "%lld days free".localized, Int64(n))
        case .week:
            return n == 1 ? "7 days free".localized : String(format: "%lld weeks free".localized, Int64(n))
        case .month:
            return n == 1 ? "1 month free".localized : String(format: "%lld months free".localized, Int64(n))
        case .year:
            return n == 1 ? "1 year free".localized : String(format: "%lld years free".localized, Int64(n))
        @unknown default: return "Free trial".localized
        }
    }

    private var selectedHasFreeTrial: Bool { freeTrialText(selectedProduct) != nil }

    /// The yearly plan expressed as a per-month figure, localized — "$1.25/mo"
    /// reframes the annual lump sum so it reads cheaper than monthly.
    private var yearlyPerMonthString: String? {
        guard let y = yearlyProduct else { return nil }
        return (y.price / 12).formatted(y.priceFormatStyle)
    }

    /// Concrete savings of yearly vs paying monthly for a year (e.g. 37).
    private var yearlySavingsPercent: Int? {
        guard let y = yearlyProduct, let m = monthlyProduct else { return nil }
        let yearOfMonthly = m.price * 12
        guard yearOfMonthly > 0 else { return nil }
        let saving = (1 - (y.price / yearOfMonthly)) * 100
        // NSDecimalNumber.intValue truncates a long-mantissa Decimal to 0; go via
        // Double so 49.79… → 49 instead of vanishing into "SAVE MORE".
        let pct = Int(NSDecimalNumber(decimal: saving).doubleValue)
        return pct > 0 ? pct : nil
    }

    private var yearlyBadge: String {
        if let pct = yearlySavingsPercent {
            return String(format: "SAVE %lld%%".localized, Int64(pct))
        }
        return "SAVE MORE".localized
    }

    private var yearlyDescription: String {
        if let perMonth = yearlyPerMonthString {
            return String(format: "%@/mo · billed yearly".localized, perMonth)
        }
        return "Best recurring value for active sites".localized
    }

    private var monthlyBadge: String {
        freeTrialText(monthlyProduct) != nil ? "FREE TRIAL".localized : "MONTHLY".localized
    }

    private var monthlyDescription: String {
        if let trial = freeTrialText(monthlyProduct) {
            return String(format: "%@, then %@/mo".localized, trial, monthlyPriceString)
        }
        return String(format: "%@/mo · cancel anytime".localized, monthlyPriceString)
    }

    private var canUseMockPurchase: Bool {
        #if DEBUG
        return true
        #else
        return false
        #endif
    }

    private var canPurchaseSelectedPlan: Bool {
        selectedProduct != nil || canUseMockPurchase
    }

    private var ctaTitle: String {
        if selectedHasFreeTrial { return "Start Free Trial".localized }
        switch selectedProductID {
        case IAPManager.ProductID.monthly:
            return String(format: "Subscribe — %@/mo".localized, monthlyPriceString)
        case IAPManager.ProductID.yearly:
            return String(format: "Get Yearly — %@".localized, yearlyPriceString)
        case IAPManager.ProductID.lifetime:
            return String(format: "Unlock Lifetime — %@".localized, lifetimePriceString)
        default:
            return String(format: "Unlock Website Commander %@".localized, IAPManager.tierDisplayName)
        }
    }

    /// Trust line shown directly under the CTA, where the decision is made — the
    /// full auto-renew legal text stays in the footer.
    private var ctaSubtext: String {
        if selectedProductID == IAPManager.ProductID.lifetime {
            return "One-time purchase · no subscription, no lock-in".localized
        }
        if selectedHasFreeTrial {
            return "No charge today · cancel anytime in Settings".localized
        }
        return "Cancel anytime in Settings".localized
    }

    private var purchaseNotice: String {
        let safetyNotice = "Website Commander Super unlocks app features. Third-party AI providers and GitHub Copilot may require your own account, subscription, or API key. AI models can make mistakes; review and test all code before deployment.".localized

        if selectedProductID == IAPManager.ProductID.monthly {
            return String(format: "Website Commander Super Monthly is an auto-renewable monthly subscription. After any eligible free trial, it renews at %@/month unless cancelled in Apple ID settings at least 24 hours before the period ends. %@".localized, monthlyPriceString, safetyNotice)
        }

        if selectedProductID == IAPManager.ProductID.yearly {
            return String(format: "Website Commander Super Yearly is an auto-renewable yearly subscription. It renews at %@/year unless cancelled in Apple ID settings at least 24 hours before the period ends. %@".localized, yearlyPriceString, safetyNotice)
        }

        return String(format: "Website Commander Super Lifetime is a one-time purchase that unlocks Super features in this app without a recurring subscription. %@".localized, safetyNotice)
    }
    
    private var ctaButton: some View {
        Button {
            Haptics.tap()
            #if DEBUG
            if canUseMockPurchase {
                loadingMockPurchase = true
                Task {
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                    iap.grantMockProForDebug()
                    loadingMockPurchase = false
                    Haptics.success()
                    celebrateAndDismiss()
                }
                return
            }
            #endif

            if let product = selectedProduct {
                loadingProduct = selectedProductID
                Task {
                    let success = await iap.purchase(product)
                    loadingProduct = nil
                    if success && iap.isPro {
                        celebrateAndDismiss()
                    }
                }
            } else {
                iap.lastPurchaseError = "This Website Commander Super plan is not available from the App Store right now. Please try again shortly.".localized
            }
        } label: {
            ZStack {
                // Pulsing glow behind CTA — gently breathes to draw the eye on the
                // highest-intent screen; static when Reduce Motion is on.
                RoundedRectangle(cornerRadius: Theme.corner)
                    .fill(Theme.actionGradient)
                    .frame(height: 56)
                    .blur(radius: 8)
                    .opacity(reduceMotion ? 0.35 : (ctaPulse ? 0.6 : 0.22))
                    .animation(reduceMotion ? nil : .easeInOut(duration: 1.4).repeatForever(autoreverses: true), value: ctaPulse)

                RoundedRectangle(cornerRadius: Theme.corner)
                    .fill(Theme.actionGradient)
                    .frame(height: 56)

                HStack {
                    if loadingMockPurchase || (loadingProduct != nil) {
                        ProgressView().tint(.white)
                    } else {
                        Text(canPurchaseSelectedPlan ? ctaTitle : "Purchases Unavailable".localized)
                            .font(.headline)
                            .foregroundStyle(.white)
                            .contentTransition(.opacity)
                    }
                }
            }
        }
        .buttonStyle(.pressable)
        .disabled(loadingMockPurchase || (loadingProduct != nil) || !canPurchaseSelectedPlan)
    }

    /// Honest trust signals (no fabricated user counts) for the exact objections
    /// that stall a buy: lock-in, data ownership, and cancellation.
    private var trustStrip: some View {
        HStack(spacing: 18) {
            ForEach([
                ("lock.shield", "Code stays\nin your repo"),
                ("xmark.circle", "Cancel\nanytime"),
                ("bolt.fill", "Ship in\nminutes")
            ], id: \.0) { icon, label in
                VStack(spacing: 5) {
                    Image(systemName: icon)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Theme.brandGradient)
                    Text(label.localized)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.white.opacity(0.85))
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity)
            }
        }
        .padding(.horizontal, 24)
        .padding(.top, 4)
    }

    /// Pinned purchase bar — keeps the CTA + reassurance reachable while the
    /// comparison grid and plan cards scroll above it (they used to push the buy
    /// button off-screen on small devices / large Dynamic Type).
    private var ctaBar: some View {
        VStack(spacing: 8) {
            ctaButton
            Text(ctaSubtext)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.white.opacity(0.88))
                .multilineTextAlignment(.center)
        }
        .padding(.horizontal, 20)
        .padding(.top, 12)
        .padding(.bottom, 6)
        .frame(maxWidth: .infinity)
        .background(.bar, ignoresSafeAreaEdges: .bottom)
        .overlay(alignment: .top) {
            Rectangle().fill(Color.white.opacity(0.08)).frame(height: 1)
        }
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            
            // Background Radial Glow
            RadialGradient(
                colors: [Theme.brand.opacity(0.25), Color.clear],
                center: .top,
                startRadius: 0,
                endRadius: 360
            )
            .ignoresSafeArea()
            
            RadialGradient(
                colors: [Theme.brandEnd.opacity(0.15), Color.clear],
                center: .topTrailing,
                startRadius: 0,
                endRadius: 400
            )
            .ignoresSafeArea()
            
            ScrollViewReader { proxy in
            ScrollView {
                VStack(spacing: 24) {
                    // Top Bar (Restore & Close)
                    HStack {
                        Button {
                            Haptics.tap()
                            restoreBusy = true
                            Task {
                                let restored = await iap.restorePurchases()
                                restoreBusy = false
                                if restored && iap.isPro {
                                    dismiss()
                                }
                            }
                        } label: {
                            if restoreBusy {
                                ProgressView()
                                    .controlSize(.small)
                                    .tint(.white)
                            } else {
                                Text("Restore")
                                    .font(.system(size: 14, weight: .bold))
                                    .foregroundStyle(Theme.brandGradient)
                            }
                        }
                        .disabled(restoreBusy)
                        .padding(.horizontal, 12)
                        .frame(height: 32)
                        .background(Color.white.opacity(0.08))
                        .clipShape(Capsule())
                        .overlay(
                            Capsule()
                                .stroke(Color.white.opacity(0.12), lineWidth: 1)
                        )
                        .accessibilityLabel("Restore Purchases")
                        
                        Spacer()
                        
                        Button {
                            Haptics.tap()
                            dismiss()
                        } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 13, weight: .bold))
                                .foregroundStyle(.white.opacity(0.7))
                                .frame(width: 32, height: 32)
                                .background(Color.white.opacity(0.08))
                                .clipShape(Circle())
                                .overlay(
                                    Circle()
                                        .stroke(Color.white.opacity(0.12), lineWidth: 1)
                                )
                                .frame(width: 44, height: 44)   // 44pt hit target
                                .contentShape(Circle())
                        }
                        .accessibilityLabel("Close")
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 8)
                    
                    // Logo Header
                    VStack(spacing: 12) {
                        ZStack {
                            Circle()
                                .fill(Theme.brandGradient)
                                .frame(width: 80, height: 80)
                                .opacity(0.18)
                                .blur(radius: 8)
                            
                            Circle()
                                .fill(Theme.brandGradient)
                                .frame(width: 68, height: 68)
                                .opacity(0.12)
                            
                            Image(systemName: "ant.fill")
                                .font(.system(size: 32))
                                .foregroundStyle(Theme.brandGradient)
                        }
                        
                        Text(context.headline)
                            .font(.system(.title, design: .rounded).weight(.black))
                            .foregroundStyle(.white)
                            .multilineTextAlignment(.center)

                        Text(context.subheadline)
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(.white.opacity(0.7))
                            .multilineTextAlignment(.center)
                            .lineSpacing(4)
                            .padding(.horizontal, 24)

                        trustStrip
                    }
                    
                    // Comparison Grid — hidden for existing subscribers switching
                    // plans (they already have Super; free-vs-Super would confuse).
                    if context.showsComparisonGrid {
                    VStack(alignment: .leading, spacing: 14) {
                        Text("CHOOSE YOUR POWER LEVEL")
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(.white.opacity(0.6))
                            .kerning(1.2)
                            .padding(.horizontal, 6)
                        
                        VStack(spacing: 0) {
                            ComparisonRowItem(
                                icon: "infinity",
                                title: "Build all day",
                                free: "8 changes / month",
                                pro: "Unlimited changes — no monthly cap",
                                isLast: false
                            )
                            ComparisonRowItem(
                                icon: "cpu",
                                title: "Every top AI model",
                                free: "GitHub Copilot only",
                                pro: "Best model auto-picked per task",
                                isLast: false
                            )
                            ComparisonRowItem(
                                icon: "magnifyingglass",
                                title: "Fix live bugs with AI",
                                free: "Basic preview",
                                pro: "Inspect console, network & elements",
                                isLast: false
                            )
                            ComparisonRowItem(
                                icon: "folder.badge.plus",
                                title: "Ship more sites",
                                free: "1 website",
                                pro: "Connect unlimited sites",
                                isLast: false
                            )
                            ComparisonRowItem(
                                icon: "gauge.with.dots.needle.bottom.50percent",
                                title: "Stay in control of spend",
                                free: "Copilot · $0",
                                pro: "Live cost meter + per-session cap",
                                isLast: true
                            )
                        }
                        .background(
                            RoundedRectangle(cornerRadius: Theme.corner)
                                .fill(Color.white.opacity(0.03))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: Theme.corner)
                                .stroke(Color.white.opacity(0.06), lineWidth: 1)
                        )
                    }
                    .padding(.horizontal, 20)
                    }

                    // Pricing Selector Cards — yearly first: it's the default and
                    // the plan we most want sold, so it leads the stack.
                    VStack(spacing: 12) {
                        EmptyView().id("plans")
                        // Always render all three (matching monthly/lifetime) so the
                        // default-selected hero plan never vanishes if StoreKit
                        // products are slow/unavailable — a nil product just falls
                        // back to its placeholder price and is gated at purchase.
                        PlanSelectionCard(
                            productID: IAPManager.ProductID.yearly,
                            title: "Super Yearly",
                            price: yearlyPriceString,
                            description: yearlyDescription,
                            badge: yearlyBadge,
                            isSelected: selectedProductID == IAPManager.ProductID.yearly
                        ) {
                            withAnimation(Theme.snappy) { selectedProductID = IAPManager.ProductID.yearly }
                        }

                        PlanSelectionCard(
                            productID: IAPManager.ProductID.monthly,
                            title: "Super Monthly",
                            price: monthlyPriceString,
                            description: monthlyDescription,
                            badge: monthlyBadge,
                            isSelected: selectedProductID == IAPManager.ProductID.monthly
                        ) {
                            withAnimation(Theme.snappy) { selectedProductID = IAPManager.ProductID.monthly }
                        }

                        PlanSelectionCard(
                            productID: IAPManager.ProductID.lifetime,
                            title: "Super Lifetime",
                            price: lifetimePriceString,
                            description: "Pay once — no subscription",
                            badge: "PAY ONCE",
                            isSelected: selectedProductID == IAPManager.ProductID.lifetime
                        ) {
                            withAnimation(Theme.snappy) { selectedProductID = IAPManager.ProductID.lifetime }
                        }

                        if iap.isLoadingProducts {
                            HStack(spacing: 8) {
                                ProgressView().controlSize(.small).tint(.white)
                                Text("Loading current App Store prices...")
                            }
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.white.opacity(0.65))
                        } else if iap.products.isEmpty && !canUseMockPurchase {
                            if Self.installCannotTransact {
                                // Resigned/sideloaded App Store IPA: products will
                                // never load. State it plainly instead of dangling
                                // an endless retry. (Restore Purchases stays below.)
                                Text("Purchases aren't available in this installation.")
                                    .font(.footnote.weight(.semibold))
                                    .foregroundStyle(.white.opacity(0.7))
                                    .multilineTextAlignment(.center)
                                    .fixedSize(horizontal: false, vertical: true)
                            } else {
                                // Recoverable: a flaky connection at the buy moment used
                                // to dead-end the sale. Offer an explicit retry.
                                Button {
                                    Haptics.tap()
                                    Task { await iap.loadProducts() }
                                } label: {
                                    Label("Purchases unavailable — tap to retry", systemImage: "arrow.clockwise")
                                        .font(.footnote.weight(.semibold))
                                }
                                .buttonStyle(.bordered)
                                .tint(.orange)
                            }
                        }
                    }
                    .padding(.horizontal, 20)
                    
                    // Footer Actions
                    VStack(spacing: 12) {
                        HStack(spacing: 16) {
                            Button {
                                Haptics.tap()
                                Task {
                                    let restored = await iap.restorePurchases()
                                    if restored && iap.isPro {
                                        dismiss()
                                    }
                                }
                            } label: {
                                Text("Restore Purchases")
                            }

                            Text("•")
                                .foregroundStyle(.white.opacity(0.3))
                            
                            Link("Terms of Use", destination: SiteAgentURL.constant("https://www.apple.com/legal/internet-services/itunes/dev/stdeula/"))
                            
                            Text("•")
                                .foregroundStyle(.white.opacity(0.3))
                            
                            Link("Privacy Policy", destination: SiteAgentURL.constant("https://mesut.uk/privacy"))
                        }
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(Theme.brandGradient)

                        Text(purchaseNotice)
                            .font(.caption2)
                            .foregroundStyle(.white.opacity(0.8))   // legal disclosure must be legible
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 36)
                            .lineSpacing(2)
                    }
                    .padding(.top, 4)
                }
                .padding(.vertical)
            }
            .safeAreaInset(edge: .bottom, spacing: 0) { ctaBar }
            #if DEBUG
            // Screenshot harness: preselect the plan being captured and scroll the
            // priced plan cards into view, so each product's review screenshot is
            // distinct and actually shows the offer.
            .task {
                guard let plan = ProcessInfo.processInfo.environment["SCREENSHOT_PLAN"] else { return }
                switch plan {
                case "monthly":  selectedProductID = IAPManager.ProductID.monthly
                case "lifetime": selectedProductID = IAPManager.ProductID.lifetime
                default:         selectedProductID = IAPManager.ProductID.yearly
                }
                try? await Task.sleep(nanoseconds: 700_000_000)
                withAnimation(.none) { proxy.scrollTo("plans", anchor: .center) }
            }
            #endif
            }
        }
        .overlay {
            if showSuccess {
                ZStack {
                    Color.black.opacity(0.65).ignoresSafeArea()
                    VStack(spacing: 16) {
                        SuccessCheck(size: 76)
                        Text("You're Super 🎉")
                            .font(.title2.weight(.bold))
                            .foregroundStyle(.white)
                    }
                }
                .transition(.opacity)
            }
        }
        .task {
            ctaPulse = true
            if iap.products.isEmpty {
                await iap.loadProducts()
            }
            // Eligibility is per subscription group; monthly & yearly share one,
            // so a single check gates all trial copy.
            if let sub = (yearlyProduct ?? monthlyProduct)?.subscription {
                introOfferEligible = await sub.isEligibleForIntroOffer
            }
        }
        .alert("Website Commander Super", isPresented: Binding(
            get: { MainActor.assumeIsolated { iap.lastPurchaseError != nil } },
            set: { show in MainActor.assumeIsolated { if !show { iap.lastPurchaseError = nil } } }
        )) {
            Button("OK", role: .cancel) { iap.lastPurchaseError = nil }
        } message: {
            Text(iap.lastPurchaseError ?? "")
        }
    }
}

struct ComparisonRowItem: View {
    let icon: String
    let title: String
    let free: String
    let pro: String
    let isLast: Bool
    
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Theme.brandGradient.opacity(0.12))
                        .frame(width: 30, height: 30)
                    
                    Image(systemName: icon)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Theme.brandGradient)
                }
                
                VStack(alignment: .leading, spacing: 3) {
                    Text(title.localized)
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(.white)

                    HStack(spacing: 6) {
                        Text(String(format: "Free: %@".localized, free.localized))
                            .font(.caption2)
                            .foregroundStyle(.white.opacity(0.65))

                        Text("•")
                            .font(.caption2)
                            .foregroundStyle(.white.opacity(0.35))

                        Text(String(format: "Super: %@".localized, pro.localized))
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.green)
                    }
                }
                Spacer()
            }
            .padding(.vertical, 12)
            .padding(.horizontal, 14)
            
            if !isLast {
                Divider()
                    .background(Color.white.opacity(0.05))
                    .padding(.leading, 56)
            }
        }
    }
}

struct PlanSelectionCard: View {
    let productID: String
    let title: String
    let price: String
    let description: String
    let badge: String?
    let isSelected: Bool
    let action: () -> Void
    
    var body: some View {
        Button(action: {
            Haptics.tap()
            action()
        }) {
            HStack(spacing: 16) {
                // Radio Indicator
                ZStack {
                    Circle()
                        .strokeBorder(isSelected ? Theme.brandGradient : LinearGradient(colors: [Color.white.opacity(0.15)], startPoint: .center, endPoint: .center), lineWidth: 2)
                        .frame(width: 20, height: 20)
                    
                    if isSelected {
                        Circle()
                            .fill(Theme.brandGradient)
                            .frame(width: 12, height: 12)
                    }
                }
                
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text(title.localized)
                            .font(.headline)
                            .foregroundStyle(.white)

                        if let badge = badge {
                            // Gold highlights the hero plan (yearly) so the eye lands there.
                            let isHero = productID == IAPManager.ProductID.yearly
                            Text(badge.localized)
                                .font(.caption2.weight(.black))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 3)
                                .background(isHero ? Color.yellow : Theme.brand, in: Capsule())
                                .foregroundStyle(isHero ? Color.black : Color.white)
                        }
                    }

                    Text(description.localized)
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.65))
                        .multilineTextAlignment(.leading)
                }

                Spacer()

                Text(price)
                    .font(.system(.title3, design: .rounded).weight(.black))
                    .foregroundStyle(.white)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 16)
            .background(
                RoundedRectangle(cornerRadius: Theme.corner)
                    .fill(isSelected ? Color.white.opacity(0.06) : Color.white.opacity(0.02))
            )
            .overlay(
                RoundedRectangle(cornerRadius: Theme.corner)
                    .stroke(
                        isSelected ? Theme.brandGradient : LinearGradient(colors: [Color.white.opacity(0.08)], startPoint: .center, endPoint: .center),
                        lineWidth: isSelected ? 2 : 1
                    )
            )
            .shadow(color: isSelected ? Theme.brand.opacity(0.15) : Color.clear, radius: 8, x: 0, y: 4)
        }
        .buttonStyle(.pressable)
        .cardHover()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(title.localized), \(price), \(description.localized)")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
