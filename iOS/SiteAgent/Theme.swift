import SwiftUI

extension Color {
    /// `#RRGGBB` (the `#` is optional). Malformed/empty input resolves to
    /// `.clear` so call sites stay non-optional and never render garbage.
    init(hex: String) {
        let s = hex.trimmingCharacters(in: CharacterSet(charactersIn: "# "))
        var v: UInt64 = 0
        guard !s.isEmpty, Scanner(string: s).scanHexInt64(&v) else {
            self = .clear
            return
        }
        self.init(red:   Double((v >> 16) & 0xFF) / 255,
                  green: Double((v >> 8) & 0xFF) / 255,
                  blue:  Double(v & 0xFF) / 255)
    }

    /// `0xRRGGBB` hex convenience (delegates to the String parser so all hex
    /// parsing lives in one place).
    init(hex: UInt32, alpha: Double = 1) {
        self = Color(hex: String(format: "%06X", hex)).opacity(alpha)
    }

    /// Resolves to `light` or `dark` hex by the active interface style — the
    /// native way to ship one adaptive color value (works on Mac Catalyst too).
    init(light: String, dark: String) {
        self = Color(UIColor { trait in
            UIColor(Color(hex: trait.userInterfaceStyle == .dark ? dark : light))
        })
    }

    /// Dynamic color from explicit light/dark `UIColor`s (keeps per-channel alpha).
    init(lightUI: UIColor, darkUI: UIColor) {
        self = Color(UIColor { $0.userInterfaceStyle == .dark ? darkUI : lightUI })
    }
}

extension String {
    /// Looks `self` up as a key in Localizable.strings for the current locale,
    /// returning the translation (or `self` unchanged if there's no entry).
    /// The app's `String`-taking view wrappers call this so their titles localize
    /// like a SwiftUI `Text("literal")` would.
    var localized: String { NSLocalizedString(self, comment: "") }
}

extension Font {
    // Design typography — unified to the Home tab's system: SF Rounded for
    // display/UI text and SF Monospaced for eyebrow/code labels, so every screen
    // speaks the same type language as Command Center (which uses `AppFont`,
    // i.e. `.system(design: .rounded/.monospaced)`).

    /// Display headings & big numbers — SF Rounded (matches `AppFont` titles).
    static func display(_ size: CGFloat, _ weight: Weight = .heavy, relativeTo style: TextStyle = .largeTitle) -> Font {
        .system(size: size, weight: weight, design: .rounded)
    }

    /// Body & UI text — SF Rounded.
    static func ui(_ size: CGFloat, _ weight: Weight = .regular, relativeTo style: TextStyle = .body) -> Font {
        .system(size: size, weight: weight, design: .rounded)
    }

    /// Eyebrow labels, code, captions — SF Monospaced.
    static func mono(_ size: CGFloat, _ weight: Weight = .medium, relativeTo style: TextStyle = .caption) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }
}

/// App theme preference: follow the system, or force light / dark.
enum ThemeMode: String, CaseIterable, Identifiable {
    case system, light, dark
    var id: String { rawValue }
    var label: String { rawValue.capitalized }
    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light:  return .light
        case .dark:   return .dark
        }
    }
}

/// Surface skin: `classic` keeps the flat native cards; `clearGlass` swaps every
/// card/pill surface to Apple Liquid Glass — the real `.glassEffect` material on
/// iOS 26+, an ultra-thin-material approximation on iOS 17–25.
enum AppSkin: String, CaseIterable, Identifiable {
    case classic, clearGlass
    var id: String { rawValue }
    var label: String {
        switch self {
        case .classic:    return "Classic"
        case .clearGlass: return "Clear Glass"
        }
    }
}

/// Central design system: brand colors, gradients, motion, and reusable
/// surface/button styles. Keeping these in one place keeps the app visually
/// consistent and makes a future re-skin a one-file change.
enum Theme {

    // MARK: Brand / accent color

    /// The selectable accent palettes.
    /// `base` is the primary tint; `hi` its lighter partner for gradients.
    /// A curated, professional cool palette (emerald default — the original
    /// Command Center mint). Muted, low-noise tints that read calm rather than
    /// candy-bright.
    enum Accent: String, CaseIterable, Identifiable {
        case colorless, emerald, sage, teal, sky, cobalt, indigo, violet, slate
        var id: String { rawValue }

