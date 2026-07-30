import SwiftUI

// MARK: - Breathing ring (expanding halo for live presence)

/// An expanding, fading halo. Used around the agent avatar while it works.
/// Renders a static faint ring under Reduce Motion.
struct BreathingRing: View {
    var tint: Color = Theme.accent
    @Environment(\.accessibilityReduceMotion) private var reduce
    @State private var phase = false

    var body: some View {
        Circle()
            .stroke(tint.opacity(reduce ? 0.45 : 0.6), lineWidth: 2)
            .scaleEffect(reduce ? 1.12 : (phase ? 1.3 : 1.0))
            .opacity(reduce ? 0.45 : (phase ? 0 : 0.7))
            .onAppear {
                guard !reduce else { return }
                withAnimation(.easeOut(duration: 1.1).repeatForever(autoreverses: false)) { phase = true }
            }
    }
}

// MARK: - Orbit dot (a tool is running)

/// A small dot orbiting the avatar — reads as "doing work right now".
struct OrbitDot: View {
    var tint: Color = Theme.accent
    var size: CGFloat
    @Environment(\.accessibilityReduceMotion) private var reduce
    @State private var spin = false

    var body: some View {
        Circle()
            .fill(tint)
            .frame(width: max(3, size * 0.16), height: max(3, size * 0.16))
            .offset(y: -size * 0.5)
            .rotationEffect(.degrees(spin ? 360 : 0))
            .onAppear {
                guard !reduce else { return }
                withAnimation(.linear(duration: 1.4).repeatForever(autoreverses: false)) { spin = true }
            }
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
        case .awaitingApproval: return Theme.warning
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

// MARK: - Streaming caret

/// A blinking text caret appended to the live, streaming assistant bubble.
struct StreamingCaret: View {
    @Environment(\.accessibilityReduceMotion) private var reduce
    @State private var on = false

    var body: some View {
        RoundedRectangle(cornerRadius: 1, style: .continuous)
            .fill(Theme.accent)
            .frame(width: 2, height: 13)
            .opacity(reduce ? 0.7 : (on ? 1 : 0.15))
            .onAppear {
                guard !reduce else { return }
                withAnimation(.easeInOut(duration: 0.6).repeatForever(autoreverses: true)) { on = true }
            }
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
        .overlay(Capsule().strokeBorder(Theme.hairline))
        .animation(Motion.snappy, value: engine.state)
    }
}
