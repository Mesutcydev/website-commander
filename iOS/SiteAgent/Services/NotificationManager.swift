import Foundation
import UserNotifications

/// Minimal local-notification helper. No backend, no BGTask: a notification only
/// fires if the run/deploy-poll finishes before iOS suspends the app — the common
/// case for a short backgrounded turn.
// ponytail: no BGTask. Add a BGProcessingTask only if runs need to survive suspension.
enum NotificationManager {
    /// Prompts for permission once (no-op if already asked). Safe to call repeatedly.
    static func requestAuthorizationIfNeeded() {
        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { settings in
            guard settings.authorizationStatus == .notDetermined else { return }
            center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
        }
    }

    static func notify(title: String, body: String) {
        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { settings in
            guard settings.authorizationStatus == .authorized
                    || settings.authorizationStatus == .provisional else { return }
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            content.sound = .default
            // Tiny non-zero delay: UNUserNotificationCenter won't deliver a
            // foreground-scheduled notification with no trigger reliably.
            let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 0.1, repeats: false)
            center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: trigger))
        }
    }

    /// Stable identifiers for re-engagement nudges (re-scheduling with the same id
    /// replaces, so they never duplicate). Cancelled on upgrade / when resolved.
    enum Nudge {
        static let trialEnding = "nudge.ondevice-trial-ending"
        static let monthlyReset = "nudge.monthly-reset"
        static let activation = "nudge.activation"
        static var all: [String] { [trialEnding, monthlyReset, activation] }
    }

    /// Schedule (or replace) a future local notification. Fires even when the app
    /// is suspended — no backend/BGTask needed. Past dates are ignored.
    static func schedule(id: String, title: String, body: String, at date: Date) {
        let interval = date.timeIntervalSinceNow
        guard interval > 1 else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: interval, repeats: false)
        UNUserNotificationCenter.current()
            .add(UNNotificationRequest(identifier: id, content: content, trigger: trigger))
    }

    static func cancel(_ ids: [String]) {
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: ids)
    }
}
