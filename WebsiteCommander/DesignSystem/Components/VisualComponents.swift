import SwiftUI

// MARK: - Stable segmented control

/// A compact segmented control rendered entirely by SwiftUI.
///
/// macOS 27 can repeatedly re-enter AppKit while measuring SwiftUI's native
/// `.pickerStyle(.segmented)` bridge, especially when a segment contains an SF
/// Symbol. Keeping this control in the SwiftUI layout graph avoids that
/// platform bridge while preserving the same keyboard, focus, and accessibility
/// semantics as a small set of mutually exclusive buttons.
struct WCInlineSegmentedControl<Selection: Hashable, LabelContent: View>: View {
    @Binding private var selection: Selection
    private let items: [Selection]
    private let accessibilityLabel: String
    private let labelContent: (Selection) -> LabelContent

    init(
        selection: Binding<Selection>,
        items: [Selection],
        accessibilityLabel: String,
        @ViewBuilder label: @escaping (Selection) -> LabelContent
    ) {
        _selection = selection
        self.items = items
        self.accessibilityLabel = accessibilityLabel
        self.labelContent = label
    }

    var body: some View {
        HStack(spacing: 2) {
            ForEach(items, id: \.self) { item in
                let isSelected = selection == item
                Button {
                    // Do not publish a redundant binding write. This matters
                    // when the control is embedded in a measured toolbar.
                    guard selection != item else { return }
                    selection = item
                } label: {
                    labelContent(item)
                        .font(Theme.ui(11.5, isSelected ? .semibold : .medium))
                        .foregroundStyle(isSelected ? Theme.accent : Theme.secondaryText)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity)
                        .frame(height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .background(
                    isSelected ? Theme.accentSoft : .clear,
                    in: RoundedRectangle(cornerRadius: Theme.Radius.badge,
                                         style: .continuous)
                )
                .accessibilityAddTraits(isSelected ? [.isSelected] : [])
            }
        }
        .padding(2)
        .frame(maxWidth: .infinity)
        .background(
            Theme.secondarySurface,
            in: RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous)
        )
        .accessibilityElement(children: .contain)
        .accessibilityLabel(accessibilityLabel)
    }
}

// MARK: - Icon tile

/// A compact SF Symbol tile. Neutral tint is the default; callers opt into the
/// brand gradient only for a genuinely primary action.
struct IconTile: View {
    let systemImage: String
    var tint: Color = Theme.secondaryText
    /// The container behind the glyph. Defaults to a soft tint of `tint`, but a
    /// semantic accent can supply its own paired surface.
    var surface: Color?
    var size: CGFloat = Theme.Height.icon
    var gradient: Bool = false

    var body: some View {
        Image(systemName: systemImage)
            .font(.system(size: size * 0.46, weight: .semibold))
            .foregroundStyle(gradient ? .white : tint)
            .frame(width: size, height: size)
            .background(
                gradient ? AnyShapeStyle(Theme.brandGradient)
                         : AnyShapeStyle(surface ?? tint.opacity(0.12)),
                in: RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
            )
    }
}

extension IconTile {
    /// A tile in one of the app's semantic accents: accent glyph on its paired
    /// soft surface.
    init(systemImage: String, accent: Theme.Accent, size: CGFloat = Theme.Height.icon) {
        self.init(systemImage: systemImage,
                  tint: accent.color,
                  surface: accent.soft,
                  size: size)
    }
}

// MARK: - Stat tile

