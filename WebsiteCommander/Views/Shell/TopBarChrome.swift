import SwiftUI
import AppKit

// MARK: - The one material layer

/// The application bar's surface — and the app's *only* blur layer.
///
/// Controls that sit on it tint it rather than blurring again, which is what
/// keeps the chrome reading as one machined bar instead of a tray of floating
/// glass pills. Under Reduce Transparency the blur is replaced by an opaque
/// elevated token so the border and separation survive.
struct TopBarMaterial: View {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        ZStack {
            if reduceTransparency {
                Rectangle().fill(Theme.Chrome.barFillOpaque)
            } else {
                Rectangle().fill(.ultraThinMaterial)
                Rectangle().fill(Theme.Chrome.barGradient)
            }
        }
        .overlay(alignment: .top) {
            Rectangle()
                .fill(Theme.Chrome.barHighlight)
                .frame(height: 1)
        }
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Theme.Chrome.barBorder)
                .frame(height: 0.5)
        }
        .compositingGroup()
        .shadow(color: Theme.Chrome.barShadow, radius: 7, y: 2)
    }
}

/// Makes the bar's background drag the window, which the hidden titlebar would
/// otherwise take away. AppKit consults `mouseDownCanMoveWindow` on whichever
/// view is hit, so this sits behind the bar's controls and only answers for the
/// empty space between them.
struct WindowDragArea: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { DragBackingView() }
    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class DragBackingView: NSView {
        override var mouseDownCanMoveWindow: Bool { true }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    }
}

// MARK: - Hairline divider

/// The shared zone separator: 1×18, fainter than any card border.
struct TopBarDivider: View {
    var body: some View {
        Rectangle()
            .fill(Theme.Chrome.separator)
            .frame(width: 1, height: TopBarMetrics.dividerHeight)
            .padding(.horizontal, TopBarMetrics.dividerMargin)
            .accessibilityHidden(true)
    }
}

// MARK: - Control surfaces

/// How much presence a control claims at rest.
enum TopBarEmphasis {
    /// Invisible until hovered. For icon actions inside a group.
    case quiet
    /// A resting translucent tint. For the project control.
    case resting
    /// The selected state: a restrained tint without a raised pill.
    case selected
    /// The primary contextual action, using the product accent sparingly.
    case accent
    /// A soft, permanently tinted identity for one control — the model
    /// selector's violet. Carries its own hover and border tints.
    case tinted(Theme.Accent)
    /// A restrained semantic treatment, e.g. Stop.
    case semantic(Color)
}

/// The single background used by every control in the bar. Depth comes from
/// surface contrast and one inner highlight — never from shadows or heavy
/// borders on individual controls.
struct TopBarControlSurface: View {
    var radius: CGFloat
    var emphasis: TopBarEmphasis
    var isHovering: Bool = false
    var isPressed: Bool = false

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: radius, style: .continuous)
    }

    var body: some View {
        shape
            .fill(fill)
            .overlay {
                if let border {
                    shape.strokeBorder(border, lineWidth: 1)
                }
            }
            .overlay(alignment: .top) {
                if showsInnerHighlight {
                    shape
                        .strokeBorder(Theme.Chrome.barHighlight.opacity(0.55), lineWidth: 1)
                        .mask(
                            LinearGradient(colors: [.white, .clear],
                                           startPoint: .top,
                                           endPoint: .center)
                        )
                }
            }
            .shadow(color: isAccent ? Theme.Shadow.key : .clear,
                    radius: isAccent ? 6 : 0,
                    y: isAccent ? 2 : 0)
    }

    private var fill: AnyShapeStyle {
        switch emphasis {
        case .quiet:
            if isPressed { return AnyShapeStyle(Theme.Chrome.barControlPressed) }
            return AnyShapeStyle(isHovering ? Theme.Chrome.barControlHover : Color.clear)
        case .resting:
            if isPressed { return AnyShapeStyle(Theme.Chrome.barControlPressed) }
            return AnyShapeStyle(isHovering ? Theme.Chrome.barControlHover : Theme.Chrome.barControlFill)
        case .selected:
            if isPressed { return AnyShapeStyle(Theme.Chrome.barControlPressed) }
            if isHovering { return AnyShapeStyle(Theme.Chrome.barControlHover) }
            return AnyShapeStyle(Theme.Chrome.barControlActiveGradient)
        case .accent:
            let base = isPressed ? Theme.accentPressed : Theme.accent
            return AnyShapeStyle(isHovering && !isPressed ? Theme.accentHover : base)
        case .tinted(let accent):
            // Rest is the accent's soft surface; hover and press strengthen it
            // by layering the accent itself rather than fading the tint.
            if isPressed { return AnyShapeStyle(accent.color.opacity(0.22)) }
            if isHovering { return AnyShapeStyle(accent.color.opacity(0.15)) }
            return AnyShapeStyle(accent.soft)
        case .semantic(let color):
            return AnyShapeStyle(color.opacity(isPressed ? 0.24 : (isHovering ? 0.18 : 0.12)))
        }
    }

    private var border: Color? {
        switch emphasis {
        case .quiet: return nil
        case .resting: return nil
        case .selected: return Theme.Chrome.barControlBorderActive
        case .accent: return nil
        case .tinted(let accent): return accent.color.opacity(0.22)
        case .semantic(let color): return color.opacity(0.28)
        }
    }

    private var showsInnerHighlight: Bool {
        switch emphasis {
        case .selected, .accent: return true
        default: return false
        }
    }

    private var isAccent: Bool {
        if case .accent = emphasis { return true }
        return false
    }
}

