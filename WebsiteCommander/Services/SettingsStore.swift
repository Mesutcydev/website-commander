import Foundation
import SwiftUI

/// Routing strategies for smart auto-routing (which model to prefer per task).
enum RoutingStrategy: String, Codable, CaseIterable, Identifiable {
    case budget = "Budget"
    case quality = "Quality"
    case code = "Code"

    var id: String { rawValue }

    var detail: String {
        switch self {
        case .budget:  return "Prefer the cheapest capable model."
        case .quality: return "Prefer the strongest reasoning model."
        case .code:    return "Prefer the best code-editing model."
        }
    }
}

/// Theme preference.
enum ThemeMode: String, Codable, CaseIterable, Identifiable {
    case system = "System"
    case light = "Light"
    case dark = "Dark"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .system: return "circle.lefthalf.filled"
        case .light:  return "sun.max.fill"
        case .dark:   return "moon.fill"
        }
    }

    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light:  return .light
        case .dark:   return .dark
        }
    }
}

/// The single source of truth for persisted app state: workspaces, the active
/// selection, provider/model choice, and behavior toggles. Workspaces and
/// preferences are saved as JSON in Application Support; secrets (API keys,
/// tokens) live in the Keychain and are referenced by provider id.
@MainActor
final class SettingsStore: ObservableObject {

    // MARK: Persisted state

    @Published var workspaces: [SiteWorkspace] = [] { didSet { save() } }
    @Published var activeWorkspaceID: UUID? { didSet { save() } }
    @Published var providerID: String = "openai" { didSet { save() } }
    @Published var model: String = "" { didSet { save() } }
    @Published var autoCommit: Bool = false { didSet { save() } }
    @Published var smartRouting: Bool = false { didSet { save() } }
    @Published var routingStrategy: RoutingStrategy = .code { didSet { save() } }
    @Published var themeMode: ThemeMode = .system { didSet { save() } }
    @Published var hasCompletedOnboarding: Bool = false { didSet { save() } }

    // Custom OpenAI-compatible provider configuration.
    @Published var customBaseURL: String = "" { didSet { save() } }
    @Published var customModel: String = "" { didSet { save() } }

    // iCloud sync of workspaces & preferences (secrets never sync).
    @Published var cloudSyncEnabled: Bool = false { didSet { save() } }

    // Local agent bridge (loopback TCP). Off by default; when on, other agents on
    // this Mac can drive the app via a token-file-authenticated socket.
    @Published var localBridgeEnabled: Bool = false { didSet { save() } }
    @Published var localBridgePort: Int = 0 { didSet { save() } }   // 0 = auto

    /// When on (and Apple Intelligence is available), the agent runs on-device
    /// instead of the configured cloud provider. Honest toggle: no effect on
    /// machines without Foundation Models.
    @Published var preferOnDevice: Bool = false { didSet { save() } }

    /// Update feed URL (https, or http on loopback for testing). Empty = the
    /// "Check for Updates" command is inert. No background polling ever.
    @Published var updateFeedURL: String = "" { didSet { save() } }

    /// Called after every persist; the app wires this to CloudSyncService.push.
    var onPersist: (() -> Void)?

    // MARK: Derived

    var activeWorkspace: SiteWorkspace? {
        guard let id = activeWorkspaceID else { return workspaces.first }
        return workspaces.first { $0.id == id } ?? workspaces.first
    }

    /// The model to use: explicit choice, else the provider's default.
    func resolvedModel(defaultFor providerDefault: String) -> String {
        model.isEmpty ? providerDefault : model
    }

    // MARK: Workspace CRUD

    func addWorkspace(_ workspace: SiteWorkspace) {
        workspaces.append(workspace)
        if activeWorkspaceID == nil { activeWorkspaceID = workspace.id }
    }

    func updateWorkspace(_ workspace: SiteWorkspace) {
        guard let idx = workspaces.firstIndex(where: { $0.id == workspace.id }) else { return }
        workspaces[idx] = workspace
    }

    func deleteWorkspace(_ workspace: SiteWorkspace) {
        workspaces.removeAll { $0.id == workspace.id }
        if activeWorkspaceID == workspace.id { activeWorkspaceID = workspaces.first?.id }
    }

