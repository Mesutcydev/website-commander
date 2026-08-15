import Foundation
import AuthenticationServices
import CryptoKit

/// Configuration for a provider's OAuth 2.0 (PKCE) login.
/// Endpoints/clientID are editable in Settings because the public defaults may
/// need adjusting per provider/account.
struct OAuthConfig {
    var providerID: String
    var authorizeURL: String
    var tokenURL: String
    var clientID: String
    var scopes: String
    var redirectURI: String        // custom-scheme callback ASWebAuthenticationSession can intercept

    static let anthropic = OAuthConfig(
        providerID: "anthropic",
        authorizeURL: "https://claude.ai/oauth/authorize",
        tokenURL: "https://console.anthropic.com/v1/oauth/token",
        clientID: "9d1c250a-e61b-44d9-88ed-5944d1962f5e",
        scopes: "org:create_api_key user:profile user:inference",
        redirectURI: "siteagent://oauth/anthropic")

    static let openai = OAuthConfig(
        providerID: "openai",
        authorizeURL: "https://auth.openai.com/oauth/authorize",
        tokenURL: "https://auth.openai.com/oauth/token",
        clientID: "app_EMoamEEZ73f0CkXaXp7hrann",
        scopes: "openid profile email offline_access",
        redirectURI: "siteagent://oauth/openai")
}

enum OAuthError: LocalizedError {
    case cancelled, badCallback, tokenExchange(String)
    var errorDescription: String? {
        switch self {
        case .cancelled: return "Sign-in was cancelled."
        case .badCallback: return "Didn't receive a valid authorization code."
        case .tokenExchange(let m): return "Token exchange failed: \(m)"
        }
    }
}

@MainActor
final class OAuthManager: NSObject, ObservableObject {
    static let shared = OAuthManager()

    /// True if we hold any (possibly-expired-but-refreshable) token for the provider.
    func isSignedIn(_ id: String) -> Bool {
        Keychain.get(Keychain.oauthAccess(id)) != nil
    }

    func signOut(_ id: String) {
        Keychain.set(nil, for: Keychain.oauthAccess(id))
        Keychain.set(nil, for: Keychain.oauthRefresh(id))
        Keychain.set(nil, for: Keychain.oauthExpiry(id))
    }

    // MARK: - Login

    func signIn(_ config: OAuthConfig) async throws {
        let verifier = Self.randomURLSafe(64)
        let challenge = Self.codeChallenge(for: verifier)
        let state = Self.randomURLSafe(16)

        guard var comps = URLComponents(string: config.authorizeURL) else {
            throw OAuthError.tokenExchange("The sign-in provider returned an invalid authorization URL.")
        }
        comps.queryItems = [
            .init(name: "response_type", value: "code"),
            .init(name: "client_id", value: config.clientID),
            .init(name: "redirect_uri", value: config.redirectURI),
            .init(name: "scope", value: config.scopes),
            .init(name: "code_challenge", value: challenge),
            .init(name: "code_challenge_method", value: "S256"),
            .init(name: "state", value: state),
        ]
        guard let authorizeURL = comps.url,
              let scheme = URL(string: config.redirectURI)?.scheme,
              !scheme.isEmpty else {
            throw OAuthError.tokenExchange("The sign-in provider has an invalid redirect configuration.")
        }

        let callback: URL = try await withCheckedThrowingContinuation { cont in
            let session = ASWebAuthenticationSession(url: authorizeURL, callbackURLScheme: scheme) { url, error in
                if let url { cont.resume(returning: url) }
                else if (error as? ASWebAuthenticationSessionError)?.code == .canceledLogin {
                    cont.resume(throwing: OAuthError.cancelled)
                } else {
                    cont.resume(throwing: error ?? OAuthError.badCallback)
                }
            }
            session.presentationContextProvider = self
            // Ephemeral session avoids shared Safari cookies selecting the wrong
            // IdP account on shared devices. Users can still complete OAuth normally.
            session.prefersEphemeralWebBrowserSession = true
            session.start()
        }

        let items = URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems ?? []
        guard let code = items.first(where: { $0.name == "code" })?.value,
              let returnedState = items.first(where: { $0.name == "state" })?.value,
              returnedState == state else {
            throw OAuthError.badCallback
        }
        try await exchangeCode(code, verifier: verifier, config: config)
    }