        var isColorless: Bool { self == .colorless }

        var name: String {
            switch self {
            case .colorless: return "Colorless"
            case .emerald: return "Emerald"
            case .sage:   return "Sage"
            case .teal:   return "Teal"
            case .sky:    return "Sky"
            case .cobalt: return "Cobalt"
            case .indigo: return "Indigo"
            case .violet: return "Violet"
            case .slate:  return "Slate"
            }
        }
        // Adaptive like `Theme.ok` (light "16A06A" / dark "46D39A"): light mode
        // gets a darker, formal tone that holds up on white; dark mode keeps the
        // original command-deck tints untouched.
        var base: Color {
            switch self {
            // Colorless removes hue from the Clear Glass light field. Controls
            // still need a visible, accessible tint, so the brand token becomes
            // an adaptive neutral instead of literal Color.clear.
            // Neutral controls must stay dark enough for their standard white
            // labels/icons in both appearances. The old dark value was nearly
            // white, producing white-on-white messages and send buttons.
            case .colorless: return Color(light: "4A5058", dark: "4A5058")
            case .emerald: return Color(light: "16A06A", dark: "46D39A")   // command-deck mint/emerald
            case .sage:   return Color(light: "3A7D5C", dark: "4FA37A")
            case .teal:   return Color(light: "0E837C", dark: "1AA39A")
            case .sky:    return Color(light: "1F6FA8", dark: "2F8BCB")
            case .cobalt: return Color(light: "2F4FC0", dark: "3E63DD")
            case .indigo: return Color(light: "4643B0", dark: "5B57D6")
            case .violet: return Color(light: "6349BA", dark: "7E62D8")
            case .slate:  return Color(light: "47586A", dark: "5E7387")
            }
        }
        var hi: Color {
            switch self {
            case .colorless: return Color(light: "626B76", dark: "626B76")
            case .emerald: return Color(light: "3DBD8B", dark: "7CE8B8")
            case .sage:   return Color(light: "5FA37F", dark: "86C6A1")
            case .teal:   return Color(light: "3AA79F", dark: "5FD0C7")
            case .sky:    return Color(light: "4E93C6", dark: "76B6E4")
            case .cobalt: return Color(light: "5E7BDD", dark: "7C97F2")
            case .indigo: return Color(light: "7370D0", dark: "948FEC")
            case .violet: return Color(light: "8B71D6", dark: "AC97EE")
            case .slate:  return Color(light: "6E8296", dark: "93A6B7")
            }
        }

        /// Text-bearing accent surfaces use a deliberately darker range than
        /// decorative glows and icon fills. Every endpoint keeps at least WCAG
        /// AA contrast with white while preserving the selected hue.
        var messageBase: Color {
            switch self {
            case .colorless: return Color(hex: "4A5058")
            case .emerald:   return Color(hex: "147A54")
            case .sage:      return Color(hex: "3A7257")
            case .teal:      return Color(hex: "0D746F")
            case .sky:       return Color(hex: "1F6798")
            case .cobalt:    return Color(hex: "2F4FC0")
            case .indigo:    return Color(hex: "4643B0")
            case .violet:    return Color(hex: "6349BA")
            case .slate:     return Color(hex: "47586A")
            }
        }

        var messageHi: Color {
            switch self {
            case .colorless: return Color(hex: "626B76")
            case .emerald:   return Color(hex: "19865C")
            case .sage:      return Color(hex: "467A60")
            case .teal:      return Color(hex: "127F78")
            case .sky:       return Color(hex: "2A72A5")
            case .cobalt:    return Color(hex: "4362C8")
            case .indigo:    return Color(hex: "5A56BF")
            case .violet:    return Color(hex: "7558C4")
            case .slate:     return Color(hex: "5C6D7F")
            }
        }
    }

    /// One canonical fallback for Settings, shared tokens, and backgrounds.
    /// Keeping this in one place prevents a fresh install from labelling one
    /// accent while rendering another.
    /// Emerald is the original Command Center mint (`#46D39A`) from the pre–
    /// Clear-Glass / pre-slate redesign.
    static let defaultAccent: Accent = .emerald

    /// Flat native cards — the original Command Center look. Clear Glass stays
    /// available in Settings as an opt-in.
    static let defaultSkin: AppSkin = .classic

