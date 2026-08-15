import Foundation

/// Typed deep-link destinations for Workspace / wizard (no string routing).
enum WorkspaceRoute: Hashable {
    case website
    case github
    case assistant
    case deployment
    case repositoryAdvanced
    case secrets
    case status
}

/// Goal-oriented readiness for the Workspace sheet and Connect wizard.
/// Derived from existing Keychain / OAuth / deploy configuration — no new storage.
struct WorkspaceStatus: Equatable {
    var hasWebsite: Bool
    var githubConnected: Bool
    var assistantReady: Bool
    var deploymentReady: Bool
    /// Trigger capability (hook / authenticated deploy). Independent of status API.
    var canTriggerDeploy: Bool
    /// History/status API capability.
    var canObserveDeployStatus: Bool

    var websiteDisplayName: String
    var assistantDisplayName: String
    var deploymentDisplayName: String

    /// Short pills under the Website card (e.g. GitHub, Cloudflare, Claude…).
    var connectedPills: [String]

    var allGreen: Bool {
        hasWebsite && githubConnected && assistantReady && deploymentReady
    }

    /// True when GitHub + AI are ready so the agent can work even if deploy is skipped.
    var agentReady: Bool {
        hasWebsite && githubConnected && assistantReady
    }

    var statusSummary: String {
        if allGreen { return "Everything is working." }
        if !hasWebsite { return "Connect a website to get started." }
        if !githubConnected { return "Sign in to GitHub to continue." }
        if !assistantReady { return "Choose an AI assistant to continue." }
        if !deploymentReady { return "Deployment isn’t connected yet — optional." }
        return "Finish setup to continue."
    }

    /// Preferred fix destination for the first incomplete readiness row.
    var primaryRoute: WorkspaceRoute {
        if !hasWebsite { return .website }
        if !githubConnected { return .github }
        if !assistantReady { return .assistant }
        if !deploymentReady { return .deployment }
        return .status
    }

    static func evaluate(
        workspace: SiteWorkspace?,
        githubConnected: Bool,
        assistantReady: Bool,
        assistantDisplayName: String,
        repo: RepoConfig
    ) -> WorkspaceStatus {
        let hasWebsite = workspace != nil
        let websiteName: String = {
            guard let workspace else { return "No website" }
            let live = workspace.configuredLiveURL
            if !live.isEmpty {
                return live
                    .replacingOccurrences(of: "https://", with: "")
                    .replacingOccurrences(of: "http://", with: "")
                    .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            }
            return workspace.name
        }()

        let deploymentName = workspace?.deployment.displayName ?? "Not set"
        let caps = DeploymentCapabilities.evaluate(workspace: workspace, repo: repo)
        // Ready when we can actually trigger a deploy — not from detection alone.
        let deploymentReady = caps.canTriggerDeploy

        var pills: [String] = []
        if githubConnected { pills.append("GitHub") }
        if let workspace, deploymentReady {
            pills.append(Self.shortHostLabel(workspace.deployment))
        }
        if assistantReady { pills.append(assistantDisplayName) }

        return WorkspaceStatus(
            hasWebsite: hasWebsite,
            githubConnected: githubConnected,
            assistantReady: assistantReady,
            deploymentReady: deploymentReady,
            canTriggerDeploy: caps.canTriggerDeploy,
            canObserveDeployStatus: caps.canObserveStatus,
            websiteDisplayName: websiteName,
            assistantDisplayName: assistantDisplayName,
            deploymentDisplayName: deploymentName,
            connectedPills: pills
        )
    }

    /// Whether the workspace can trigger deploys with current secrets/config.
    /// Detection of wrangler/vercel files alone never returns true.
    static func isDeploymentReady(workspace: SiteWorkspace?, repo: RepoConfig) -> Bool {
        DeploymentCapabilities.evaluate(workspace: workspace, repo: repo).canTriggerDeploy
    }

    static func shortHostLabel(_ type: DeploymentType) -> String {
        switch type {
        case .cloudflarePages: return "Cloudflare"
        case .cloudflareWorkers: return "Cloudflare"
        case .vercel: return "Vercel"
        case .netlify: return "Netlify"
        case .render: return "Render"
        case .railway: return "Railway"
        case .awsAmplify: return "Amplify"
        case .githubPages: return "GitHub Pages"
        case .sshFtp: return "SSH"
        }
    }
}
