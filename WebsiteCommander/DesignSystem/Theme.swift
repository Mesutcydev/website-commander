import SwiftUI
import AppKit

/// The visual language of Website Commander.
///
/// A calm, Mac-native palette built around a single "command" gradient
/// (teal → indigo). Everything is driven by semantic tokens so views never hard
/// code raw colors — swap the accent here and the whole app follows.
enum Theme {

    private static func adaptive(light: NSColor, dark: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
        })
    }

    // MARK: Accent

    /// Primary brand accent.
    static let accent = Color(red: 0.357, green: 0.373, blue: 0.937) // #5B5FEF
    /// Secondary accent that the brand gradient blends into.
    static let accentDeep = Color(red: 0.345, green: 0.722, blue: 0.780) // #58B8C7
    static let accentHover = Color(red: 0.408, green: 0.424, blue: 0.949)
    static let accentPressed = Color(red: 0.306, green: 0.322, blue: 0.847)
    static let slateAccent = Color(red: 0.494, green: 0.549, blue: 0.639)
    static let accentSecondaryMuted = accentDeep.opacity(0.16)

    /// The signature brand gradient, used for hero buttons, active sidebar
    /// selection, and stat-tile highlights.
    static var brandGradient: LinearGradient {
        LinearGradient(
            colors: [accent, accentDeep],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    /// A soft, mostly-transparent wash of the brand gradient for backgrounds.
    static var brandWash: LinearGradient {
        LinearGradient(
            colors: [accent.opacity(0.16), accentDeep.opacity(0.10)],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    // MARK: Semantic status colors

    static let success = adaptive(
        light: NSColor(red: 0.075, green: 0.478, blue: 0.345, alpha: 1),
        dark: NSColor(red: 0.231, green: 0.827, blue: 0.604, alpha: 1)
    )
    static let warning = adaptive(
        light: NSColor(red: 0.596, green: 0.396, blue: 0.0, alpha: 1),
        dark: NSColor(red: 0.945, green: 0.722, blue: 0.294, alpha: 1)
    )
    static let danger = adaptive(
        light: NSColor(red: 0.788, green: 0.204, blue: 0.302, alpha: 1),
        dark: NSColor(red: 1.0, green: 0.396, blue: 0.478, alpha: 1)
    )
    static let info = adaptive(
        light: NSColor(red: 0.153, green: 0.435, blue: 0.800, alpha: 1),
        dark: NSColor(red: 0.388, green: 0.655, blue: 1.0, alpha: 1)
    )

    // MARK: Surfaces

    /// True-black OLED canvas. Keeping this token centralized prevents gray
    /// system materials from washing out large parts of the window.
    static let canvas = adaptive(
        light: NSColor(red: 0.965, green: 0.973, blue: 0.984, alpha: 1),
        dark: NSColor(red: 0.027, green: 0.035, blue: 0.051, alpha: 1)
    )
    static let sidebarFill = adaptive(
        light: NSColor(red: 0.925, green: 0.945, blue: 0.969, alpha: 1),
        dark: NSColor(red: 0.035, green: 0.047, blue: 0.067, alpha: 1)
    )
    static let panelFill = adaptive(
        light: NSColor(red: 1, green: 1, blue: 1, alpha: 1),
        dark: NSColor(red: 0.055, green: 0.071, blue: 0.094, alpha: 1)
    )
    static let raisedFill = adaptive(
        light: NSColor(red: 0.953, green: 0.965, blue: 0.980, alpha: 1),
        dark: NSColor(red: 0.075, green: 0.094, blue: 0.129, alpha: 1)
    )
    static let surfaceHover = adaptive(
        light: NSColor(red: 0.902, green: 0.925, blue: 0.957, alpha: 1),
        dark: NSColor(red: 0.110, green: 0.137, blue: 0.188, alpha: 1)
    )
    static let surfaceSelected = accent.opacity(0.13)
    static let textPrimary = adaptive(
        light: NSColor(red: 0.082, green: 0.102, blue: 0.137, alpha: 1),
        dark: NSColor(red: 0.957, green: 0.969, blue: 0.984, alpha: 1)
    )
    static let secondaryText = adaptive(
        light: NSColor(red: 0.290, green: 0.337, blue: 0.408, alpha: 1),
        dark: NSColor(red: 0.647, green: 0.682, blue: 0.733, alpha: 1)
    )
    static let tertiaryText = adaptive(
        light: NSColor(red: 0.420, green: 0.467, blue: 0.545, alpha: 1),
        dark: NSColor(red: 0.443, green: 0.482, blue: 0.545, alpha: 1)
    )
    static let surface = panelFill
    static let surfaceRaised = raisedFill

    /// Cards stay visibly separated from black without illuminating large
    /// screen areas—important for OLED power use and readable hierarchy.
    static var cardFill: AnyShapeStyle {
        AnyShapeStyle(panelFill)
    }

    /// Strong enough to remain visible against true black.
    static let borderSubtle = adaptive(
        light: NSColor(red: 0.800, green: 0.831, blue: 0.875, alpha: 0.72),
        dark: NSColor(red: 0.169, green: 0.200, blue: 0.251, alpha: 0.66)
    )
    static let borderStrong = adaptive(
        light: NSColor(red: 0.714, green: 0.753, blue: 0.808, alpha: 1),
        dark: NSColor(red: 0.169, green: 0.200, blue: 0.251, alpha: 1)
    )
    static var hairline: Color { borderSubtle }
    static let strongBorder = borderStrong
    static let focusRing = accent.opacity(0.78)

    // MARK: Workspace chrome

    /// Tokens for the unified workspace command bar. Deliberately neutral:
    /// tonal separation from the canvas instead of a colored band, with the
    /// accent reserved for live activity, selection, and focus.
    enum Chrome {

        /// Semi-transparent toolbar surface; pairs with `.ultraThinMaterial`
        /// so scrolled content reads faintly through it.
        static let toolbarFill = adaptive(
            light: NSColor(red: 0.988, green: 0.988, blue: 0.992, alpha: 0.94),
            dark: NSColor(red: 0.067, green: 0.078, blue: 0.102, alpha: 0.94)
        )
        static let controlFill = adaptive(
            light: NSColor(red: 0.941, green: 0.945, blue: 0.957, alpha: 1),
            dark: NSColor(red: 0.098, green: 0.114, blue: 0.145, alpha: 1)
        )
        static let controlHover = adaptive(
            light: NSColor(red: 0.914, green: 0.922, blue: 0.941, alpha: 1),
            dark: NSColor(red: 0.125, green: 0.145, blue: 0.184, alpha: 1)
        )
        static let controlPressed = adaptive(
            light: NSColor(red: 0.886, green: 0.898, blue: 0.922, alpha: 1),
            dark: NSColor(red: 0.153, green: 0.176, blue: 0.220, alpha: 1)
        )
        static let controlBorder = adaptive(
            light: NSColor(red: 0.882, green: 0.894, blue: 0.914, alpha: 1),
            dark: NSColor(white: 1, alpha: 0.08)
        )
        /// Elevated separator that appears once content scrolls under the bar.
        static let toolbarBorderRaised = adaptive(
            light: NSColor(red: 0.816, green: 0.835, blue: 0.863, alpha: 1),
            dark: NSColor(white: 1, alpha: 0.14)
        )
        static let textPrimary = adaptive(
            light: NSColor(red: 0.125, green: 0.133, blue: 0.157, alpha: 1),
            dark: NSColor(red: 0.953, green: 0.961, blue: 0.973, alpha: 1)
        )
        static let textSecondary = adaptive(
            light: NSColor(red: 0.435, green: 0.459, blue: 0.502, alpha: 1),
            dark: NSColor(red: 0.635, green: 0.663, blue: 0.706, alpha: 1)
        )
        static let textMuted = adaptive(
            light: NSColor(red: 0.573, green: 0.596, blue: 0.639, alpha: 1),
            dark: NSColor(red: 0.451, green: 0.486, blue: 0.537, alpha: 1)
        )
        /// Restrained indigo used only for live state, selection, and focus.
        static let accent = adaptive(
            light: NSColor(red: 0.384, green: 0.357, blue: 0.965, alpha: 1), // #625BF6
            dark: NSColor(red: 0.471, green: 0.447, blue: 0.973, alpha: 1)  // #7872F8
        )
        static let accentHover = adaptive(
            light: NSColor(red: 0.341, green: 0.314, blue: 0.914, alpha: 1), // #5750E9
            dark: NSColor(red: 0.529, green: 0.506, blue: 0.984, alpha: 1)
        )
        static let accentTint = accent.opacity(0.10)

        // MARK: Application bar
        //
        // The shell's top bar is the app's single material layer: one
        // translucent surface, one hairline, one inner highlight, one very soft
        // separation shadow. Controls inside it never add blur of their own —
        // they tint the bar they sit on. Values are the neutral chrome scale
        // tuned to this app's cool slate palette.

        /// The bar's translucent surface, layered over one blur.
        static let barFill = adaptive(
            light: NSColor(red: 0.973, green: 0.976, blue: 0.984, alpha: 0.78),
            dark: NSColor(red: 0.067, green: 0.082, blue: 0.118, alpha: 0.76)
        )
        /// The bar's bottom hairline.
        static let barBorder = adaptive(
            light: NSColor(red: 0.071, green: 0.094, blue: 0.149, alpha: 0.10),
            dark: NSColor(white: 1, alpha: 0.09)
        )
        /// A single inner highlight along the bar's top edge.
        static let barHighlight = adaptive(
            light: NSColor(white: 1, alpha: 0.72),
            dark: NSColor(white: 1, alpha: 0.055)
        )
        /// Extremely soft separation under the bar.
        static let barShadow = adaptive(
            light: NSColor(red: 0.063, green: 0.094, blue: 0.157, alpha: 0.045),
            dark: NSColor(white: 0, alpha: 0.22)
        )
        /// Opaque fallback if the material is unavailable.
        static let barFillOpaque = adaptive(
            light: NSColor(red: 0.973, green: 0.976, blue: 0.984, alpha: 1),
            dark: NSColor(red: 0.067, green: 0.082, blue: 0.118, alpha: 1)
        )

        /// Vertical hairline dividers between zones. Deliberately fainter than
        /// card borders so the bar stays quiet.
        static let separator = adaptive(
            light: NSColor(red: 0.071, green: 0.094, blue: 0.149, alpha: 0.11),
            dark: NSColor(white: 1, alpha: 0.08)
        )

        /// Translucent control surfaces that read as tints of the bar.
        static let barControlFill = adaptive(
            light: NSColor(white: 1, alpha: 0.46),
            dark: NSColor(white: 1, alpha: 0.045)
        )
        static let barControlHover = adaptive(
            light: NSColor(white: 1, alpha: 0.72),
            dark: NSColor(white: 1, alpha: 0.075)
        )
        static let barControlActive = adaptive(
            light: NSColor(white: 1, alpha: 0.86),
            dark: NSColor(white: 1, alpha: 0.105)
        )
        static let barControlPressed = adaptive(
            light: NSColor(red: 0.898, green: 0.910, blue: 0.933, alpha: 0.92),
            dark: NSColor(white: 1, alpha: 0.135)
        )
        static let barControlBorder = adaptive(
            light: NSColor(red: 0.071, green: 0.094, blue: 0.149, alpha: 0.08),
            dark: NSColor(white: 1, alpha: 0.07)
        )
        /// A slightly firmer hairline for the selected state only.
        static let barControlBorderActive = adaptive(
            light: NSColor(red: 0.071, green: 0.094, blue: 0.149, alpha: 0.13),
            dark: NSColor(white: 1, alpha: 0.12)
        )

        /// Grouped containers (navigation, view controls) recess very slightly
        /// instead of sitting on a brighter surface.
        static let barGroupFill = adaptive(
            light: NSColor(red: 0.071, green: 0.094, blue: 0.149, alpha: 0.035),
            dark: NSColor(white: 1, alpha: 0.028)
        )

        // MARK: Popovers
        //
        // Popovers deliberately do *not* repeat the bar's blur: menus need
        // legibility, so they use a near-opaque elevated surface.

        static let popoverFill = adaptive(
            light: NSColor(red: 0.988, green: 0.992, blue: 0.996, alpha: 0.99),
            dark: NSColor(red: 0.114, green: 0.129, blue: 0.161, alpha: 0.99)
        )
        static let popoverBorder = adaptive(
            light: NSColor(red: 0.071, green: 0.094, blue: 0.149, alpha: 0.12),
            dark: NSColor(white: 1, alpha: 0.10)
        )
        static let popoverShadow = adaptive(
            light: NSColor(white: 0, alpha: 0.14),
            dark: NSColor(white: 0, alpha: 0.44)
        )
        static let popoverRowHover = adaptive(
            light: NSColor(red: 0.071, green: 0.094, blue: 0.149, alpha: 0.05),
            dark: NSColor(white: 1, alpha: 0.055)
        )
        static let popoverRowSelected = adaptive(
            light: NSColor(red: 0.071, green: 0.094, blue: 0.149, alpha: 0.075),
            dark: NSColor(white: 1, alpha: 0.085)
        )

        enum Metrics {
            /// The shell's bar height lives in `TopBarMetrics` — this alias
            /// exists so older call sites keep resolving to one value.
            static var toolbarHeight: CGFloat { TopBarMetrics.height }
            static let controlHeight: CGFloat = 32
            static let controlRadius: CGFloat = 8
            static let groupRadius: CGFloat = 9
            static let toggleSize: CGFloat = 32
            static let toggleRadius: CGFloat = 8
            static let statusHeight: CGFloat = 28
            static let statusDot: CGFloat = 6
            static let iconSize: CGFloat = 15
            static let edgePadding: CGFloat = 12
            static let regionGap: CGFloat = 10
        }

        enum Timing {
            /// The shell's easing curve. Native-feeling: quick to leave, slow
            /// to arrive, no overshoot.
            static func curve(_ duration: Double) -> Animation {
                .timingCurve(0.2, 0.8, 0.2, 1, duration: duration)
            }

            static let hover = curve(0.13)
            static let press = curve(0.07)
            static let status = curve(0.16)
            static let selection = curve(0.17)
            static let elevation = curve(0.18)
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
        static let card: CGFloat = 12
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
    /// Standard panel chrome. Depth comes from luminance rather than decorative
    /// gradient borders, keeping the signature gradient meaningful.
    func commandCard(padding: CGFloat = Theme.cardPadding) -> some View {
        self
            .padding(padding)
            .background(Theme.cardFill, in: RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                    .strokeBorder(Theme.borderSubtle, lineWidth: 1)
            )
    }

    /// A full-pane glass surface inspired by the calm, luminous treatment used
    /// across SiteAgent and ScreenHarbor.
    func glassPane(cornerRadius: CGFloat = Theme.Radius.large) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        return self
            .background(Theme.panelFill.opacity(0.96), in: shape)
            .overlay(
                shape.strokeBorder(Theme.borderSubtle, lineWidth: 1)
            )
            .clipShape(shape)
            .shadow(color: .black.opacity(0.18), radius: 12, y: 6)
    }
}