/// A 2pt keyboard focus ring derived from the accent, offset by a transparent
/// 2pt gap. Focus is never signalled by colour change alone.
private struct TopBarFocusRing: ViewModifier {
    var radius: CGFloat
    var isFocused: Bool

    func body(content: Content) -> some View {
        content.overlay {
            RoundedRectangle(cornerRadius: radius + 3, style: .continuous)
                .strokeBorder(Theme.Chrome.accent.opacity(isFocused ? 0.9 : 0), lineWidth: 2)
                .padding(-3)
        }
    }
}

extension View {
    func topBarFocusRing(radius: CGFloat, isFocused: Bool) -> some View {
        modifier(TopBarFocusRing(radius: radius, isFocused: isFocused))
    }
}

/// The shared button style for every control in the bar: it owns hover, press,
/// focus, and disabled so no call site invents its own.
struct TopBarControlButtonStyle: ButtonStyle {
    var radius: CGFloat = TopBarMetrics.controlRadius
    var emphasis: TopBarEmphasis = .resting

    func makeBody(configuration: Configuration) -> some View {
        Surface(configuration: configuration, radius: radius, emphasis: emphasis)
    }

    private struct Surface: View {
        let configuration: Configuration
        let radius: CGFloat
        let emphasis: TopBarEmphasis

        @Environment(\.isEnabled) private var isEnabled
        @Environment(\.isFocused) private var isFocused
        @Environment(\.accessibilityReduceMotion) private var reduceMotion
        @State private var isHovering = false

        var body: some View {
            configuration.label
                .background {
                    TopBarControlSurface(
                        radius: radius,
                        emphasis: emphasis,
                        isHovering: isHovering && isEnabled,
                        isPressed: configuration.isPressed
                    )
                }
                .contentShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
                .topBarFocusRing(radius: radius, isFocused: isFocused)
                .scaleEffect(configuration.isPressed && !reduceMotion ? 0.985 : 1)
                .opacity(isEnabled ? 1 : 0.42)
                .animation(Theme.Chrome.Timing.hover, value: isHovering)
                .animation(Theme.Chrome.Timing.press, value: configuration.isPressed)
                .onHover { hovering in isHovering = hovering }
        }
    }
}

    /// A compact icon action with an accessible name, tooltip, and focus ring.
