import Foundation
import UIKit

/// GitHub Copilot authentication.
///
/// Copilot isn't an API-key provider: you sign in with GitHub's OAuth **device
/// flow** (no redirect URI needed — the user enters a code on github.com), which
/// yields a long-lived GitHub token. That token is then exchanged for a
/// short-lived Copilot API bearer token (cached until it expires). Requires an
/// active GitHub Copilot subscription on the account.
@MainActor
final class CopilotAuth {
    static let shared = CopilotAuth()
    private init() {}

    /// GitHub's published Copilot OAuth client ID (public; device flow).
    /// NOTE: This is GitHub's VS Code / Copilot client ID. Third-party use may
    /// conflict with GitHub ToS or break if GitHub restricts the client. Prefer
    /// a dedicated OAuth app if/when GitHub exposes a supported third-party path.
    private let clientID = "Iv1.b507a08c87ecfe98"
    /// Editor-identity headers expected by Copilot's endpoints (VS Code shape).
    /// Same policy caveat as `clientID` above.
    nonisolated static let editorVersion = "vscode/1.95.0"
    nonisolated static let pluginVersion = "copilot-chat/0.22.0"

    struct DeviceCode {
        var deviceCode: String
        var userCode: String
        var verificationURI: String
        var interval: Int
        var expiresIn: Int
    }

    var isSignedIn: Bool { Keychain.get(Keychain.copilotGitHub) != nil }

    func signOut() {
        Keychain.set(nil, for: Keychain.copilotGitHub)
        Keychain.set(nil, for: Keychain.copilotAPIToken)
        Keychain.set(nil, for: Keychain.copilotAPIExpiry)
    }

    // MARK: - Device flow

    /// Step 1: ask GitHub for a device + user code to show the user.
    func requestDeviceCode() async throws -> DeviceCode {
        var req = URLRequest(url: SiteAgentURL.constant("https://github.com/login/device/code"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: ["client_id": clientID, "scope": "read:user"])

        let (data, _) = try await URLSession.shared.data(for: req)
        guard let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let device = o["device_code"] as? String,
              let user = o["user_code"] as? String,
              let uri = o["verification_uri"] as? String else {
            throw OAuthError.tokenExchange("Couldn't start GitHub sign-in.")
        }
        return DeviceCode(deviceCode: device, userCode: user, verificationURI: uri,
                          interval: (o["interval"] as? Int) ?? 5,
                          expiresIn: (o["expires_in"] as? Int) ?? 900)
    }

    /// Step 2: poll until the user authorizes on github.com, then store the token.
    func pollForToken(_ device: DeviceCode) async throws {
        let deadline = Date().addingTimeInterval(Double(device.expiresIn))
        var interval = max(device.interval, 1)

        // Request a background task so iOS keeps the app executing while user is in Safari
        var bgTask: UIBackgroundTaskIdentifier = .invalid
        bgTask = UIApplication.shared.beginBackgroundTask(withName: "CopilotDeviceFlowPoll") {
            UIApplication.shared.endBackgroundTask(bgTask)
            bgTask = .invalid
        }
        
        defer {
            if bgTask != .invalid {
                UIApplication.shared.endBackgroundTask(bgTask)
            }
        }

        while Date() < deadline {
            try await Task.sleep(nanoseconds: UInt64(interval) * 1_000_000_000)

            var req = URLRequest(url: SiteAgentURL.constant("https://github.com/login/oauth/access_token"))
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Accept")
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONSerialization.data(withJSONObject: [
                "client_id": clientID,
                "device_code": device.deviceCode,
                "grant_type": "urn:ietf:params:oauth:grant-type:device_code",
            ])

            do {
                let (data, _) = try await URLSession.shared.data(for: req)
                let o = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]

                if let token = o["access_token"] as? String {
                    Keychain.set(token, for: Keychain.copilotGitHub)
                    return
                }
                switch o["error"] as? String {
                case "authorization_pending":
                    continue
                case "slow_down":
                    interval += 5
                case .some(let err):
                    throw OAuthError.tokenExchange(err)
                case .none:
                    continue
                }
            } catch {
                if Task.isCancelled {
                    throw error
                }
                if let oauthErr = error as? OAuthError {
                    throw oauthErr
                }
                // Ignore transient network errors (e.g. background suspension connection lost) and retry.
                #if DEBUG
                print("Temporary network error during Copilot auth polling: \(error.localizedDescription)")
                #endif
            }
        }
        throw OAuthError.tokenExchange("Timed out waiting for authorization.")
    }

    // MARK: - Copilot API bearer token (short-lived, cached)

    /// Returns a valid Copilot API bearer token, exchanging/refreshing as needed.
    func bearerToken() async throws -> String {
        if let token = Keychain.get(Keychain.copilotAPIToken),
           let expStr = Keychain.get(Keychain.copilotAPIExpiry), let exp = Double(expStr),
           Date().timeIntervalSince1970 < exp - 60 {
            return token
        }
        guard let gh = Keychain.get(Keychain.copilotGitHub) else {
            throw LLMError.noKey("GitHub Copilot")
        }

        var req = URLRequest(url: SiteAgentURL.constant("https://api.github.com/copilot_internal/v2/token"))
        req.setValue("token \(gh)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue(Self.editorVersion, forHTTPHeaderField: "Editor-Version")
        req.setValue("WebsiteCommander", forHTTPHeaderField: "User-Agent")

        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let token = o["token"] as? String else {
            let code = (resp as? HTTPURLResponse)?.statusCode ?? -1
            throw LLMError.http(code, "Copilot token exchange failed — is Copilot active on this GitHub account?")
        }
        Keychain.set(token, for: Keychain.copilotAPIToken)
        let exp = (o["expires_at"] as? Double) ?? (Date().timeIntervalSince1970 + 1500)
        Keychain.set(String(exp), for: Keychain.copilotAPIExpiry)
        return token
    }
}
