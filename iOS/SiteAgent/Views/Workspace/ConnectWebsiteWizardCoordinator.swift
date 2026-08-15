import Foundation
import SwiftUI

enum WizardIssue: Equatable {
    case message(String)
    case duplicateWorkspace(SiteWorkspace)

    var text: String {
        switch self {
        case .message(let s): return s
        case .duplicateWorkspace: return "This website is already connected."
        }
    }
}

/// Temporary wizard state. Commits a workspace only on Finish (except OAuth tokens).
@MainActor
final class ConnectWebsiteWizardCoordinator: ObservableObject {
    enum Step: Int, CaseIterable, Equatable {
        case github = 0
        case website = 1
        case deployment = 2
        case assistant = 3

        var title: String {
            switch self {
            case .github: return "GitHub"
            case .website: return "Website"
            case .deployment: return "Deployment"
            case .assistant: return "Assistant"
            }
        }
    }

    @Published var step: Step = .github
    @Published var githubLogin: String?
    @Published var githubCredentialID: UUID?
    @Published var repositories: [GitHubRepoSummary] = []
    @Published var repoSearch = ""
    @Published var loadingRepos = false
    @Published var detecting = false
    @Published var selectedRepository: GitHubRepoSummary?
    @Published var selectedBranch: String?
    @Published var detection: RepoDetectionResult?
    @Published var deployHookDraft = ""
    @Published var skipDeployment = false
    @Published var selectedProviderID: String = "copilot"
    @Published var isWorking = false
    @Published var issue: WizardIssue?
    @Published var duplicateWorkspace: SiteWorkspace?
    @Published var didFinish = false

    /// Shared session so temporary dismiss / OAuth return can resume non-secret state.
    static let shared = ConnectWebsiteWizardCoordinator()

