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
    static let accent = tone(0x5368E8, 0x7183E8)
    static let accentHover = tone(0x465BD5, 0x8492F0)
    static let accentPressed = tone(0x3E50BE, 0x5C6DD2)
    /// A soft indigo surface for selected rows and quiet primary tiles. The dark
    /// alpha is raised because it now composites over true black rather than a
    /// near-black canvas, and a 20% tint there reads as almost nothing.
    static let accentSoft = tone(0xEEF0FF, 0x5368E8, darkAlpha: 0.28)
    static let accentBorder = tone(0xC9CFFF, 0x7183E8, darkAlpha: 0.38)

    /// The teal the brand gradient blends into. Used by the logo and the one
    /// branded gradient — not as a general-purpose accent.
    static let accentDeep = tone(0x279B94, 0x43B5AC)

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

    static let violet = tone(0x7A62D9, 0x9A88E4)
    static let violetSoft = tone(0xF1EDFF, 0x7A62D9, darkAlpha: 0.28)

    static let teal = tone(0x279B94, 0x43B5AC)
    static let tealSoft = tone(0xE7F6F4, 0x279B94, darkAlpha: 0.24)

    static let green = tone(0x329369, 0x4DB786)
    static let greenSoft = tone(0xE9F5EF, 0x329369, darkAlpha: 0.26)

    static let amber = tone(0xB7791F, 0xD9A244)
    static let amberSoft = tone(0xFFF4DA, 0xB7791F, darkAlpha: 0.24)
    /// The Recommended badge's label: darker than `amber` so 11pt text on
    /// `amberSoft` clears WCAG AA.
    static let amberText = tone(0x946312, 0xE7BE75)
    static let amberBorder = tone(0xB7791F, 0xD9A244, lightAlpha: 0.18, darkAlpha: 0.30)

    static let rose = tone(0xC85B75, 0xDE7E94)
    static let roseSoft = tone(0xFCECF1, 0xC85B75, darkAlpha: 0.26)

    static let cyan = tone(0x358CA8, 0x5CACC6)
    static let cyanSoft = tone(0xEAF5F8, 0x358CA8, darkAlpha: 0.26)

    static let destructive = tone(0xC94F4F, 0xE06C6C)
    static let destructiveSoft = tone(0xFCECEC, 0xC94F4F, darkAlpha: 0.28)

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
        static let sweep: [Color] = [Theme.accent, Theme.violet, Theme.teal, Theme.accent]

        /// A hair thicker than a resting hairline, so the travel is legible
        /// without the composer gaining weight.
        static let lineWidth: CGFloat = 1.6
        /// Sits on the focus halo's geometry, so switching between them never
        /// shifts the composer's apparent size.
        static let haloWidth: CGFloat = 3
        static let haloOpacity: Double = 0.22

        /// Seconds per rotation. Slow enough to read as ambient presence.
        static let period: Double = 2.8
        /// Cross-fade in and out of the resting border.
        static let fade = Animation.easeInOut(duration: 0.18)

        /// Reduce Motion substitute: the model's violet, held still.
        static let staticTint = Theme.violet

        static func gradient(angle: Angle) -> AngularGradient {
            AngularGradient(colors: sweep, center: .center, angle: angle)
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

    /// Level 1 — the application canvas. Warm off-white in light; true black in
    /// dark, so on OLED the largest region of the app draws no power at all.
    static let canvas = tone(0xF7F7F5, 0x000000)
    /// Level 1 — the workspace pane, a shade brighter than the canvas.
    static let workspaceSurface = tone(0xFBFBFA, 0x0B0B0E)
    /// Level 2 — chrome and other secondary regions.
    static let chromeSurface = tone(0xF1F2F3, 0x141418)
    /// Level 3 — cards, popovers, the composer.
    static let elevatedSurface = tone(0xFFFFFF, 0x1A1A1F)
    /// A quiet inset surface: attachment chips, icon tiles, code wells.
    static let secondarySurface = tone(0xF4F5F6, 0x222229)
    /// The next step down, for hover on an inset surface.
    static let tertiarySurface = tone(0xEEEFF1, 0x2C2C34)

    /// The card surface as a shape style, for the many call sites that switch
    /// between it and an accent fill.
    static var cardFill: AnyShapeStyle { AnyShapeStyle(elevatedSurface) }

    // MARK: Text
    //
    // Dark body text stops short of white on purpose. Near-white on true black
    // is where OLED halation shows up — strokes bleed and long paragraphs smear
    // during scrolling — so primary sits at #E3E5EA, still 16.7:1 on the canvas
    // and 13.8:1 on a card. Secondary and tertiary come down with it, because a
    // darker canvas raises every foreground's contrast and would otherwise
    // flatten the three levels into one.

    static let textPrimary = tone(0x202226, 0xE3E5EA)
    static let secondaryText = tone(0x626873, 0x9BA1AB)
    static let tertiaryText = tone(0x8B919B, 0x868C96)
    static let disabledText = tone(0xADB1B8, 0x626873)
    static let textInverse = Color.white

    // MARK: Borders
    //
    // Raised in dark. With the canvas at true black and shadows unable to
    // register on it, the hairline is half of what separates a card from what
    // it sits on — the surface step is the other half.

    static let borderSubtle = tone(0xE3E5E8, 0xFFFFFF, darkAlpha: 0.12)
    static let borderStandard = tone(0xD8DBE0, 0xFFFFFF, darkAlpha: 0.17)
    static let borderStrong = tone(0xC8CDD4, 0xFFFFFF, darkAlpha: 0.23)
    /// Hairline rules between regions. Fainter than any card border.
    static let divider = tone(0x1F2329, 0xFFFFFF, lightAlpha: 0.08, darkAlpha: 0.11)

    /// Focus is signalled by an indigo border plus a soft outer ring — never by
    /// a colour change alone.
    static let focusRing = accent
    static let focusRingHalo = tone(0x5368E8, 0x7183E8, lightAlpha: 0.12, darkAlpha: 0.30)

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
        static let ambient = tone(0x14181F, 0x000000, lightAlpha: 0.03, darkAlpha: 0.48)
        static let key = tone(0x14181F, 0x000000, lightAlpha: 0.025, darkAlpha: 0.40)
        static let ambientRaised = tone(0x14181F, 0x000000, lightAlpha: 0.05, darkAlpha: 0.55)
        static let keyRaised = tone(0x14181F, 0x000000, lightAlpha: 0.05, darkAlpha: 0.46)
    }

    // MARK: Workspace chrome

    /// Tokens for the application bar. Neutral by construction: the bar is a
    /// white translucent surface with one hairline, and the accent appears only
    /// on live activity, selection, and focus.
    enum Chrome {

        /// The bar's translucent surface, layered over one blur. In dark it is
        /// both darker and more opaque: `.bar` renders around #1D1D21 over a
        /// black canvas, and letting a fifth of that through would float the
        /// chrome well above its own level on the ladder. At 88% the bar lands
        /// on `chromeSurface` and stops depending on what the material does.
        static let barFill = tone(0xFFFFFF, 0x121216, lightAlpha: 0.82, darkAlpha: 0.88)
        /// Opaque fallback when the material is unavailable.
        static let barFillOpaque = tone(0xF7F8F8, 0x141418)
        static let barBorder = Theme.divider
        /// A single inner highlight along the bar's top edge.
        static let barHighlight = tone(0xFFFFFF, 0xFFFFFF, lightAlpha: 0.70, darkAlpha: 0.06)
        /// Extremely soft separation under the bar.
        static let barShadow = tone(0x14181F, 0x000000, lightAlpha: 0.04, darkAlpha: 0.38)
        /// Vertical hairline dividers between zones.
        static let separator = tone(0x1F2329, 0xFFFFFF, lightAlpha: 0.09, darkAlpha: 0.11)

        static let textPrimary = Theme.textPrimary
        static let textSecondary = Theme.secondaryText
        static let textMuted = Theme.tertiaryText

        /// Primary interaction inside the chrome — the same indigo as the rest
        /// of the app, not a second blue.
        static let accent = Theme.accent
        static let accentHover = Theme.accentHover
        static let accentTint = Theme.accentSoft

        /// Control surfaces read as neutral tints of the bar.
        static let controlFill = Theme.secondarySurface
        static let controlHover = Theme.tertiarySurface
        static let controlPressed = tone(0xE7E8EB, 0x34343D)
        static let controlBorder = Theme.borderSubtle

        // The dark tints step up with the bar: they are read against a darker
        // surface than before, and the selected state has to hold its own
        // without the shadow underneath it doing any work.

        static let barControlFill = tone(0xFFFFFF, 0xFFFFFF, lightAlpha: 0.55, darkAlpha: 0.06)
        static let barControlHover = tone(0xFFFFFF, 0xFFFFFF, lightAlpha: 0.85, darkAlpha: 0.09)
        /// The selected state is an elevated white surface, not a tint.
        static let barControlActive = tone(0xFFFFFF, 0xFFFFFF, lightAlpha: 1, darkAlpha: 0.13)
        static let barControlPressed = tone(0xEDEEF0, 0xFFFFFF, lightAlpha: 0.95, darkAlpha: 0.16)
        static let barControlBorder = tone(0x1F2329, 0xFFFFFF, lightAlpha: 0.07, darkAlpha: 0.09)
        /// A slightly firmer hairline for the selected state only.
        static let barControlBorderActive = tone(0xD8DBE0, 0xFFFFFF, lightAlpha: 1, darkAlpha: 0.16)
        /// Grouped containers recess very slightly instead of sitting on a
        /// brighter surface.
        static let barGroupFill = tone(0x1F2329, 0xFFFFFF, lightAlpha: 0.04, darkAlpha: 0.045)

        // Popovers deliberately do *not* repeat the bar's blur: menus need
        // legibility, so they use a near-opaque elevated surface.

        static let popoverFill = tone(0xFFFFFF, 0x1E1E25, lightAlpha: 0.99, darkAlpha: 0.99)
        static let popoverBorder = Theme.borderStandard
        static let popoverShadow = tone(0x14181F, 0x000000, lightAlpha: 0.13, darkAlpha: 0.58)
        static let popoverRowHover = tone(0x1F2329, 0xFFFFFF, lightAlpha: 0.05, darkAlpha: 0.08)
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
        static let small: CGFloat = 8
        static let medium: CGFloat = 12
        static let large: CGFloat = 16
        static let card: CGFloat = 13
        static let composer: CGFloat = 15
    }

    enum Space {
        static let xs: CGFloat = 4
        static let s: CGFloat = 8
        static let m: CGFloat = 12
        static let l: CGFloat = 16
        static let xl: CGFloat = 24
        static let xxl: CGFloat = 32
    }

    /// Standard inner padding for cards and sections.
    static let cardPadding: CGFloat = Space.l

    // MARK: Typography helpers

    /// Large rounded display style for hero numbers and titles.
    static func display(_ size: CGFloat, weight: Font.Weight = .bold) -> Font {
        .system(size: size, weight: weight, design: .rounded)
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
            .shadow(color: raised ? Theme.Shadow.ambientRaised : Theme.Shadow.ambient,
                    radius: raised ? 2 : 1.5, y: raised ? 1 : 1)
            .shadow(color: raised ? Theme.Shadow.keyRaised : Theme.Shadow.key,
                    radius: raised ? 18 : 12, y: raised ? 8 : 5)
    }

    /// Standard panel chrome: elevated surface, neutral hairline, soft lift.
    func commandCard(padding: CGFloat = Theme.cardPadding) -> some View {
        self
            .padding(padding)
            .background(Theme.cardFill, in: RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                    .strokeBorder(Theme.borderSubtle, lineWidth: 1)
            )
            .cardElevation()
    }

    /// A full-pane elevated surface for sheets and large panels.
    func glassPane(cornerRadius: CGFloat = Theme.Radius.large) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        return self
            .background(Theme.elevatedSurface, in: shape)
            .overlay(
                shape.strokeBorder(Theme.borderSubtle, lineWidth: 1)
            )
            .clipShape(shape)
            .cardElevation(raised: true)
    }
}
