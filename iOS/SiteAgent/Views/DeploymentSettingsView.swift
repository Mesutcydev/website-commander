import SwiftUI

struct DeploymentSettingsView: View {
    // Pass the engine explicitly. This view is opened from several navigation
    // destinations; relying on environment propagation at those boundaries can
    // leave the destination without the workspace model it needs.
    @ObservedObject var engine: AgentEngine
    @Environment(\.openURL) private var openURL

    /// The sheet passes the workspace that was active when the user tapped
    /// Configure. Keeping that identity separate from the engine's mutable
    /// active workspace prevents a disk refresh or site switch during sheet
    /// presentation from making the view read a half-updated workspace.
    var workspaceID: UUID? = nil

    /// When true, show the goal-oriented Connect path; expand full token/env UI under Advanced.
    var simpleMode: Bool = false
    /// Deep-link anchor so the Sites tiles land on the right section:
    /// "domains" (Domain tile) or "environment" (Secrets tile).
    var scrollTo: String? = nil

    @State private var cloudflareToken = ""
    @State private var vercelToken = ""
    @State private var netlifyToken = ""
    @State private var renderToken = ""
    @State private var railwayToken = ""
    @State private var amplifyToken = ""
    @State private var deployHookURL = ""
    @State private var statusMessage: String?
    @State private var statusOK = false
    // Which action produced the current status, so feedback renders inline under
    // the button the user tapped — not in a single far-away box at the bottom.
    @State private var statusSource: StatusSource = .none
    private enum StatusSource { case none, cloudflare, hook, detection, connection, pages }
    @State private var checking = false
    @State private var publishing = false
    @State private var detecting = false
    @State private var domains: [DeploymentDomain] = []
    @State private var cloudflareWorkersToken = ""
    @State private var cloudflareProjects: [String] = []
    @State private var showProjectPicker = false
    @State private var showWorkerPicker = false
    @State private var loadingProjects = false
    @State private var keychainError: String?
    @State private var showAdvancedDeploy = false
    @State private var connectionIssue: DeploymentConnectionIssue?
    @State private var showChangeHosting = false
    @State private var pendingScrollTask: Task<Void, Never>?

    private var workspace: SiteWorkspace? {
        DeploymentSettingsLookup.workspace(
            id: workspaceID,
            workspaces: engine.workspaces,
            active: engine.activeWorkspace
        )
    }

    private func repo(for workspace: SiteWorkspace) -> RepoConfig {
        RepoConfig(
            owner: workspace.gitOwner,
            name: workspace.gitRepo,
            branch: workspace.gitBranch,
            githubCredentialID: workspace.githubCredentialID
        )
    }

    private var deploymentCapabilities: DeploymentCapabilities {
        DeploymentCapabilities.evaluate(
            workspace: workspace,
            repo: workspace.map { repo(for: $0) } ?? .none
        )
    }

    private var connectionState: DeploymentConnectionState {
        DeploymentCapabilities.connectionState(
            workspace: workspace,
            repo: workspace.map { repo(for: $0) } ?? .none,
            verifying: checking && statusSource == .connection,
            lastFailure: connectionIssue
        )
    }

    /// Persist a deploy secret; surface Keychain failures instead of silent drop.
    /// Blank fields are ignored so opening Deploy Integrations cannot wipe tokens.
    private func saveSecret(_ value: String, for key: String, label: String) {
        if case .preserve = Keychain.commitAction(for: value) { return }
        if Keychain.set(value, for: key) {
            if keychainError != nil { keychainError = nil }
            engine.noteSecretsChanged()
        } else {
            keychainError = "Could not save \(label) to Keychain. Try again or free device storage."
            statusMessage = keychainError
            statusOK = false
            statusSource = .none
        }
    }
    var body: some View {
        ScrollViewReader { proxy in
        ScrollView {
            VStack(spacing: 20) {
                if let keychainError {
                    Label(keychainError, systemImage: "exclamationmark.triangle.fill")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.red)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                        .background(Color.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                if let ws = workspace {
                    if simpleMode {
                        simpleModeContent(ws)
                    } else {
                        fullModeContent(ws)
                    }
                } else {
                    ContentUnavailableView(
                        "No Workspace",
                        systemImage: "folder.badge.questionmark",
                        description: Text("Connect a website before configuring deployment.")
                    )
                    .padding(.top, 60)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .readableWidth(640)
        }
        .appBackground(.grouped)
        .navigationTitle(simpleMode ? "Deployment" : "Deploy Integrations")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            loadSecrets()
            if scrollTo != nil { showAdvancedDeploy = true }
            if let anchor = scrollTo {
                pendingScrollTask?.cancel()
                pendingScrollTask = Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 350_000_000)
                    guard !Task.isCancelled else { return }
                    withAnimation { proxy.scrollTo(anchor, anchor: .top) }
                }
            }
        }
        .onChange(of: engine.activeWorkspace?.id) { _, _ in loadSecrets() }
        .onDisappear {
            pendingScrollTask?.cancel()
            pendingScrollTask = nil
        }
        }
    }