struct TopBarIconButton: View {
    let title: String
    let systemImage: String
    var isSelected: Bool = false
    var emphasis: TopBarEmphasis?
    var isEnabled: Bool = true
    /// 8pt inside a group; the standalone overflow control uses 9.
    var radius: CGFloat = TopBarMetrics.smallControlRadius
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: TopBarMetrics.iconSize, weight: .medium))
                .foregroundStyle(isSelected ? Theme.Chrome.accent : Theme.Chrome.textSecondary)
                .frame(width: TopBarMetrics.smallControlSize,
                       height: TopBarMetrics.smallControlSize)
        }
        .buttonStyle(TopBarControlButtonStyle(
            radius: radius,
            emphasis: emphasis ?? (isSelected ? .selected : .quiet)
        ))
        .disabled(!isEnabled)
        .help(title)
        .accessibilityLabel(title)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// A grouped container for related controls, so a family of actions reads as
/// one machined control rather than several independently bordered squares.
struct TopBarControlGroup<Content: View>: View {
    var height: CGFloat = TopBarMetrics.viewGroupHeight
    var radius: CGFloat = TopBarMetrics.viewGroupRadius
    var padding: CGFloat = 2
    var spacing: CGFloat = 2
    @ViewBuilder var content: Content

    var body: some View {
        HStack(spacing: spacing) { content }
            .padding(padding)
            .frame(height: height)
            .background {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(Theme.Chrome.barGroupFill)
            }
    }
}

// MARK: - One popover system

/// Every menu the bar opens is one of these, and only one may be open at a
/// time. Keeping them in an enum is what makes that guarantee structural
/// rather than a convention.
enum TopBarPopoverKind: String, Hashable, Identifiable {
    case project
    case navigation
    case model
    case status
    case overflow

    var id: String { rawValue }

    /// Popover width, per the shell's design system.
    var width: CGFloat {
        switch self {
        case .project: return 280
        case .navigation: return 236
        case .model: return 320
        case .status: return 288
        case .overflow: return 272
        }
    }

    /// Preferred maximum height before the window cap applies.
    var preferredHeight: CGFloat {
        switch self {
        case .project: return 420
        case .navigation: return 320
        case .model: return 480
        case .status: return 300
        case .overflow: return 420
        }
    }
}

/// Publishes each trigger's frame so the shell can place its popover 8pt below
/// it, aligned to its leading edge, without any absolute layout in the bar.
struct TopBarTriggerAnchorKey: PreferenceKey {
    static let defaultValue: [TopBarPopoverKind: Anchor<CGRect>] = [:]

    static func reduce(value: inout [TopBarPopoverKind: Anchor<CGRect>],
                       nextValue: () -> [TopBarPopoverKind: Anchor<CGRect>]) {
        value.merge(nextValue()) { _, new in new }
    }
}

extension View {
    /// Marks this control as the anchor for a top-bar popover.
    func topBarTrigger(_ kind: TopBarPopoverKind) -> some View {
        anchorPreference(key: TopBarTriggerAnchorKey.self, value: .bounds) { [kind: $0] }
    }
}

/// The shared popover shell: an opaque elevated surface — deliberately *not*
/// the bar's blur, because menus have to stay legible — with the shared radius,
/// hairline, padding, and shadow.
struct TopBarPopoverPanel<Content: View>: View {
    @ViewBuilder var content: Content

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: TopBarMetrics.popoverRadius, style: .continuous)
    }

    var body: some View {
        content
            .padding(8)
            .background(Theme.Chrome.popoverFill, in: shape)
            .overlay { shape.strokeBorder(Theme.Chrome.popoverBorder, lineWidth: 1) }
            .clipShape(shape)
            .shadow(color: Theme.Chrome.popoverShadow, radius: 22, y: 12)
    }
}

/// A section label inside a popover: 11/600 with restrained tracking.
struct TopBarPopoverSectionLabel: View {
    let text: String

    var body: some View {
        Text(LocalizedStringKey(text))
            .font(Theme.ui(11, .semibold))
            .tracking(0.3)
            .foregroundStyle(Theme.Chrome.textMuted)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 9)
            .padding(.top, 6)
            .padding(.bottom, 3)
            .accessibilityAddTraits(.isHeader)
    }
}

