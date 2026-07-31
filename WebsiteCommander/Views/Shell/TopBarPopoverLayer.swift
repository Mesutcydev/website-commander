import SwiftUI

/// The shell's single popover layer.
///
/// It deliberately lives above *both* the bar and the workspace rather than
/// inside the bar. The bar is the shell's top safe-area inset, so anything the
/// bar draws below its own 68pt band is visible but not clickable — the
/// workspace wins the mouse. Hoisting the layer here is what makes an open menu
/// a real menu: its rows take clicks, and a click anywhere else dismisses it.
///
/// There is only ever one open popover, positioned 8pt under its trigger and
/// aligned to the trigger's leading edge, clamped to stay inside the window.
struct TopBarPopoverLayer: View {

    let metrics: TopBarMetrics
    let shellSize: CGSize
    let anchors: [TopBarPopoverKind: Anchor<CGRect>]
    @Binding var open: TopBarPopoverKind?
    @Binding var destination: Destination
    @Binding var showsPreview: Bool
    let showsViewControls: Bool

    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var engine: AgentEngine
    @EnvironmentObject private var updater: UpdateChecker
    @Environment(\.openSettings) private var openSettings
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var status: AgentStatusPresentation {
        .from(state: engine.state, pendingChanges: engine.pendingChanges.count)
    }

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .topLeading) {
                if open != nil {
                    // Click-outside: behaves like a menu's event-swallowing
                    // window, but stays inside the app's own hierarchy.
                    Rectangle()
                        .fill(Color.black.opacity(0.0001))
                        .contentShape(Rectangle())
                        .onTapGesture { close() }
                        .accessibilityHidden(true)

                    Button("") { close() }
                        .buttonStyle(.plain)
                        .keyboardShortcut(.cancelAction)
                        .frame(width: 0, height: 0)
                        .opacity(0)
                        .accessibilityHidden(true)
                }

                if let kind = open, let anchor = anchors[kind] {
                    let trigger = proxy[anchor]
                    content(kind)
                        .modifier(TopBarPopoverTransition(reduceMotion: reduceMotion))
                        .offset(x: clampedX(kind: kind, triggerMinX: trigger.minX),
                                y: trigger.maxY + TopBarMetrics.popoverGap)
                        .onExitCommand { close() }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .allowsHitTesting(open != nil)
    }

    private func clampedX(kind: TopBarPopoverKind, triggerMinX: CGFloat) -> CGFloat {
        let width = kind.width
        let available = shellSize.width > 0 ? shellSize.width : width + TopBarMetrics.paddingX * 2
        let maximum = available - width - TopBarMetrics.paddingX
        return min(max(TopBarMetrics.paddingX, triggerMinX), max(TopBarMetrics.paddingX, maximum))
    }

    @ViewBuilder
    private func content(_ kind: TopBarPopoverKind) -> some View {
        let cap = metrics.popoverHeight(preferred: kind.preferredHeight,
                                        windowHeight: shellSize.height)
        switch kind {
        case .project:
            TopBarProjectPopover(
                maxHeight: max(140, cap - 96),
                onSelect: { workspace in
                    settings.setActive(workspace)
                    close()
                },
                onAddSite: {
                    close()
                    destination = .sites
                    NotificationCenter.default.post(name: .requestAddSite, object: nil)
                }
            )
        case .navigation:
            TopBarPopoverPanel {
                VStack(spacing: 2) {
                    ForEach(Destination.allCases) { item in
                        TopBarPopoverRow(
                            title: item.rawValue,
                            isSelected: item == destination,
                            leading: { TopBarRowIcon(systemImage: item.icon) },
                            action: {
                                close()
                                select(item)
                            }
                        )
                    }
                }
            }
            .frame(width: TopBarPopoverKind.navigation.width)
        case .model:
            TopBarModelPopover(maxHeight: max(180, cap - 24), onSelect: { close() })
        case .status:
            TopBarStatusPopover(
                status: status,
                maxHeight: max(110, cap - 140),
                // The staged-change review UI lives in the Agent workspace;
                // this navigates to it rather than inventing a second one.
                onReviewChanges: {
                    close()
                    select(.agent)
                }
            )
        case .overflow:
            overflow
        }
    }

    /// Lower-priority actions only, and only ones that really exist elsewhere
    /// in the app. Project, model, status, and Stop are never in here.
    private var overflow: some View {
        TopBarPopoverPanel {
            VStack(spacing: 2) {
                if showsViewControls && metrics.viewControlPlacement == .overflow {
                    TopBarPopoverRow(
                        title: showsPreview
                            ? String(localized: "Hide live preview")
                            : String(localized: "Show live preview"),
                        isSelected: showsPreview,
                        leading: { TopBarRowIcon(systemImage: "rectangle.split.2x1") },
                        action: {
                            close()
                            setPreview(!showsPreview)
                        }
                    )
                    TopBarPopoverSeparator()
                }
                TopBarPopoverRow(
                    title: String(localized: "Saved chats"),
                    leading: { TopBarRowIcon(systemImage: "tray.full") },
                    action: {
                        close()
                        NotificationCenter.default.post(name: .requestConversations, object: nil)
                    }
                )
                TopBarPopoverRow(
                    title: String(localized: "Command Palette…"),
                    leading: { TopBarRowIcon(systemImage: "command") },
                    action: {
                        close()
                        NotificationCenter.default.post(name: .requestPalette, object: nil)
                    }
                )
                TopBarPopoverRow(
                    title: String(localized: "Debug Current Site…"),
                    isEnabled: settings.activeWorkspace != nil,
                    leading: { TopBarRowIcon(systemImage: "ladybug") },
                    action: {
                        close()
                        NotificationCenter.default.post(name: .requestDebug, object: nil)
                    }
                )
                TopBarPopoverSeparator()
                TopBarPopoverRow(
                    title: String(localized: "Add Website…"),
                    leading: { TopBarRowIcon(systemImage: "plus") },
                    action: {
                        close()
                        destination = .sites
                        NotificationCenter.default.post(name: .requestAddSite, object: nil)
                    }
                )
                TopBarPopoverRow(
                    title: updater.checking
                        ? String(localized: "Checking for Updates…")
                        : (updater.available.map { String(localized: "Update \($0.version)…") }
                           ?? String(localized: "Check for Updates…")),
                    isEnabled: !updater.checking && !updater.installing,
                    leading: {
                        TopBarRowIcon(
                            systemImage: updater.available == nil
                                ? "arrow.triangle.2.circlepath"
                                : "arrow.down.app"
                        )
                    },
                    action: {
                        close()
                        Task { await updater.check(feedURL: settings.updateFeedURL, userInitiated: true) }
                    }
                )
                TopBarPopoverRow(
                    title: String(localized: "Settings…"),
                    leading: { TopBarRowIcon(systemImage: "gearshape") },
                    action: {
                        close()
                        openSettings()
                    }
                )
            }
        }
        .frame(width: TopBarPopoverKind.overflow.width)
    }

    // MARK: Behaviour

    private func close() {
        withAnimation(Theme.Chrome.Timing.popoverClose) { open = nil }
    }

    private func select(_ item: Destination) {
        guard item != destination else { return }
        withAnimation(Theme.Chrome.Timing.selection) { destination = item }
    }

    private func setPreview(_ visible: Bool) {
        guard visible != showsPreview else { return }
        withAnimation(Theme.Chrome.Timing.selection) { showsPreview = visible }
    }
}