    var filteredRepositories: [GitHubRepoSummary] {
        let q = repoSearch.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return repositories }
        return repositories.filter {
            $0.fullName.lowercased().contains(q)
                || $0.displayTitle.lowercased().contains(q)
                || ($0.description?.lowercased().contains(q) ?? false)
        }
    }

    var suggestedDeployment: DeploymentType? {
        detection?.suggestedDeployment
    }

    func reset() {
        step = .github
        githubLogin = nil
        githubCredentialID = nil
        repositories = []
        repoSearch = ""
        loadingRepos = false
        detecting = false
        selectedRepository = nil
        selectedBranch = nil
        detection = nil
        deployHookDraft = ""
        skipDeployment = false
        selectedProviderID = "copilot"
        isWorking = false
        issue = nil
        duplicateWorkspace = nil
        didFinish = false
    }

    func prepareOnAppear(engine: AgentEngine) {
        if didFinish { reset() }
        if let requested = engine.requestedWizardStep {
            step = requested
            engine.requestedWizardStep = nil
        } else if hasGitHubToken, step == .github {
            step = .website
        }
        selectedProviderID = engine.activeProviderID
        if hasGitHubToken {
            Task { await refreshGitHub(engine: engine) }
        }
    }

    func refreshGitHub(engine: AgentEngine) async {
        guard hasGitHubToken else { return }
        loadingRepos = true
        issue = nil
        defer { loadingRepos = false }
        do {
            let client = GitHubClient(repo: RepoConfig(
                owner: "", name: "", branch: "main",
                githubCredentialID: githubCredentialID
            ))
            async let loginTask = client.verifyToken()
            async let reposTask = client.listAccessibleRepos()
            githubLogin = try await loginTask
            repositories = try await reposTask
        } catch {
            issue = .message(error.localizedDescription)
        }
    }

    func selectRepository(_ repo: GitHubRepoSummary, engine: AgentEngine) async {
        selectedRepository = repo
        selectedBranch = repo.defaultBranch
        detecting = true
        issue = nil
        defer { detecting = false }

        let branch = selectedBranch ?? repo.defaultBranch
        let client = GitHubClient(repo: RepoConfig(
            owner: repo.owner, name: repo.name, branch: branch,
            githubCredentialID: githubCredentialID
        ))
        do {
            let listed = try await client.listRecursiveDetailed()
            var wrangler: String?
            if listed.entries.contains(where: {
                let n = $0.name.lowercased()
                return n == "wrangler.toml" || n == "wrangler.json" || n == "wrangler.jsonc"
            }) {
                wrangler = try? await client.read(path: "wrangler.toml").content
                if wrangler == nil {
                    wrangler = try? await client.read(path: "wrangler.json").content
                }
            }
            var packageJSON: String?
            if listed.entries.contains(where: { $0.name.lowercased() == "package.json" }) {
                packageJSON = try? await client.read(path: "package.json").content
            }
            detection = RepoAutoDetector.detect(
                entries: listed.entries,
                packageJSON: packageJSON,
                wranglerTOML: wrangler,
                homepageURL: repo.homepage
            )
        } catch {
            detection = RepoAutoDetector.detect(entries: [], packageJSON: nil, homepageURL: repo.homepage)
        }
        withAnimation { step = .deployment }
    }

    func continueFromDeployment(skip: Bool) {
        skipDeployment = skip
        withAnimation { step = .assistant }
    }

    /// Atomically create or open existing workspace. Returns the workspace on success.
    @discardableResult
    func finish(engine: AgentEngine) -> SiteWorkspace? {
        guard !didFinish else { return engine.activeWorkspace }
        guard hasGitHubToken else {
            issue = .message("Sign in to GitHub to continue.")
            step = .github
            return nil
        }
        guard let repo = selectedRepository else {
            issue = .message("Choose a website repository.")
            step = .website
            return nil
        }
        let branch = (selectedBranch ?? repo.defaultBranch).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !branch.isEmpty else {
            issue = .message("Choose a branch for this repository.")
            return nil
        }

        if let existing = engine.existingWorkspace(owner: repo.owner, repo: repo.name, branch: branch) {
            duplicateWorkspace = existing
            issue = .duplicateWorkspace(existing)
            return nil
        }

        isWorking = true
        defer { isWorking = false }

        var config: [String: String] = [:]
        if let live = detection?.suggestedLiveURL ?? repo.homepage, !live.isEmpty {
            config["liveURL"] = live
        }
        if let worker = detection?.suggestedWorkerName {
            config["cloudflareWorkerName"] = worker
        }
        if let build = detection?.buildCommand { config["buildCommand"] = build }
        if let output = detection?.outputDirectory { config["outputDirectory"] = output }

        let deployment: DeploymentType = {
            // Preserve suggestion even when skipped so Workspace can guide later.
            detection?.suggestedDeployment ?? .githubPages
        }()

        engine.activeProviderID = selectedProviderID

        let workspace = SiteWorkspace(
            name: repo.displayTitle,
            gitOwner: repo.owner,
            gitRepo: repo.name,
            gitBranch: branch,
            githubCredentialID: githubCredentialID,
            techStack: detection?.techStack ?? .vanillaHTML,
            deployment: deployment,
            defaultModel: engine.selectedModel,
            customRules: "",
            deploymentConfig: config
        )

        engine.saveWorkspace(workspace)
        engine.selectWorkspace(workspace)

        if !skipDeployment,
           (deployment == .cloudflareWorkers || deployment == .awsAmplify),
           case .store(let hook) = Keychain.commitAction(for: deployHookDraft) {
            _ = Keychain.set(hook, for: Keychain.deployHookURL(workspaceID: workspace.id))
            engine.noteSecretsChanged()
        }

        didFinish = true
        issue = nil
        Haptics.success()
        return workspace
    }

    var hasGitHubToken: Bool {
        Keychain.hasGitHubToken(credentialID: githubCredentialID)
    }

    func usePrimaryAccount(engine: AgentEngine) {
        githubCredentialID = nil
        clearRepositorySelection()
        Task { await refreshGitHub(engine: engine) }
    }

    func useAnotherAccount() {
        if githubCredentialID == nil { githubCredentialID = UUID() }
        githubLogin = nil
        repositories = []
        clearRepositorySelection()
    }

    private func clearRepositorySelection() {
        selectedRepository = nil
        selectedBranch = nil
        detection = nil
        repoSearch = ""
        issue = nil
    }

    func openExistingDuplicate(engine: AgentEngine) {
        guard let existing = duplicateWorkspace else { return }
        engine.selectWorkspace(existing)
        didFinish = true
        issue = nil
        Haptics.success()
    }
}
