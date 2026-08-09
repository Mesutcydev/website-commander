import SwiftUI
import AppKit

/// The visual language of Website Commander.
///
/// The palette is deliberately **neutral**: canvas, chrome, cards, borders, and
/// body text are true warm grays and charcoals, never desaturated navy. Colour
/// is semantic punctuation on top of that — indigo for primary interaction and
/// focus, violet for the model/AI controls, and a small closed set of accents
/// (teal, green, amber, rose, cyan) for categories and status.
///
/// Dark is tuned for OLED: the canvas is true black so unlit pixels stay off,
/// and everything above it is a near-black ladder with roughly even L* steps.
/// Because a black shadow over a black canvas is invisible, separation in dark
/// comes from those surface steps plus hairlines — not from elevation.
///
/// Every value lives here. Views read semantic tokens (`Theme.textSecondary`,
/// `Theme.borderSubtle`, `Theme.Accent.violet`) so a palette change is one edit,
/// and nothing downstream can reintroduce a one-off colour.
enum Theme {

    // MARK: Palette primitives

    /// A token from a hex literal, so the palette below reads like the spec it
    /// implements rather than a wall of float triples.
    private static func srgb(_ hex: UInt32, _ alpha: CGFloat = 1) -> NSColor {
        NSColor(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: alpha
        )
    }

