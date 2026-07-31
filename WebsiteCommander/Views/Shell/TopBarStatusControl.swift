import SwiftUI

/// The bar's status vocabulary.
///
/// Deliberately small and closed: every case maps from a real engine state (or
/// from real pending changes), so the bar can never claim something the app
/// isn't doing. Kept as a plain value type so the mapping is testable without a
/// store or an engine.
enum AgentStatusPresentation: String, CaseIterable {
    case ready
    case thinking
    case working
    case waiting
    case reviewing
    case failed

    var label: String {
        switch self {
        case .ready:     return String(localized: "Ready")
        case .thinking:  return String(localized: "Thinking")
        case .working:   return String(localized: "Working")
        case .waiting:   return String(localized: "Waiting")
        case .reviewing: return String(localized: "Reviewing")
        case .failed:    return String(localized: "Failed")
        }
    }

    /// Only real work animates. Ready never pulses.
    var animates: Bool {
        self == .thinking || self == .working
    }

    var indicatorColor: Color {
        switch self {
        case .ready:     return Theme.success
        case .thinking:  return Theme.Chrome.accent
        case .working:   return Theme.Chrome.accent
        case .waiting:   return Theme.warning
        case .reviewing: return Theme.warning
        case .failed:    return Theme.danger
        }
    }

    static func from(state: AgentState, pendingChanges: Int) -> AgentStatusPresentation {
        switch state {
        case .thinking:         return .thinking
        case .streaming:        return .working
        case .runningTool:      return .working
        case .committing:       return .working
        case .awaitingApproval: return .waiting
        case .paused:           return .waiting
        case .failed:           return .failed
        case .idle, .done:      return pendingChanges > 0 ? .reviewing : .ready
        }
    }
}

/// The agent status control: a 6pt state indicator plus a short label on a
/// capsule. The pill itself never animates and never changes size, so a state
/// change cannot shift anything beside it.
struct TopBarStatusControl: View {
    let status: AgentStatusPresentation
    /// Narrow windows drop the label; the popover keeps it discoverable.
    let showsLabel: Bool
    let isOpen: Bool
    let onToggle: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pulsing = false
    @FocusState private var isFocused: Bool

    /// A fixed label column: "Thinking" and "Ready" must occupy the same space
    /// or the model selector beside them would move on every state change.
    private static let labelWidth: CGFloat = 58

    var body: some View {
        Button(action: onToggle) {
            HStack(spacing: 6) {
                Circle()
                    .fill(status.indicatorColor)
                    .frame(width: TopBarMetrics.statusDotSize,
                           height: TopBarMetrics.statusDotSize)
                    .scaleEffect(animating ? 1.3 : 1)
                    .opacity(animating ? 0.5 : 1)
                if showsLabel {
                    Text(status.label)
                        .font(Theme.ui(12, .medium))
                        .foregroundStyle(Theme.Chrome.textSecondary)
                        .lineLimit(1)
                        .contentTransition(.opacity)
                        .frame(width: Self.labelWidth, alignment: .leading)
                }
            }
            .padding(.horizontal, 9)
            .frame(height: TopBarMetrics.statusHeight)
        }
        .buttonStyle(TopBarControlButtonStyle(
            radius: TopBarMetrics.statusHeight / 2,
            emphasis: isOpen ? .selected : .resting
        ))
        .focused($isFocused)
        .help("Agent activity")
        .accessibilityLabel("\(String(localized: "Agent status")): \(status.label)")
        .accessibilityValue(isOpen ? "Expanded" : "Collapsed")
        .topBarTrigger(.status)
        .animation(Theme.Chrome.Timing.status, value: status)
        .onAppear { restartIndicator() }
        .onChange(of: status) { _, _ in restartIndicator() }
        .onChange(of: reduceMotion) { _, _ in restartIndicator() }
        .onChange(of: isOpen) { wasOpen, open in
            if wasOpen && !open { isFocused = true }
        }
    }

    private var animating: Bool { pulsing && status.animates && !reduceMotion }

