import SwiftUI

/// The application bar: one row, three structurally independent zones, one
/// material layer.
///
/// The zones are laid out as `[flexible, auto, flexible]`, so the centred
/// navigation stays centred in the window no matter how wide the left and right
/// zones happen to be — nothing here is centred by guessing padding. Both side
/// zones may compress to nothing (`min-width: 0`) so a long project or model
/// name can never force the bar wider than the window or push it onto a second
/// row.
///
/// Order, left to right: brand, divider, project · destinations · status,
/// model, divider, view controls, primary action, overflow.
struct TopBar: View {

    let metrics: TopBarMetrics
    /// The whole shell's size — the popover layer needs it to clamp menus
    /// inside the window and to size its click-outside area.
    let shellSize: CGSize
    @Binding var destination: Destination
    @Binding var showsPreview: Bool
    /// View controls only appear where the app really has more than one view —
    /// today that is the Agent workspace's split.
    let showsViewControls: Bool

    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var engine: AgentEngine
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.openSettings) private var openSettings

    /// Exactly one bar popover can be open, by construction.
    @State private var openPopover: TopBarPopoverKind?

    private var status: AgentStatusPresentation {
        .from(state: engine.state, pendingChanges: engine.pendingChanges.count)
    }

    // MARK: Body

    var body: some View {
        HStack(spacing: TopBarMetrics.zoneGap) {
            leftZone
            centerZone
            rightZone
        }
        .padding(.horizontal, TopBarMetrics.paddingX)
        .frame(height: metrics.height)
        .frame(maxWidth: .infinity)
        .background {
            TopBarMaterial()
                .background { WindowDragArea() }
        }
        .overlayPreferenceValue(TopBarTriggerAnchorKey.self) { anchors in
            popoverLayer(anchors: anchors)
        }
        .animation(Theme.Chrome.Timing.selection, value: metrics.density)
    }

    // MARK: Left zone

    private var leftZone: some View {
        HStack(spacing: TopBarMetrics.leftZoneGap) {
            brand
            TopBarDivider()
            TopBarProjectControl(
                metrics: metrics,
                isOpen: openPopover == .project,
                onToggle: { toggle(.project) }
            )
            Spacer(minLength: 0)
        }
        // The hidden titlebar puts the window's traffic lights inside the bar;
        // this is the room they occupy, not decorative padding.
        .padding(.leading, TopBarMetrics.trafficLightInset - TopBarMetrics.paddingX)
        .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
        .clipped()
    }

    /// The product lockup: the existing mark plus the wordmark. There is no
    /// application-level menu behind it, so it stays a non-interactive lockup
    /// with no hover state rather than pretending to be a control.
    private var brand: some View {
        HStack(spacing: 8) {
            LivingTabMark(size: TopBarMetrics.brandMarkSize, style: .gradient, animated: false)
            if metrics.showsWordmark {
                Text("Website Commander")
                    .font(Theme.ui(14, .semibold))
                    .tracking(-0.21)
                    .foregroundStyle(Theme.Chrome.textPrimary)
                    .lineLimit(1)
            }
        }
        .padding(.leading, 6)
        .padding(.trailing, 8)
        .frame(height: TopBarMetrics.brandHeight)
        .fixedSize()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Website Commander")
    }

    // MARK: Center zone

    private var centerZone: some View {
        Group {
            switch metrics.navigationStyle {
            case .destinations:
                destinationRow
            case .selector:
                destinationSelector
            }
        }
        .fixedSize()
        .layoutPriority(1)
    }

    private var destinationRow: some View {
        HStack(spacing: 2) {
            ForEach(Destination.allCases) { item in
                TopBarNavigationItem(
                    item: item,
                    isActive: item == destination,
                    action: { select(item) }
                )
            }
        }
        .padding(3)
        .frame(height: TopBarMetrics.navigationContainerHeight)
        .background {
            RoundedRectangle(cornerRadius: TopBarMetrics.groupRadius, style: .continuous)
                .fill(Theme.Chrome.barGroupFill)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Destinations")
    }

    /// The same navigation, reduced to one control. Below 1200pt five items
    /// would have to steal width from the project or model control.
    private var destinationSelector: some View {
        Button { toggle(.navigation) } label: {
            HStack(spacing: 6) {
                Image(systemName: destination.icon)
                    .font(.system(size: TopBarMetrics.navigationIconSize, weight: .medium))
                    .foregroundStyle(Theme.Chrome.accent)
                Text(destination.barLabel)
                    .font(Theme.ui(13, .medium))
                    .tracking(-0.13)
                    .foregroundStyle(Theme.Chrome.textPrimary)
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Theme.Chrome.textMuted)
                    .frame(width: TopBarMetrics.chevronSize,
                           height: TopBarMetrics.chevronSize)
            }
            .padding(.horizontal, 10)
            .frame(height: TopBarMetrics.controlHeight)
        }
        .buttonStyle(TopBarControlButtonStyle(
            radius: TopBarMetrics.controlRadius,
            emphasis: openPopover == .navigation ? .selected : .resting
        ))
        .help("Go to a destination")
        .accessibilityLabel("\(String(localized: "Destination")): \(destination.rawValue)")
        .accessibilityValue(openPopover == .navigation ? "Expanded" : "Collapsed")
        .topBarTrigger(.navigation)
    }

    // MARK: Right zone

    private var rightZone: some View {
        HStack(spacing: TopBarMetrics.groupGap) {
            Spacer(minLength: 0)
            TopBarStatusControl(
                status: status,
                showsLabel: metrics.showsStatusLabel,
                isOpen: openPopover == .status,
                onToggle: { toggle(.status) }
            )
            TopBarModelControl(
                metrics: metrics,
                isOpen: openPopover == .model,
                onToggle: { toggle(.model) }
            )
            if barHostsViewControls {
                TopBarDivider()
                viewControls
            }
            TopBarPrimaryAction(
                isRunning: engine.state.isActive,
                showsLabel: metrics.primaryActionShowsLabel,
                action: primaryAction
            )
            TopBarIconButton(
                title: String(localized: "More actions"),
                systemImage: "ellipsis",
                isSelected: openPopover == .overflow,
                radius: TopBarMetrics.popoverRowRadius,
                action: { toggle(.overflow) }
            )
            .topBarTrigger(.overflow)
        }
        .frame(minWidth: 0, maxWidth: .infinity, alignment: .trailing)
    }

    private var barHostsViewControls: Bool {
        showsViewControls && metrics.viewControlPlacement != .overflow
    }

    /// One coherent group for the workspace's real view modes. There are two —
    /// the conversation alone, or the conversation beside the live preview — so
    /// the group has two cells and invents nothing.
    @ViewBuilder
    private var viewControls: some View {
        switch metrics.viewControlPlacement {
        case .group:
            TopBarControlGroup {
                TopBarIconButton(
                    title: String(localized: "Conversation only"),
                    systemImage: "rectangle",
                    isSelected: !showsPreview,
                    action: { setPreview(false) }
                )
                TopBarIconButton(
                    title: String(localized: "Conversation and live preview"),
                    systemImage: "rectangle.split.2x1",
                    isSelected: showsPreview,
                    action: { setPreview(true) }
                )
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Workspace view")
        case .essential:
            TopBarIconButton(
                title: showsPreview
                    ? String(localized: "Hide live preview")
                    : String(localized: "Show live preview"),
                systemImage: "rectangle.split.2x1",
                isSelected: showsPreview,
                action: { setPreview(!showsPreview) }
            )
        case .overflow:
            EmptyView()
        }
    }

    // MARK: Popover layer

    /// One layer, one popover, positioned 8pt under its trigger and aligned to
    /// the trigger's leading edge. It lives here rather than in the shell so the
    /// bar owns its own menus, and it is drawn above the workspace because the
    /// bar is the shell's top safe-area inset.
    @ViewBuilder
    private func popoverLayer(anchors: [TopBarPopoverKind: Anchor<CGRect>]) -> some View {
        GeometryReader { proxy in
            ZStack(alignment: .topLeading) {
                if openPopover != nil {
                    // Click-outside: behaves like a menu's event-swallowing
                    // window, but stays inside the app's own hierarchy.
                    Rectangle()
                        .fill(Color.black.opacity(0.0001))
                        .frame(width: max(shellSize.width, proxy.size.width),
                               height: max(shellSize.height, proxy.size.height))
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

                if let kind = openPopover, let anchor = anchors[kind] {
                    let trigger = proxy[anchor]
                    popoverContent(kind)
                        .modifier(TopBarPopoverTransition(reduceMotion: reduceMotion))
                        .offset(x: clampedX(kind: kind, triggerMinX: trigger.minX),
                                y: trigger.maxY + TopBarMetrics.popoverGap)
                        .onExitCommand { close() }
                }
            }
        }
    }

    private func clampedX(kind: TopBarPopoverKind, triggerMinX: CGFloat) -> CGFloat {
        let width = kind.width
        let available = shellSize.width > 0 ? shellSize.width : width + TopBarMetrics.paddingX * 2
        let maximum = available - width - TopBarMetrics.paddingX * 2
        return min(max(0, triggerMinX), max(0, maximum))
    }

    @ViewBuilder
    private func popoverContent(_ kind: TopBarPopoverKind) -> some View {
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
            overflowPopover
        }
    }

    /// Lower-priority actions only, and only ones that really exist elsewhere
    /// in the app. Project, model, status, and Stop are never in here.
    private var overflowPopover: some View {
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

    private func toggle(_ kind: TopBarPopoverKind) {
        if openPopover == kind {
            close()
        } else {
            withAnimation(Theme.Chrome.Timing.popoverOpen) { openPopover = kind }
        }
    }

    private func close() {
        withAnimation(Theme.Chrome.Timing.popoverClose) { openPopover = nil }
    }

    private func select(_ item: Destination) {
        guard item != destination else { return }
        withAnimation(Theme.Chrome.Timing.selection) { destination = item }
    }

    private func setPreview(_ visible: Bool) {
        guard visible != showsPreview else { return }
        withAnimation(Theme.Chrome.Timing.selection) { showsPreview = visible }
    }

    /// The one contextual action: start a new change, or stop the run in
    /// progress. Both are the engine's existing behaviour.
    private func primaryAction() {
        if engine.state.isActive {
            engine.cancelGeneration()
        } else {
            engine.newChat()
            destination = .agent
        }
    }
}

// MARK: - Navigation item

/// One destination in the centred row. The active item is a restrained elevated
/// surface with a hairline and a slightly stronger label — never the brightest
/// object on screen.
private struct TopBarNavigationItem: View {
    let item: Destination
    let isActive: Bool
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: item.icon)
                    .font(.system(size: TopBarMetrics.navigationIconSize, weight: .medium))
                Text(item.barLabel)
                    .font(Theme.ui(13, .medium))
                    .tracking(-0.13)
                    .lineLimit(1)
            }
            .foregroundStyle(foreground)
            .padding(.horizontal, 10)
            .frame(height: TopBarMetrics.navigationItemHeight)
        }
        .buttonStyle(TopBarControlButtonStyle(
            radius: TopBarMetrics.popoverRowRadius,
            emphasis: isActive ? .selected : .quiet
        ))
        .onHover { hovering in
            withAnimation(Theme.Chrome.Timing.hover) { isHovering = hovering }
        }
        .help(item.rawValue)
        .accessibilityLabel(item.rawValue)
        .accessibilityAddTraits(isActive ? [.isSelected] : [])
        .accessibilityValue(isActive ? String(localized: "Current page") : "")
    }

    private var foreground: Color {
        if isActive { return Theme.Chrome.textPrimary }
        return isHovering ? Theme.Chrome.textPrimary : Theme.Chrome.textSecondary
    }
}

