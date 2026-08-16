import SwiftUI

// View-layer accent helpers for a workspace. Kept out of the model file so the
// headless `wc` target (which compiles Models without SwiftUI) stays clean.

extension SiteWorkspace {

    /// A curated palette used for the "auto" derivation and the swatch picker.
    static let accentPalette: [String] = [
        "#33B8C7", "#5A66EA", "#34C759", "#FF9F0A", "#FF453A",
        "#BF5AF2", "#FF375F", "#64D2FF", "#FFD60A", "#AC8E68"
    ]

    /// Sentinel `accentHex` value for the name-derived ("Auto") color. A plain
    /// `nil` means colorless — the neutral glass default.
    static let autoAccent = "auto"

    /// The site's accent. Colorless (`nil`, the default) resolves to a neutral
    /// glass tone; `autoAccent` derives a stable palette pick from the site
    /// name; anything else is an explicit `#RRGGBB` hex.
    var accentColor: Color {
        if let hex = accentHex {
            if hex == Self.autoAccent {
                let idx = Self.stableIndex(for: name)
                return Color(hex: Self.accentPalette[idx]) ?? Theme.accent
            }
            if let c = Color(hex: hex) { return c }
        }
        return Theme.secondaryText
    }

    /// A deterministic (per-process-independent) FNV-1a hash so a site's derived
    /// accent is stable across launches. `String.hashValue` is seeded per
    /// process, which would change the color every launch (and `abs` can trap
    /// on `Int.min`).
    private static func stableIndex(for name: String) -> Int {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in name.utf8 {
            hash = (hash ^ UInt64(byte)) &* 0x100000001b3
        }
        return Int(hash % UInt64(accentPalette.count))
    }
}

extension Color {
    /// Parse a `#RRGGBB` or `#RRGGBBAA` hex string. Nil on malformed input.
    init?(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6 || s.count == 8,
              let v = UInt64(s, radix: 16) else { return nil }
        let r, g, b, a: Double
        if s.count == 6 {
            r = Double((v >> 16) & 0xFF) / 255
            g = Double((v >> 8) & 0xFF) / 255
            b = Double(v & 0xFF) / 255
            a = 1
        } else {
            r = Double((v >> 24) & 0xFF) / 255
            g = Double((v >> 16) & 0xFF) / 255
            b = Double((v >> 8) & 0xFF) / 255
            a = Double(v & 0xFF) / 255
        }
        self = Color(.sRGB, red: r, green: g, blue: b, opacity: a)
    }
}