    func setActive(_ workspace: SiteWorkspace) {
        activeWorkspaceID = workspace.id
    }

    // MARK: Secrets (Keychain-backed)

    /// Named GitHub accounts beyond the implicit default. The default account
    /// (`credentialID == nil`) is represented by the legacy token slot and is not
    /// stored here; the UI composes [default?] + githubAccounts.
    @Published var githubAccounts: [GitHubCredential] = [] { didSet { save() } }

    func apiKey(for providerID: String) -> String? {
        Keychain.get("apikey.\(providerID)")
    }

    func setAPIKey(_ key: String, for providerID: String) {
        if key.isEmpty {
            Keychain.delete("apikey.\(providerID)")
        } else {
            Keychain.set(key, for: "apikey.\(providerID)")
        }
        objectWillChange.send()
    }

    /// The default (legacy) GitHub token, i.e. `credentialID == nil`.
    var githubToken: String? { Keychain.getGitHubToken(nil) }

    func setGitHubToken(_ token: String) {
        Keychain.setGitHubToken(token, for: nil)
        objectWillChange.send()
    }

    /// Token for a specific account (nil = default).
    func token(forCredential id: UUID?) -> String? {
        Keychain.getGitHubToken(id)
    }

    /// The token to use for a workspace: its assigned account, else the default.
    func resolvedGitHubToken(for workspace: SiteWorkspace?) -> String? {
        if let id = workspace?.githubCredentialID, let token = token(forCredential: id), !token.isEmpty {
            return token
        }
        return githubToken
    }

    /// True when at least one GitHub token (default or any account) is present.
    var hasAnyGitHubToken: Bool {
        if !(githubToken ?? "").isEmpty { return true }
        return githubAccounts.contains { !(token(forCredential: $0.id) ?? "").isEmpty }
    }

    /// Add a named GitHub account, storing its token in the Keychain.
    @discardableResult
    func addGitHubAccount(label: String, token: String, login: String? = nil) -> GitHubCredential {
        let credential = GitHubCredential(id: UUID(), label: label, login: login)
        Keychain.setGitHubToken(token, for: credential.id)
        githubAccounts.append(credential)
        return credential
    }

    /// Remove a named account and detach any workspace that referenced it.
    func removeGitHubAccount(_ id: UUID) {
        Keychain.deleteGitHubToken(id)
        githubAccounts.removeAll { $0.id == id }
        for index in workspaces.indices where workspaces[index].githubCredentialID == id {
            workspaces[index].githubCredentialID = nil
        }
    }

    /// All accounts as options including the implicit default first.
    var accountOptions: [AccountOption] {
        var list: [AccountOption] = []
        if !(githubToken ?? "").isEmpty { list.append(AccountOption(id: nil, name: "Default account")) }
        list.append(contentsOf: githubAccounts.map { AccountOption(id: $0.id, name: $0.displayName) })
        return list
    }

    // MARK: Persistence

    private struct Snapshot: Codable {
        var workspaces: [SiteWorkspace]
        var activeWorkspaceID: UUID?
        var providerID: String
        var model: String
        var autoCommit: Bool
        var smartRouting: Bool
        var routingStrategy: RoutingStrategy
        var themeMode: ThemeMode
        var hasCompletedOnboarding: Bool
        var customBaseURL: String
        var customModel: String
        var cloudSyncEnabled: Bool
        var githubAccounts: [GitHubCredential]
        var localBridgeEnabled: Bool
        var localBridgePort: Int
        var preferOnDevice: Bool
        var updateFeedURL: String

        // Backward-compatible decode: older settings files predate some fields
        // (notably githubAccounts). Missing keys fall back to defaults instead of
        // failing the whole load (which would wipe the user's configuration).
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
            hasCompletedOnboarding = (try? c.decode(Bool.self, forKey: .hasCompletedOnboarding)) ?? false
            customBaseURL = (try? c.decode(String.self, forKey: .customBaseURL)) ?? ""
            customModel = (try? c.decode(String.self, forKey: .customModel)) ?? ""
            cloudSyncEnabled = (try? c.decode(Bool.self, forKey: .cloudSyncEnabled)) ?? false
            githubAccounts = (try? c.decode([GitHubCredential].self, forKey: .githubAccounts)) ?? []
            localBridgeEnabled = (try? c.decode(Bool.self, forKey: .localBridgeEnabled)) ?? false
            localBridgePort = (try? c.decode(Int.self, forKey: .localBridgePort)) ?? 0
            preferOnDevice = (try? c.decode(Bool.self, forKey: .preferOnDevice)) ?? false
            updateFeedURL = (try? c.decode(String.self, forKey: .updateFeedURL)) ?? ""
        }

