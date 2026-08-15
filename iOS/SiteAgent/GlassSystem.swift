import SwiftUI

// MARK: - Optical glass roles

/// One coherent optical hierarchy for the whole app. Every role is backed by a
/// live, colorless system material rather than a static fill.
enum GlassRole: Sendable {
    case hero
    case card
    case button
    case capsule
    case icon
    case badge
    case tabBar
    case toolbarButton
    case listRow
    case composer
    case composerField

    fileprivate var cornerRadius: CGFloat {
        switch self {
        case .hero: return 24
        case .card, .listRow: return 18
        case .button: return 16
        case .composer: return 30
        case .composerField: return 20
        case .capsule, .badge: return 999
        case .icon, .toolbarButton: return 14
        case .tabBar: return 30
        }
    }

    fileprivate var contentMaterial: Material {
        switch self {
        case .hero: return .ultraThin
        case .card: return .thin
        case .listRow: return .regular
        case .button, .capsule, .icon, .badge, .tabBar, .toolbarButton, .composer, .composerField: return .ultraThin
        }
    }

    fileprivate var shadowRadius: CGFloat {
        switch self {
        case .hero: return 10
        case .card, .listRow: return 8
        case .button, .tabBar, .composer: return 7
        case .capsule, .icon, .badge, .toolbarButton, .composerField: return 5
        }
    }

    fileprivate var shadowY: CGFloat {
        switch self {
        case .hero: return 6
        case .card, .listRow, .composer: return 4
        default: return 3
        }
    }

    fileprivate var isInteractive: Bool {
        switch self {
        case .button, .capsule, .icon, .badge, .toolbarButton, .tabBar, .composer, .composerField: return true
        case .hero, .card, .listRow: return false
        }
    }

    /// Preserve a visible optical rim on compact controls while keeping broad
    /// surfaces transparent enough for wallpaper detail to read through.
    fileprivate var materialOpacity: Double {
        switch self {
        case .hero, .card, .listRow: return 0.30
        case .button: return 0.34
        // The composer sits over dense scrolling content, so it gets a
        // stronger native plate plus a separate field layer. Both remain
        // untinted `.clear` glass and sample the live backdrop.
        case .composer: return 0.72
        case .composerField: return 0.62
        case .capsule, .icon, .badge, .toolbarButton, .tabBar: return 0.52
        }
    }
}

// MARK: - Single material renderer

@available(iOS 26.0, *)
private func nativeGlass(
    role: GlassRole
) -> Glass {
    // This skin deliberately selects Apple's high-transparency variant in both
    // appearances. Do not add `.tint`: color must come only from the live
    // content behind the material.
    var glass: Glass = .clear
    if role.isInteractive { glass = glass.interactive() }
    return glass
}

private struct GlassSurfaceModifier: ViewModifier {
    let role: GlassRole
    let cornerRadius: CGFloat?
    let accentReflection: Color?

    @ViewBuilder
    func body(content: Content) -> some View {
        let radius = cornerRadius ?? role.cornerRadius
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)

        if #available(iOS 26.0, *) {
            // Keep Liquid Glass out of layout measurement. On iOS 27, applying
            // glassEffect directly to flexible button/list content can enlarge
            // its optical bounds and make the whole row overflow the screen.
            // A geometry-locked, colorless backdrop preserves the original
            // content size while still letting the system render live blur,
            // refraction, edge light and interaction.
            content.background {
                GeometryReader { geometry in
                    Color.clear
                        .frame(width: geometry.size.width, height: geometry.size.height)
                        .glassEffect(
                            nativeGlass(role: role),
                            in: .rect(cornerRadius: radius)
                        )
                        // `.clear` remains Apple's native material; reducing only
                        // the material layer's alpha prevents large light-mode
                        // panes from reading as opaque white paint.
                        .opacity(role.materialOpacity)
                }
            }
        } else {
            content.background(.ultraThinMaterial, in: shape)
        }
    }
}

extension View {
    func glassSurface(
        _ role: GlassRole = .card,
        cornerRadius: CGFloat? = nil,
        accentReflection: Color? = nil
    ) -> some View {
        modifier(GlassSurfaceModifier(
            role: role,
            cornerRadius: cornerRadius,
            accentReflection: accentReflection
        ))
    }

    /// Keeps the existing classic skin intact while routing Clear Glass through
    /// the single native renderer.
    func adaptiveGlassSurface(
        _ role: GlassRole,
        cornerRadius: CGFloat,
        accentReflection: Color? = nil,
        classicFill: Color = Theme.chip
    ) -> some View {
        modifier(AdaptiveGlassSurfaceModifier(
            role: role,
            cornerRadius: cornerRadius,
            accentReflection: accentReflection,
            classicFill: classicFill
        ))
    }
}

private struct AdaptiveGlassSurfaceModifier: ViewModifier {
    let role: GlassRole
    let cornerRadius: CGFloat
    let accentReflection: Color?
    let classicFill: Color
    private let glass = Theme.isGlass

    @ViewBuilder
    func body(content: Content) -> some View {
        if glass {
            content.glassSurface(role, cornerRadius: cornerRadius, accentReflection: accentReflection)
        } else {
            let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            content
                .background(classicFill, in: shape)
                .overlay(shape.strokeBorder(Theme.separator, lineWidth: 0.5))
        }
    }
}

// MARK: - Semantic glass components

struct GlassSurface<Content: View>: View {
    let role: GlassRole
    var cornerRadius: CGFloat? = nil
    var accentReflection: Color? = nil
    @ViewBuilder let content: Content

