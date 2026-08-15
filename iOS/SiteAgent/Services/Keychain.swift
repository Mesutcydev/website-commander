import Foundation
import Security
import OSLog

/// Stores secrets (API keys, GitHub token) in Keychain.
/// Items are written as synchronizable so they can follow the user through
/// iCloud Keychain. Nothing sensitive is written to UserDefaults or disk.
enum Keychain {
    private static let service = "uk.mesut.SiteAgent.secrets"
    private static let log = Logger(subsystem: "uk.mesut.SiteAgent", category: "Keychain")

    private enum SyncScope {
        case synchronizable
        case legacyLocal
    }

    /// What a SecureField / settings commit should do to Keychain.
    /// Blank text **preserves** the existing item — empty SecureFields must never
    /// wipe secrets (e.g. after a TestFlight update when Settings reloads).
    /// Pass `nil` only for intentional clears (sign-out, disconnect).
    enum CommitAction: Equatable {
        case clear
        case preserve
        case store(String)
    }

    static func commitAction(for value: String?) -> CommitAction {
        guard let value else { return .clear }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return .preserve }
        return .store(trimmed)
    }

    /// Result of a Keychain write so callers can surface failures instead of
    /// silently believing a secret was persisted.
    /// - `nil`: delete the item (explicit clear).
    /// - blank / whitespace: no-op (keep whatever is already stored).
    /// - non-empty: replace with the trimmed value.
    @discardableResult
    static func set(_ value: String?, for key: String) -> Bool {
        switch commitAction(for: value) {
        case .preserve:
            return true
        case .clear:
            return delete(key)
        case .store(let trimmed):
            guard let data = trimmed.data(using: .utf8) else { return false }

            let syncStatus = replace(data, for: key, scope: .synchronizable)
            if syncStatus == errSecSuccess {
                _ = deleteItems(for: key, scope: .legacyLocal)
                return true
            }

            log.error("iCloud Keychain write failed for account \(key, privacy: .public): \(syncStatus)")

            let localStatus = replace(data, for: key, scope: .legacyLocal)
            if localStatus == errSecSuccess {
                return true
            }

            log.error("Local Keychain fallback write failed for account \(key, privacy: .public): \(localStatus)")
            return false
        }
    }

    @discardableResult
    private static func delete(_ key: String) -> Bool {
        let syncStatus = deleteItems(for: key, scope: .synchronizable)
        let localStatus = deleteItems(for: key, scope: .legacyLocal)
        let okStatuses: Set<OSStatus> = [errSecSuccess, errSecItemNotFound]
        if okStatuses.contains(syncStatus) && okStatuses.contains(localStatus) {
            return true
        }
        log.error("Keychain delete failed for account \(key, privacy: .public): sync=\(syncStatus), local=\(localStatus)")
        return false
    }

    private static func baseQuery(for key: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
    }

    private static func query(for key: String, scope: SyncScope) -> [String: Any] {
        var query = baseQuery(for: key)
        if scope == .synchronizable {
            query[kSecAttrSynchronizable as String] = true
        }
        return query
    }

    private static func replace(_ data: Data, for key: String, scope: SyncScope) -> OSStatus {
        let deleteStatus = deleteItems(for: key, scope: scope)
        guard deleteStatus == errSecSuccess || deleteStatus == errSecItemNotFound else {
            return deleteStatus
        }

        var add = query(for: key, scope: scope)
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = scope == .synchronizable
            ? kSecAttrAccessibleAfterFirstUnlock
            : kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        return SecItemAdd(add as CFDictionary, nil)
    }

    @discardableResult
    private static func deleteItems(for key: String, scope: SyncScope) -> OSStatus {
        SecItemDelete(query(for: key, scope: scope) as CFDictionary)
    }

    private static func copyString(for key: String, scope: SyncScope) -> String? {
        var query = query(for: key, scope: scope)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess,
              let data = result as? Data,
              let string = String(data: data, encoding: .utf8) else {
            if status != errSecItemNotFound {
                log.debug("Keychain read missed for account \(key, privacy: .public), scope \(String(describing: scope), privacy: .public): \(status)")
            }
            return nil
        }
        return string
    }

    static func get(_ key: String) -> String? {
        if let synced = copyString(for: key, scope: .synchronizable) {
            _ = deleteItems(for: key, scope: .legacyLocal)
            return synced
        }

        guard let legacy = copyString(for: key, scope: .legacyLocal) else { return nil }
        _ = set(legacy, for: key)
        return legacy
    }

    // Well-known keys.
    static let githubToken = "github_token"
    /// How the current GitHub token was obtained: "oauth" (device flow — granted
    /// `repo` write scope, so provably writable) or "manual" (pasted; unverified).
    /// Lets the UI claim "connected" only when write access is actually assured.
    static let githubTokenSource = "github_token_source"
    static func githubToken(credentialID: UUID?) -> String {
        credentialID.map { "github_token_\($0.uuidString)" } ?? githubToken
    }
    static func githubTokenSource(credentialID: UUID?) -> String {
        credentialID.map { "github_token_source_\($0.uuidString)" } ?? githubTokenSource
    }
    static func hasGitHubToken(credentialID: UUID?) -> Bool {
        !(get(githubToken(credentialID: credentialID)) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
    static func providerKey(_ providerID: String) -> String { "llm_key_\(providerID)" }
    static func deploymentToken(_ providerID: String, workspaceID: UUID) -> String {
        "deploy_\(providerID)_token_\(workspaceID.uuidString)"
    }
    static func deployHookURL(workspaceID: UUID) -> String {
        "deploy_hook_url_\(workspaceID.uuidString)"
    }
    /// Bearer token for a self-hosted MCP server, keyed by its configuration id.
    static func mcpToken(serverID: UUID) -> String {
        "mcp_token_\(serverID.uuidString)"
    }

    /// Removes all deployment secrets orphaned by a deleted/renamed workspace:
    /// every `deploy_*_token_<id>` and `deploy_hook_url_<id>` entry. Not wired into
    /// deleteWorkspace here (owned elsewhere); intended to be called from there.
    static func clearWorkspace(id: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrSynchronizable as String: kSecAttrSynchronizableAny,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let items = result as? [[String: Any]] else { return }
        let suffix = "_\(id)"
        for item in items {
            guard let account = item[kSecAttrAccount as String] as? String,
                  account.hasPrefix("deploy_"), account.hasSuffix(suffix) else { continue }
            delete(account)
        }
    }

    // OAuth tokens (per provider).
    static func oauthAccess(_ id: String) -> String { "oauth_access_\(id)" }
    static func oauthRefresh(_ id: String) -> String { "oauth_refresh_\(id)" }
    static func oauthExpiry(_ id: String) -> String { "oauth_expiry_\(id)" }

    // GitHub Copilot: long-lived GitHub device-flow token + short-lived API token cache.
    static let copilotGitHub = "copilot_gh_token"
    static let copilotAPIToken = "copilot_api_token"
    static let copilotAPIExpiry = "copilot_api_expiry"
}