/// A visual metric card: big rounded number, label, and an icon tile.
struct StatTile: View {
    let title: String
    let value: String
    let systemImage: String
    var tint: Color = Theme.secondaryText
    /// When set, the icon slot shows this official brand mark instead of the SF Symbol.
    var brandID: BrandMarkID? = nil
    /// When true, the value is rendered as a medium label (for words like a
    /// provider name) instead of a large heavy number.
    var compact: Bool = false
    var caption: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            HStack {
                if let brandID {
                    BrandMark(id: brandID)
                        .fill(tint)
                        .padding(7)
                        .frame(width: 34, height: 34)
                        .background(tint.opacity(0.12),
                                    in: RoundedRectangle(cornerRadius: 34 * 0.28, style: .continuous))
                } else {
                    IconTile(systemImage: systemImage, tint: tint, size: 34, gradient: false)
                }
                Spacer()
            }
            VStack(alignment: .leading, spacing: 2) {
                if compact {
                    Text(value)
                        .font(.title3.weight(.semibold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                } else {
                    Text(value)
                        .font(Theme.display(28, weight: .heavy))
                        .contentTransition(.numericText())
                }
                Text(LocalizedStringKey(title))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                if let caption {
                    Text(caption)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .commandCard()
        .wcAppear()
    }
}

// MARK: - Badge

/// A compact status badge (tech stack, deployment target, status). Neutral by
/// default: a badge only takes an accent when the accent carries meaning.
struct Badge: View {
    let text: String
    var systemImage: String? = nil
    var tint: Color = Theme.secondaryText
    /// The chip behind the label. Defaults to a soft tint of `tint`.
    var surface: Color?

    var body: some View {
        HStack(spacing: 4) {
            if let systemImage {
                Image(systemName: systemImage)
                    .font(.system(size: 9.5, weight: .semibold))
            }
            Text(text).font(Theme.ui(10.5, .medium))
        }
        .padding(.horizontal, 7)
        .frame(height: Theme.Height.badge)
        .foregroundStyle(tint)
        .background(surface ?? tint.opacity(0.10),
                    in: RoundedRectangle(cornerRadius: Theme.Radius.badge, style: .continuous))
    }
}

// MARK: - Status dot

/// A tiny colored presence dot (green = ready, amber = needs attention, etc.).
/// A colour alone carries no meaning for screen readers or for anyone who can't
/// separate the hues, so a dot that reports state takes a `label`; a purely
/// decorative one stays hidden from assistive technology.
struct StatusDot: View {
    var color: Color = Theme.success
    var pulse: Bool = false
    var size: CGFloat = 9
    var label: String? = nil

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: size, height: size)
            .overlay(
                Circle().stroke(color.opacity(0.35), lineWidth: pulse ? 3 : 0)
            )
            .shadow(color: color.opacity(0.6), radius: pulse ? 4 : 1)
            .help(label ?? "")
            .accessibilityHidden(label == nil)
            .accessibilityLabel(label ?? "")
    }
}

// MARK: - Section header

/// A compact section title with an optional trailing accessory.
struct SectionHeader<Accessory: View>: View {
    let title: String
    var systemImage: String? = nil
    @ViewBuilder var accessory: Accessory

    var body: some View {
        HStack(spacing: Theme.Space.s) {
            if let systemImage {
                Image(systemName: systemImage)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.secondaryText)
            }
            Text(LocalizedStringKey(title))
                .font(Theme.ui(13, .semibold))
                .foregroundStyle(Theme.textPrimary)
            Spacer()
            accessory
        }
    }
}

extension SectionHeader where Accessory == EmptyView {
    init(title: String, systemImage: String? = nil) {
        self.title = title
        self.systemImage = systemImage
        self.accessory = EmptyView()
    }
}

// MARK: - Button styles

/// The hero action style: a solid primary fill and a white label. The brand
/// gradient stays reserved for the product mark, so a button never competes
/// with it.
struct PrimaryButtonStyle: ButtonStyle {
    var prominent: Bool = true
    /// The inline size: matches a 28pt field, for a button that sits beside one.
    var compact: Bool = false

    func makeBody(configuration: Configuration) -> some View {
        Surface(configuration: configuration, prominent: prominent, compact: compact)
    }

    private struct Surface: View {
        let configuration: Configuration
        let prominent: Bool
        let compact: Bool

        @Environment(\.isEnabled) private var isEnabled
        @Environment(\.isFocused) private var isFocused
        @Environment(\.accessibilityReduceMotion) private var reduceMotion
        @State private var isHovering = false

        private let shape = RoundedRectangle(cornerRadius: Theme.Radius.medium, style: .continuous)

        var body: some View {
            configuration.label
                .font(Theme.ui(compact ? 12 : 13, .semibold))
                .foregroundStyle(label)
                .padding(.horizontal, compact ? Theme.Space.m : Theme.Space.l)
                .padding(.vertical, compact ? 5 : Theme.Space.s + 2)
                .background(fill, in: shape)
                .overlay {
                    shape.strokeBorder(border, lineWidth: 1)
                }
                .overlay(alignment: .top) {
                    if prominent && isEnabled {
                        shape
                            .strokeBorder(Color.white.opacity(0.22), lineWidth: 1)
                            .mask(LinearGradient(colors: [.white, .clear],
                                                  startPoint: .top,
                                                  endPoint: .center))
                    }
                }
                .focusRing(isFocused, cornerRadius: Theme.Radius.medium)
                .scaleEffect(configuration.isPressed && !reduceMotion ? 0.97 : 1)
                .animation(Theme.Chrome.Timing.press, value: configuration.isPressed)
                .animation(Theme.Chrome.Timing.hover, value: isHovering)
                .onHover { isHovering = $0 }
                .shadow(color: prominent && isEnabled ? Theme.Shadow.key : .clear,
                        radius: prominent ? 6 : 0, y: prominent ? 2 : 0)
        }

