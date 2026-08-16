import Foundation
import Security

/// A thin macOS Keychain wrapper for storing secrets (API keys, GitHub tokens).
/// Values never touch UserDefaults or disk — only the Keychain.
///
/// All secrets live in ONE generic-password item ("vault") so macOS presents at
/// most one authorization prompt per app signature — never one per credential.
/// Ad-hoc development builds get a new code signature every build; with the old
/// per-key layout that meant a prompt per saved key after every install.
enum Keychain {

    private static let service = "uk.mesut.WebsiteCommander"
    private static let vaultAccount = "credentials.vault"
    private static let lock = NSLock()
    private static var vault: [String: String]?
    private static var vaultAttempted = false

    /// Warm the in-memory cache. Called once at startup so the first secret
    /// read does not hit the Keychain mid-UI.
    static func prime() {
        lock.lock()
        if loadVaultLocked() == nil { migrateLegacyLocked() }
        lock.unlock()
    }

    // MARK: - Vault (single keychain item)

    private static func loadVaultLocked() -> [String: String]? {
        if let vault { return vault }
        if vaultAttempted { return nil }
        vaultAttempted = true

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: vaultAccount,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        if SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
           let data = item as? Data,
           let dict = try? JSONSerialization.jsonObject(with: data) as? [String: String] {
            vault = dict
            return dict
        }
        return nil
    }

    private static func saveVaultLocked(_ values: [String: String]) {
        guard let data = try? JSONSerialization.data(withJSONObject: values) else { return }
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: vaultAccount
        ]
        SecItemDelete(base as CFDictionary)
        var add = base
        add[kSecValueData as String] = data
        // Only readable while the Mac is unlocked; not exported in backups.
        add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlocked
        if SecItemAdd(add as CFDictionary, nil) == errSecSuccess {
            vault = values
        }
    }

    // MARK: - One-time migration from the legacy per-key layout

    /// Moves any legacy per-key items into the vault with a single bulk query,
    /// then deletes them so future code signatures never re-prompt for them.
    private static func migrateLegacyLocked() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnAttributes as String: true,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let items = result as? [[String: Any]], !items.isEmpty else { return }

        var merged: [String: String] = [:]
        var migratedKeys: [String] = []
        for item in items {
            guard let account = item[kSecAttrAccount as String] as? String,
                  account != vaultAccount,
                  let data = item[kSecValueData as String] as? Data,
                  let value = String(data: data, encoding: .utf8) else { continue }
            merged[account] = value
            migratedKeys.append(account)
        }
        guard !merged.isEmpty else { return }
        saveVaultLocked(merged)
        for key in migratedKeys {
            let deleteQuery: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: key
            ]
            SecItemDelete(deleteQuery as CFDictionary)
        }
    }

    // MARK: - Public API (key/value facade over the vault)

    /// Store (or overwrite) a secret for `key`.
    static func set(_ value: String, for key: String) {
        lock.lock()
        var values = loadVaultLocked() ?? [:]
        if values[key] == value {
            lock.unlock()
            return
        }
        values[key] = value
        saveVaultLocked(values)
        lock.unlock()
    }

    /// Read a secret for `key`, or nil if absent.
    static func get(_ key: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return loadVaultLocked()?[key]
    }

    /// Delete a secret for `key`.
    static func delete(_ key: String) {
        lock.lock()
        var values = loadVaultLocked() ?? [:]
        values.removeValue(forKey: key)
        saveVaultLocked(values)
        lock.unlock()
    }

    // MARK: - GitHub tokens (multi-account)

    /// The legacy single-account slot. `credentialID == nil` resolves here so
    /// existing single-account setups keep working without migration.
    private static let legacyGitHubTokenKey = "github.token"

    /// Keychain key for a GitHub token, per account.
    static func githubTokenKey(_ credentialID: UUID?) -> String {
        credentialID.map { "github.\($0.uuidString)" } ?? legacyGitHubTokenKey
    }

    static func getGitHubToken(_ credentialID: UUID? = nil) -> String? {
        get(githubTokenKey(credentialID))
    }

    static func setGitHubToken(_ token: String, for credentialID: UUID? = nil) {
        let key = githubTokenKey(credentialID)
        if token.isEmpty { delete(key) } else { set(token, for: key) }
    }

    static func deleteGitHubToken(_ credentialID: UUID? = nil) {
        delete(githubTokenKey(credentialID))
    }

    static func hasGitHubToken(_ credentialID: UUID? = nil) -> Bool {
        !(getGitHubToken(credentialID) ?? "").isEmpty
    }
}