// MARK: - Primary contextual action

/// New and Stop are one control with one footprint. Nothing in the right zone
/// moves when the agent starts or stops.
private struct TopBarPrimaryAction: View {
    let isRunning: Bool
    let showsLabel: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: isRunning ? "stop.fill" : "plus")
                    .font(.system(size: isRunning ? 12 : TopBarMetrics.iconSize,
                                  weight: .semibold))
                if showsLabel {
                    Text(isRunning ? String(localized: "Stop") : String(localized: "New"))
                        .font(Theme.ui(13, .medium))
                        .lineLimit(1)
                }
            }
            .foregroundStyle(isRunning ? AnyShapeStyle(Theme.warning) : AnyShapeStyle(Color.white))
            .frame(width: showsLabel ? TopBarMetrics.primaryActionLabelledWidth
                                     : TopBarMetrics.controlHeight,
                   height: TopBarMetrics.controlHeight)
        }
        .buttonStyle(TopBarControlButtonStyle(
            radius: TopBarMetrics.controlRadius,
            emphasis: isRunning ? .semantic(Theme.warning) : .accent
        ))
        // No shortcut is attached here: ⌘N already lives in the File menu and
        // ⌘. on the composer's stop control. Duplicating either would make the
        // binding ambiguous.
        .help(isRunning ? "Stop the agent" : "New change")
        .accessibilityLabel(isRunning ? String(localized: "Stop the agent")
                                      : String(localized: "New change"))
        .animation(Theme.Chrome.Timing.status, value: isRunning)
    }
}
