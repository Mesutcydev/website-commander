import CoreText
import Foundation

/// Registers the bundled design fonts (Bricolage Grotesque, Geist, Geist Mono)
/// at launch so `Font.custom(_:size:)` can find them by PostScript name. Done at
/// runtime rather than via Info.plist `UIAppFonts` so it survives the xcodegen
/// build setup unchanged and works identically on Mac Catalyst.
enum Fonts {
    /// Call once, early (App.init). Idempotent: re-registering an already-known
    /// font is a harmless no-op (we swallow the error pointer).
    static func register() {
        let urls = Bundle.main.urls(forResourcesWithExtension: "ttf", subdirectory: nil) ?? []
        for url in urls {
            CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
        }
    }
}
