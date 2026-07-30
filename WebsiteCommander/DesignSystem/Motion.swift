import SwiftUI

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
    @State private var up = false

    func body(content: Content) -> some View {
        content
            .offset(y: reduce ? 0 : (up ? -4 : 4))
            .onAppear {
                guard !reduce else { return }
                withAnimation(.easeInOut(duration: 3.4).repeatForever(autoreverses: true)) { up = true }
            }
    }
}

// MARK: - Presence pulse (active indicators)

private struct WCPulse: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduce
    let active: Bool
    @State private var on = false

    func body(content: Content) -> some View {
        content
            .scaleEffect(active && on && !reduce ? 1.05 : 1.0)
            .onChange(of: active) { _, isActive in
                guard isActive, !reduce else { on = false; return }
                withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) { on = true }
            }
            .onAppear {
                guard active, !reduce else { return }
                withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) { on = true }
            }
    }
}

extension View {
    /// Fade + settle in once, on appear. Respects Reduce Motion.
    func wcAppear(delay: Double = 0) -> some View { modifier(WCAppear(delay: delay)) }
    /// A slow ambient vertical drift for hero art. Disabled under Reduce Motion.
    func wcFloat() -> some View { modifier(WCFloat()) }
    /// A gentle breathing scale while `active`. Disabled under Reduce Motion.
    func wcPulse(active: Bool) -> some View { modifier(WCPulse(active: active)) }
}