        /// Disabled is neutral, never a pale accent: a washed-out indigo reads as
        /// an enabled control that has lost its colour.
        private var fill: Color {
            guard isEnabled else { return Theme.secondarySurface }
            guard prominent else { return Theme.accentSoft }
            if configuration.isPressed { return Theme.accentPressed }
            return isHovering ? Theme.accentHover : Theme.accent
        }

        private var label: Color {
            guard isEnabled else { return Theme.disabledText }
            return prominent ? Theme.textInverse : Theme.accentText
        }

        private var border: Color {
            guard isEnabled else { return Theme.borderSubtle }
            return prominent ? .clear : Theme.accentBorder
        }
    }
}

/// A borderless icon button used in toolbars, card corners, and beside field
/// headers.
struct IconButtonStyle: ButtonStyle {
    var size: CGFloat = 30
    var glyphSize: CGFloat = 15

    func makeBody(configuration: Configuration) -> some View {
        Surface(configuration: configuration, size: size, glyphSize: glyphSize)
    }

    private struct Surface: View {
        let configuration: Configuration
        let size: CGFloat
        let glyphSize: CGFloat

        @Environment(\.isEnabled) private var isEnabled
        @Environment(\.isFocused) private var isFocused
        @Environment(\.accessibilityReduceMotion) private var reduceMotion
        @State private var isHovering = false

        var body: some View {
            configuration.label
                .font(.system(size: glyphSize, weight: .medium))
                .foregroundStyle(label)
                .frame(width: size, height: size)
                .background(Circle().fill(fill))
                .focusRing(isFocused, cornerRadius: size / 2)
                .contentShape(Circle())
                .scaleEffect(configuration.isPressed && !reduceMotion ? 0.94 : 1)
                .animation(Theme.Chrome.Timing.press, value: configuration.isPressed)
                .animation(Theme.Chrome.Timing.hover, value: isHovering)
                .onHover { isHovering = $0 }
        }

        private var fill: Color {
            guard isEnabled else { return Theme.secondarySurface }
            if configuration.isPressed { return Theme.Chrome.controlPressed }
            return isHovering ? Theme.tertiarySurface : Theme.secondarySurface
        }

        private var label: Color {
            guard isEnabled else { return Theme.disabledText }
            return isHovering ? Theme.textPrimary : Theme.secondaryText
        }
    }
}

/// A quiet text button for a destructive row action ("Remove", "Clear"). The
/// destructive tint only fills in on hover, so a list of rows stays calm.
struct DestructiveTextButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        Surface(configuration: configuration)
    }

    private struct Surface: View {
        let configuration: Configuration

        @Environment(\.isEnabled) private var isEnabled
        @Environment(\.isFocused) private var isFocused
        @Environment(\.accessibilityReduceMotion) private var reduceMotion
        @State private var isHovering = false

        var body: some View {
            configuration.label
                .font(Theme.ui(12, .semibold))
                .foregroundStyle(isEnabled ? Theme.destructive : Theme.disabledText)
                .padding(.horizontal, Theme.Space.s + 2)
                .padding(.vertical, 5)
                .background(fill, in: Capsule())
                .focusRing(isFocused, shape: Capsule())
                .contentShape(Capsule())
                .scaleEffect(configuration.isPressed && !reduceMotion ? 0.97 : 1)
                .animation(Theme.Chrome.Timing.press, value: configuration.isPressed)
                .animation(Theme.Chrome.Timing.hover, value: isHovering)
                .onHover { isHovering = $0 }
        }

        private var fill: Color {
            guard isEnabled else { return .clear }
            if configuration.isPressed { return Theme.destructive.opacity(0.20) }
            return isHovering ? Theme.destructiveSoft : .clear
        }
    }
}