    /// The persisted accent choice (raw string under "appAccent"). The reactive
    /// driver is `AgentEngine.accent` — it writes this key and fires
    /// objectWillChange, so every view that reads `Theme.brand` re-skins at once.
    static var accent: Accent {
        Accent(rawValue: UserDefaults.standard.string(forKey: "appAccent") ?? "") ?? defaultAccent
    }

    /// The persisted surface skin (raw string under "appSkin"). Reactive driver
    /// is `AgentEngine.skin` — same pattern as `accent` above.
    static var skin: AppSkin {
        AppSkin(rawValue: UserDefaults.standard.string(forKey: "appSkin") ?? "") ?? defaultSkin
    }
    static var isGlass: Bool { skin == .clearGlass }

    /// The app's primary tint — driven by the user's accent (default Emerald), so a
    /// single picker re-skins everything that reads `Theme.brand`.
    static var brand: Color { accent.base }
    static var brandEnd: Color { accent.hi }

    /// One-shot restore after a bad default ship (slate + Clear Glass). Existing
    /// installs already wrote those keys into UserDefaults, so changing Swift
    /// defaults alone would not bring the mint Command Center look back.
    static func restoreClassicCommandCenterDesignIfNeeded() {
        let flag = "designRestoredClassicEmerald_20260728"
        let defaults = UserDefaults.standard
        guard defaults.bool(forKey: flag) == false else { return }
        defaults.set(defaultAccent.rawValue, forKey: "appAccent")
        defaults.set(defaultSkin.rawValue, forKey: "appSkin")
        defaults.set(true, forKey: flag)
    }

    /// Foreground tint for system controls. Colorless uses a bright neutral in
    /// dark mode so alert actions, tab selections, and navigation controls do
    /// not disappear against system glass. Filled brand surfaces still use the
    /// intentionally darker `brand` token with white content.
    static var controlTint: Color {
        accent.isColorless ? Color(light: "4A5058", dark: "D7DCE3") : brand
    }

