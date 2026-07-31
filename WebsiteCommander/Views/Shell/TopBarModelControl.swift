import SwiftUI

/// Which providers the user can actually pick right now.
///
/// Reads the store's published set rather than the Keychain: a Keychain lookup
/// from a view body runs on every layout pass and can block the main thread on
/// an access prompt.
enum ModelCatalog {
    @MainActor
    static func pairedProviders(_ settings: SettingsStore) -> [ProviderInfo] {
        ProviderRegistry.catalog.filter { provider in
            switch provider.id {
            case "ondevice":
                #if canImport(FoundationModels)
                if #available(macOS 26.0, *) {
                    return OnDeviceProvider.isAvailable
                }
                #endif
                return false
            case "custom":
                return !settings.customBaseURL.isEmpty
                    && settings.pairedProviderIDs.contains(provider.id)
            default:
                return settings.pairedProviderIDs.contains(provider.id)
            }
        }
    }

    /// Mirrors the previous picker's rules exactly, so switching behaviour is
    /// unchanged by the redesign.
    @MainActor
    static func select(provider: ProviderInfo, in settings: SettingsStore) {
        if provider.id == "ondevice" {
            settings.preferOnDevice = true
        } else {
            settings.preferOnDevice = false
            settings.providerID = provider.id
        }
        settings.smartRouting = false
        settings.model = ""
    }
}

/// A real provider mark: the brand path where the app already ships one, and
/// the provider's own SF Symbol otherwise. Nothing is invented here.
struct ProviderGlyph: View {
    let providerID: String
    let fallbackSymbol: String
    var size: CGFloat = TopBarMetrics.iconSize
    var tint: Color = Theme.Chrome.textSecondary

    var body: some View {
        Group {
            if let mark = BrandMarkID.from(providerID: providerID) {
                BrandMark(id: mark)
                    .fill(tint)
                    .frame(width: size * 0.88, height: size * 0.88)
            } else {
                Image(systemName: fallbackSymbol)
                    .font(.system(size: size * 0.8, weight: .medium))
                    .foregroundStyle(tint)
            }
        }
        .frame(width: size, height: size)
    }
}

// MARK: - Control

/// The model selector. Same selection behaviour as before, restated on the
/// shell's control and popover system.
struct TopBarModelControl: View {
    let metrics: TopBarMetrics
    let isOpen: Bool
    let onToggle: () -> Void

    @EnvironmentObject private var settings: SettingsStore
    @FocusState private var isFocused: Bool

    private var selection: ModelSelection { .current(settings) }
    private var isConfigured: Bool { ProviderRegistry.info(for: selection.providerID) != nil }

    private var fixedWidth: CGFloat {
        18 + TopBarMetrics.iconSize + 7 + TopBarMetrics.chevronSize + 7
    }

    var body: some View {
        Button(action: onToggle) {
            HStack(spacing: 7) {
                ProviderGlyph(providerID: selection.providerID,
                              fallbackSymbol: selection.providerIcon,
                              tint: Theme.violet)
                // The label stays charcoal: violet at 13pt on the violet surface
                // would not clear AA, so the accent lives in the glyph and the
                // surface instead.
                Text(selection.modelLabel)
                    .font(Theme.ui(13, .medium))
                    .foregroundStyle(isConfigured ? Theme.Chrome.textPrimary : Theme.Chrome.textMuted)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(minWidth: 0,
                           maxWidth: metrics.modelMaxWidth - fixedWidth,
                           alignment: .leading)
                    .contentTransition(.opacity)
                Image(systemName: "chevron.down")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Theme.violet.opacity(0.7))
                    .frame(width: TopBarMetrics.chevronSize,
                           height: TopBarMetrics.chevronSize)
            }
            .padding(.horizontal, 9)
            .frame(height: TopBarMetrics.controlHeight)
            .frame(minWidth: metrics.modelMinWidth, alignment: .leading)
        }
        // The model control is the app's AI surface, so it carries the violet
        // identity instead of being a second blue control in the bar.
        .buttonStyle(TopBarControlButtonStyle(
            radius: TopBarMetrics.controlRadius,
            emphasis: .tinted(.violet)
        ))
        .focused($isFocused)
        .help("Choose the provider and model the agent uses")
        .accessibilityLabel("\(String(localized: "Model")): \(selection.providerName), \(selection.modelLabel)")
        .accessibilityValue(isOpen ? "Expanded" : "Collapsed")
        .topBarTrigger(.model)
        .animation(Theme.Chrome.Timing.status, value: selection.modelLabel)
        .onChange(of: isOpen) { wasOpen, open in
            if wasOpen && !open { isFocused = true }
        }
    }
}

// MARK: - Popover

struct TopBarModelPopover: View {
    let maxHeight: CGFloat
    let onSelect: () -> Void

    @EnvironmentObject private var settings: SettingsStore

    private var activeProviderID: String {
        settings.preferOnDevice ? "ondevice" : settings.providerID
    }

    private var paired: [ProviderInfo] {
        ModelCatalog.pairedProviders(settings)
    }

    var body: some View {
        TopBarPopoverPanel {
            VStack(alignment: .leading, spacing: 2) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        TopBarPopoverSectionLabel(text: "Provider")
                        if paired.isEmpty {
                            TopBarPopoverEmptyState(
                                systemImage: "key",
                                message: "No providers paired yet"
                            )
                        } else {
                            ForEach(paired) { provider in
                                TopBarPopoverRow(
                                    title: provider.displayName,
                                    isSelected: provider.id == activeProviderID,
                                    leading: {
                                        ProviderGlyph(providerID: provider.id,
                                                      fallbackSymbol: provider.icon,
                                                      size: 18,
                                                      tint: provider.id == activeProviderID
                                                          ? Theme.violet
                                                          : Theme.Chrome.textSecondary)
                                    },
                                    action: {
                                        ModelCatalog.select(provider: provider, in: settings)
                                        onSelect()
                                    }
                                )
                            }
                        }

                        if let provider = ProviderRegistry.info(for: activeProviderID) {
                            TopBarPopoverSeparator()
                            TopBarPopoverSectionLabel(text: "Model")
                            TopBarPopoverRow(
                                title: "\(String(localized: "Default")) · \(provider.modelLabel(provider.defaultModel))",
                                isSelected: settings.model.isEmpty,
                                action: {
                                    settings.model = ""
                                    onSelect()
                                }
                            )
                            ForEach(provider.models, id: \.self) { model in
                                TopBarPopoverRow(
                                    title: provider.modelLabel(model),
                                    isSelected: settings.model == model,
                                    action: {
                                        settings.model = model
                                        onSelect()
                                    }
                                )
                            }
                        }
                    }
                }
                .frame(maxHeight: maxHeight)
                // A scroll view is greedy: without this it claims the whole
                // cap and leaves a dead band under a short list.
                .fixedSize(horizontal: false, vertical: true)
                .scrollBounceBehavior(.basedOnSize)
            }
        }
        .frame(width: TopBarPopoverKind.model.width)
    }
}
