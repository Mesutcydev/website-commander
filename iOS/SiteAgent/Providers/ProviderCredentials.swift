import Foundation

struct ResolvedAuth {
    var token: String
    var isOAuth: Bool          // true → logged in; false → API key
}

extension OAuthConfig {
    static func builtin(for id: String) -> OAuthConfig? {
        switch id {
        case "anthropic": return .anthropic
        case "openai": return .openai
        default: return nil
        }
    }
}

/// Outcome of resolving a provider's auth. `needsReAuth` is distinct from `noCredential`
/// so callers can prompt "sign in again" instead of masking an OAuth failure as "no key".
enum AuthResolution {
    case resolved(ResolvedAuth)
    case needsReAuth      // OAuth was configured but the token is invalid/unrefreshable
    case noCredential     // neither OAuth nor a manual API key was ever configured
}

/// Resolves how to authenticate a provider call: prefer a logged-in OAuth token,
/// fall back to a stored API key. Providers call this instead of reading Keychain.
enum ProviderCredentials {
    /// Provider variants can share one account credential without duplicating
    /// secrets in Keychain (for example OpenRouter and OpenRouter Free).
    nonisolated static func keychainProviderID(for id: String) -> String {
        id == "openrouter-free" ? "openrouter" : id
    }

    @MainActor
    static func resolve(_ id: String) async -> ResolvedAuth? {
        switch await resolveDetailed(id) {
        case .resolved(let auth): return auth
        case .needsReAuth, .noCredential: return nil
        }
    }

    @MainActor
    static func resolveDetailed(_ id: String) async -> AuthResolution {
        let credentialID = keychainProviderID(for: id)
        // Capture OAuth-configured state before refreshing; a failed refresh clears the
        // access token, so checking afterwards would wrongly look like "never configured".
        let oauthConfigured = OAuthManager.shared.isSignedIn(credentialID)
        if let token = await OAuthManager.shared.validAccessToken(
            for: credentialID,
            config: .builtin(for: credentialID)
        ) {
            return .resolved(ResolvedAuth(token: token, isOAuth: true))
        }
        if oauthConfigured {
            return .needsReAuth
        }
        if let key = Keychain.get(Keychain.providerKey(credentialID))?
            .trimmingCharacters(in: .whitespacesAndNewlines), !key.isEmpty {
            return .resolved(ResolvedAuth(token: key, isOAuth: false))
        }
        return .noCredential
    }
}
