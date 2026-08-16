import Foundation

/// Syncs workspaces and key preferences across the user's Macs via iCloud
/// key-value storage. Degrades gracefully: if the user isn't signed in to iCloud
/// (or the capability isn't provisioned), every call is a silent no-op.
///
/// Secrets (API keys, tokens, deploy hooks) are NEVER synced — they stay in the
/// local Keychain on each machine.
///
/// Conflict handling: every payload carries the timestamp of the Mac that wrote
/// it. A pull only applies a payload that is newer than the last state this Mac
/// wrote or applied, so a stale remote payload can never clobber newer local
/// changes. Workspaces are merged by id (remote wins for matching ids, local-only
/// workspaces are kept) instead of a wholesale replacement, so two Macs editing
/// different sites do not erase each other's work.
@MainActor
final class CloudSyncService: ObservableObject {

    static let storageKey = "uk.mesut.WebsiteCommander.sync.v1"
    /// Local record of the newest payload this Mac has written or applied, so a
    /// pull can tell stale remote data from newer local state.
    private static let lastSyncKey = "uk.mesut.WebsiteCommander.sync.lastSyncAt"
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
        /// When the pushing Mac wrote this payload. Nil for payloads written by
        /// app versions before timestamp tracking existed.
        var updatedAt: Date?

        /// Tolerant decode: payloads from older versions lack `updatedAt`.
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            workspaces = (try? c.decode([SiteWorkspace].self, forKey: .workspaces)) ?? []
            activeWorkspaceID = try? c.decode(UUID?.self, forKey: .activeWorkspaceID)
            providerID = (try? c.decode(String.self, forKey: .providerID)) ?? "openai"
            model = (try? c.decode(String.self, forKey: .model)) ?? ""
            autoCommit = (try? c.decode(Bool.self, forKey: .autoCommit)) ?? false
            smartRouting = (try? c.decode(Bool.self, forKey: .smartRouting)) ?? false
            routingStrategy = (try? c.decode(RoutingStrategy.self, forKey: .routingStrategy)) ?? .code
            themeMode = (try? c.decode(ThemeMode.self, forKey: .themeMode)) ?? .system
            updatedAt = try? c.decode(Date?.self, forKey: .updatedAt) ?? nil
        }

        init(workspaces: [SiteWorkspace], activeWorkspaceID: UUID?, providerID: String,
             model: String, autoCommit: Bool, smartRouting: Bool,
             routingStrategy: RoutingStrategy, themeMode: ThemeMode,
             updatedAt: Date?) {
            self.workspaces = workspaces
            self.activeWorkspaceID = activeWorkspaceID
            self.providerID = providerID
            self.model = model
            self.autoCommit = autoCommit
            self.smartRouting = smartRouting
            self.routingStrategy = routingStrategy
            self.themeMode = themeMode
            self.updatedAt = updatedAt
        }
    }

    static var isSignedIn: Bool {
        FileManager.default.ubiquityIdentityToken != nil
    }

    /// The timestamp of the newest payload this Mac has written or applied.
    private var lastSyncAt: Date {
        get { UserDefaults.standard.object(forKey: Self.lastSyncKey) as? Date ?? .distantPast }
        set { UserDefaults.standard.set(newValue, forKey: Self.lastSyncKey) }
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
            themeMode: settings.themeMode,
            updatedAt: Date())
        guard let data = try? JSONEncoder().encode(payload) else { return }
        store.set(data, forKey: Self.storageKey)
        // Record the timestamp we just wrote so a later delivery of this same
        // payload is recognized as already applied.
        lastSyncAt = payload.updatedAt ?? .distantPast
        _ = store.synchronize()
    }

    /// Pull the latest settings from iCloud into `settings`.
    func pull(into settings: SettingsStore) {
        guard settings.cloudSyncEnabled, Self.isSignedIn else { return }
        guard let data = store.data(forKey: Self.storageKey),
              let payload = try? JSONDecoder().decode(Payload.self, from: data) else { return }

        // A payload written before timestamp tracking exists carries no age.
        // Apply it only when this Mac has no local workspaces yet (a fresh
        // install or a new Mac); never let it overwrite established local state.
        if let remoteTime = payload.updatedAt {
            guard remoteTime > lastSyncAt else {
                lastSyncNote = "Local changes are newer; kept the local copy."
                return
            }
        } else if !settings.workspaces.isEmpty {
            lastSyncNote = "Kept local changes over an older iCloud copy."
            return
        }

        isApplyingRemote = true
        defer { isApplyingRemote = false }
        let merged = Self.mergeWorkspaces(local: settings.workspaces, remote: payload.workspaces)
        settings.workspaces = merged
        // The remote active-site choice only survives when its workspace still
        // exists after the merge; otherwise keep the local selection.
        if let remoteActive = payload.activeWorkspaceID,
           merged.contains(where: { $0.id == remoteActive }) {
            settings.activeWorkspaceID = remoteActive
        }
        settings.providerID = payload.providerID
        settings.model = payload.model
        settings.autoCommit = payload.autoCommit
        settings.smartRouting = payload.smartRouting
        settings.routingStrategy = payload.routingStrategy
        settings.themeMode = payload.themeMode
        lastSyncAt = payload.updatedAt ?? Date()
        lastSyncNote = "Synced from iCloud."
    }

    /// Merge remote workspaces with local ones by id: remote entries win for
    /// matching ids (the remote payload is newer), and local-only workspaces are
    /// kept. Local order is preserved; remote-only workspaces are appended.
    static func mergeWorkspaces(local: [SiteWorkspace], remote: [SiteWorkspace]) -> [SiteWorkspace] {
        var merged = local
        for ws in remote {
            if let idx = merged.firstIndex(where: { $0.id == ws.id }) {
                merged[idx] = ws
            } else {
                merged.append(ws)
            }
        }
        return merged
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
