import Foundation

/// One GitHub account that the app can act as. The token itself lives in the
/// Keychain, keyed by `id`; this value is the non-secret descriptor stored with
/// the rest of settings. A workspace references one of these via
/// `githubCredentialID` so different sites can use different accounts.
///
/// `id == nil` (the implicit "default" account) maps to the legacy single-token
/// Keychain slot, so single-account setups keep working unchanged.
struct GitHubCredential: Identifiable, Codable, Equatable {
    var id: UUID
    var label: String        // user-chosen name, e.g. "Work", "Personal"
    var login: String?       // GitHub username, fetched via /user when available

    var displayName: String {
        if let login, !login.isEmpty { return login }
        if !label.isEmpty { return label }
        return "GitHub account"
    }
}
