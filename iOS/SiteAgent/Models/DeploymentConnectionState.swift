import Foundation

/// Why a deployment connection failed or is incomplete.
enum DeploymentConnectionIssue: Equatable {
    case missingHook
    case missingToken
    case missingProject
    case missingAccount
    case verificationFailed(String)
    case unsupported

    var userMessage: String {
        switch self {
        case .missingHook: return "Add a deploy hook to publish approved changes."
        case .missingToken: return "Add a provider API token to connect."
        case .missingProject: return "Choose the project Website Commander should deploy."
        case .missingAccount: return "Add the account ID for this host."
        case .verificationFailed(let message): return message
        case .unsupported: return "This host isn’t supported for automatic deploy yet."
        }
    }
}

/// Independent of provider *detection* — only reflects configuration / verification.
enum DeploymentConnectionState: Equatable {
    case notConfigured
    /// Repo hints suggested a host; credentials are not necessarily present.
    case detected(DeploymentType)
    case verifying
    case connected(DeploymentType)
    case failed(DeploymentConnectionIssue)

    var statusLabel: String {
        switch self {
        case .notConfigured: return "Not configured"
        case .detected: return "Needs setup"
        case .verifying: return "Verifying…"
        case .connected: return "Connected"
        case .failed: return "Needs attention"
        }
    }
}

/// What the current secrets/config actually enable (detection alone never sets these).
struct DeploymentCapabilities: Equatable {
    /// Can trigger a publish (deploy hook or authenticated deploy route).
    var canTriggerDeploy: Bool
    /// Can list status / history via provider API.
    var canObserveStatus: Bool

    var hasAutomaticDeploy: Bool { canTriggerDeploy }

    static let none = DeploymentCapabilities(canTriggerDeploy: false, canObserveStatus: false)

    static func evaluate(workspace: SiteWorkspace?, repo: RepoConfig) -> DeploymentCapabilities {
        guard let workspace else { return .none }
        switch workspace.deployment {
        case .sshFtp:
            return .none
        case .githubPages:
            let github = Keychain.hasGitHubToken(credentialID: repo.githubCredentialID)
            return DeploymentCapabilities(canTriggerDeploy: github, canObserveStatus: github)
        case .cloudflareWorkers:
            let hook = DeploymentClientFactory.deployHookURL(for: workspace) != nil
            let client = DeploymentClientFactory.client(for: workspace, repo: repo) != nil
            return DeploymentCapabilities(canTriggerDeploy: hook || client, canObserveStatus: client)
        case .awsAmplify:
            let hook = DeploymentClientFactory.deployHookURL(for: workspace) != nil
            return DeploymentCapabilities(canTriggerDeploy: hook, canObserveStatus: false)
        default:
            let client = DeploymentClientFactory.client(for: workspace, repo: repo) != nil
            let hook = DeploymentClientFactory.deployHookURL(for: workspace) != nil
            return DeploymentCapabilities(canTriggerDeploy: client || hook, canObserveStatus: client)
        }
    }

    /// Local configuration presence → connection state (before remote verify).
    static func connectionState(
        workspace: SiteWorkspace?,
        repo: RepoConfig,
        detectedSuggestion: DeploymentType? = nil,
        verifying: Bool = false,
        lastFailure: DeploymentConnectionIssue? = nil
    ) -> DeploymentConnectionState {
        if verifying { return .verifying }
        if let lastFailure { return .failed(lastFailure) }
        guard let workspace else {
            if let detectedSuggestion { return .detected(detectedSuggestion) }
            return .notConfigured
        }
        let caps = evaluate(workspace: workspace, repo: repo)
        if caps.canTriggerDeploy || caps.canObserveStatus {
            return .connected(workspace.deployment)
        }
        // Configured host but missing secrets — still needs setup (not "connected").
        if let detectedSuggestion {
            return .detected(detectedSuggestion)
        }
        return .notConfigured
    }
}
