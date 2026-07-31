import SwiftUI

/// The resolved provider + model for the current settings. Single source of
/// truth shared by the bar's model control and its popover.
struct ModelSelection {
    let providerID: String
    let providerName: String
    let providerIcon: String
    let modelLabel: String

    /// Provider-only shorthand used when horizontal space is tight.
    var shortLabel: String { providerName }

    @MainActor
    static func current(_ settings: SettingsStore) -> ModelSelection {
        let providerID = settings.preferOnDevice ? "ondevice" : settings.providerID
        let info = ProviderRegistry.info(for: providerID)
        let model = settings.model.isEmpty ? (info?.defaultModel ?? "") : settings.model
        return ModelSelection(
            providerID: providerID,
            providerName: info?.displayName ?? String(localized: "Provider"),
            providerIcon: info?.icon ?? "cpu",
            modelLabel: info?.modelLabel(model) ?? (model.isEmpty ? String(localized: "Model") : model)
        )
    }
}
