import AppKit

/// One mutable entry point for all lightweight app audio feedback.
enum AudioNotificationPlayer {
    static func play(_ sound: NotificationSound) {
        NSSound(named: NSSound.Name(sound.rawValue))?.play()
    }
}
