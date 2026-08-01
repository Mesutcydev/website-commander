import SwiftUI

// MARK: - Breathing ring (expanding halo for live presence)

/// An expanding, fading halo. Used around the agent avatar while it works.
/// Renders a static faint ring under Reduce Motion.
struct BreathingRing: View {
    var tint: Color = Theme.accent
    @Environment(\.accessibilityReduceMotion) private var reduce
    @EnvironmentObject private var motion: AmbientMotionCoordinator

    var body: some View {
        let phase = motion.phase(period: 2.8)
        let enabled = motion.isRunning && !reduce
        let breath = AmbientMotionMath.breathe(phase)
        Circle()
            .stroke(tint.opacity(enabled ? 0.18 * (1 - breath) : 0.45), lineWidth: 1.5)
            .scaleEffect(enabled ? 1 + breath * 0.30 : 1.12)
    }
}

// MARK: - Orbit dot (a tool is running)

/// A small dot orbiting the avatar — reads as "doing work right now".
struct OrbitDot: View {
    var tint: Color = Theme.accent
    var size: CGFloat
    @Environment(\.accessibilityReduceMotion) private var reduce
    @EnvironmentObject private var motion: AmbientMotionCoordinator

    var body: some View {
        let phase = motion.phase(period: 4.8)
        Circle()
            .fill(tint)
            .frame(width: max(3, size * 0.16), height: max(3, size * 0.16))
            .offset(y: -size * 0.5)
            .rotationEffect(.degrees(reduce || !motion.isRunning ? 0 : phase * 360))
    }
}

// MARK: - Provider avatar (the agent's identity)

/// The agent's face: the active provider's official mark in a gradient disc,
/// wrapped in a state-driven animated indicator so you can see at a glance
/// whether the agent is idle, thinking, streaming, running a tool, or stuck.
struct ProviderAvatar: View {
    var size: CGFloat = 28
    var providerID: String? = nil
    var active: Bool = false
    var state: AgentState = .idle

    private var mark: BrandMarkID? { providerID.flatMap(BrandMarkID.from(providerID:)) }

    private var ringTint: Color {
        switch state {
        case .failed: return Theme.danger
        case .awaitingApproval, .paused: return Theme.warning
        case .done: return Theme.success
        default: return Theme.accent
        }
    }

    private var showRing: Bool { state != .idle }
    private var animateRing: Bool { state.isActive }   // thinking / streaming / runningTool / committing

    var body: some View {
        ZStack {
            if showRing {
                if animateRing {
                    BreathingRing(tint: ringTint)
                } else {
                    Circle().stroke(ringTint.opacity(0.5), lineWidth: 2).scaleEffect(1.12)
                }
            }
            if state == .runningTool {
                OrbitDot(tint: ringTint, size: size)
            }
            core
        }
        .frame(width: size, height: size)
        .animation(Motion.smooth, value: state)
    }

    private var core: some View {
        ZStack {
            Circle().fill(Theme.brandGradient)
            Group {
                if let mark {
                    BrandMark(id: mark).fill(.white).padding(size * 0.26)
                } else {
                    Image(systemName: "sparkle")
                        .font(.system(size: size * 0.46, weight: .bold))
                        .foregroundStyle(.white)
                }
            }
        }
        .frame(width: size * 0.82, height: size * 0.82)
        .wcPulse(active: active && state == .thinking)
    }
}

// MARK: - Branded activity glyph

/// The one activity symbol used for real agent work. The product mark remains
/// recognizable at every state; only a small edge signal or state glyph
/// changes, so this never becomes an oversized orb or generic spinner.
struct AgentActivityGlyph: View {
    let state: AgentState
    var size: CGFloat = 18

    @EnvironmentObject private var motion: AmbientMotionCoordinator
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var tint: Color {
        switch state {
        case .awaitingApproval, .paused: return Theme.warning
        case .failed: return Theme.danger
        case .done: return Theme.success
        default: return Theme.accent
        }
    }

    var body: some View {
        let phase = motion.phase(period: state.isActive ? 1.8 : 3.2)
        let enabled = motion.isRunning && !reduceMotion
        ZStack {
            LivingTabMark(size: size * 0.9, style: .gradient, animated: false)
                .rotationEffect(.degrees(state == .thinking && enabled ? phase * 10 : 0))

            if state == .runningTool && enabled {
                Rectangle()
                    .fill(Theme.cyan.opacity(0.85))
                    .frame(width: size * 0.48, height: 1.2)
                    .offset(y: (phase * 2 - 1) * size * 0.26)
            } else if state == .committing && state.isActive {
                Circle()
                    .trim(from: 0.10, to: enabled ? 0.52 : 0.32)
                    .stroke(tint.opacity(enabled ? 0.85 : 0.5), style: StrokeStyle(lineWidth: 1.4, lineCap: .round))
                    .frame(width: size, height: size)
                    .rotationEffect(.degrees(enabled ? phase * 360 : -45))
            } else if state == .awaitingApproval || state == .paused {
                Circle()
                    .stroke(tint.opacity(enabled ? 0.18 : 0.45), lineWidth: 1)
                    .frame(width: size, height: size)
                    .scaleEffect(enabled ? 1 + AmbientMotionMath.breathe(phase) * 0.16 : 1)
            } else if state == .done || state == .failed {
                Image(systemName: state == .done ? "checkmark" : "xmark")
                    .font(.system(size: size * 0.38, weight: .bold))
                    .foregroundStyle(tint)
                    .background(Circle().fill(Theme.elevatedSurface).padding(-2))
            }
        }
        .frame(width: size, height: size)
        .animation(Motion.layout, value: state)
        .accessibilityLabel(state.label)
    }
}