    var body: some View {
        content.glassSurface(role, cornerRadius: cornerRadius, accentReflection: accentReflection)
    }
}

struct GlassHero<Content: View>: View {
    var accentReflection: Color? = nil
    @ViewBuilder let content: Content

    var body: some View {
        GlassSurface(role: .hero, accentReflection: accentReflection) { content }
    }
}

struct GlassMetricCard<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        GlassSurface(role: .card) { content }
    }
}

struct GlassButton<Label: View>: View {
    let primary: Bool
    let action: () -> Void
    @ViewBuilder let label: Label

    init(primary: Bool = false, action: @escaping () -> Void, @ViewBuilder label: () -> Label) {
        self.primary = primary
        self.action = action
        self.label = label()
    }

    var body: some View {
        Button(action: action) {
            label.glassSurface(.button, accentReflection: primary ? Theme.brand : nil)
        }
        .buttonStyle(.glassPress)
    }
}

struct GlassCapsule<Content: View>: View {
    var accentReflection: Color? = nil
    @ViewBuilder let content: Content

    var body: some View {
        content.glassSurface(.capsule, accentReflection: accentReflection)
    }
}

struct GlassIcon: View {
    let systemName: String
    var tint: Color = Theme.brand
    var size: CGFloat = 34

    var body: some View {
        Image(systemName: systemName)
            .font(.system(size: size * 0.42, weight: .semibold))
            .foregroundStyle(tint)
            .frame(width: size, height: size)
            .glassSurface(.icon, cornerRadius: size / 2, accentReflection: tint)
            .accessibilityHidden(true)
    }
}

struct GlassBadge<Content: View>: View {
    var accentReflection: Color? = nil
    @ViewBuilder let content: Content

    var body: some View {
        content.glassSurface(.badge, accentReflection: accentReflection)
    }
}

/// Configures the real system tab bar. It never draws replacement navigation.
struct GlassTabBar<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        content
            .tint(Theme.controlTint)
            .toolbarBackground(.automatic, for: .tabBar)
    }
}

struct GlassToolbarButton: View {
    let systemName: String
    let accessibilityLabel: LocalizedStringKey
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(Theme.brand)
                .frame(width: 38, height: 38)
                .glassSurface(.toolbarButton, cornerRadius: 19, accentReflection: Theme.brand)
        }
        .buttonStyle(.glassPress)
        .accessibilityLabel(accessibilityLabel)
    }
}

struct GlassListRow<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        GlassSurface(role: .listRow) { content }
    }
}

// MARK: - Background and status light

struct GlassBackground: View {
    @Environment(\.colorScheme) private var colorScheme
    // Observe the persisted selection directly. Without this dynamic property,
    // SwiftUI can retain an existing GlassBackground subtree after controls
    // re-skin, leaving the old accent glow behind.
    @AppStorage("appAccent") private var accentRaw = Theme.defaultAccent.rawValue

    private var accent: Theme.Accent {
        Theme.Accent(rawValue: accentRaw) ?? Theme.defaultAccent
    }

    var body: some View {
        // This is backdrop content, not a glass tint. Clear Liquid Glass must
        // have real luminance, color and detail behind it to reveal refraction.
        // The material above remains completely untinted `.clear`.
        ZStack {
            Color(.systemGroupedBackground)

            Circle()
                .fill(backgroundLightPrimary)
                .frame(width: 460, height: 460)
                .blur(radius: 105)
                .offset(x: -150, y: -260)

            Circle()
                .fill(backgroundLightSecondary)
                .frame(width: 400, height: 400)
                .blur(radius: 115)
                .offset(x: 170, y: 300)

            GridTexture(
                spacing: 22,
                color: Color.primary.opacity(colorScheme == .dark ? 0.065 : 0.045)
            )
        }
        .animation(Theme.snappy, value: accentRaw)
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private var backgroundLightPrimary: Color {
        if accent.isColorless {
            return Color.primary.opacity(colorScheme == .dark ? 0.12 : 0.08)
        }
        return accent.base.opacity(colorScheme == .dark ? 0.24 : 0.18)
    }

    private var backgroundLightSecondary: Color {
        if accent.isColorless {
            return Color.secondary.opacity(colorScheme == .dark ? 0.10 : 0.07)
        }
        return accent.hi.opacity(colorScheme == .dark ? 0.18 : 0.13)
    }
}

struct GlassLED: View {
    var color: Color = Theme.ok
    var size: CGFloat = 6

    var body: some View {
        ZStack {
            Circle().fill(color.opacity(0.16)).frame(width: size * 2.4, height: size * 2.4)
                .blur(radius: size * 0.55)
            Circle().fill(color).frame(width: size, height: size)
                .overlay(Circle().fill(.white.opacity(0.55)).frame(width: size * 0.28, height: size * 0.28)
                    .offset(x: -size * 0.16, y: -size * 0.18))
        }
        .frame(width: size * 2.4, height: size * 2.4)
        .accessibilityHidden(true)
    }
}

// MARK: - Physical press feedback

struct GlassPressStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.965 : 1)
            .brightness(configuration.isPressed ? 0.045 : 0)
            .animation(.spring(response: 0.20, dampingFraction: 0.82), value: configuration.isPressed)
    }
}

extension ButtonStyle where Self == GlassPressStyle {
    static var glassPress: GlassPressStyle { GlassPressStyle() }
}