    /// The signature diagonal gradient: accent → its lighter partner.
    static var brandGradient: LinearGradient {
        LinearGradient(colors: [brand, brandEnd],
                       startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    /// Accessible accent surface for user-authored text. Decorative brand
    /// gradients remain unchanged; this token guarantees readable white copy.
    static var messageGradient: LinearGradient {
        LinearGradient(colors: [accent.messageBase, accent.messageHi],
                       startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    /// Accessible accent surface for buttons, badges, and other controls that
    /// place white labels or symbols on top of the accent color.
    static var actionGradient: LinearGradient {
        messageGradient
    }

    /// A soft, low-alpha version for tinted backgrounds / glows.
    static var brandSoft: LinearGradient {
        LinearGradient(colors: [brand.opacity(0.18), brandEnd.opacity(0.18)],
                       startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    // MARK: Signal colors

    /// Status signals from the design, adaptive across light/dark.
    static let ok = Color(light: "16A06A", dark: "46D39A")     // success · live · connected
    static let warn = Color(light: "C47E16", dark: "FFB23E")   // pending · draft · canceled
    static let danger = Color(light: "E5484D", dark: "FF6B6B") // failure · error
    static let info = Color(light: "2563EB", dark: "3BA7FF")   // building · in-progress

    // MARK: Surfaces & text (design "glass" tokens, adaptive light/dark)

    /// Text levels — primary / secondary / tertiary.
    static let t1 = Color(lightUI: UIColor(red: 20/255, green: 16/255, blue: 28/255, alpha: 0.95),
                          darkUI:  UIColor(white: 1, alpha: 0.97))
    static let t2 = Color(lightUI: UIColor(red: 20/255, green: 16/255, blue: 28/255, alpha: 0.55),
                          darkUI:  UIColor(white: 1, alpha: 0.60))
    static let t3 = Color(lightUI: UIColor(red: 20/255, green: 16/255, blue: 28/255, alpha: 0.34),
                          darkUI:  UIColor(white: 1, alpha: 0.38))
    /// Hairline edge of a glass card.
    static let glassBorder = Color(lightUI: UIColor(white: 1, alpha: 0.85),
                                   darkUI:  UIColor(white: 1, alpha: 0.16))
    /// Bright top inset highlight on glass.
    static let glassHi = Color(lightUI: UIColor(white: 1, alpha: 0.95),
                               darkUI:  UIColor(white: 1, alpha: 0.42))
    /// Separator inside cards.
    static let separator = Color(lightUI: UIColor(red: 20/255, green: 16/255, blue: 28/255, alpha: 0.07),
                                 darkUI:  UIColor(white: 1, alpha: 0.09))
    /// Small inline chip / field fill.
    static let chip = Color(lightUI: UIColor(red: 20/255, green: 16/255, blue: 28/255, alpha: 0.05),
                            darkUI:  UIColor(white: 1, alpha: 0.10))
    /// Tinted accent wash for icon tiles / soft backgrounds.
    static var accentSoft: Color { brand.opacity(0.18) }

    /// Flat, native card fill for the clean style — white in light, #1C1C1E in
    /// dark — so cards read like Settings.app grouped cells on the OLED backdrop.
    static let cardFill = Color(.secondarySystemGroupedBackground)

    // MARK: Shape & motion

    static let corner: CGFloat = 16   // matches Home's CC card corner (design unified)
    static let cornerSmall: CGFloat = 12

    /// The standard spring used for press feedback and content insertion.
    static let spring = Animation.spring(response: 0.34, dampingFraction: 0.72)
    static let snappy = Animation.spring(response: 0.26, dampingFraction: 0.7)

    // MARK: Splash / onboarding motion tone

    /// The one place the splash + onboarding entrance choreography is tuned.
    /// Swap `Theme.motion` to another preset to re-time the whole intro — every
    /// duration, spring, slide distance and easing curve flows from here.
    struct Motion {
        var speed: Double          // global time scale (1 = calm baseline)
        var entry: Double          // entrance duration (s)
        var slide: CGFloat         // slide-in distance (pt)
        var enter: Animation       // withAnimation curve for entrances
        var pop: Animation         // withAnimation curve for pops/overshoots
        var ease: (Double) -> Double     // clock-driven progress easing (splash)
        var popEase: (Double) -> Double  // clock-driven pop easing (splash)

        // px→pt ≈ ÷2.75 (prototype is 1080pt wide ≈ 2.75× an iPhone pt grid).
        static let calm = Motion(
            speed: 1.0, entry: 0.9, slide: 25,
            enter: .easeOut(duration: 0.9), pop: .easeOut(duration: 0.9),
            ease: Ease.outCubic, popEase: Ease.outCubic)
        static let playful = Motion(
            speed: 0.95, entry: 0.75, slide: 40,
            enter: .spring(response: 0.34, dampingFraction: 0.62),
            pop: .spring(response: 0.34, dampingFraction: 0.62),
            ease: Ease.outBack, popEase: Ease.outBack)
        static let techy = Motion(
            speed: 0.78, entry: 0.45, slide: 55,
            enter: .spring(response: 0.22, dampingFraction: 0.9),
            pop: .spring(response: 0.22, dampingFraction: 0.9),
            ease: Ease.outExpo, popEase: Ease.outExpo)
    }

    /// Active tone. Default: "Calm & confident".
    static let motion = Motion.calm
}

/// Normalized (0→1) easing curves for clock-driven animation (the splash reads
/// elapsed time and maps it through these — same curves as the design source).
enum Ease {
    static func outCubic(_ x: Double) -> Double { 1 - pow(1 - x, 3) }
    static func inCubic(_ x: Double) -> Double { x * x * x }
    static func inOutCubic(_ x: Double) -> Double {
        x < 0.5 ? 4 * x * x * x : 1 - pow(-2 * x + 2, 3) / 2
    }
    static func outBack(_ x: Double) -> Double {
        let c1 = 1.70158, c3 = c1 + 1
        return 1 + c3 * pow(x - 1, 3) + c1 * pow(x - 1, 2)
    }
    static func outExpo(_ x: Double) -> Double {
        x >= 1 ? 1 : 1 - pow(2, -10 * x)
    }
    /// clamp t to [lo,hi] then normalize to 0→1 across [a,b].
    static func ramp(_ t: Double, _ a: Double, _ b: Double) -> Double {
        min(max((t - a) / (b - a), 0), 1)
    }
}

// MARK: - Reusable surfaces

/// Optical weight for Clear Glass surfaces. Larger structural panes carry more
/// frost, edge energy, and shadow; controls and badges stay thin so nested glass
/// does not collapse into one uniform sheet.
enum GlassThickness: Equatable {
    case hero, card, control, pill, badge

    fileprivate var role: GlassRole {
        switch self {
        case .hero: return .hero
        case .card: return .card
        case .control: return .button
        case .pill: return .capsule
        case .badge: return .badge
        }
    }
}

extension View {
    /// Compatibility entry point for older call sites. Rendering is centralized
    /// in `GlassSurfaceModifier`: native Clear Liquid Glass on iOS 26+, with one
    /// material pass on older systems.
    @ViewBuilder
    func liquidGlass(
        in shape: RoundedRectangle,
        tint: Color? = nil,
        thickness: GlassThickness = .card
    ) -> some View {
        self.glassSurface(
            thickness.role,
            cornerRadius: shape.cornerSize.width,
            accentReflection: tint
        )
    }

    /// Luminous-LED bloom for status dots under the Clear Glass skin (no-op on
    /// classic, so the flat design stays flat).
    @ViewBuilder
    func glassGlow(_ color: Color, radius: CGFloat = 6) -> some View {
        if Theme.isGlass {
            self.shadow(color: color.opacity(0.9), radius: radius)
        } else {
            self
        }
    }

    /// iOS 26 Liquid Glass scroll-edge effect — content melts softly under the
    /// navigation bar and pinned bottom chrome (composer / tab bar).
    @ViewBuilder
    func glassScrollEdge() -> some View {
        if #available(iOS 26.0, *) {
            self.scrollEdgeEffectStyle(.soft, for: [.top, .bottom])
        } else {
            self
        }
    }
}

struct CardSurfaceModifier: ViewModifier {
    let cornerRadius: CGFloat
    // Captured at init (not read in body) so a skin toggle changes the modifier
    // value itself — otherwise SwiftUI's diffing skips the body re-run and the
    // card only re-skins on the next full rebuild.
    private let glass = Theme.isGlass

    @ViewBuilder
    func body(content: Content) -> some View {
        // Glass keeps the classic radius so card geometry is identical across
        // skins — only the surface material changes.
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        if glass {
            content.glassSurface(.card, cornerRadius: cornerRadius)
        } else {
            // Flat, native, seamless: a solid grouped-cell fill + hairline, no glass
            // blur or drop shadow — clean on the OLED/native backdrop.
            content
                .background(Theme.cardFill, in: shape)
                .overlay(shape.strokeBorder(Theme.separator, lineWidth: 0.5))
        }
    }
}

extension View {
    /// A raised card: layered fill, hairline stroke, soft shadow.
    func cardSurface(cornerRadius: CGFloat = Theme.corner) -> some View {
        self.modifier(CardSurfaceModifier(cornerRadius: cornerRadius))
    }
}

// MARK: - App Backgrounds & OLED Modifiers

enum AppBackgroundStyle {
    case primary, secondary, tertiary, grouped
}

/// The app backdrop. `clean` (default) is a flat, native, OLED-friendly fill;
/// `signature` is the original vertical gradient with soft accent "blobs".
/// Sits behind every screen via `.appBackground()`.
struct DesignBackground: View {
    // Captured at init so a skin toggle re-runs the body (see CardSurfaceModifier).
    private let glass = Theme.isGlass

    var body: some View {
        Group {
            if glass { GlassBackground() }
            else { Color(.systemGroupedBackground).ignoresSafeArea() }
        }
    }
}

/// The shared Clear Glass light field. Two localized sources keep the page black
/// between areas of interest: a primary light behind the hero and a much fainter
/// reflection near lower content/deployments.
struct GlassAmbientLight: View {
    var body: some View {
        GlassBackground()
    }
}

struct AppBackgroundModifier: ViewModifier {
    let style: AppBackgroundStyle   // kept for call-site compatibility — one backdrop now

    func body(content: Content) -> some View {
        content
            .scrollContentBackground(.hidden)
            .background(DesignBackground())
            .glassScrollEdge()
    }
}

struct ListRowBackgroundModifier: ViewModifier {
    func body(content: Content) -> some View {
        // Rows float on the gradient; row content supplies its own glass surface.
        content.listRowBackground(Color.clear)
    }
}

extension View {
    func appBackground(_ style: AppBackgroundStyle = .primary) -> some View {
        self.modifier(AppBackgroundModifier(style: style))
    }

    func appListRowBackground() -> some View {
        self.modifier(ListRowBackgroundModifier())
    }

    func appSecondaryBackground() -> some View {
        self.modifier(AppSecondaryBackgroundModifier())
    }

    /// Caps content to a comfortable reading measure and centers it, so feeds and
    /// forms don't stretch edge-to-edge on iPad / Mac Catalyst.
    func readableWidth(_ maxWidth: CGFloat = 700) -> some View {
        frame(maxWidth: maxWidth).frame(maxWidth: .infinity)
    }

    /// Pointer highlight for iPad-with-trackpad and Mac Catalyst; a no-op on touch.
    func cardHover() -> some View {
        hoverEffect(.highlight)
    }
}

/// The app-wide titled-group header — uppercase, kerned caption — so Home, Chat
/// and Settings speak one visual language (mirrors SettingsSection's header).
struct SectionHeader: View {
    let title: String
    init(_ title: String) { self.title = title }
    var body: some View {
        Text(title.localized.uppercased(with: .current))
            .font(.mono(12, .semibold))
            .kerning(1.35)
            .foregroundStyle(Theme.t3)
    }
}

struct AppSecondaryBackgroundModifier: ViewModifier {
    func body(content: Content) -> some View {
        content.background(.bar)
    }
}

// MARK: - Button styles

/// Scales and dims slightly while pressed — gives every tappable element a
/// tactile, springy feel.
struct PressableStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var scale: CGFloat = 0.97

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed && !reduceMotion ? scale : 1)
            .brightness(configuration.isPressed ? 0.035 : 0)
            .opacity(configuration.isPressed ? 0.94 : 1)
            .animation(.spring(response: 0.16, dampingFraction: 0.92),
                       value: configuration.isPressed)
    }
}

extension ButtonStyle where Self == PressableStyle {
    static var pressable: PressableStyle { PressableStyle() }
}

// MARK: - Animated accents

/// A status dot that softly pulses an outer ring while `active` is true.
/// Driven by `TimelineView(.animation)` (the display clock) so it animates on a
/// real device too — the old `.repeatForever` kicked off in `onAppear` silently
/// failed to start on device. Runs even under Reduce Motion: a live-status pulse
/// is a signal, not decoration.
struct PulsingDot: View {
    var color: Color
    var active: Bool
    private let period: Double = 1.4   // seconds per expand/fade cycle

    var body: some View {
        ZStack {
            if active {
                TimelineView(.animation) { tl in
                    let p = tl.date.timeIntervalSinceReferenceDate
                        .truncatingRemainder(dividingBy: period) / period   // 0→1
                    Circle()
                        .stroke(color.opacity(0.5), lineWidth: 2)
                        .frame(width: 8, height: 8)
                        .scaleEffect(1 + p * 1.4)
                        .opacity(0.8 * (1 - p))
                }
            }
            Circle().fill(color).frame(width: 8, height: 8)
                .shadow(color: color.opacity(0.7), radius: active ? 4 : 0)
        }
    }
}

/// Three dots that ripple up and down — the agent's "thinking" indicator.
struct TypingIndicator: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var phase = false
    var body: some View {
        HStack(spacing: 4) {
            ForEach(0..<3) { i in
                Circle()
                    .fill(Theme.brandGradient)
                    .frame(width: 6, height: 6)
                    .offset(y: (phase && !reduceMotion) ? -3 : 0)
                    .animation(reduceMotion ? nil
                               : .easeInOut(duration: 0.5).repeatForever().delay(Double(i) * 0.15),
                               value: phase)
            }
        }
        .onAppear { phase = true }
    }
}

// MARK: - Surface environment values

/// The OLED-aware secondary/tertiary surface fills, computed once at a root
/// view and read by descendants via `@Environment(\.secondarySurface)` etc., so
/// the `oledMode && colorScheme == .dark ? … : …` expression isn't copied into
/// every bubble/row. Defaults mirror the non-OLED system fills.
private struct SecondarySurfaceKey: EnvironmentKey {
    static let defaultValue: Color = Color(.secondarySystemBackground)
}
private struct TertiarySurfaceKey: EnvironmentKey {
    static let defaultValue: Color = Color(.tertiarySystemBackground)
}

extension EnvironmentValues {
    var secondarySurface: Color {
        get { self[SecondarySurfaceKey.self] }
        set { self[SecondarySurfaceKey.self] = newValue }
    }
    var tertiarySurface: Color {
        get { self[TertiarySurfaceKey.self] }
        set { self[TertiarySurfaceKey.self] = newValue }
    }
}
