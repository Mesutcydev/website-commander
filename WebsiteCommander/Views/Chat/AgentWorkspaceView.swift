import SwiftUI

/// Persistent, testable layout state for the Agent workspace. The preview
/// column only exists in the split state; closing it can never leave a stale
/// flex basis or invisible hit-testing surface behind.
struct WorkspaceLayout {
    static let agentMinimum: CGFloat = 360
    static let agentDefault: CGFloat = 420
    static let agentMaximum: CGFloat = 520
    static let previewMinimum: CGFloat = 520
    static let dividerWidth: CGFloat = 8
    static let compactBreakpoint: CGFloat = agentMinimum + previewMinimum + dividerWidth + 48

    static func defaultAgentWidth(in available: CGFloat) -> CGFloat {
        clampedAgentWidth(agentDefault, in: available)
    }

    static func clampedAgentWidth(_ proposed: CGFloat, in available: CGFloat) -> CGFloat {
        let availableMaximum = max(agentMinimum, available - previewMinimum - dividerWidth)
        let maximum = min(agentMaximum, availableMaximum)
        return min(max(proposed, agentMinimum), maximum)
    }
}

/// The primary working surface: a full-width workspace that starts immediately
/// under the application bar.
///
/// It owns no chrome of its own. The bar carries the destination, the project,
/// agent status, the model, the view controls, and the primary action, so this
/// view is only ever the conversation, the conversation beside the live preview,
/// or the live preview — all laid out on `AgentWorkspaceMetrics`.
struct AgentWorkspaceView: View {
    @AppStorage("workspace.previewVisible") private var showsPreview = true
    @AppStorage("workspace.agentWidth") private var storedAgentWidth = 0.0
    @EnvironmentObject private var engine: AgentEngine
    @State private var dragStartWidth: CGFloat?

    var body: some View {
        GeometryReader { proxy in
            workspaceBody(width: proxy.size.width)
                .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
        }
        .background { GlassWorkspaceBackground() }
        .onReceive(NotificationCenter.default.publisher(for: .requestAgentPreview)) { _ in
            showsPreview = true
        }
    }

    // MARK: Workspace body

    /// Three states from one flag, driven by the bar's view controls: the
    /// conversation alone, the conversation beside the live preview, or — when
    /// the window is too narrow for a genuine split — the live preview alone.
    @ViewBuilder
    private func workspaceBody(width: CGFloat) -> some View {
        if showsPreview && width < WorkspaceLayout.compactBreakpoint {
            PreviewView(embedded: true)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if showsPreview {
            splitWorkspace(available: width)
        } else {
            expandedAgent(width: width)
        }
    }

    private func expandedAgent(width: CGFloat) -> some View {
        ChatView(
            embedded: true,
            showsBrowser: false,
            paneWidth: width,
            onToggleBrowser: { showsPreview = true },
            showsToolbarControls: false
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background { GlassPaneBackground() }
    }

    private func splitWorkspace(available: CGFloat) -> some View {
        let agentWidth = WorkspaceLayout.clampedAgentWidth(
            storedAgentWidth > 0 ? storedAgentWidth : WorkspaceLayout.defaultAgentWidth(in: available),
            in: available
        )

        return HStack(spacing: 0) {
            ChatView(
                embedded: true,
                showsBrowser: true,
                paneWidth: agentWidth,
                onToggleBrowser: { showsPreview = false },
                showsToolbarControls: false
            )
            .frame(width: agentWidth)
            .frame(minWidth: WorkspaceLayout.agentMinimum, maxHeight: .infinity)
            .background { GlassPaneBackground() }

            splitter(currentWidth: agentWidth, available: available)

            PreviewView(embedded: true)
                .frame(minWidth: WorkspaceLayout.previewMinimum, maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func splitter(currentWidth: CGFloat, available: CGFloat) -> some View {
        Rectangle()
            .fill(Theme.recessedSurface)
            .frame(width: WorkspaceLayout.dividerWidth)
            .overlay {
                Capsule()
                    .fill(Theme.borderStrong)
                    .frame(width: 2, height: 34)
            }
            .contentShape(Rectangle())
            .onHover { hovering in
                if hovering { NSCursor.resizeLeftRight.push() }
                else { NSCursor.pop() }
            }
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        let start = dragStartWidth ?? currentWidth
                        dragStartWidth = start
                        storedAgentWidth = Double(WorkspaceLayout.clampedAgentWidth(
                            start + value.translation.width,
                            in: available
                        ))
                    }
                    .onEnded { _ in dragStartWidth = nil }
            )
            .accessibilityLabel("Resize Agent and Preview panes")
            .accessibilityValue("\(Int(currentWidth)) points")
            .accessibilityAdjustableAction { direction in
                let delta: CGFloat = direction == .increment ? 24 : -24
                storedAgentWidth = Double(WorkspaceLayout.clampedAgentWidth(currentWidth + delta, in: available))
            }
    }

}
