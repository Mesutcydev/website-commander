import SwiftUI
import AppKit

/// One clock for the app's small amount of ambient motion.
///
/// Views read this clock instead of owning independent repeat-forever timers.
/// That keeps the motion budget visible, lets the app pause as one unit when
/// it is inactive, and avoids waking a collection of views while the user is
/// working in another app.
@MainActor
final class AmbientMotionCoordinator: ObservableObject {
    @Published private(set) var now = Date()
    @Published private(set) var isRunning = false

    private let notifications: NotificationCenter
    private var timer: Timer?
    private var observerTokens: [NSObjectProtocol] = []

    init(notificationCenter: NotificationCenter = .default) {
        notifications = notificationCenter

        let names: [Notification.Name] = [
            NSApplication.didBecomeActiveNotification,
            NSApplication.didResignActiveNotification,
            NSApplication.didHideNotification,
            NSApplication.didUnhideNotification,
            NSWindow.didMiniaturizeNotification,
            NSWindow.didDeminiaturizeNotification,
            NSWindow.didBecomeKeyNotification,
            NSWindow.didResignKeyNotification,
            Notification.Name("NSProcessInfoPowerStateDidChangeNotification"),
            Notification.Name("NSProcessInfoThermalStateDidChangeNotification")
        ]

        observerTokens = names.map { name in
            notifications.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in self?.reconcile() }
            }
        }
        reconcile()
    }

    deinit {
        observerTokens.forEach(notifications.removeObserver)
        timer?.invalidate()
    }

    /// Re-evaluate visibility after the first window is created. The app owns
    /// this object for the lifetime of the process, so there is no per-view
    /// setup or teardown to get out of sync.
    func reconcile() {
        let appIsActive = NSApp.isActive
        let visibleWindow = NSApp.windows.isEmpty || NSApp.windows.contains {
            $0.isVisible && !$0.isMiniaturized
        }
        let thermal = ProcessInfo.processInfo.thermalState
        let thermallyConstrained = thermal == .serious || thermal == .critical
        let lowPower: Bool
        if #available(macOS 12.0, *) {
            lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
        } else {
            lowPower = false
        }

        let shouldRun = appIsActive && visibleWindow && !lowPower && !thermallyConstrained
        if isRunning != shouldRun { isRunning = shouldRun }

        if shouldRun {
            startTimerIfNeeded()
        } else {
            timer?.invalidate()
            timer = nil
        }
    }

    /// Normalized phase in the range 0...1. Slow ambient loops can all derive
    /// from this same timestamp without introducing their own timers.
    func phase(period: TimeInterval, offset: TimeInterval = 0) -> Double {
        guard period > 0 else { return 0 }
        let elapsed = now.timeIntervalSinceReferenceDate + offset
        let remainder = elapsed.truncatingRemainder(dividingBy: period)
        return remainder >= 0 ? remainder / period : (remainder + period) / period
    }

    /// A one-pass travel window inside a longer idle cycle. `nil` means the
    /// signal is intentionally resting, which keeps a telemetry line from
    /// reading like a progress bar.
    func traversal(period: TimeInterval, activeDuration: TimeInterval,
                   offset: TimeInterval = 0) -> (progress: Double, opacity: Double)? {
        guard period > 0, activeDuration > 0 else { return nil }
        let elapsed = phase(period: period, offset: offset) * period
        guard elapsed < min(activeDuration, period) else { return nil }
        let progress = min(1, elapsed / activeDuration)
        let edge = min(progress, 1 - progress) * 2
        return (progress, 0.04 + 0.12 * edge)
    }

    private func startTimerIfNeeded() {
        guard timer == nil else { return }
        // ~15 fps is enough for the slow ambient loops (2.4–9.4s periods) and
        // halves the number of body re-evaluations versus a 30 fps clock.
        let timer = Timer(timeInterval: 1.0 / 15.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.isRunning else { return }
                self.now = Date()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }
}