    @ViewBuilder
    private func simpleModeContent(_ ws: SiteWorkspace) -> some View {
        // Overview — host + readiness (never claim Connected from detection alone).
        cardSection("Hosting") {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(ws.deployment.displayName)
                        .font(.headline)
                    Text(connectionState.statusLabel)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(connectionStateAccent)
                }
                Spacer()
                Button("Change Hosting") {
                    Haptics.tap()
                    showChangeHosting = true
                }
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Theme.controlTint)
            }
            .padding(.vertical, 10)
            .confirmationDialog("Change hosting", isPresented: $showChangeHosting, titleVisibility: .visible) {
                ForEach(DeploymentType.allCases) { type in
                    Button(type.displayName) { setDeploymentType(type) }
                }
                Button("Cancel", role: .cancel) {}
            }

            if deploymentCapabilities.hasAutomaticDeploy {
                divider
                VStack(alignment: .leading, spacing: 4) {
                    Text("Automatic deployment")
                        .font(.subheadline.weight(.semibold))
                    Text("Your website can be deployed after approved changes.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 8)
            }
        }

        simpleConnectCard(for: ws)

        cardSection("Connection") {
            actionButton(
                "Verify Connection",
                systemImage: "checkmark.shield.fill",
                style: .primary,
                loading: checking && statusSource == .connection
            ) {
                Task { await saveAndVerify(ws) }
            }
            .disabled(checking)
            statusFeedback(.connection)
        }

        cardSection("Advanced", footer: "API tokens, worker/project names, environment variables, and diagnostics.") {
            DisclosureGroup("Show advanced options", isExpanded: $showAdvancedDeploy) {
                VStack(spacing: 20) {
                    providerCard(for: ws)
                    if ws.deployment != .cloudflareWorkers && ws.deployment != .awsAmplify {
                        deployHookCard(for: ws)
                    } else if showAdvancedDeploy {
                        // Hook is primary for Workers; still available under Advanced as raw URL.
                        deployHookCard(for: ws)
                    }
                    apiSetupCard(for: ws)
                    buildHintsCard(for: ws)
                    environmentCard(for: ws).id("environment")
                    domainsCard(for: ws).id("domains")
                    detectionCard
                }
                .padding(.top, 12)
            }
            .tint(Theme.controlTint)
            .padding(.vertical, 8)
        }
    }

    private var connectionStateAccent: Color {
        switch connectionState {
        case .connected: return .green
        case .verifying: return Theme.controlTint
        case .failed: return .orange
        case .detected, .notConfigured: return .secondary
        }
    }

    /// Goal-oriented connect UI — provider-specific, no token dump on the default surface.
    @ViewBuilder
    private func simpleConnectCard(for ws: SiteWorkspace) -> some View {
        switch ws.deployment {
        case .cloudflareWorkers:
            cardSection(
                "Connect Cloudflare Workers",
                footer: "The hook URL is a secret. Anyone with it can trigger a build."
            ) {
                setupStep(
                    1,
                    title: "Open your Worker’s build settings",
                    detail: "Cloudflare → Workers & Pages → your Worker → Settings → Builds → Deploy Hooks."
                )
                divider
                actionButton("Open Cloudflare Deploy Hooks", systemImage: "arrow.up.forward.app", style: .secondary) {
                    openWorkersDashboard(ws)
                }
                divider
                setupStep(
                    2,
                    title: "Create and copy the hook",
                    detail: "Choose Add deploy hook, name it “Website Commander”, select \(ws.gitBranch), then copy the generated URL."
                )
                divider
                setupStep(
                    3,
                    title: "Paste and verify",
                    detail: "Paste the copied URL below. A separate API token is not required to trigger this hook."
                )
                divider
                secureRow("Deploy hook URL", text: $deployHookURL) {
                    saveSecret(deployHookURL, for: Keychain.deployHookURL(workspaceID: ws.id), label: "deploy hook URL")
                    connectionIssue = nil
                }
                divider
                actionButton("Save and Verify", systemImage: "checkmark.circle", style: .primary, loading: checking) {
                    Task { await saveAndVerify(ws) }
                }
                .disabled(deployHookURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || checking)
                statusFeedback(.hook)
                statusFeedback(.connection)
            }

        case .cloudflarePages:
            cardSection(
                "Connect Cloudflare Pages",
                footer: "Use a scoped API Token, not the Global API Key. Website Commander stores it only in Keychain."
            ) {
                setupStep(
                    1,
                    title: "Create a Cloudflare API token",
                    detail: "Choose Create Token → Custom Token. Add Account → Cloudflare Pages → Edit and limit it to the account that owns this project."
                )
                divider
                actionButton("Open Cloudflare API Tokens", systemImage: "key.horizontal", style: .secondary) {
                    openCloudflareTokenPage()
                }
                divider
                setupStep(
                    2,
                    title: "Copy your Account ID",
                    detail: "Open the Cloudflare account overview and copy Account ID from the account details panel."
                )
                divider
                setupStep(
                    3,
                    title: "Paste the details below",
                    detail: "Enter the Account ID, Pages project name, and the token secret. The token secret is shown only once."
                )
                divider
                configField("Account ID", key: "cloudflareAccountID", placeholder: "Cloudflare account ID")
                divider
                configField("Pages project", key: "cloudflareProjectName", placeholder: "my-site")
                divider
                secureRow("API token", text: $cloudflareToken) {
                    saveSecret(cloudflareToken, for: Keychain.deploymentToken(DeploymentProviderID.cloudflare.rawValue, workspaceID: ws.id), label: "Cloudflare API token")
                    connectionIssue = nil
                }
                divider
                actionButton("Save and Verify", systemImage: "checkmark.circle", style: .primary, loading: checking) {
                    Task { await saveAndVerify(ws) }
                }
                .disabled(checking)
                statusFeedback(.connection)
            }

        case .githubPages:
            cardSection(
                "GitHub Pages",
                footer: "Uses your GitHub sign-in. No extra deploy token is required."
            ) {
                Label(
                    engine.hasGitHubToken ? "GitHub connected — Pages can publish from this repository." : "Sign in to GitHub in Workspace to enable Pages.",
                    systemImage: engine.hasGitHubToken ? "checkmark.circle.fill" : "exclamationmark.circle"
                )
                .font(.subheadline)
                .foregroundStyle(engine.hasGitHubToken ? .green : .orange)
                .padding(.vertical, 10)
            }

        case .vercel, .netlify:
            cardSection(
                "Connect \(ws.deployment.displayName)",
                footer: "Detected configuration is not the same as Connected. Add the token and project ID to enable deploys."
            ) {
                Text("Add your \(ws.deployment.displayName) token and project under Advanced, then Verify Connection.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 10)
                divider
                Button("Show advanced options") {
                    withAnimation { showAdvancedDeploy = true }
                }
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Theme.controlTint)
                .padding(.vertical, 8)
            }

        case .awsAmplify:
            cardSection(
                "Connect AWS Amplify",
                footer: "Paste the Amplify deploy hook so Website Commander can trigger rebuilds."
            ) {
                secureRow("Deploy hook URL", text: $deployHookURL) {
                    saveSecret(deployHookURL, for: Keychain.deployHookURL(workspaceID: ws.id), label: "deploy hook URL")
                    connectionIssue = nil
                }
                divider
                actionButton("Save and Verify", systemImage: "checkmark.circle", style: .primary, loading: checking) {
                    Task { await saveAndVerify(ws) }
                }
                .disabled(deployHookURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || checking)
                statusFeedback(.hook)
            }

        default:
            cardSection("Connect \(ws.deployment.displayName)") {
                Text("Configure credentials under Advanced when you’re ready. Detection alone does not mean Connected.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 10)
                divider
                Button("Show advanced options") {
                    withAnimation { showAdvancedDeploy = true }
                }
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Theme.controlTint)
                .padding(.vertical, 8)
            }
        }
    }

    /// Persist visible fields, then verify the supported endpoint / hook.
    private func saveAndVerify(_ ws: SiteWorkspace) async {
        // Commit draft fields without wiping existing secrets with blanks.
        if case .store(let hook) = Keychain.commitAction(for: deployHookURL) {
            saveSecret(hook, for: Keychain.deployHookURL(workspaceID: ws.id), label: "deploy hook URL")
        }
        if ws.deployment == .cloudflarePages,
           case .store(let token) = Keychain.commitAction(for: cloudflareToken) {
            saveSecret(token, for: Keychain.deploymentToken(DeploymentProviderID.cloudflare.rawValue, workspaceID: ws.id), label: "Cloudflare API token")
        }

        // Local validation first.
        switch ws.deployment {
        case .cloudflareWorkers, .awsAmplify:
            if deployHookURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
               DeploymentClientFactory.deployHookURL(for: ws) == nil {
                connectionIssue = .missingHook
                statusSource = .connection
                statusOK = false
                statusMessage = DeploymentConnectionIssue.missingHook.userMessage
                return
            }
        case .cloudflarePages:
            let account = (ws.deploymentConfig["cloudflareAccountID"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let project = (ws.deploymentConfig["cloudflareProjectName"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let token = cloudflareToken.trimmingCharacters(in: .whitespacesAndNewlines)
            if account.isEmpty {
                connectionIssue = .missingAccount
                statusSource = .connection
                statusOK = false
                statusMessage = DeploymentConnectionIssue.missingAccount.userMessage
                return
            }
            if project.isEmpty {
                connectionIssue = .missingProject
                statusSource = .connection
                statusOK = false
                statusMessage = DeploymentConnectionIssue.missingProject.userMessage
                return
            }
            if token.isEmpty {
                connectionIssue = .missingToken
                statusSource = .connection
                statusOK = false
                statusMessage = DeploymentConnectionIssue.missingToken.userMessage
                return
            }
        default:
            break
        }

        connectionIssue = nil
        await checkProvider(ws)
        if !statusOK {
            connectionIssue = .verificationFailed(statusMessage ?? "Verification failed.")
        } else {
            connectionIssue = nil
            engine.noteSecretsChanged()
        }
    }

    @ViewBuilder
    private func fullModeContent(_ ws: SiteWorkspace) -> some View {
        activeWorkspaceCard(ws)
        providerCard(for: ws)
        apiSetupCard(for: ws)
        buildHintsCard(for: ws)
        environmentCard(for: ws).id("environment")
        domainsCard(for: ws).id("domains")
        deployHookCard(for: ws)
        detectionCard
        connectionCard(for: ws)
    }

    // MARK: - Cards

    private func activeWorkspaceCard(_ ws: SiteWorkspace) -> some View {
        cardSection("Active Workspace", footer: "Tap Provider to switch hosts — e.g. Cloudflare Workers if your repo deploys with Workers Builds instead of Pages.") {
            providerPickerRow(ws)
            divider
            valueRow("Repository", ws.slug)
            divider
            valueRow("Branch", ws.gitBranch)
        }
    }

    @ViewBuilder
    private func providerCard(for ws: SiteWorkspace) -> some View {
        switch ws.deployment {
        case .cloudflarePages:
            cardSection("Cloudflare Pages", footer: "Use an API token (not the Global API Key) scoped to Account → Cloudflare Pages. Stored only in Keychain.") {
                secureRow("Cloudflare API token", text: $cloudflareToken) {
                    saveSecret(cloudflareToken, for: Keychain.deploymentToken(DeploymentProviderID.cloudflare.rawValue, workspaceID: ws.id), label: "Cloudflare API token")
                }
                if cloudflareTokenLooksLikeGlobalKey {
                    divider
                    inlineWarning("That looks like a Global API Key. Website Commander needs an API Token instead — create one below with Cloudflare Pages access.")
                }
                divider
                configField("Account ID", key: "cloudflareAccountID", placeholder: "Cloudflare account ID")
                divider
                configField("Pages project", key: "cloudflareProjectName", placeholder: "my-site")
                divider
                actionButton("Find my projects", systemImage: "magnifyingglass", style: .secondary, loading: loadingProjects) {
                    Task { await loadCloudflareProjects(ws) }
                }
                divider
                actionButton("Create Cloudflare token", systemImage: "key.horizontal", style: .secondary) {
                    openCloudflareTokenPage()
                }
                statusFeedback(.cloudflare)
            }
            .confirmationDialog("Choose your Pages project", isPresented: $showProjectPicker, titleVisibility: .visible) {
                ForEach(cloudflareProjects, id: \.self) { name in
                    Button(name) { setCloudflareProject(name) }
                }
                Button("Cancel", role: .cancel) {}
            }

        case .cloudflareWorkers:
            cardSection("Cloudflare Workers", footer: "Workers Builds deploys are triggered by a deploy hook (in “Manual Rebuild Hook” below) — no Pages project needed. The API token (Workers Scripts:Read) is only used to check status / list Workers; the deploy hook needs no token.") {
                secureRow("Cloudflare API token (for status)", text: $cloudflareWorkersToken) {
                    saveSecret(cloudflareWorkersToken, for: Keychain.deploymentToken(DeploymentProviderID.cloudflareWorkers.rawValue, workspaceID: ws.id), label: "Cloudflare Workers token")
                }
                divider
                configField("Account ID", key: "cloudflareAccountID", placeholder: "Cloudflare account ID")
                divider
                configField("Worker application", key: "cloudflareWorkerName", placeholder: "website")
                divider
                actionButton("Find my Workers", systemImage: "magnifyingglass", style: .secondary, loading: loadingProjects) {
                    Task { await loadCloudflareWorkers(ws) }
                }
                divider
                inlineNote("To deploy: paste this Worker's deploy hook URL into “Manual Rebuild Hook” below, then tap Trigger. Create it in Cloudflare → Workers → \(ws.deploymentConfig["cloudflareWorkerName"] ?? "your Worker") → Settings → Builds → Deploy Hooks.",
                           systemImage: "info.circle", tint: Theme.controlTint)
                divider
                actionButton("Open Workers build settings", systemImage: "arrow.up.forward.app", style: .secondary) {
                    openWorkersDashboard(ws)
                }
                statusFeedback(.cloudflare)
            }
            .confirmationDialog("Choose your Worker", isPresented: $showWorkerPicker, titleVisibility: .visible) {
                ForEach(cloudflareProjects, id: \.self) { name in
                    Button(name) { setCloudflareWorker(name) }
                }
                Button("Cancel", role: .cancel) {}
            }

        case .vercel:
            cardSection("Vercel", footer: "Used for deployment status and build events. Team ID is only needed for team-owned projects.") {
                secureRow("Vercel token", text: $vercelToken) {
                    saveSecret(vercelToken, for: Keychain.deploymentToken(DeploymentProviderID.vercel.rawValue, workspaceID: ws.id), label: "Vercel token")
                }
                divider
                configField("Project ID or name", key: "vercelProjectID", placeholder: "prj_… or project-name")
                divider
                configField("Team ID", key: "vercelTeamID", placeholder: "team_… (optional)")
            }

        case .netlify:
            cardSection("Netlify", footer: "Used for deploy status, deploy details, and restoring an older deploy.") {
                secureRow("Netlify token", text: $netlifyToken) {
                    saveSecret(netlifyToken, for: Keychain.deploymentToken(DeploymentProviderID.netlify.rawValue, workspaceID: ws.id), label: "Netlify token")
                }
                divider
                configField("Site ID", key: "netlifySiteID", placeholder: "site UUID or API ID")
            }

        case .render:
            cardSection("Render", footer: "API token from Render → Account Settings → API Keys. Service ID is the srv-… id from your service URL.") {
                secureRow("Render API token", text: $renderToken) {
                    saveSecret(renderToken, for: Keychain.deploymentToken(DeploymentProviderID.render.rawValue, workspaceID: ws.id), label: "Render API token")
                }
                divider
                configField("Service ID", key: "renderServiceID", placeholder: "srv-…")
            }

        case .railway:
            cardSection("Railway", footer: "Account token from Railway → Account → Tokens, or a project token (set token type below). Copy IDs via Cmd+K in the Railway dashboard.") {
                secureRow("Railway token", text: $railwayToken) {
                    saveSecret(railwayToken, for: Keychain.deploymentToken(DeploymentProviderID.railway.rawValue, workspaceID: ws.id), label: "Railway token")
                }
                divider
                configField("Project ID", key: "railwayProjectID", placeholder: "project UUID")
                divider
                configField("Service ID", key: "railwayServiceID", placeholder: "service UUID")
                divider
                configField("Environment ID", key: "railwayEnvironmentID", placeholder: "environment UUID")
                divider
                configField("Token type", key: "railwayTokenType", placeholder: "project (optional — for project tokens)")
            }

        case .awsAmplify:
            cardSection("AWS Amplify", footer: "Connect your repo in the Amplify Console first. Website Commander triggers rebuilds via a deploy hook — no AWS SigV4 API in this version.") {
                secureRow("Amplify token (optional)", text: $amplifyToken) {
                    saveSecret(amplifyToken, for: Keychain.deploymentToken(DeploymentProviderID.awsAmplify.rawValue, workspaceID: ws.id), label: "Amplify token")
                }
                divider
                inlineNote("Deployment history isn't fetched from Amplify yet. Paste a deploy hook URL in “Manual Rebuild Hook” below to trigger builds from Website Commander.",
                           systemImage: "info.circle", tint: Theme.controlTint)
                divider
                actionButton("Open AWS Amplify Console", systemImage: "arrow.up.forward.app", style: .secondary) {
                    if let url = URL(string: "https://console.aws.amazon.com/amplify/home") { openURL(url) }
                }
            }

        case .githubPages:
            cardSection("GitHub Pages / Actions", footer: "Publishing serves your repo at username.github.io/repo. The first build can take a minute; private repos need a paid GitHub plan.") {
                inlineNote("GitHub Actions uses the GitHub token already configured for this workspace.",
                           systemImage: "checkmark.seal", tint: engine.hasGitHubToken ? .green : .orange)
                divider
                actionButton(((ws.deploymentConfig["liveURL"] ?? "").isEmpty) ? "Publish with GitHub Pages" : "Re-publish with GitHub Pages",
                             systemImage: "globe",
                             style: ((ws.deploymentConfig["liveURL"] ?? "").isEmpty) ? .primary : .secondary,
                             loading: publishing) {
                    Task { await publishPages(ws) }
                }
                .disabled(publishing)
                statusFeedback(.pages)
                divider
                configField("Workflow hint", key: "githubActionsWorkflow", placeholder: "deploy.yml (optional)")
            }

        case .sshFtp:
            cardSection("SSH / SFTP") {
                Text("SSH/SFTP is manual in this version. You can still add build hints and a deploy hook if an external system supports one.")
                    .font(.footnote).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func apiSetupCard(for ws: SiteWorkspace) -> some View {
        cardSection("API Setup", footer: "Provider tokens and deploy hook URLs are saved in Keychain per workspace.") {
            VStack(spacing: 12) {
                switch ws.deployment {
                case .cloudflarePages:
                    guideRow("Cloudflare token", "Create an API token with Account → Cloudflare Pages → Edit, then paste it above.")
                    guideRow("Account ID", "Cloudflare account identifier for the account that owns the Pages project.")
                    guideRow("Pages project", "The Pages project slug from the Cloudflare dashboard.")
                case .cloudflareWorkers:
                    guideRow("Deploy hook (main path)", "Workers Builds deploys via a deploy hook — create it in Workers → your Worker → Settings → Builds → Deploy Hooks, paste it in “Manual Rebuild Hook”.")
                    guideRow("Worker application", "The Worker name (e.g. “website”) — NOT the account subdomain like mesutcydev.")
                    guideRow("API token (optional)", "Only for status checks / “Find my Workers”: a token with Workers Scripts:Read. The deploy hook needs none.")
                case .vercel:
                    guideRow("Vercel token", "Create a Vercel access token and paste it above.")
                    guideRow("Project ID or name", "Use the project id when available. Team projects also need Team ID.")
                case .netlify:
                    guideRow("Netlify token", "Create a Netlify personal access token and paste it above.")
                    guideRow("Site ID", "Use the API site id from Netlify site settings.")
                case .render:
                    guideRow("Render token", "Create an API key in Render → Account Settings.")
                    guideRow("Service ID", "Copy the srv-… id from your Render service dashboard URL.")
                case .railway:
                    guideRow("Railway token", "Create a token in Railway → Account → Tokens, or a project token scoped to one environment.")
                    guideRow("Project / Service / Environment ID", "Copy each UUID from the Railway dashboard (Cmd+K → Copy … ID).")
                    guideRow("Project tokens", "Set token type to “project” when using a project token — it uses a different auth header.")
                case .awsAmplify:
                    guideRow("Amplify setup", "Connect the GitHub repo in AWS Amplify Console, then add a deploy hook URL below.")
                    guideRow("Optional token", "Reserved for a future Amplify API integration — not required for deploy hooks.")
                case .githubPages:
                    guideRow("GitHub token", "Use the GitHub connection in Settings. No separate deploy token is needed.")
                    guideRow("Workflow hint", "Optional file name such as deploy.yml when multiple workflows exist.")
                case .sshFtp:
                    guideRow("Deploy hook", "Paste a provider webhook URL below if an external build system exposes one.")
                }
                guideRow("Deploy hook", "Optional. Treat it as secret — the URL alone can start a rebuild.")
                guideRow("Environment variables", "Add names here for AI review. Add actual secret values in the hosting dashboard.")
            }
        }
    }

    private func buildHintsCard(for ws: SiteWorkspace) -> some View {
        cardSection("Build Hints", footer: "These hints guide the agent and make provider setup easier. They do not run builds on-device.") {
            configField("Build command", key: "buildCommand", placeholder: "npm run build")
            divider
            configField("Output directory", key: "outputDirectory", placeholder: "dist, public, _site…")
            divider
            configField("Root directory", key: "rootDirectory", placeholder: "apps/web (optional)")
        }
    }

    private func environmentCard(for ws: SiteWorkspace) -> some View {
        cardSection("Environment Variables", footer: "Website Commander stores only names/hints here. Manage actual secrets in the hosting provider.") {
            configField("Required variables", key: "requiredEnvVars", placeholder: "API_URL, PUBLIC_SITE_NAME…")
            divider
            actionButton("Audit env vars with AI", systemImage: "key.horizontal", style: .secondary) {
                engine.prefilledPrompt = "Audit this repository for environment variables required by the build/runtime. Compare against these configured hints: \(ws.deploymentConfig["requiredEnvVars"] ?? "none"). Tell me which variables should be added to \(ws.deployment.rawValue), which can be public, and which must stay secret."
                engine.requestedTab = .agent
            }
        }
    }

    private func domainsCard(for ws: SiteWorkspace) -> some View {
        cardSection("Domains", footer: "Live site URL powers the Sites tab preview and “Open Site”. Required for Cloudflare Workers — the deploy API does not expose a public URL.") {
            configField("Live site URL", key: "liveURL", placeholder: "https://example.com")
            divider
            if ws.deployment == .cloudflareWorkers {
                configField("Account subdomain (optional)", key: "cloudflareAccountSubdomain", placeholder: "mesutcydev")
                divider
            }
            if domains.isEmpty {
                Text("No custom domains detected yet. Connect your hosting provider above, then run “Check provider” to load domains.")
                    .font(.footnote).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                divider
            }
            ForEach(Array(domains.enumerated()), id: \.element.id) { index, domain in
                if index > 0 { divider }
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(domain.name).font(.subheadline.weight(.medium))
                        Spacer()
                        Text(domain.status)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(domain.status == "active" ? .green : .orange)
                    }
                    if let hint = domain.validationHint {
                        Text(hint)
                            .font(.caption2.monospaced())
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                }
                .padding(.vertical, 6)
            }
            divider
            actionButton("Ask AI about DNS", systemImage: "network", style: .secondary) {
                let lines = domains.map { "\($0.name): \($0.status) \($0.validationHint ?? "")" }.joined(separator: "\n")
                engine.prefilledPrompt = "Help me resolve these custom domain/DNS statuses for \(ws.deployment.rawValue):\n\n\(lines)"
                engine.requestedTab = .agent
            }
        }
    }

    private func deployHookCard(for ws: SiteWorkspace) -> some View {
        cardSection("Manual Rebuild Hook", footer: "Deploy hook URLs are secrets — the URL itself can trigger a rebuild. Stored in Keychain.") {
            deployHookDirections(for: ws)
            divider
            secureRow("Deploy hook URL", text: $deployHookURL) {
                saveSecret(deployHookURL, for: Keychain.deployHookURL(workspaceID: ws.id), label: "deploy hook URL")
            }
            divider
            actionButton("Trigger deploy hook", systemImage: "paperplane.fill", style: .primary, loading: checking) {
                Task { await triggerHook(ws) }
            }
            .disabled(deployHookURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || checking)
            statusFeedback(.hook)
        }
    }

    @ViewBuilder
    private func deployHookDirections(for ws: SiteWorkspace) -> some View {
        switch ws.deployment {
        case .cloudflarePages, .cloudflareWorkers:
            setupStep(
                1,
                title: "Create the hook in Cloudflare",
                detail: "Workers & Pages → your project → Settings → Builds → Deploy Hooks → Add deploy hook."
            )
            divider
            actionButton("Open Cloudflare build settings", systemImage: "arrow.up.forward.app", style: .secondary) {
                if ws.deployment == .cloudflareWorkers {
                    openWorkersDashboard(ws)
                } else if let url = URL(string: "https://dash.cloudflare.com/") {
                    openURL(url)
                }
            }
            divider
            setupStep(
                2,
                title: "Copy the generated URL",
                detail: "Name it “Website Commander”, select \(ws.gitBranch), create it, then paste the unique URL below."
            )
        case .vercel:
            setupStep(1, title: "Create a Vercel Deploy Hook", detail: "Project → Settings → Git → Deploy Hooks. Choose \(ws.gitBranch), create, and copy the URL.")
            divider
            externalGuideButton("Open Vercel Deploy Hooks guide", url: "https://vercel.com/docs/deploy-hooks")
        case .netlify:
            setupStep(1, title: "Create a Netlify Build Hook", detail: "Project configuration → Build & deploy → Continuous deployment → Build hooks → Add build hook.")
            divider
            externalGuideButton("Open Netlify Build Hooks guide", url: "https://docs.netlify.com/build/configure-builds/build-hooks/")
        default:
            setupStep(1, title: "Create a provider build hook", detail: "Open your hosting project’s build/deploy settings and create a hook for \(ws.gitBranch), then paste its URL below.")
        }
    }

    private func setupStep(_ number: Int, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text("\(number)")
                .font(.caption.weight(.bold))
                .foregroundStyle(Theme.controlTint)
                .frame(width: 26, height: 26)
                .background(Theme.controlTint.opacity(0.12), in: Circle())
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 4)
    }

    private func externalGuideButton(_ title: String, url: String) -> some View {
        actionButton(title, systemImage: "arrow.up.forward.app", style: .secondary) {
            if let destination = URL(string: url) {
                openURL(destination)
            }
        }
    }

    private var detectionCard: some View {
        cardSection("Repo Detection") {
            actionButton("Auto-detect stack & build settings", systemImage: "wand.and.stars", style: .secondary, loading: detecting) {
                Task { await runDetection() }
            }
            .disabled(detecting || !engine.hasGitHubToken || engine.activeWorkspace == nil)
            statusFeedback(.detection)
        }
    }

    private func connectionCard(for ws: SiteWorkspace) -> some View {
        cardSection("Connection") {
            actionButton("Check deploy provider", systemImage: "checkmark.shield.fill", style: .primary, loading: checking) {
                Task { await checkProvider(ws) }
            }
            .disabled(checking)
            statusFeedback(.connection)
        }
    }

    /// Inline status under the action that produced it.
    @ViewBuilder private func statusFeedback(_ source: StatusSource) -> some View {
        if let statusMessage, statusSource == source {
            divider
            statusBanner(statusMessage, ok: statusOK)
        }
    }

    // MARK: - Reusable themed pieces

    /// A titled card: uppercase header, themed surface, optional footer caption.
    private func cardSection<Content: View>(_ title: String, footer: String? = nil, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title.uppercased())
                .font(.caption.weight(.bold)).kerning(0.8)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 4)
            VStack(spacing: 0) { content() }
                .padding(.horizontal, 14)
                .padding(.vertical, 4)
                .cardSurface()
            if let footer {
                Text(footer)
                    .font(.caption).foregroundStyle(.secondary)
                    .padding(.horizontal, 4)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var divider: some View {
        Divider().background(Color.primary.opacity(0.06))
    }

    private func valueRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).foregroundStyle(.secondary)
            Spacer(minLength: 12)
            Text(value).fontWeight(.medium).multilineTextAlignment(.trailing)
        }
        .font(.subheadline)
        .padding(.vertical, 11)
    }

    /// Tappable Provider row — switch the deployment host right here.
    private func providerPickerRow(_ ws: SiteWorkspace) -> some View {
        Menu {
            ForEach(DeploymentType.allCases) { type in
                Button {
                    setDeploymentType(type)
                } label: {
                    if ws.deployment == type { Label(type.rawValue, systemImage: "checkmark") }
                    else { Text(type.rawValue) }
                }
            }
        } label: {
            HStack {
                Text("Provider").foregroundStyle(.secondary)
                Spacer(minLength: 12)
                Text(ws.deployment.rawValue).fontWeight(.medium).foregroundStyle(Theme.controlTint)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.caption2.weight(.bold)).foregroundStyle(.tertiary)
            }
            .font(.subheadline)
            .padding(.vertical, 11)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func setDeploymentType(_ type: DeploymentType) {
        guard var ws = workspace, ws.deployment != type else { return }
        ws.deployment = type
        engine.saveWorkspace(ws)
        statusSource = .connection
        statusOK = true
        statusMessage = "Switched to \(type.rawValue). Fill in the fields above for this host."
        Haptics.tap()
    }

    /// One-tap publish: enable GitHub Pages for this repo and store the live URL.
    private func publishPages(_ ws: SiteWorkspace) async {
        publishing = true
        statusSource = .pages
        defer { publishing = false }
        let client = GitHubClient(repo: repo(for: ws))
        do {
            let url = try await client.enablePages(owner: ws.gitOwner, name: ws.gitRepo, branch: ws.gitBranch)
            var updated = ws
            updated.deploymentConfig["liveURL"] = url
            engine.saveWorkspace(updated)
            statusOK = true
            statusMessage = "Publishing \(url) — the first build can take a minute."
            Haptics.success()
        } catch {
            statusOK = false
            statusMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            Haptics.error()
        }
    }

    private func configField(_ title: String, key: String, placeholder: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            TextField(placeholder, text: Binding(
                get: { engine.activeWorkspace?.deploymentConfig[key] ?? "" },
                set: { setConfig(key, $0) }
            ))
            .font(.subheadline)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
        }
        .padding(.vertical, 9)
    }

    private func secureRow(_ title: String, text: Binding<String>, onCommit: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            DebouncedSecureField(placeholder: "Paste token", text: text, onCommit: onCommit) {
                engine.noteSecretsChanged()
            }
            .font(.subheadline)
        }
        .padding(.vertical, 9)
    }

    private func guideRow(_ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "info.circle.fill")
                .font(.caption)
                .foregroundStyle(Theme.controlTint)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline.weight(.semibold))
                Text(detail).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
    }

    private func inlineNote(_ text: String, systemImage: String, tint: Color) -> some View {
        Label(text, systemImage: systemImage)
            .font(.footnote).foregroundStyle(tint)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 9)
    }

    private func inlineWarning(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            Text(text).font(.footnote).foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.vertical, 9)
    }

    private enum ButtonKind { case primary, secondary }

    private func actionButton(_ title: String, systemImage: String, style: ButtonKind, loading: Bool = false, action: @escaping () -> Void) -> some View {
        Button {
            Haptics.tap(); action()
        } label: {
            HStack(spacing: 8) {
                if loading { ProgressView().controlSize(.small).tint(style == .primary ? .white : Theme.controlTint) }
                else { Image(systemName: systemImage).font(.subheadline.weight(.semibold)) }
                Text(title).fontWeight(.semibold)
            }
            .font(.subheadline)
            .frame(maxWidth: .infinity)          // centers the icon+label cluster
            .padding(.vertical, 13)
            .foregroundStyle(style == .primary ? Color.white : Theme.controlTint)
            .background {
                if style == .primary {
                    RoundedRectangle(cornerRadius: Theme.cornerSmall, style: .continuous).fill(Theme.actionGradient)
                } else {
                    RoundedRectangle(cornerRadius: Theme.cornerSmall, style: .continuous)
                        .fill(Theme.controlTint.opacity(0.12))
                        .overlay(RoundedRectangle(cornerRadius: Theme.cornerSmall, style: .continuous)
                            .strokeBorder(Theme.controlTint.opacity(0.25), lineWidth: 1))
                }
            }
        }
        .buttonStyle(.pressable)
        .padding(.vertical, 8)
    }

    private func statusBanner(_ message: String, ok: Bool) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: ok ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(ok ? Theme.ok : Theme.warn)
            Text(message).font(.footnote).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background((ok ? Theme.ok : Theme.warn).opacity(0.12),
                    in: RoundedRectangle(cornerRadius: Theme.cornerSmall, style: .continuous))
        .padding(.vertical, 8)
    }

    // MARK: - Cloudflare token helpers

    /// Cloudflare Global API Keys are 37 hex chars; real API tokens are ~40 chars
    /// with mixed case and `_`/`-`. Catch the common paste-the-wrong-thing mistake.
    private var cloudflareTokenLooksLikeGlobalKey: Bool {
        let t = cloudflareToken.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.count == 37 && t.allSatisfy { $0.isHexDigit }
    }

    private func openCloudflareTokenPage() {
        // No public OAuth exists to mint Cloudflare tokens, so deep-link the user
        // to the token page; they pick the "Cloudflare Pages" template (Edit).
        if let url = URL(string: "https://dash.cloudflare.com/profile/api-tokens") { openURL(url) }
    }

    /// Turn an opaque provider error into something the user can act on.
    private func friendlyError(_ error: Error, ws: SiteWorkspace) -> String {
        let raw = error.localizedDescription
        let lower = raw.lowercased()
        if ws.deployment == .cloudflarePages,
           raw.contains("403") || raw.contains("10000") || lower.contains("authentication error") {
            return """
            Cloudflare rejected the token. Check that:
            • It's an API Token, not the Global API Key
            • It has Account → Cloudflare Pages → Edit
            • The Account ID matches the account that owns the project
            Tap “Create Cloudflare token” to mint one with the right scope.
            """
        }
        if ws.deployment == .cloudflarePages, raw.contains("404") || lower.contains("not found") {
            let name = ws.deploymentConfig["cloudflareProjectName"] ?? ""
            return """
            No Cloudflare Pages project named “\(name)” in this account.
            • Tap “Find my projects” to pick the right Pages slug, and confirm the Account ID.
            • If this repo deploys with Cloudflare Workers Builds (not Pages), switch the workspace's deployment to “Cloudflare Workers” and use a deploy hook.
            """
        }
        // Cap length — DeployJSON already sanitizes bodies; avoid dumping leftovers.
        return String(raw.prefix(280))
    }

    /// Fetch the account's Worker scripts so the user can pick the right name.
    private func loadCloudflareWorkers(_ ws: SiteWorkspace) async {
        statusSource = .cloudflare
        let token = cloudflareWorkersToken.trimmingCharacters(in: .whitespacesAndNewlines)
        let accountID = (ws.deploymentConfig["cloudflareAccountID"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty, !accountID.isEmpty else {
            statusOK = false
            statusMessage = "Add a Cloudflare API token (Workers Scripts:Read) and Account ID first. (The deploy hook below works without a token.)"
            return
        }
        loadingProjects = true
        defer { loadingProjects = false }
        do {
            let names = try await CloudflareWorkers.listScriptNames(accountID: accountID, token: token)
            if names.isEmpty {
                statusOK = false
                statusMessage = "No Workers in this account — double-check the Account ID and token scope."
            } else if names.count == 1 {
                setCloudflareWorker(names[0])
            } else {
                cloudflareProjects = names
                showWorkerPicker = true
            }
        } catch {
            statusOK = false
            statusMessage = friendlyError(error, ws: ws)
        }
    }

    private func setCloudflareWorker(_ name: String) {
        setConfig("cloudflareWorkerName", name)
        statusSource = .cloudflare
        statusOK = true
        statusMessage = "Worker set to “\(name)”. Add its deploy hook below to deploy."
        Haptics.success()
    }

    private func openWorkersDashboard(_ ws: SiteWorkspace) {
        let account = ws.deploymentConfig["cloudflareAccountID"] ?? ""
        let url = account.isEmpty
            ? "https://dash.cloudflare.com/?to=/:account/workers-and-pages"
            : "https://dash.cloudflare.com/\(account)/workers-and-pages"
        if let u = URL(string: url) { openURL(u) }
    }

    /// Fetch the account's Pages projects so the user can pick the right slug —
    /// the fix for a 404 "project not found".
    private func loadCloudflareProjects(_ ws: SiteWorkspace) async {
        statusSource = .cloudflare
        let token = cloudflareToken.trimmingCharacters(in: .whitespacesAndNewlines)
        let accountID = (ws.deploymentConfig["cloudflareAccountID"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty, !accountID.isEmpty else {
            statusOK = false
            statusMessage = "Add your Cloudflare API token and Account ID first."
            return
        }
        loadingProjects = true
        defer { loadingProjects = false }
        do {
            let names = try await CloudflarePages.listProjectNames(accountID: accountID, token: token)
            if names.isEmpty {
                statusOK = false
                statusMessage = "No Pages projects in this account — double-check the Account ID."
            } else if names.count == 1 {
                setCloudflareProject(names[0])
            } else {
                cloudflareProjects = names
                showProjectPicker = true
            }
        } catch {
            statusOK = false
            statusMessage = friendlyError(error, ws: ws)
        }
    }

    private func setCloudflareProject(_ name: String) {
        setConfig("cloudflareProjectName", name)
        statusSource = .cloudflare
        statusOK = true
        statusMessage = "Project set to “\(name)”. Tap “Check deploy provider” to confirm."
        Haptics.success()
    }

    // MARK: - Logic (unchanged behavior)

    private func setConfig(_ key: String, _ value: String) {
        guard var ws = workspace else { return }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        ws.deploymentConfig[key] = trimmed.isEmpty ? nil : trimmed
        engine.saveWorkspace(ws)
    }

    private func loadSecrets() {
        guard let ws = workspace else { return }
        cloudflareToken = Keychain.get(Keychain.deploymentToken(DeploymentProviderID.cloudflare.rawValue, workspaceID: ws.id)) ?? ""
        cloudflareWorkersToken = Keychain.get(Keychain.deploymentToken(DeploymentProviderID.cloudflareWorkers.rawValue, workspaceID: ws.id)) ?? ""
        vercelToken = Keychain.get(Keychain.deploymentToken(DeploymentProviderID.vercel.rawValue, workspaceID: ws.id)) ?? ""
        netlifyToken = Keychain.get(Keychain.deploymentToken(DeploymentProviderID.netlify.rawValue, workspaceID: ws.id)) ?? ""
        renderToken = Keychain.get(Keychain.deploymentToken(DeploymentProviderID.render.rawValue, workspaceID: ws.id)) ?? ""
        railwayToken = Keychain.get(Keychain.deploymentToken(DeploymentProviderID.railway.rawValue, workspaceID: ws.id)) ?? ""
        amplifyToken = Keychain.get(Keychain.deploymentToken(DeploymentProviderID.awsAmplify.rawValue, workspaceID: ws.id)) ?? ""
        deployHookURL = Keychain.get(Keychain.deployHookURL(workspaceID: ws.id)) ?? ""
    }

    private func checkProvider(_ ws: SiteWorkspace) async {
        statusSource = .connection
        checking = true
        defer { checking = false }
        if ws.deployment == .awsAmplify {
            let hookReady = DeploymentClientFactory.deployHookURL(for: ws) != nil
                || !deployHookURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            statusOK = hookReady
            statusMessage = hookReady
                ? "Amplify deploy hook configured. Website Commander can trigger rebuilds after approved changes."
                : "Add an Amplify deploy hook URL. Connect the repo in AWS Amplify Console first."
            return
        }
        if ws.deployment == .cloudflareWorkers {
            let hookReady = DeploymentClientFactory.deployHookURL(for: ws) != nil
                || !deployHookURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            if let client = DeploymentClientFactory.client(for: ws, repo: repo(for: ws)) {
                do {
                    let deployments = try await client.listDeployments(limit: 3, commitSHA: nil)
                    statusOK = true
                    if let first = deployments.first {
                        statusMessage = "Workers status connected. Latest: \(first.state.label).\(hookReady ? " Deploy hook ready." : " Add a deploy hook to trigger publishes.")"
                    } else {
                        statusMessage = "Workers status connected.\(hookReady ? " Deploy hook ready." : " Add a deploy hook to trigger publishes.")"
                    }
                } catch {
                    // Preserve hook-only capability when status API fails.
                    if hookReady {
                        statusOK = true
                        statusMessage = "Deploy hook ready. Status API unavailable: \(friendlyError(error, ws: ws))"
                    } else {
                        statusOK = false
                        statusMessage = friendlyError(error, ws: ws)
                    }
                }
                return
            }
            statusOK = hookReady
            statusMessage = hookReady
                ? "Deploy hook saved. Website Commander can publish approved changes. Add an API token under Advanced for deployment history."
                : "Add a Workers deploy hook to publish approved changes."
            return
        }
        if ws.deployment == .githubPages {
            statusOK = engine.hasGitHubToken
            statusMessage = statusOK
                ? "GitHub Pages uses your GitHub sign-in."
                : "Sign in to GitHub to enable Pages."
            return
        }
        guard let client = DeploymentClientFactory.client(for: ws, repo: repo(for: ws)) else {
            statusOK = false
            statusMessage = "Add the required provider token and project identifiers first."
            return
        }
        do {
            let deployments = try await client.listDeployments(limit: 3, commitSHA: nil)
            domains = (try? await client.domains()) ?? []
            statusOK = true
            if let first = deployments.first {
                statusMessage = "\(client.providerName) connected. Latest deployment: \(first.state.label)\(first.shortSHA.isEmpty ? "" : " · \(first.shortSHA)")"
            } else {
                statusMessage = "\(client.providerName) connected, but no deployments were returned."
            }
        } catch {
            statusOK = false
            statusMessage = friendlyError(error, ws: ws)
        }
    }

    private func triggerHook(_ ws: SiteWorkspace) async {
        statusSource = .hook
        checking = true
        defer { checking = false }
        do {
            try await DeploymentClientFactory.triggerDeployHook(for: ws)
            statusOK = true
            statusMessage = "Deploy hook triggered."
        } catch {
            statusOK = false
            statusMessage = error.localizedDescription
        }
    }

    private func runDetection() async {
        statusSource = .detection
        detecting = true
        defer { detecting = false }
        if let result = await engine.detectActiveRepositorySettings() {
            statusOK = true
            var pieces = ["Detected \(result.techStack.rawValue)"]
            if let build = result.buildCommand { pieces.append(build) }
            if let output = result.outputDirectory { pieces.append(output) }
            statusMessage = pieces.joined(separator: " · ")
        } else {
            statusOK = false
            statusMessage = engine.lastError ?? "Could not inspect the repository."
        }
    }
}

/// SecureField that only fires `onCommit` (e.g. `Keychain.set`) after typing
/// pauses ~0.4s, or on submit — never per keystroke. `onChange` fires
/// immediately so cheap UI-refresh signals (e.g. `noteSecretsChanged`) stay
/// responsive. Each new change cancels the pending commit task.
struct DebouncedSecureField: View {
    let placeholder: String
    @Binding var text: String
    let onCommit: () -> Void
    let onChange: () -> Void

    @State private var debounceTask: Task<Void, Never>?

    init(placeholder: String,
         text: Binding<String>,
         onCommit: @escaping () -> Void,
         onChange: @escaping () -> Void = {}) {
        self.placeholder = placeholder
        self._text = text
        self.onCommit = onCommit
        self.onChange = onChange
    }

    var body: some View {
        SecureField(placeholder, text: $text)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .onChange(of: text) { _, _ in
                onChange()
                debounceTask?.cancel()
                debounceTask = Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 400_000_000)
                    guard !Task.isCancelled else { return }
                    onCommit()
                }
            }
            .onSubmit {
                debounceTask?.cancel()
                onCommit()
            }
    }
}
