import Foundation
import Security

/// A thin macOS Keychain wrapper for storing secrets (API keys, GitHub tokens).
/// Values never touch UserDefaults or disk — only the Keychain.
enum Keychain {

    private static let service = "uk.mesut.WebsiteCommander"
    private static let lock = NSLock()
    private static var cache: [String: String] = [:]
    private static var cachePrimed = false

    static func prime() {
        lock.lock()
        if cachePrimed {
            lock.unlock()
            return
        }

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnAttributes as String: true,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecSuccess, let items = result as? [[String: Any]] {
            for item in items {
                guard let account = item[kSecAttrAccount as String] as? String,
                      let data = item[kSecValueData as String] as? Data,
                      let value = String(data: data, encoding: .utf8) else { continue }
                cache[account] = value
            }
            cachePrimed = true
        } else if status == errSecItemNotFound {
            cachePrimed = true
        }
        lock.unlock()
    }

    /// Store (or overwrite) a secret for `key`.
    static func set(_ value: String, for key: String) {
        guard let data = value.data(using: .utf8) else { return }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key
        ]
        // Delete any existing item, then add fresh (simplest upsert).
        SecItemDelete(query as CFDictionary)
        var add = query
        add[kSecValueData as String] = data
        // Only readable while the Mac is unlocked; not exported in backups.
        add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlocked
        let status = SecItemAdd(add as CFDictionary, nil)
        if status == errSecSuccess {
            lock.lock()
            cache[key] = value
            cachePrimed = true
            lock.unlock()
        }
    }

    /// Read a secret for `key`, or nil if absent.
    static func get(_ key: String) -> String? {
        prime()
        lock.lock()
        let cached = cache[key]
        lock.unlock()
        if let cached { return cached }

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let value = String(data: data, encoding: .utf8) else { return nil }
        lock.lock()
        cache[key] = value
        lock.unlock()
        return value
    }

    /// Delete a secret for `key`.
    static func delete(_ key: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key
        ]
        SecItemDelete(query as CFDictionary)
        lock.lock()
        cache.removeValue(forKey: key)
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
