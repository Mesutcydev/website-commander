import Foundation

/// Syncs workspaces and key preferences across the user's Macs via iCloud
/// key-value storage. Degrades gracefully: if the user isn't signed in to iCloud
/// (or the capability isn't provisioned), every call is a silent no-op.
///
/// Secrets (API keys, tokens, deploy hooks) are NEVER synced — they stay in the
/// local Keychain on each machine.
@MainActor
final class CloudSyncService: ObservableObject {

    static let storageKey = "uk.mesut.WebsiteCommander.sync.v1"
    private let store = NSUbiquitousKeyValueStore.default

    /// True while a remote payload is being applied, to suppress the echo push
    /// that the resulting `save()` calls would otherwise trigger.
    private var isApplyingRemote = false

    @Published var lastSyncNote: String?

    /// The payload that travels through iCloud. Deliberately excludes secrets.
    private struct Payload: Codable {
        var workspaces: [SiteWorkspace]
        var activeWorkspaceID: UUID?
        var providerID: String
        var model: String
        var autoCommit: Bool
        var smartRouting: Bool
        var routingStrategy: RoutingStrategy
        var themeMode: ThemeMode
    }

    static var isSignedIn: Bool {
        FileManager.default.ubiquityIdentityToken != nil
    }

    /// Push the current settings to iCloud.
    func push(_ settings: SettingsStore) {
        guard !isApplyingRemote, settings.cloudSyncEnabled, Self.isSignedIn else { return }
        let payload = Payload(
            workspaces: settings.workspaces,
            activeWorkspaceID: settings.activeWorkspaceID,
            providerID: settings.providerID,
            model: settings.model,
            autoCommit: settings.autoCommit,
            smartRouting: settings.smartRouting,
            routingStrategy: settings.routingStrategy,
            themeMode: settings.themeMode)
        guard let data = try? JSONEncoder().encode(payload) else { return }
        store.set(data, forKey: Self.storageKey)
        _ = store.synchronize()
    }

    /// Pull the latest settings from iCloud into `settings`.
    func pull(into settings: SettingsStore) {
        guard settings.cloudSyncEnabled, Self.isSignedIn else { return }
        guard let data = store.data(forKey: Self.storageKey),
              let payload = try? JSONDecoder().decode(Payload.self, from: data) else { return }
        isApplyingRemote = true
        defer { isApplyingRemote = false }
        settings.workspaces = payload.workspaces
        settings.activeWorkspaceID = payload.activeWorkspaceID
        settings.providerID = payload.providerID
        settings.model = payload.model
        settings.autoCommit = payload.autoCommit
        settings.smartRouting = payload.smartRouting
        settings.routingStrategy = payload.routingStrategy
        settings.themeMode = payload.themeMode
        lastSyncNote = "Synced from iCloud."
    }

    /// Begin observing external iCloud changes and pull when they arrive.
    func startObserving(settings: SettingsStore) {
        NotificationCenter.default.addObserver(
            forName: NSUbiquitousKeyValueStore.didChangeExternallyNotification,
            object: store, queue: .main) { [weak self] _ in
                Task { @MainActor in
                    self?.pull(into: settings)
                }
            }
        _ = store.synchronize()
    }
}
