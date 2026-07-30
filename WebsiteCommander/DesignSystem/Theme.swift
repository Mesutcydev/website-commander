import SwiftUI

/// The visual language of Website Commander.
///
/// A calm, Mac-native palette built around a single "command" gradient
/// (teal → indigo). Everything is driven by semantic tokens so views never hard
/// code raw colors — swap the accent here and the whole app follows.
enum Theme {

    // MARK: Accent

    /// Primary brand accent.
    static let accent = Color(red: 0.20, green: 0.72, blue: 0.78)
    /// Secondary accent that the brand gradient blends into.
    static let accentDeep = Color(red: 0.36, green: 0.40, blue: 0.92)

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

    static let success = Color(red: 0.30, green: 0.78, blue: 0.47)
    static let warning = Color(red: 0.95, green: 0.66, blue: 0.20)
    static let danger  = Color(red: 0.90, green: 0.36, blue: 0.36)
    static let info    = accentDeep

    // MARK: Surfaces

    /// Card surface — a material so the window backdrop subtly shows through.
    static var cardFill: AnyShapeStyle {
        AnyShapeStyle(.regularMaterial)
    }

    /// A hairline separator/stroke that adapts to light & dark.
    static var hairline: Color {
        Color.primary.opacity(0.08)
    }

    // MARK: Metrics

    enum Radius {
        static let small: CGFloat = 8
        static let medium: CGFloat = 12
        static let large: CGFloat = 16
        static let card: CGFloat = 18
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
    /// The standard card chrome: material fill, rounded corners, hairline stroke.
    func commandCard(padding: CGFloat = Theme.cardPadding) -> some View {
        self
            .padding(padding)
            .background(Theme.cardFill, in: RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                    .strokeBorder(Theme.hairline, lineWidth: 1)
            )
    }
}