    /// One restrained 1.6s cycle on the indicator only — never the pill, never
    /// three bouncing dots.
    private func restartIndicator() {
        pulsing = false
        guard status.animates, !reduceMotion else { return }
        withAnimation(Theme.Chrome.Timing.activity.repeatForever(autoreverses: true)) {
            pulsing = true
        }
    }
}

// MARK: - Popover

/// The activity popover. Everything in it is read from the engine: the current
/// state, the operations it is actually running, real staged changes, and the
/// real last error. When there is nothing to show it says so.
struct TopBarStatusPopover: View {
    let status: AgentStatusPresentation
    let maxHeight: CGFloat
    let onReviewChanges: () -> Void

    @EnvironmentObject private var engine: AgentEngine

    private var recentEvents: [ToolEvent] {
        Array(engine.liveToolEvents.suffix(6).reversed())
    }

    var body: some View {
        TopBarPopoverPanel {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 8) {
                    Circle()
                        .fill(status.indicatorColor)
                        .frame(width: TopBarMetrics.statusDotSize,
                               height: TopBarMetrics.statusDotSize)
                    Text(status.label)
                        .font(Theme.ui(13, .semibold))
                        .foregroundStyle(Theme.Chrome.textPrimary)
                    Spacer(minLength: 6)
                }
                .padding(.horizontal, 9)
                .frame(height: 30)

                if let error = engine.lastError, !error.isEmpty {
                    Text(error)
                        .font(Theme.ui(12, .regular))
                        .foregroundStyle(Theme.danger)
                        .lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 9)
                        .padding(.bottom, 6)
                }

                if !recentEvents.isEmpty {
                    TopBarPopoverSeparator()
                    TopBarPopoverSectionLabel(text: "Operations")
                    ScrollView {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(recentEvents) { event in
                                HStack(spacing: 8) {
                                    eventIcon(event)
                                    Text(event.summary)
                                        .font(Theme.ui(12, .regular))
                                        .foregroundStyle(Theme.Chrome.textSecondary)
                                        .lineLimit(2)
                                        .fixedSize(horizontal: false, vertical: true)
                                    Spacer(minLength: 0)
                                }
                                .padding(.horizontal, 9)
                            }
                        }
                        .padding(.vertical, 2)
                    }
                    .frame(maxHeight: maxHeight)
                    // A scroll view is greedy: without this it claims the whole
                    // cap and leaves a dead band under a short list.
                    .fixedSize(horizontal: false, vertical: true)
                    .scrollBounceBehavior(.basedOnSize)
                }

                if !engine.pendingChanges.isEmpty {
                    TopBarPopoverSeparator()
                    TopBarPopoverRow(
                        title: pendingTitle,
                        leading: { TopBarRowIcon(systemImage: "tray.full", tint: Theme.warning) },
                        action: onReviewChanges
                    )
                }

                if recentEvents.isEmpty && engine.pendingChanges.isEmpty && engine.lastError == nil {
                    Text(status == .ready
                         ? String(localized: "No operation running.")
                         : String(localized: "No operation details yet."))
                        .font(Theme.ui(12, .regular))
                        .foregroundStyle(Theme.Chrome.textMuted)
                        .padding(.horizontal, 9)
                        .padding(.bottom, 8)
                }
            }
        }
        .frame(width: TopBarPopoverKind.status.width)
    }

    private var pendingTitle: String {
        let count = engine.pendingChanges.count
        return count == 1
            ? String(localized: "Review 1 staged change")
            : "\(String(localized: "Review")) \(count) \(String(localized: "staged changes"))"
    }

    @ViewBuilder
    private func eventIcon(_ event: ToolEvent) -> some View {
        switch event.status {
        case .running:
            ProgressView().controlSize(.mini).frame(width: 14, height: 14)
        case .success:
            Image(systemName: "checkmark")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Theme.success)
                .frame(width: 14, height: 14)
        case .failure:
            Image(systemName: "xmark")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Theme.danger)
                .frame(width: 14, height: 14)
        }
    }
}