/// A popover row: 40pt tall, 9pt radius, subtle active surface plus a
/// checkmark for the selected item — never a gradient-filled row.
struct TopBarPopoverRow<Leading: View, Trailing: View>: View {
    var title: String
    var subtitle: String?
    var isSelected: Bool = false
    var isEnabled: Bool = true
    @ViewBuilder var leading: Leading
    @ViewBuilder var trailing: Trailing
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                leading
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(Theme.ui(13, .medium))
                        .foregroundStyle(Theme.Chrome.textPrimary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    if let subtitle, !subtitle.isEmpty {
                        Text(subtitle)
                            .font(Theme.ui(11, .regular))
                            .foregroundStyle(Theme.Chrome.textMuted)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                Spacer(minLength: 6)
                trailing
                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Theme.Chrome.accent)
                }
            }
            .padding(.horizontal, 9)
            .frame(minHeight: 38)
            .frame(height: subtitle == nil ? 40 : nil)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(PopoverRowStyle(isSelected: isSelected))
        .disabled(!isEnabled)
    }

    private struct PopoverRowStyle: ButtonStyle {
        let isSelected: Bool

        func makeBody(configuration: Configuration) -> some View {
            RowSurface(configuration: configuration, isSelected: isSelected)
        }

        private struct RowSurface: View {
            let configuration: Configuration
            let isSelected: Bool
            @Environment(\.isEnabled) private var isEnabled
            @Environment(\.isFocused) private var isFocused
            @State private var isHovering = false

            var body: some View {
                let shape = RoundedRectangle(cornerRadius: TopBarMetrics.popoverRowRadius,
                                             style: .continuous)
                configuration.label
                    .background {
                        shape.fill(fill)
                    }
                    .contentShape(shape)
                    .topBarFocusRing(radius: TopBarMetrics.popoverRowRadius, isFocused: isFocused)
                    .opacity(isEnabled ? 1 : 0.4)
                    .animation(Theme.Chrome.Timing.hover, value: isHovering)
                    .onHover { isHovering = $0 }
            }

            private var fill: Color {
                if configuration.isPressed { return Theme.Chrome.popoverRowSelected }
                if isSelected { return Theme.Chrome.popoverRowSelected }
                return isHovering && isEnabled ? Theme.Chrome.popoverRowHover : .clear
            }
        }
    }
}

extension TopBarPopoverRow where Leading == EmptyView, Trailing == EmptyView {
    init(title: String,
         subtitle: String? = nil,
         isSelected: Bool = false,
         isEnabled: Bool = true,
         action: @escaping () -> Void) {
        self.init(title: title,
                  subtitle: subtitle,
                  isSelected: isSelected,
                  isEnabled: isEnabled,
                  leading: { EmptyView() },
                  trailing: { EmptyView() },
                  action: action)
    }
}

extension TopBarPopoverRow where Trailing == EmptyView {
    init(title: String,
         subtitle: String? = nil,
         isSelected: Bool = false,
         isEnabled: Bool = true,
         @ViewBuilder leading: () -> Leading,
         action: @escaping () -> Void) {
        self.init(title: title,
                  subtitle: subtitle,
                  isSelected: isSelected,
                  isEnabled: isEnabled,
                  leading: leading,
                  trailing: { EmptyView() },
                  action: action)
    }
}

/// A leading glyph for popover rows, sized to the shared 16pt icon scale.
struct TopBarRowIcon: View {
    let systemImage: String
    var tint: Color = Theme.Chrome.textSecondary

    var body: some View {
        Image(systemName: systemImage)
            .font(.system(size: TopBarMetrics.iconSize, weight: .medium))
            .foregroundStyle(tint)
            .frame(width: 18, height: 18)
    }
}

/// The transition every top-bar popover uses: 150ms in, 110ms out, no delayed
/// exit, and a static fade under Reduce Motion.
struct TopBarPopoverTransition: ViewModifier {
    let reduceMotion: Bool

    func body(content: Content) -> some View {
        content.transition(
            .asymmetric(
                insertion: reduceMotion
                    ? .opacity
                    : .opacity.combined(with: .offset(y: -3)).combined(with: .scale(scale: 0.985, anchor: .top)),
                removal: .opacity
            )
        )
    }
}
