import SwiftUI
import AppKit
import CoreText

extension Theme {

    /// The typographic voice of Website Commander: a neo-grotesque for app
    /// chrome, so the workspace reads as a designed desktop product rather than
    /// a default SwiftUI window.
    ///
    /// **On the typeface.** The reference specimen is *Die Grotesk* (Kris
    /// Sowersby, Klim Type Foundry). Die Grotesk is a commercial retail family —
    /// its licence forbids redistributing the font files, so an MIT-licensed
    /// repository cannot ship them. Instead the family is *resolved at runtime*
    /// from an ordered preference list:
    ///
    /// 1. `Die Grotesk` — picked up automatically if the user has bought a
    ///    licence and installed the family (`~/Library/Fonts`). Nothing else to
    ///    configure.
    /// 2. `Hanken Grotesk` — the bundled stand-in (SIL Open Font License 1.1,
    ///    see `Resources/Fonts/OFL.txt`). Same Helvetica/Akzidenz lineage as Die
    ///    Grotesk, with slightly more open apertures that hold up better at
    ///    12–15pt on screen, and full Latin-ext coverage for the Turkish
    ///    localisation.
    /// 3. `Helvetica Neue` — ships with macOS; the closest system-native
    ///    grotesque.
    /// 4. The system font, if somehow none of the above resolve.
    ///
    /// Code and diffs deliberately stay monospaced; this face is for chrome only.
    enum Typography {

        /// Families tried in order. Extend rather than replace — the first
        /// entry exists so a licensed local Die Grotesk install wins.
        static let familyPreference = [
            "Die Grotesk",
            "Hanken Grotesk",
            "Helvetica Neue"
        ]

        /// The family actually available on this machine, or `nil` to mean
        /// "fall back to the system font". Resolved once at first use, after
        /// the bundled family is registered — so the ordering can't be got
        /// wrong from a call site.
        static let resolvedFamily: String? = {
            registerBundledFonts()
            let installed = Set(NSFontManager.shared.availableFontFamilies)
            return familyPreference.first { installed.contains($0) }
        }()

        /// Loads `Contents/Resources/Fonts` into this process. Registration is
        /// process-scoped: nothing is installed into the user's font library.
        /// Registered one URL at a time because the batch variant is the only
        /// one that can complete asynchronously — the family has to be
        /// matchable by the time this returns.
        private static func registerBundledFonts() {
            let urls = Bundle.main.urls(forResourcesWithExtension: "ttf", subdirectory: "Fonts") ?? []
            for url in urls {
                CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
            }
        }

        // MARK: Semantic styles
        //
        // Sizes match the chrome metrics in `Theme.Chrome`; keep changes here
        // rather than at call sites so the bar stays on a single scale.

        /// Page headings inside scrollable content ("Agent Chat").
        static let pageTitle = font(19, .semibold)
        /// The supporting line under a page heading.
        static let pageSubtitle = font(13, .regular)
        /// The leading section name in the toolbar breadcrumb.
        static let breadcrumbTitle = font(15, .semibold)
        /// The muted separator and site crumb next to it.
        static let breadcrumbCrumb = font(13, .medium)
        /// Text inside toolbar controls (model selector, buttons).
        static let control = font(13, .medium)
        /// The live agent activity capsule.
        static let status = font(12.5, .medium)
        /// Small supporting labels in chrome.
        static let caption = font(11.5, .medium)

        /// Optical tracking for display-size chrome. Grotesques set tighter
        /// than SF at large sizes; without this, headings look loose.
        static let titleTracking: CGFloat = -0.3

        // MARK: Resolution

        /// A chrome font at an explicit size and weight, falling back to the
        /// system font when no grotesque is available.
        static func font(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
            Font(nsFont(size, weight))
        }

        /// The same resolution as `font(_:_:)`, as an `NSFont` — used to measure
        /// chrome text so layout budgets can be checked against the face the app
        /// will actually render with.
        static func nsFont(_ size: CGFloat, _ weight: Font.Weight = .regular) -> NSFont {
            if let family = resolvedFamily,
               let resolved = cachedFont(family: family, size: size, weight: weight) {
                return resolved
            }
            return .systemFont(ofSize: size, weight: weight.appKitWeight)
        }

        /// Rendered width of a chrome string, rounded up to whole points.
        static func width(_ string: String, size: CGFloat, weight: Font.Weight = .regular) -> CGFloat {
            let measured = NSAttributedString(
                string: string,
                attributes: [.font: nsFont(size, weight)]
            ).size().width
            return measured.rounded(.up)
        }

        private static let cache = FontCache()

        private static func cachedFont(family: String, size: CGFloat, weight: Font.Weight) -> NSFont? {
            let key = "\(family)|\(size)|\(weight.appKitWeight.rawValue)"
            if let hit = cache.font(for: key) { return hit }
            let descriptor = NSFontDescriptor(fontAttributes: [
                .family: family,
                .traits: [NSFontDescriptor.TraitKey.weight: weight.appKitWeight.rawValue]
            ])
            guard let font = NSFont(descriptor: descriptor, size: size) else { return nil }
            cache.store(font, for: key)
            return font
        }
    }

    /// Shorthand for chrome text: a drop-in for `.system(size:weight:)`.
    static func ui(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        Typography.font(size, weight)
    }
}

// MARK: - Cache

/// Descriptor matching is cheap but not free, and chrome fonts are requested
/// on every body evaluation. A tiny locked cache keeps that off the hot path.
private final class FontCache: @unchecked Sendable {
    private var storage: [String: NSFont] = [:]
    private let lock = NSLock()

    func font(for key: String) -> NSFont? {
        lock.lock()
        defer { lock.unlock() }
        return storage[key]
    }

    func store(_ font: NSFont, for key: String) {
        lock.lock()
        storage[key] = font
        lock.unlock()
    }
}

// MARK: - Weight bridging

private extension Font.Weight {
    /// SwiftUI weights carry no public numeric value, so map them onto AppKit's
    /// scale to drive descriptor matching.
    var appKitWeight: NSFont.Weight {
        switch self {
        case .ultraLight: return .ultraLight
        case .thin:       return .thin
        case .light:      return .light
        case .medium:     return .medium
        case .semibold:   return .semibold
        case .bold:       return .bold
        case .heavy:      return .heavy
        case .black:      return .black
        default:          return .regular
        }
    }
}