    private static func adaptive(light: NSColor, dark: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
        })
    }

    /// A token defined by two hex literals, one per appearance.
    private static func tone(_ light: UInt32, _ dark: UInt32,
                            lightAlpha: CGFloat = 1, darkAlpha: CGFloat = 1) -> Color {
        adaptive(light: srgb(light, lightAlpha), dark: srgb(dark, darkAlpha))
    }

    // MARK: Primary interaction colour

    /// Indigo. Reserved for primary actions, focus rings, active controls, and
    /// selection — never for borders, card fills, or body text.
    static let accent = tone(0x5E5CE6, 0x8179FF)
    static let accentHover = tone(0x5150D8, 0x918AFF)
    static let accentPressed = tone(0x4645C5, 0x7068E8)
    static let accentSoft = tone(0xEEEFFF, 0x8179FF, darkAlpha: 0.14)
    static let accentMuted = tone(0xE5E7FF, 0x8179FF, darkAlpha: 0.14)
    static let accentBorder = tone(0xCBCFFF, 0x8179FF, darkAlpha: 0.30)
    static let accentText = tone(0x484BC2, 0xB8B2FF)

    /// The teal the brand gradient blends into. Used by the logo and the one
    /// branded gradient — not as a general-purpose accent.
    static let accentDeep = tone(0x2BA58F, 0x45D6A8)

    // MARK: Controlled accents
    //
    // A closed set. Each pair is a foreground for glyphs and small labels plus a
    // soft tint for the container behind them, so an accent can identify a
    // category without colouring a whole surface.
    //
    // The dark foregrounds are pulled down a few points of L* from their light
    // counterparts' mirror: at 9–10:1 against true black a saturated hue blooms,
    // and the extra brightness bought nothing. The dark soft alphas are tuned
    // per hue so every tint lands in the same L*12–13 band over black — blue
    // carries almost no luminance and needs more alpha than teal or amber to
    // read as the same weight of tint.

    /// Kept as a compatibility alias for provider/agent call sites. The final
    /// palette intentionally folds the old purple note into the indigo family.
    static let violet = tone(0x5E5CE6, 0x7C81FF)
    static let violetSoft = tone(0xEEEFFF, 0x7C81FF, darkAlpha: 0.15)

    static let teal = tone(0x2BA58F, 0x45D6A8)
    static let tealSoft = tone(0xE8F6F2, 0x45D6A8, darkAlpha: 0.13)

    static let green = tone(0x2D9961, 0x43B77D)
    static let greenSoft = tone(0xEAF6EF, 0x43B77D, darkAlpha: 0.13)

    static let amber = tone(0xBF8429, 0xDDAA5C)
    static let amberSoft = tone(0xFFF5E4, 0xDDAA5C, darkAlpha: 0.14)
    /// The Recommended badge's label: darker than `amber` so 11pt text on
    /// `amberSoft` clears WCAG AA.
    static let amberText = tone(0x98651D, 0xF1C779)
    static let amberBorder = tone(0xF1D9AD, 0xDDAA5C, lightAlpha: 1, darkAlpha: 0.30)

    static let rose = tone(0xD45A63, 0xF07A83)
    static let roseSoft = tone(0xFDEDEF, 0xF07A83, darkAlpha: 0.14)

    static let cyan = tone(0x397BC9, 0x70A7EA)
    static let cyanSoft = tone(0xEBF3FC, 0x70A7EA, darkAlpha: 0.14)

    static let destructive = tone(0xD45A63, 0xF07A83)
    static let destructiveSoft = tone(0xFDEDEF, 0xF07A83, darkAlpha: 0.14)

    /// Status vocabulary, expressed through the accent set so there is one
    /// palette rather than two.
    static let success = green
    static let warning = amber
    static let danger = destructive
    static let info = cyan

    /// One semantic accent: a glyph colour plus the soft tint behind it. Task
    /// categories, status tiles, and icon containers all resolve through this so
    /// no call site invents a pairing.
    enum Accent: CaseIterable {
        case primary, violet, teal, green, amber, rose, cyan, neutral

        var color: Color {
            switch self {
            case .primary: return Theme.accent
            case .violet:  return Theme.violet
            case .teal:    return Theme.teal
            case .green:   return Theme.green
            case .amber:   return Theme.amber
            case .rose:    return Theme.rose
            case .cyan:    return Theme.cyan
            case .neutral: return Theme.textPrimary
            }
        }

        var soft: Color {
            switch self {
            case .primary: return Theme.accentSoft
            case .violet:  return Theme.violetSoft
            case .teal:    return Theme.tealSoft
            case .green:   return Theme.greenSoft
            case .amber:   return Theme.amberSoft
            case .rose:    return Theme.roseSoft
            case .cyan:    return Theme.cyanSoft
            case .neutral: return Theme.secondarySurface
            }
        }
    }

    // MARK: The one branded gradient

    /// Indigo → teal. Reserved for the product mark and very small brand
    /// details; it is never a surface fill.
    static var brandGradient: LinearGradient {
        LinearGradient(
            colors: [accent, accentDeep],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    /// A near-neutral wash for large decorative areas: a hint of the brand at
    /// the very edge of perceptibility, so it can sit behind content without
    /// tinting it.
    static var brandWash: LinearGradient {
        LinearGradient(
            colors: [accent.opacity(0.05), accentDeep.opacity(0.035)],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    // MARK: Live activity

    /// The border a control wears while the agent is genuinely working. Three
    /// branded hues only — indigo (interaction), violet (the model), teal (the
    /// brand's second note) — closing back on indigo so the rotation has no
    /// seam. The sweep is the signal; brightness never pulses.
    enum Activity {
        static let sweep: [Color] = [Theme.accent, Theme.teal, Theme.accent]
        static let focusSweep: [Color] = [.clear, .clear, Theme.accent, Theme.teal, .clear]

        /// A hair thicker than a resting hairline, so the travel is legible
        /// without the composer gaining weight.
        static let lineWidth: CGFloat = 1.6
        /// Sits on the focus halo's geometry, so switching between them never
        /// shifts the composer's apparent size.
        static let haloWidth: CGFloat = 3
        static let haloOpacity: Double = 0.22

        /// Seconds per rotation. Slow enough to read as ambient presence.
        static let period: Double = 3.2
        static let focusPeriod: Double = 7.0
        /// Cross-fade in and out of the resting border.
        static let fade = Animation.easeInOut(duration: 0.18)

        /// Reduce Motion substitute: the model's violet, held still.
        static let staticTint = Theme.violet

        static func gradient(angle: Angle) -> AngularGradient {
            AngularGradient(colors: sweep, center: .center, angle: angle)
        }

        static func focusGradient(angle: Angle) -> AngularGradient {
            AngularGradient(colors: focusSweep, center: .center, angle: angle)
        }
    }

    // MARK: Surfaces
    //
    // Three levels, and only three: the application canvas, the secondary
    // regions (chrome, grouped controls), and elevated interactive surfaces
    // (cards, popovers, the composer).
    //
    // In dark the canvas is true black and the levels above it are spaced by
    // roughly 3–5 points of CIE L*, against 1.3–1.9 before. Even steps are the
    // whole game on OLED: the base emits nothing, so a level is only "above"
    // another if the step itself is perceptible, and nothing else is left to
    // fake it once shadows stop registering.

    /// Level 0 — the application foundation.
    static let canvas = tone(0xF1F2F4, 0x0C0F14)
    /// Level 1 — the workspace pane and grouped page regions.
    static let workspaceSurface = tone(0xF6F7F9, 0x0E1217)
    /// Level 2 — standard content surfaces.
    static let standardSurface = tone(0xFCFCFD, 0x151A21)
    /// Level 3 — selected cards, composers, modals, and raised interaction.
    static let elevatedSurface = tone(0xFFFFFF, 0x1A2028)
    /// Recessed controls and quiet icon/badge tiles.
    static let secondarySurface = tone(0xF1F2F5, 0x202731)
    static let chromeSurface = secondarySurface
    static let recessedSurface = tone(0xEBEDF1, 0x11151B)
    /// Hover and selected compatibility surfaces.
    static let tertiarySurface = tone(0xF5F5F8, 0x242C37)
    static let selectedSurface = tone(0xF0F1FF, 0x8179FF, darkAlpha: 0.12)
    static let hoverSurface = tertiarySurface
    static let surfaceHover = tertiarySurface
    static let surfacePressed = tone(0xF0F1F4, 0x29323E)
    static let mutedSurface = secondarySurface
    /// The preview workspace is intentionally darker than the rendered site.
    static let previewWorkspace = tone(0xECEFF3, 0x11151B)
    static let previewGrid = tone(0x3F4550, 0xFFFFFF, lightAlpha: 0.035, darkAlpha: 0.06)
    static let modalHeader = tone(0xF8F9FB, 0x1C2128)
    static let editorSurface = tone(0xF7F8FA, 0x171B21)
    static let modalFooter = tone(0xFAFAFC, 0x1A1E24)

    // MARK: Translucent window language

    /// The macOS client uses a restrained glass layer rather than a stack of
    /// opaque panels. Materials do the platform-native blur; these tints keep
    /// the app's neutral palette readable over a desktop wallpaper or a live
    /// preview. Reduce Transparency is handled by the material and the
    /// explicit opaque fallbacks in the shell/background views.
    enum Glass {
        static let windowTint = tone(0xF4F5F8, 0x080A0D,
                                     lightAlpha: 0.62, darkAlpha: 0.66)
        static let cardTint = tone(0xFFFFFF, 0xFFFFFF,
                                   lightAlpha: 0.16, darkAlpha: 0.07)
        static let paneTint = tone(0xFFFFFF, 0xFFFFFF,
                                   lightAlpha: 0.11, darkAlpha: 0.05)
        static let highlight = tone(0xFFFFFF, 0xFFFFFF,
                                    lightAlpha: 0.70, darkAlpha: 0.10)
        static let border = tone(0xFFFFFF, 0xFFFFFF,
                                 lightAlpha: 0.28, darkAlpha: 0.13)
    }

    /// A restrained atmosphere for large workspaces; it is subtle enough to
    /// disappear under Reduce Transparency without affecting readability.
    static var workspaceAtmosphere: RadialGradient {
        RadialGradient(colors: [accent.opacity(0.035), .clear],
                       center: UnitPoint(x: 0.78, y: 0),
                       startRadius: 0,
                       endRadius: 520)
    }

    /// Standard panels use a tonal fill before they ever need a border.
    static var standardPanelGradient: LinearGradient {
        LinearGradient(colors: [elevatedSurface, standardSurface, standardSurface],
                       startPoint: .top, endPoint: .bottom)
    }

    static var selectedPanelGradient: LinearGradient {
        LinearGradient(colors: [elevatedSurface, tone(0xF8F8FF, 0x252A35)],
                       startPoint: .top, endPoint: .bottom)
    }

    /// The card surface is deliberately opaque. Shared tonal steps create
    /// hierarchy; repeated blur layers made every page read like a web tray of
    /// glass cards.
    static var cardFill: AnyShapeStyle { AnyShapeStyle(standardSurface) }

    // MARK: Text
    //
    // Dark body text stops short of white on purpose. Near-white on true black
    // is where OLED halation shows up — strokes bleed and long paragraphs smear
    // during scrolling — so primary sits at #E3E5EA, still 16.7:1 on the canvas
    // and 13.8:1 on a card. Secondary and tertiary come down with it, because a
    // darker canvas raises every foreground's contrast and would otherwise
    // flatten the three levels into one.

    static let textHeading = tone(0x20232A, 0xFFFFFF)
    static let textPrimary = tone(0x181A20, 0xF4F5F7)
    static let secondaryText = tone(0x4E5561, 0xBBC1CB)
    static let tertiaryText = tone(0x7A818D, 0x858D99)
    static let quaternaryText = tone(0x9299A4, 0x707782)
    static let disabledText = tone(0xADB2BB, 0x5F6671)
    static let textInverse = Color.white

    static let codeComment = success
    static let codeString = warning
    static let codeNumber = info
    static let codeKeyword = accentText

    // MARK: Borders
    //
    // Raised in dark. With the canvas at true black and shadows unable to
    // register on it, the hairline is half of what separates a card from what
    // it sits on — the surface step is the other half.

    static let borderHairline = tone(0x1A1D24, 0xFFFFFF, lightAlpha: 0.07, darkAlpha: 0.05)
    static let borderSubtle = tone(0x1A1D24, 0xFFFFFF, lightAlpha: 0.10, darkAlpha: 0.08)
    static let borderStandard = tone(0x1A1D24, 0xFFFFFF, lightAlpha: 0.13, darkAlpha: 0.11)
    static let borderStrong = tone(0x1A1D24, 0xFFFFFF, lightAlpha: 0.18, darkAlpha: 0.16)
    /// Hairline rules between regions. Fainter than any card border.
    static let divider = borderHairline

    /// Focus is signalled by an indigo border plus a soft outer ring — never by
    /// a colour change alone.
    static let focusRing = accent
    static let focusRingHalo = tone(0x5E5CE6, 0x8179FF, lightAlpha: 0.10, darkAlpha: 0.20)

    // MARK: Elevation
    //
    // Two very soft neutral layers. Shadows are never coloured and never used to
    // simulate glass.
    //
    // In dark these no longer carry hierarchy. A black shadow over the black
    // canvas is literally a no-op, so anything sitting directly on the canvas —
    // every `commandCard`, the Sites and History lists — is separated by its
    // surface step and its hairline instead. What is left for the shadows is the
    // minority of cases where something floats over a *lit* surface: the
    // composer and the execution rail over the workspace pane, popovers over a
    // card. The dark alphas are raised so that residual darkening is actually
    // legible in those places rather than a rounding error.

    enum Shadow {
        static let ambient = tone(0x12161E, 0x000000, lightAlpha: 0.035, darkAlpha: 0.32)
        static let key = tone(0x12161E, 0x000000, lightAlpha: 0.035, darkAlpha: 0.28)
        static let ambientRaised = tone(0x12161E, 0x000000, lightAlpha: 0.075, darkAlpha: 0.42)
        static let keyRaised = tone(0x12161E, 0x000000, lightAlpha: 0.055, darkAlpha: 0.34)
    }

    // MARK: Workspace chrome

    /// Tokens for the application bar. Neutral by construction: the bar is a
    /// white translucent surface with one hairline, and the accent appears only
    /// on live activity, selection, and focus.
    enum Chrome {

        /// The bar's translucent surface, layered over one blur. The lower
        /// opacity is intentional: the desktop/preview atmosphere should be
        /// perceptible through the titlebar without reducing label contrast.
        static let barFill = tone(0xFAFAFC, 0x11151B, lightAlpha: 0.72, darkAlpha: 0.92)
        /// Opaque fallback when the material is unavailable.
        static let barFillOpaque = tone(0xF7F8FA, 0x11151B)
        static var barGradient: LinearGradient {
            LinearGradient(
                colors: [tone(0xFDFDFE, 0x11151B, lightAlpha: 0.94, darkAlpha: 0.94),
                         tone(0xF7F8FA, 0x11151B, lightAlpha: 0.82, darkAlpha: 0.90)],
                startPoint: .top,
                endPoint: .bottom
            )
        }
        static let barBorder = Theme.divider
        /// A single inner highlight along the bar's top edge.
        static let barHighlight = tone(0xFFFFFF, 0xFFFFFF, lightAlpha: 0.45, darkAlpha: 0.035)
        /// Extremely soft separation under the bar.
        static let barShadow = tone(0x12161E, 0x000000, lightAlpha: 0.045, darkAlpha: 0.32)
        /// Vertical hairline dividers between zones.
        static let separator = tone(0x1A1D24, 0xFFFFFF, lightAlpha: 0.09, darkAlpha: 0.08)

        static let textPrimary = Theme.textPrimary
        static let textSecondary = Theme.secondaryText
        static let textMuted = Theme.tertiaryText
        static let productText = tone(0x252830, 0xF4F5F7)
        static let controlText = tone(0x383D47, 0xD9DDE4)
        static let selectedText = tone(0x36396F, 0xD7D9FF)

        /// Primary interaction inside the chrome — the same indigo as the rest
        /// of the app, not a second blue.
        static let accent = Theme.accent
        static let accentHover = Theme.accentHover
        static let accentTint = Theme.accentSoft

        /// Control surfaces read as neutral tints of the bar.
        static let controlFill = Theme.secondarySurface
        static let controlHover = tone(0xEBECF1, 0x242C37)
        static let controlPressed = tone(0xE1E3E8, 0x29323E)
        static let controlBorder = Theme.borderSubtle

        // The dark tints step up with the bar: they are read against a darker
        // surface than before, and the selected state has to hold its own
        // without the shadow underneath it doing any work.

        static let barControlFill = Theme.secondarySurface
        static let barControlHover = controlHover
        /// Selection is a quiet indigo tint, not a raised white pill.
        static let barControlActive = Theme.accentSoft
        static let barControlActiveGradient = LinearGradient(
            colors: [tone(0xF3F2FF, 0x8179FF, darkAlpha: 0.14),
                     tone(0xEDEEFF, 0x8179FF, darkAlpha: 0.10)],
            startPoint: .top, endPoint: .bottom)
        static let barControlPressed = controlPressed
        static let barControlBorder = tone(0x1A1D24, 0xFFFFFF, lightAlpha: 0.07, darkAlpha: 0.08)
        /// A slightly firmer hairline for the selected state only.
        static let barControlBorderActive = tone(0x5E5CE6, 0x8179FF, lightAlpha: 0.14, darkAlpha: 0.26)
        /// Grouped containers recess very slightly instead of sitting on a
        /// brighter surface.
        static let barGroupFill = tone(0x1A1D24, 0xFFFFFF, lightAlpha: 0.045, darkAlpha: 0.045)

        // Popovers deliberately do *not* repeat the bar's blur: menus need
        // legibility, so they use a near-opaque elevated surface.

        static let popoverFill = tone(0xFFFFFF, 0x1A2028, lightAlpha: 0.99, darkAlpha: 0.99)
        static let popoverBorder = Theme.borderStandard
        static let popoverShadow = tone(0x12161E, 0x000000, lightAlpha: 0.16, darkAlpha: 0.48)
        static let popoverRowHover = tone(0x1A1D24, 0xFFFFFF, lightAlpha: 0.05, darkAlpha: 0.07)
        static let popoverRowSelected = Theme.accentSoft

        // The chrome's dimensions all live in `TopBarMetrics`: there is one
        // bar, so one place owns its scale.

        enum Timing {
            /// The shell's easing curve. Native-feeling: quick to leave, slow
            /// to arrive, no overshoot.
            static func curve(_ duration: Double) -> Animation {
                .timingCurve(0.2, 0.8, 0.2, 1, duration: duration)
            }

            static let hover = curve(0.15)
            static let press = curve(0.09)
            static let status = curve(0.16)
            static let selection = curve(0.17)
            static let elevation = curve(0.19)
            static let popoverOpen = curve(0.15)
            static let popoverClose = curve(0.11)
            /// One restrained indicator cycle while real work is happening.
            static let activity = Animation.easeInOut(duration: 0.8)
        }
    }

    // MARK: Metrics

    enum Radius {
        /// Small status labels and inline metadata.
        static let badge: CGFloat = 5
        /// Icon buttons and compact icon containers.
        static let icon: CGFloat = 7
        static let small: CGFloat = 8
        /// Standard panels and fields.
        static let panel: CGFloat = 10
        /// Kept as a semantic alias for existing panel call sites.
        static let medium: CGFloat = panel
        static let card: CGFloat = 12
        /// Modal and sheet corners.
        static let large: CGFloat = 14
        static let modal: CGFloat = large
        static let composer: CGFloat = 10
    }

    enum Space {
        static let xs: CGFloat = 4
        static let s: CGFloat = 8
        static let m: CGFloat = 12
        static let l: CGFloat = 16
        static let xl: CGFloat = 24
        static let xxl: CGFloat = 32
    }

    /// Shared control sizes. Keeping these semantic prevents each screen from
    /// inventing its own button, row, or icon scale.
    enum Height {
        static let badge: CGFloat = 20
        static let icon: CGFloat = 28
        static let compact: CGFloat = 28
        static let control: CGFloat = 32
        static let input: CGFloat = 34
        static let prominent: CGFloat = 36
        static let compactRow: CGFloat = 44
        static let detailedRow: CGFloat = 52
        static let composer: CGFloat = 44
        static let pageHeader: CGFloat = 48
        static let toolbar: CGFloat = 58
        static let modalFooter: CGFloat = 56
    }

    enum IconSize {
        static let small: CGFloat = 13
        static let metadata: CGFloat = 13
        static let regular: CGFloat = 16
        static let primary: CGFloat = 17
        static let large: CGFloat = 18
        static let feature: CGFloat = 18
        static let tile: CGFloat = 28
    }

    /// Standard inner padding for cards and sections.
    static let cardPadding: CGFloat = Space.l

    // MARK: Typography helpers

    /// Large rounded display style for hero numbers and titles.
    static func display(_ size: CGFloat, weight: Font.Weight = .bold) -> Font {
        .system(size: size, weight: weight)
    }
}

/// A shared backdrop for the main workspace. It is deliberately one material
/// layer with a quiet brand wash, so the app feels like one translucent Mac
/// window instead of a collection of unrelated frosted cards.
struct GlassWorkspaceBackground: View {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        ZStack {
            if reduceTransparency {
                Theme.canvas
            } else {
                Rectangle().fill(.ultraThinMaterial)
                Rectangle().fill(Theme.Glass.windowTint)
                Theme.workspaceAtmosphere
            }
        }
        .ignoresSafeArea()
    }
}

/// A slightly denser material for panes that sit inside the shared workspace,
/// such as the agent conversation and execution rail.
struct GlassPaneBackground: View {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        ZStack {
            if reduceTransparency {
                Theme.workspaceSurface
            } else {
                Rectangle().fill(.thinMaterial)
                Rectangle().fill(Theme.Glass.paneTint)
            }
        }
    }
}

/// Configures the SwiftUI window as a transparent, movable glass surface. The
/// view is intentionally tiny and invisible; it only gives AppKit the window
/// flags that SwiftUI does not expose through `WindowGroup`.
struct GlassWindowConfigurator: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { WindowView() }

    func updateNSView(_ nsView: NSView, context: Context) {
        (nsView as? WindowView)?.configureWindow()
    }

    private final class WindowView: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            configureWindow()
        }

        func configureWindow() {
            guard let window else { return }
            window.isOpaque = false
            window.backgroundColor = .clear
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.hasShadow = true
            // WindowDragArea owns dragging so buttons and fields remain precise.
            window.isMovableByWindowBackground = false
        }
    }
}