        init(workspaces: [SiteWorkspace], activeWorkspaceID: UUID?, providerID: String, model: String,
             autoCommit: Bool, smartRouting: Bool, routingStrategy: RoutingStrategy, themeMode: ThemeMode,
             hasCompletedOnboarding: Bool, customBaseURL: String, customModel: String,
             cloudSyncEnabled: Bool, githubAccounts: [GitHubCredential],
             localBridgeEnabled: Bool, localBridgePort: Int, preferOnDevice: Bool,
             updateFeedURL: String) {
            self.workspaces = workspaces
            self.activeWorkspaceID = activeWorkspaceID
            self.providerID = providerID
            self.model = model
            self.autoCommit = autoCommit
            self.smartRouting = smartRouting
            self.routingStrategy = routingStrategy
            self.themeMode = themeMode
            self.hasCompletedOnboarding = hasCompletedOnboarding
            self.customBaseURL = customBaseURL
            self.customModel = customModel
            self.cloudSyncEnabled = cloudSyncEnabled
            self.githubAccounts = githubAccounts
            self.localBridgeEnabled = localBridgeEnabled
            self.localBridgePort = localBridgePort
            self.preferOnDevice = preferOnDevice
            self.updateFeedURL = updateFeedURL
        }
    }

    private static func defaultFileURL() -> URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("WebsiteCommander", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("settings.json")
    }

    /// Where settings are persisted. Overridable so unit tests can redirect to a
    /// temp file and never touch the user's real configuration.
    static var fileURL: URL = SettingsStore.defaultFileURL()

    init() {
        load()
    }

    private func load() {
        guard let data = try? Data(contentsOf: Self.fileURL),
              let snap = try? JSONDecoder().decode(Snapshot.self, from: data) else { return }
        workspaces = snap.workspaces
        activeWorkspaceID = snap.activeWorkspaceID
        providerID = snap.providerID
        model = snap.model
        autoCommit = snap.autoCommit
        smartRouting = snap.smartRouting
        routingStrategy = snap.routingStrategy
        themeMode = snap.themeMode
        hasCompletedOnboarding = snap.hasCompletedOnboarding
        customBaseURL = snap.customBaseURL
        customModel = snap.customModel
        cloudSyncEnabled = snap.cloudSyncEnabled
        githubAccounts = snap.githubAccounts
        localBridgeEnabled = snap.localBridgeEnabled
        localBridgePort = snap.localBridgePort
        preferOnDevice = snap.preferOnDevice
        updateFeedURL = snap.updateFeedURL
    }

    private func save() {
        let snap = Snapshot(
            workspaces: workspaces,
            activeWorkspaceID: activeWorkspaceID,
            providerID: providerID,
            model: model,
            autoCommit: autoCommit,
            smartRouting: smartRouting,
            routingStrategy: routingStrategy,
            themeMode: themeMode,
            hasCompletedOnboarding: hasCompletedOnboarding,
            customBaseURL: customBaseURL,
            customModel: customModel,
            cloudSyncEnabled: cloudSyncEnabled,
            githubAccounts: githubAccounts,
            localBridgeEnabled: localBridgeEnabled,
            localBridgePort: localBridgePort,
            preferOnDevice: preferOnDevice,
            updateFeedURL: updateFeedURL
        )
        guard let data = try? JSONEncoder().encode(snap) else { return }
        try? data.write(to: Self.fileURL, options: .atomic)
        onPersist?()
    }
}

/// A selectable GitHub account row (id == nil is the implicit default account).
struct AccountOption: Identifiable, Hashable {
    let id: UUID?
    let name: String
}