// MARK: - Streaming caret

/// A blinking text caret appended to the live, streaming assistant bubble.
struct StreamingCaret: View {
    @Environment(\.accessibilityReduceMotion) private var reduce
    @EnvironmentObject private var motion: AmbientMotionCoordinator

    var body: some View {
        let phase = motion.phase(period: 0.9)
        RoundedRectangle(cornerRadius: 1, style: .continuous)
            .fill(Theme.accent)
            .frame(width: 2, height: 13)
            .opacity(reduce || !motion.isRunning ? 0.7 : (phase < 0.5 ? 1 : 0.15))
    }
}

// MARK: - Activity border (live work, on the control's own edge)

/// Owns all three border states of a rounded control so they can never overlap:
/// a neutral hairline at rest, indigo plus a soft halo while focused, and — only
/// while the agent is actually working — a branded gradient that travels slowly
/// around the same edge, replacing both.
private struct ActivityBorder: ViewModifier {
    let active: Bool
    let focused: Bool
    let cornerRadius: CGFloat

    @Environment(\.accessibilityReduceMotion) private var reduce
    @EnvironmentObject private var motion: AmbientMotionCoordinator

    func body(content: Content) -> some View {
        content
            .overlay {
                shape.strokeBorder(focused ? Theme.focusRing : Theme.borderStandard, lineWidth: 1)
                    .opacity(active ? 0 : 1)
            }
            // Focus adds a soft outer ring instead of a permanent bright
            // outline, so the resting composer stays quiet.
            .overlay {
                halo.strokeBorder(focused ? Theme.focusRingHalo : .clear,
                                  lineWidth: Theme.Activity.haloWidth)
                    .opacity(active ? 0 : 1)
            }
            .overlay { sweep }
            .animation(Theme.Activity.fade, value: active)
    }

    @ViewBuilder private var sweep: some View {
        if active {
            if reduce {
                stroked(Theme.Activity.staticTint).transition(.opacity)
            } else {
                stroked(Theme.Activity.gradient(
                    angle: .degrees(motion.isRunning
                                    ? motion.phase(period: Theme.Activity.period) * 360
                                    : 0)))
                    .transition(.opacity)
            }
        }
    }

    private func stroked<S: ShapeStyle>(_ style: S) -> some View {
        ZStack {
            halo.strokeBorder(style, lineWidth: Theme.Activity.haloWidth)
                .opacity(Theme.Activity.haloOpacity)
            shape.strokeBorder(style, lineWidth: Theme.Activity.lineWidth)
        }
    }

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
    }

    private var halo: some InsettableShape {
        RoundedRectangle(cornerRadius: cornerRadius + Theme.Activity.haloWidth, style: .continuous)
            .inset(by: -Theme.Activity.haloWidth)
    }

}

extension View {
    /// Draws this control's resting, focused, and working borders as one
    /// mutually exclusive set. See `ActivityBorder`.
    func activityBorder(active: Bool, focused: Bool,
                        cornerRadius: CGFloat = Theme.Radius.composer) -> some View {
        modifier(ActivityBorder(active: active, focused: focused, cornerRadius: cornerRadius))
    }
}

// MARK: - Chat status pill (toolbar)

/// A compact, animated identity+state pill for the chat toolbar: the provider's
/// mark, the live agent state, and the model in use (or "On-Device").
struct AgentStatusPill: View {
    @EnvironmentObject var engine: AgentEngine
    @EnvironmentObject var settings: SettingsStore

    private var onDeviceActive: Bool {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) { return settings.preferOnDevice && OnDeviceProvider.isAvailable }
        #endif
        return false
    }

    private var effectiveProviderID: String {
        if onDeviceActive { return "ondevice" }
        if settings.smartRouting { return ProviderRegistry.routedProviderID(settings) }
        return settings.providerID
    }

    private var modelLabel: String {
        if onDeviceActive { return "On-Device" }
        if settings.smartRouting { return "Auto · \(settings.routingStrategy.rawValue)" }
        if !settings.model.isEmpty { return settings.model }
        return ProviderRegistry.info(for: settings.providerID)?.defaultModel ?? "auto"
    }

    var body: some View {
        HStack(spacing: 6) {
            ProviderAvatar(size: 22, providerID: effectiveProviderID,
                           active: engine.state.isActive, state: engine.state)
            VStack(alignment: .leading, spacing: 0) {
                Text(engine.state.label)
                    .font(.caption.weight(.semibold))
                    .contentTransition(.opacity)
                Text(modelLabel)
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 8).padding(.vertical, 4)
        .background(Theme.cardFill, in: Capsule())
        .overlay(Capsule().strokeBorder(Theme.borderSubtle))
        .animation(Motion.snappy, value: engine.state)
    }
}