    private func exchangeCode(_ code: String, verifier: String, config: OAuthConfig) async throws {
        guard let tokenURL = URL(string: config.tokenURL),
              tokenURL.scheme?.lowercased() == "https",
              tokenURL.host != nil else {
            throw OAuthError.tokenExchange("The sign-in provider has an invalid token URL.")
        }
        var req = URLRequest(url: tokenURL)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = [
            "grant_type": "authorization_code",
            "code": code,
            "redirect_uri": config.redirectURI,
            "client_id": config.clientID,
            "code_verifier": verifier,
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        try await performTokenRequest(req, providerID: config.providerID)
    }

    // MARK: - Access token retrieval (with refresh)

    /// Returns a currently-valid access token, refreshing if needed. Nil if not signed in
    /// or if the refresh failed (revoked token / network) — in the latter case the stale
    /// access/refresh/expiry entries are cleared so callers can prompt re-auth rather than
    /// sending an expired token and getting a confusing 401.
    func validAccessToken(for id: String, config: OAuthConfig?) async -> String? {
        guard let access = Keychain.get(Keychain.oauthAccess(id)) else { return nil }
        guard let expiryStr = Keychain.get(Keychain.oauthExpiry(id)),
              let epoch = Double(expiryStr) else {
            return access   // no expiry recorded → use as-is
        }
        if Date().timeIntervalSince1970 < epoch - 60 { return access }
        guard let config, let refreshed = try? await refresh(config: config) else {
            signOut(id)
            return nil
        }
        return refreshed
    }

    private func refresh(config: OAuthConfig) async throws -> String? {
        guard let refreshToken = Keychain.get(Keychain.oauthRefresh(config.providerID)) else { return nil }
        guard let tokenURL = URL(string: config.tokenURL),
              tokenURL.scheme?.lowercased() == "https",
              tokenURL.host != nil else {
            throw OAuthError.tokenExchange("The sign-in provider has an invalid token URL.")
        }
        var req = URLRequest(url: tokenURL)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = [
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
            "client_id": config.clientID,
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        try await performTokenRequest(req, providerID: config.providerID)
        return Keychain.get(Keychain.oauthAccess(config.providerID))
    }

    private func performTokenRequest(_ req: URLRequest, providerID: String) async throws {
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let access = obj["access_token"] as? String else {
            throw OAuthError.tokenExchange(String((String(data: data, encoding: .utf8) ?? "").prefix(300)))
        }
        Keychain.set(access, for: Keychain.oauthAccess(providerID))
        if let refresh = obj["refresh_token"] as? String {
            Keychain.set(refresh, for: Keychain.oauthRefresh(providerID))
        }
        if let expiresIn = obj["expires_in"] as? Double {
            Keychain.set(String(Date().timeIntervalSince1970 + expiresIn), for: Keychain.oauthExpiry(providerID))
        } else {
            // Refresh response omitted expires_in → drop any stale expiry so we don't
            // keep treating the token as expired against a cached old timestamp.
            Keychain.set(nil, for: Keychain.oauthExpiry(providerID))
        }
    }

    // MARK: - PKCE helpers

    private static func randomURLSafe(_ bytes: Int) -> String {
        var data = Data(count: bytes)
        _ = data.withUnsafeMutableBytes { buffer in
            guard let baseAddress = buffer.baseAddress else { return errSecParam }
            return SecRandomCopyBytes(kSecRandomDefault, bytes, baseAddress)
        }
        return base64URL(data)
    }
    private static func codeChallenge(for verifier: String) -> String {
        base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
    }
    private static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

extension OAuthManager: ASWebAuthenticationPresentationContextProviding {
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        return scenes.first?.keyWindow ?? ASPresentationAnchor()
    }
}
