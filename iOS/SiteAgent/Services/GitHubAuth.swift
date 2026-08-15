import Foundation
import UIKit

/// "Sign in with GitHub" for *pushing* — GitHub's OAuth **device flow**, which
/// yields a token carrying the `repo` (read+write) scope.
///
/// This exists because hand-built Personal Access Tokens are the #1 setup
/// failure: users create a token without write permission (or forget to grant
/// the repo) and only discover it when a commit 403s. The device flow has no
/// permission checkboxes to misconfigure — GitHub grants exactly the scope we
/// request, and `repo` is all-or-nothing, so the token can't come back
/// read-only. The resulting token is written to the SAME keychain slot a manual
/// token uses (`Keychain.githubToken`), so `GitHubClient` and everything else
/// stay unchanged — they neither know nor care how the token was obtained.
///
/// Mirrors `CopilotAuth`'s proven device-flow implementation (no client secret,
/// no redirect URI, no backend).
@MainActor
final class GitHubAuth {
    static let shared = GitHubAuth()
    private init() {}

    /// SiteAgent's GitHub OAuth App **client ID** — registered ONCE by the
    /// developer and shipped in the binary. Every downloaded user authorizes this
    /// same app against their own GitHub account; users never register anything.
    /// The client ID is public and safe to ship — the device flow needs no client
    /// secret. (To register: create an OAuth App at
    /// https://github.com/settings/applications/new, enable "Device Flow", copy
    /// its Client ID.)
    ///
    /// Split by build configuration so debug/local sign-ins can use a separate
    /// OAuth App and stay out of the production app's user list. App Store and
    /// TestFlight builds are Release → they use the production ID below.
    #if DEBUG
    // Development builds. Register a SEPARATE OAuth App for debugging and paste
    // its Client ID here, replacing the placeholder. Until a real dev Client ID
    // is pasted, `isConfigured` returns false so debug builds fail gracefully
    // instead of silently authorizing against the production OAuth App (which
    // would pollute the production app's authorized-apps list).
    static let clientID = "DEV_GITHUB_OAUTH_CLIENT_ID"
    #else
    // Production (App Store / TestFlight).
    static let clientID = "Ov23likbAwZPky4GT7B5"
    #endif

    /// `repo` grants read+write to repository contents — exactly what committing
    /// needs. It's all-or-nothing, so a token from this flow can never be the
    /// read-only token that produced the 403 we're fixing.
    private let scope = "repo"

    /// False until a real client ID is filled in — lets the UI hide the button
    /// rather than show one that 404s against GitHub. In DEBUG builds the
    /// placeholder is treated as unset so dev builds without a configured dev
    /// OAuth App fail with a clear message instead of hitting the production app.
    var isConfigured: Bool {
        let id = Self.clientID
        return !id.isEmpty
            && id != "REPLACE_WITH_SITEAGENT_OAUTH_CLIENT_ID"
            && id != "DEV_GITHUB_OAUTH_CLIENT_ID"
    }

    struct DeviceCode {
        var deviceCode: String
        var userCode: String
        var verificationURI: String
        var interval: Int
        var expiresIn: Int
    }

    // MARK: - Device flow

    /// Step 1: ask GitHub for a device + user code to show the user.
    func requestDeviceCode() async throws -> DeviceCode {
        guard isConfigured else {
            throw OAuthError.tokenExchange("GitHub sign-in isn’t set up in this build yet.")
        }
        var req = URLRequest(url: SiteAgentURL.constant("https://github.com/login/device/code"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: ["client_id": Self.clientID, "scope": scope])

        let (data, _) = try await URLSession.shared.data(for: req)
        guard let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let device = o["device_code"] as? String,
              let user = o["user_code"] as? String,
              let uri = o["verification_uri"] as? String else {
            throw OAuthError.tokenExchange("Couldn’t start GitHub sign-in.")
        }
        return DeviceCode(deviceCode: device, userCode: user, verificationURI: uri,
                          interval: (o["interval"] as? Int) ?? 5,
                          expiresIn: (o["expires_in"] as? Int) ?? 900)
    }

    /// Step 2: poll until the user authorizes on github.com, then store the token
    /// in the standard GitHub-token slot the rest of the app reads.
    func pollForToken(_ device: DeviceCode, credentialID: UUID? = nil) async throws {
        let deadline = Date().addingTimeInterval(Double(device.expiresIn))
        var interval = max(device.interval, 1)

        // Keep executing while the user is over in Safari authorizing.
        var bgTask: UIBackgroundTaskIdentifier = .invalid
        bgTask = UIApplication.shared.beginBackgroundTask(withName: "GitHubDeviceFlowPoll") {
            UIApplication.shared.endBackgroundTask(bgTask); bgTask = .invalid
        }
        defer { if bgTask != .invalid { UIApplication.shared.endBackgroundTask(bgTask) } }

        while Date() < deadline {
            try await Task.sleep(nanoseconds: UInt64(interval) * 1_000_000_000)

            var req = URLRequest(url: SiteAgentURL.constant("https://github.com/login/oauth/access_token"))
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Accept")
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONSerialization.data(withJSONObject: [
                "client_id": Self.clientID,
                "device_code": device.deviceCode,
                "grant_type": "urn:ietf:params:oauth:grant-type:device_code",
            ])

            do {
                let (data, _) = try await URLSession.shared.data(for: req)
                let o = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]

                if let token = o["access_token"] as? String {
                    Keychain.set(token, for: Keychain.githubToken(credentialID: credentialID))
                    // Mark provenance: this token carries the `repo` scope we asked
                    // for, so the UI may truthfully report write access.
                    Keychain.set("oauth", for: Keychain.githubTokenSource(credentialID: credentialID))
                    return
                }
                switch o["error"] as? String {
                case "authorization_pending": continue
                case "slow_down":             interval += 5
                case .some(let err):          throw OAuthError.tokenExchange(err)
                case .none:                   continue
                }
            } catch {
                if Task.isCancelled { throw error }
                if let oauthErr = error as? OAuthError { throw oauthErr }
                // Transient network blip (e.g. backgrounded) — keep polling.
                #if DEBUG
                print("Temporary network error during GitHub auth polling: \(error.localizedDescription)")
                #endif
            }
        }
        throw OAuthError.tokenExchange("Timed out waiting for authorization.")
    }
}