/// Shared math for motion views. Keeping the curve here prevents each status
/// indicator from inventing a slightly different rhythm.
enum AmbientMotionMath {
    static func breathe(_ phase: Double) -> Double {
        0.5 - 0.5 * cos(phase * .pi * 2)
    }
}

/// The motion language of Website Commander: a small set of named springs plus
/// reduced-motion-aware modifiers. Every animation in the app should go through
/// here so the feel stays coherent and, crucially, so users who enable
/// "Reduce Motion" get calm fades instead of movement.
///
/// Principles: motion communicates state, not decoration. Springs for physical
/// things (toggles, pops), ease-outs for reveals, gentle loops only for live
/// "the agent is working" presence. Nothing bounces for fun.
enum Motion {
    /// Quick UI toggles, highlights, selection changes.
    static let snappy = Animation.spring(response: 0.30, dampingFraction: 0.74)
    /// Layout / content / sheet reveals.
    static let smooth = Animation.spring(response: 0.45, dampingFraction: 0.82)
    /// Playful-but-controlled accents (avatar pop, send button).
    static let bouncy = Animation.spring(response: 0.42, dampingFraction: 0.66)
    /// Simple fades.
    static let gentle = Animation.easeOut(duration: 0.28)
    /// A short, critically damped transition for viewport and selection
    /// changes. Continuous motion never uses a spring.
    static let layout = Animation.spring(response: 0.26, dampingFraction: 0.96)
    /// Small press/hover feedback; deliberately settles without overshoot.
    static let interaction = Animation.timingCurve(0.2, 0.8, 0.2, 1, duration: 0.12)

    /// Entrance used by `.wcAppear`.
    static func appear(delay: Double = 0) -> Animation {
        Animation.spring(response: 0.5, dampingFraction: 0.82).delay(delay)
    }
}

// MARK: - Entrance

private struct WCAppear: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduce
    let delay: Double
    @State private var shown = false

    func body(content: Content) -> some View {
        content
            .opacity(shown ? 1 : 0)
            .scaleEffect(shown ? 1 : (reduce ? 1 : 0.97))
            .offset(y: shown ? 0 : (reduce ? 0 : 6))
            .onAppear {
                if reduce { shown = true }
                else { withAnimation(Motion.appear(delay: delay)) { shown = true } }
            }
    }
}

// MARK: - Ambient float (hero illustrations)

private struct WCFloat: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduce
    @EnvironmentObject private var motion: AmbientMotionCoordinator

    func body(content: Content) -> some View {
        let phase = motion.phase(period: 9.0)
        let drift = reduce || !motion.isRunning ? 0 : sin(phase * .pi * 2) * 1.4
        content
            .offset(y: drift)
    }
}

private struct WCPreviewDrift: ViewModifier {
    let active: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @EnvironmentObject private var motion: AmbientMotionCoordinator

    func body(content: Content) -> some View {
        let phase = motion.phase(period: 9.4)
        let enabled = active && motion.isRunning && !reduceMotion
        content
            .offset(x: enabled ? sin(phase * .pi * 2) * 0.8 : 0,
                    y: enabled ? cos(phase * .pi * 2) * 0.8 : 0)
            .scaleEffect(enabled ? 1.008 : 1)
    }
}

// MARK: - Presence pulse (active indicators)

private struct WCPulse: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduce
    @EnvironmentObject private var motion: AmbientMotionCoordinator
    let active: Bool

    func body(content: Content) -> some View {
        let phase = motion.phase(period: 3.2)
        let amount = active && motion.isRunning && !reduce
            ? 1 + AmbientMotionMath.breathe(phase) * 0.015
            : 1
        content
            .scaleEffect(amount)
    }
}