// MARK: - View conveniences

extension View {
    /// The shared card elevation: two very soft neutral layers, slightly
    /// clearer while hovered. Depth comes from luminance and these two shadows
    /// — never from a coloured glow. In dark the shadows fall away over the
    /// black canvas and the luminance step plus the hairline in `commandCard`
    /// carry the separation on their own.
    func cardElevation(raised: Bool = false) -> some View {
        self
            .shadow(color: raised ? Theme.Shadow.ambientRaised : .clear,
                    radius: raised ? 2 : 0, y: raised ? 1 : 0)
            .shadow(color: raised ? Theme.Shadow.keyRaised : .clear,
                    radius: raised ? 18 : 0, y: raised ? 8 : 0)
    }

    /// Standard panel chrome: elevated surface, neutral hairline, soft lift.
    func commandCard(padding: CGFloat = Theme.cardPadding,
                     surface: AnyShapeStyle = Theme.cardFill) -> some View {
        self
            .padding(padding)
            .background(surface, in: RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                    .strokeBorder(Theme.borderHairline, lineWidth: 1)
            )
            .cardElevation()
    }

    /// A full-pane elevated surface for sheets and large panels.
    func glassPane(cornerRadius: CGFloat = Theme.Radius.large) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        return self
            .background(.regularMaterial, in: shape)
            .background(Theme.Glass.paneTint, in: shape)
            .overlay(
                shape.strokeBorder(Theme.borderSubtle, lineWidth: 1)
            )
            .clipShape(shape)
            .cardElevation(raised: true)
    }
}