extension ButtonStyle where Self == PrimaryButtonStyle {
    static var primary: PrimaryButtonStyle { PrimaryButtonStyle() }
    static var primarySoft: PrimaryButtonStyle { PrimaryButtonStyle(prominent: false) }
    static var primaryCompact: PrimaryButtonStyle { PrimaryButtonStyle(compact: true) }
    static var primarySoftCompact: PrimaryButtonStyle {
        PrimaryButtonStyle(prominent: false, compact: true)
    }
}

extension ButtonStyle where Self == IconButtonStyle {
    static var icon: IconButtonStyle { IconButtonStyle() }
    /// The inline size, for a control that sits next to 11pt metadata.
    static var iconCompact: IconButtonStyle { IconButtonStyle(size: 20, glyphSize: 11) }
}

extension ButtonStyle where Self == DestructiveTextButtonStyle {
    static var destructiveText: DestructiveTextButtonStyle { DestructiveTextButtonStyle() }
}

// MARK: - Focus ring

/// The one focus treatment in the app: an indigo border on the control's own
/// edge plus a soft outer halo, so focus never relies on a colour swap alone.
struct FocusRing<S: InsettableShape>: ViewModifier {
    let focused: Bool
    let shape: S

    func body(content: Content) -> some View {
        content
            .overlay {
                shape.strokeBorder(focused ? Theme.focusRing : .clear, lineWidth: 1.5)
            }
            .overlay {
                shape.strokeBorder(focused ? Theme.focusRingHalo : .clear,
                                   lineWidth: Theme.Activity.haloWidth)
                    .padding(-Theme.Activity.haloWidth / 2)
            }
            .animation(Theme.Chrome.Timing.selection, value: focused)
    }
}

extension View {
    func focusRing<S: InsettableShape>(_ focused: Bool, shape: S) -> some View {
        modifier(FocusRing(focused: focused, shape: shape))
    }

    func focusRing(_ focused: Bool, cornerRadius: CGFloat) -> some View {
        focusRing(focused, shape: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }
}

// MARK: - Field chrome

/// The shared look of a text entry: a level-3 surface, one hairline, a single
/// height so stacked rows align, and the app's focus ring. Applying it also
/// strips the platform bezel, so callers pass a bare `TextField`/`SecureField`.
struct FieldChrome: ViewModifier {
    let focused: Bool

    @Environment(\.isEnabled) private var isEnabled

    func body(content: Content) -> some View {
        content
            .textFieldStyle(.plain)
            .font(Theme.ui(13))
            .foregroundStyle(isEnabled ? Theme.textPrimary : Theme.disabledText)
            .padding(.horizontal, Theme.Space.s + 2)
            .frame(height: Theme.Height.input)
            .background(isEnabled ? Theme.recessedSurface : Theme.secondarySurface,
                        in: RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous)
                    .strokeBorder(isEnabled ? Theme.borderSubtle : Theme.borderHairline, lineWidth: 1)
            }
            .overlay(alignment: .top) {
                RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.34), lineWidth: 1)
                    .mask(LinearGradient(colors: [.white, .clear],
                                          startPoint: .top,
                                          endPoint: .center))
            }
            .focusRing(focused, cornerRadius: Theme.Radius.small)
    }
}

extension View {
    /// Field chrome for a bare text entry. The caller owns focus (via
    /// `@FocusState`) because only it knows the field's identity.
    func fieldChrome(focused: Bool = false) -> some View {
        modifier(FieldChrome(focused: focused))
    }
}

// MARK: - Empty state

/// A friendly visual placeholder for lists/areas with no content yet. The hero is
/// the app's brand illustration; the state-specific `systemImage` is shown as a
/// small gradient chip so each empty state stays meaningful *and* on-brand.
struct EmptyStateView: View {
    let systemImage: String
    let title: String
    var message: String? = nil
    var actionTitle: String? = nil
    var action: (() -> Void)? = nil
    var useBrandArt: Bool = true

