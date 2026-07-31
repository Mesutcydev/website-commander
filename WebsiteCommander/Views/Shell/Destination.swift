import SwiftUI

/// The five top-level destinations of the app.
///
/// Raw values are the canonical route names and are persisted, so they must not
/// change. `barLabel` is the shorter form the top bar shows — the route keeps
/// its full name everywhere else (accessibility, palette, page context).
enum Destination: String, CaseIterable, Identifiable, Hashable {
    case commandCenter = "Command Center"
    case sites = "Sites"
    case agent = "Agent"
    case preview = "Preview"
    case history = "History"

    var id: String { rawValue }

    /// Compact label used in the top bar's destination row.
    var barLabel: String {
        switch self {
        case .commandCenter: return "Command"
        case .sites:         return "Sites"
        case .agent:         return "Agent"
        case .preview:       return "Preview"
        case .history:       return "History"
        }
    }

    /// One icon family, one stroke weight, no filled/outline mixing.
    var icon: String {
        switch self {
        case .commandCenter: return "square.grid.2x2"
        case .sites:         return "folder"
        case .agent:         return "bubble.left.and.text.bubble.right"
        case .preview:       return "eye"
        case .history:       return "clock"
        }
    }
}

// MARK: - Destination environment (lets deep views navigate)

private struct DestinationKey: EnvironmentKey {
    static let defaultValue: Binding<Destination?> = .constant(.commandCenter)
}

extension EnvironmentValues {
    /// The shell's current destination. Views deep in a screen write to this to
    /// navigate; the shell owns the storage.
    var destination: Binding<Destination?> {
        get { self[DestinationKey.self] }
        set { self[DestinationKey.self] = newValue }
    }
}