extension View {
    /// Fade + settle in once, on appear. Respects Reduce Motion.
    func wcAppear(delay: Double = 0) -> some View { modifier(WCAppear(delay: delay)) }
    /// A slow ambient vertical drift for hero art. Disabled under Reduce Motion.
    func wcFloat() -> some View { modifier(WCFloat()) }
    /// A tiny selected/hovered preview drift. Inactive site previews stay still.
    func wcPreviewDrift(active: Bool) -> some View { modifier(WCPreviewDrift(active: active)) }
    /// A gentle breathing scale while `active`. Disabled under Reduce Motion.
    func wcPulse(active: Bool) -> some View { modifier(WCPulse(active: active)) }
}

// MARK: - Shared live signals

/// A tiny connection signal used by the toolbar, active site, and preview URL.
/// The dot stays stable; only the low-opacity ring or progress arc moves.
struct AmbientConnectionSignal: View {
    enum Mode { case breathing, progress, staticDot }

    var tint: Color = Theme.success
    var mode: Mode = .breathing
    var active = true
    var label: String?

    @EnvironmentObject private var motion: AmbientMotionCoordinator
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let phase = motion.phase(period: mode == .progress ? 2.4 : 2.6)
        let enabled = active && motion.isRunning && !reduceMotion
        let breath = AmbientMotionMath.breathe(phase)

        ZStack {
            if mode == .breathing && active {
                Circle()
                    .stroke(tint.opacity(enabled ? 0.18 * (1 - breath) : 0.12), lineWidth: 1)
                    .scaleEffect(enabled ? 1 + 0.35 * breath : 1.12)
            } else if mode == .progress && active {
                Circle()
                    .trim(from: 0.08, to: enabled ? 0.38 : 0.26)
                    .stroke(tint.opacity(enabled ? 0.8 : 0.45), style: StrokeStyle(lineWidth: 1.4, lineCap: .round))
                    .rotationEffect(.degrees(enabled ? phase * 360 : -45))
            }

            Circle()
                .fill(tint)
                .frame(width: 5, height: 5)
        }
        .frame(width: 12, height: 12)
        .help(label ?? "")
        .accessibilityHidden(label == nil)
        .accessibilityLabel(label ?? "")
    }
}

/// A single, low-contrast signal travelling across a separator. The longer
/// cycle includes a deliberate resting interval so it never reads as loading.
struct AmbientTelemetryLine: View {
    var tint: Color = Theme.accent
    var active = true

    @EnvironmentObject private var motion: AmbientMotionCoordinator
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { proxy in
            let segmentWidth = max(28, proxy.size.width * 0.16)
            let travel = motion.traversal(period: 6.0, activeDuration: 1.0)
            let enabled = active && motion.isRunning && !reduceMotion
            ZStack(alignment: .leading) {
                Rectangle()
                    .fill(tint.opacity(active ? 0.06 : 0))
                if active {
                    Capsule()
                        .fill(tint.opacity(enabled ? (travel?.opacity ?? 0) : 0.10))
                        .frame(width: segmentWidth, height: 1)
                        .offset(x: enabled && travel != nil
                                ? (-segmentWidth + CGFloat(travel!.progress) * (proxy.size.width + segmentWidth))
                                : 0)
                }
            }
        }
        .frame(height: 1)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// A narrow progress track for the activity rail. It uses a truthful
/// indeterminate signal only while the engine is active.
struct AmbientProgressTrack: View {
    var tint: Color = Theme.accent
    var active = false

    @EnvironmentObject private var motion: AmbientMotionCoordinator
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { proxy in
            let segmentWidth = max(22, proxy.size.width * 0.2)
            let phase = motion.phase(period: 5.4)
            let enabled = active && motion.isRunning && !reduceMotion
            ZStack(alignment: .leading) {
                Rectangle().fill(tint.opacity(active ? 0.09 : 0))
                if active {
                    Capsule()
                        .fill(tint.opacity(enabled ? 0.34 : 0.18))
                        .frame(width: segmentWidth, height: 2)
                        .offset(x: enabled
                                ? (-segmentWidth + CGFloat(phase) * (proxy.size.width + segmentWidth))
                                : 0)
                }
            }
        }
        .frame(height: 2)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
