import StoreKit
import UIKit

/// Asks for an App Store rating at a genuine delight moment (a successful ship).
/// The system rate-limits these prompts (~3/year) and ignores extra calls, so
/// callers only need to pick a good moment.
enum AppReview {
    @MainActor
    static func request() {
        guard let scene = UIApplication.shared.connectedScenes
            .first(where: { $0.activationState == .foregroundActive }) as? UIWindowScene else { return }
        AppStore.requestReview(in: scene)
    }
}