    var body: some View {
        VStack(spacing: Theme.Space.m) {
            ZStack(alignment: .bottomTrailing) {
                if useBrandArt {
                    BrandIllustration(size: 132)
                } else {
                    Image(systemName: systemImage)
                        .font(.system(size: 44, weight: .light))
                        .foregroundStyle(Theme.brandGradient)
                        .frame(width: 132, height: 108)
                }
                Image(systemName: systemImage)
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 34, height: 34)
                    .background(Theme.accent, in: Circle())
                    .overlay(Circle().strokeBorder(Theme.elevatedSurface, lineWidth: 2))
                    .cardElevation()
                    .offset(x: 6, y: 6)
            }
            .padding(.bottom, Theme.Space.s)
            Text(title)
                .font(.title3.weight(.semibold))
            if let message {
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 360)
            }
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .buttonStyle(.primary)
                    .padding(.top, Theme.Space.s)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(Theme.Space.xxl)
    }
}

/// Shared recoverable failure state. Copy always explains that user work remains
/// safe and provides one clear recovery action supplied by the caller.
struct ErrorStateView: View {
    let title: String
    let message: String
    var retryTitle = "Try Again"
    let retry: () -> Void

    var body: some View {
        VStack(spacing: Theme.Space.m) {
            LivingTabMark(size: 58, style: .monochrome)
                .foregroundStyle(Theme.danger)
            Text(title)
                .font(.title3.weight(.semibold))
                .foregroundStyle(Theme.textPrimary)
            Text(message)
                .font(.callout)
                .foregroundStyle(Theme.secondaryText)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
            Button(retryTitle, action: retry)
                .buttonStyle(.primarySoft)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(Theme.Space.xxl)
    }
}

// MARK: - Help button

/// A small "?" affordance that opens a popover with a plain-language explanation
/// and direct links to the relevant external configuration page (e.g. where to
/// create a GitHub token or a deploy hook).
struct HelpButton: View {
    let title: String
    let message: String
    var links: [(label: String, url: String)] = []

    @State private var showing = false

    var body: some View {
        Button { showing = true } label: {
            Image(systemName: "questionmark")
        }
        .buttonStyle(.iconCompact)
        .help(title)
        .accessibilityLabel("Help: \(title)")
        .popover(isPresented: $showing, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: Theme.Space.m) {
                Text(title).font(Theme.ui(13, .semibold))
                Text(message)
                    .font(Theme.ui(12))
                    .foregroundStyle(Theme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                if !links.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(links, id: \.url) { link in
                            Link(destination: URL(string: link.url)!) {
                                HStack(spacing: 4) {
                                    Text(link.label)
                                    Image(systemName: "arrow.up.right")
                                        .font(.caption2)
                                }
                                .font(.callout.weight(.medium))
                            }
                        }
                    }
                    .padding(.top, 2)
                }
            }
            .padding(Theme.Space.l)
            .frame(width: 330)
        }
    }
}

// MARK: - Field header

/// A field label row with an optional inline help popover.
struct FieldHeader: View {
    let label: String
    var help: HelpButton? = nil

    var body: some View {
        HStack(spacing: 5) {
            Text(LocalizedStringKey(label))
                .font(Theme.ui(11, .semibold))
                .foregroundStyle(Theme.secondaryText)
            if let help { help }
        }
    }
}

// MARK: - Form row

/// One row of a form: a small header above a full-width field, with optional
/// helper text underneath. Rows own the vertical rhythm so a stack of them
/// aligns without any call site nudging padding.
struct FormRow<Field: View>: View {
    let label: String
    var help: HelpButton? = nil
    /// Guidance that belongs to the field — a format hint, a default, a caveat.
    /// Never a second label: it sits below the field it describes.
    var footnote: String? = nil
    @ViewBuilder var field: Field

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            FieldHeader(label: label, help: help)
            field
            if let footnote {
                Text(LocalizedStringKey(footnote))
                    .font(Theme.ui(11))
                    .foregroundStyle(Theme.tertiaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Risk badge

/// Security-risk indicator for a staged change (High / Medium / Low / Clean).
struct RiskBadge: View {
    let level: RiskLevel

    enum RiskLevel: String {
        case high = "High risk"
        case medium = "Medium risk"
        case low = "Low risk"
        case clean = "No risks"

        var color: Color {
            switch self {
            case .high: return Theme.danger
            case .medium: return Theme.warning
            case .low: return Theme.info
            case .clean: return Theme.success
            }
        }

        var icon: String {
            switch self {
            case .high: return "exclamationmark.octagon.fill"
            case .medium: return "exclamationmark.triangle.fill"
            case .low: return "info.circle.fill"
            case .clean: return "checkmark.shield.fill"
            }
        }
    }

    var body: some View {
        Badge(text: level.rawValue, systemImage: level.icon, tint: level.color)
    }
}
