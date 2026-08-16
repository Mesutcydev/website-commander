import SwiftUI

/// A guided sheet for connecting a GitHub repository as a workspace. Every field
/// carries a plain-language description and, where it points at an external
/// service, a help popover with a direct link to the right configuration page.
struct AddWorkspaceSheet: View {

    @EnvironmentObject var settings: SettingsStore
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openSettings) private var openSettings

    enum Source: String, CaseIterable { case pick = "My Repos", manual = "Manual" }
    @State private var source: Source = .pick

    @State private var repos: [GitHubRepoSummary] = []
    @State private var selectedRepo: GitHubRepoSummary?
    @State private var isLoadingRepos = false
    @State private var loadError: String?

    @State private var name = ""
    @State private var owner = ""
    @State private var repo = ""
    @State private var branch = "main"
    @State private var techStack: TechStack = .vanillaHTML
    @State private var deployment: DeploymentType = .githubPages
    @State private var liveURL = ""
    @State private var defaultModel = ""
    @State private var customRules = ""
    @State private var deployHookURL = ""
    @State private var selectedCredentialID: UUID? = nil
    @State private var accentHex: String? = nil
    @State private var validationMessage: String?

    /// Whether the currently selected GitHub account has a usable token.
    private var hasToken: Bool {
        settings.hasGitHubToken(forCredential: selectedCredentialID)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Space.l) {
                    accountPicker
                    if !hasToken { tokenBanner }

                    WCInlineSegmentedControl(
                        selection: $source,
                        items: Array(Source.allCases),
                        accessibilityLabel: "How do you want to add it?"
                    ) { option in
                        Text(option.rawValue)
                    }

                    if source == .pick { repoPicker } else { manualFields }

                    Divider().padding(.vertical, Theme.Space.s)

                    environmentSection
                    accentSection
                    agentSection
                }
                .padding(Theme.Space.xl)
            }
            Divider()
            footer
        }
        .frame(width: 600, height: 700)
        .task {
            selectInitialAccount()
            if source == .pick { await loadRepos() }
        }
        .onChange(of: source) { _, new in
            if new == .pick { Task { await loadRepos() } }
        }
        .onChange(of: selectedCredentialID) { _, _ in
            if source == .pick { Task { await loadRepos() } }
        }
        .onChange(of: settings.accountOptions) { _, options in
            guard !options.isEmpty,
                  !options.contains(where: { $0.id == selectedCredentialID }) else { return }
            selectedCredentialID = options[0].id
        }
        .onChange(of: validationSignature) { _, _ in
            validationMessage = nil
        }
    }

    /// Picker for which GitHub account lists repos and owns this site.
    private var accountPicker: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 5) {
                Text("GitHub account").font(.caption).foregroundStyle(.secondary)
                HelpButton(title: "GitHub account",
                           message: "Pick which connected GitHub account to use for this site. The repo list below comes from this account's token, and commits will be made as this account. Add more accounts in Settings → GitHub.",
                           links: [("Manage accounts", "https://github.com/settings/tokens")])
            }
            if settings.accountOptions.isEmpty {
                Text("No accounts yet — add one in Settings → GitHub, or paste a token below after creating it.")
                    .font(.caption).foregroundStyle(Theme.warning)
            } else {
                Picker("", selection: $selectedCredentialID) {
                    ForEach(settings.accountOptions) { opt in
                        Text(opt.name).tag(opt.id)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                if hasToken {
                    Label("Token connected", systemImage: "checkmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(Theme.success)
                }
            }
        }
    }

    private var header: some View {
        HStack(spacing: Theme.Space.m) {
            IconTile(systemImage: "plus.circle.fill", size: 36)
            VStack(alignment: .leading, spacing: 2) {
                Text("Add Website").font(.title3.weight(.semibold))
                Text("Connect a GitHub repository the agent can edit").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(Theme.Space.l)
    }

    // MARK: Token banner

    private var tokenBanner: some View {
        HStack(alignment: .top, spacing: Theme.Space.m) {
            Image(systemName: "key.fill")
                .foregroundStyle(Theme.warning)
                .font(.title3)
            VStack(alignment: .leading, spacing: 6) {
                Text("Add a GitHub token first").font(.body.weight(.semibold))
                Text("Website Commander needs a personal access token to list and edit your repositories. It's stored only in your macOS Keychain — never on our servers.")
                    .font(.caption).foregroundStyle(.secondary)
                HStack(spacing: Theme.Space.m) {
                    Link(destination: URL(string: "https://github.com/settings/tokens")!) {
                        Label("Create a token", systemImage: "arrow.up.forward.app")
                            .font(.callout.weight(.semibold))
                    }
                    Button { openSettings() } label: {
                        Label("Open Settings", systemImage: "gearshape")
                    }
                    .buttonStyle(.plain)
                    HelpButton(title: "Creating a GitHub token",
                               message: "Generate a classic Personal Access Token with the `repo` scope (it grants read & write to your repositories). Paste it into Settings → GitHub, then come back here.",
                               links: [("github.com/settings/tokens", "https://github.com/settings/tokens")])
                }
            }
        }
        .padding(Theme.Space.m)
        .background(Theme.warning.opacity(0.12), in: RoundedRectangle(cornerRadius: Theme.Radius.medium))
    }

    // MARK: Repo picker

    private var repoPicker: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            HStack {
                SectionHeader(title: "Repository", systemImage: "github") {
                    Button { Task { await loadRepos() } } label: { Image(systemName: "arrow.clockwise") }
                        .buttonStyle(.icon)
                }
                HelpButton(title: "Pick from your repositories",
                           message: "We list the repositories your GitHub token can access, most recently updated first. Select one and we'll fill in the owner, repo, and default branch for you.",
                           links: [("Manage token scopes", "https://github.com/settings/tokens")])
            }
            if isLoadingRepos {
                HStack { ProgressView().controlSize(.small); Text("Loading your repos…").foregroundStyle(.secondary) }
                    .padding(.vertical, Theme.Space.m)
            } else if let loadError {
                Text(loadError).font(.callout).foregroundStyle(Theme.danger)
            } else {
                ScrollView {
                    LazyVStack(spacing: 6) {
                        ForEach(repos) { r in
                            RepoRow(repo: r, isSelected: selectedRepo?.id == r.id) {
                                selectedRepo = r
                                name = r.displayTitle
                                owner = r.owner
                                repo = r.name
                                branch = r.defaultBranch
                                if let home = r.homepage { liveURL = home }
                            }
                        }
                    }
                }
                .frame(height: 180)
                .commandCard(padding: Theme.Space.s)
            }
        }
    }

    private var manualFields: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            HStack {
                SectionHeader(title: "Repository", systemImage: "github")
                HelpButton(title: "Enter a repository manually",
                           message: "Use this for a repo your token can reach but that isn't listed above, or to point at any owner/repo. The branch is usually `main`.",
                           links: [("Your repositories", "https://github.com/")])
            }
            fieldWithHelp("Display name", text: $name, placeholder: "My Portfolio",
                          help: HelpButton(title: "Display name",
                                           message: "A friendly name shown throughout the app. You can change it later."))
            HStack {
                fieldWithHelp("Owner", text: $owner, placeholder: "username",
                              help: HelpButton(title: "Owner", message: "The GitHub username or organization that owns the repository."))
                fieldWithHelp("Repo", text: $repo, placeholder: "my-site",
                              help: HelpButton(title: "Repository", message: "The repository name (the part after the owner in the GitHub URL)."))
                fieldWithHelp("Branch", text: $branch, placeholder: "main",
                              help: HelpButton(title: "Branch", message: "The branch the agent edits and commits to. Usually `main`."))
            }
        }
    }

    // MARK: Environment

    private var environmentSection: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            HStack {
                SectionHeader(title: "Environment", systemImage: "slider.horizontal.3")
                HelpButton(title: "Environment",
                           message: "Tell the agent what your site is built with and where it's hosted, so it follows the right conventions and can trigger redeployments.")
            }
            HStack(spacing: Theme.Space.m) {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 5) {
                        Text("Tech stack").font(.caption).foregroundStyle(.secondary)
                        HelpButton(title: "Tech stack",
                                   message: "The framework your site uses. The agent adapts its edits (file locations, config, build steps) to match.")
                    }
                    Picker("", selection: $techStack) {
                        ForEach(TechStack.allCases) { Label($0.rawValue, systemImage: $0.icon).tag($0) }
                    }
                    .labelsHidden()
                }
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 5) {
                        Text("Deployment").font(.caption).foregroundStyle(.secondary)
                        HelpButton(title: "Deployment",
                                   message: "Where the site is hosted. Git-push hosts redeploy automatically; hook-capable hosts (Cloudflare, Vercel, Netlify) can be triggered from the app.")
                    }
                    Picker("", selection: $deployment) {
                        ForEach(DeploymentType.allCases) { Label($0.rawValue, systemImage: $0.icon).tag($0) }
                    }
                    .labelsHidden()
                }
            }

            fieldWithHelp("Live URL (for preview)", text: $liveURL, placeholder: "https://example.com",
                          help: HelpButton(title: "Live URL",
                                           message: "The public address of your site. The Preview tab renders this so you can see changes live and run audits."))

            if DeploymentService.supportsHook(deployment) {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 5) {
                        Text("Deploy hook URL (optional)").font(.caption).foregroundStyle(.secondary)
                        deployHookHelp
                    }
                    SecureField("https://…", text: $deployHookURL)
                        .textFieldStyle(.roundedBorder)
                }
            }
        }
    }

    private var deployHookHelp: HelpButton {
        HelpButton(title: "Deploy hook for \(deployment.rawValue)",
                   message: DeploymentService.hookHelp(for: deployment),
                   links: [(deployDashboardLabel, deployDashboardURL)])
    }

    private var deployDashboardLabel: String {
        switch deployment {
        case .cloudflarePages: return "Open Cloudflare"
        case .vercel: return "Open Vercel"
        case .netlify: return "Open Netlify"
        default: return "Open dashboard"
        }
    }

    private var deployDashboardURL: String {
        switch deployment {
        case .cloudflarePages: return "https://dash.cloudflare.com/"
        case .vercel: return "https://vercel.com/dashboard"
        case .netlify: return "https://app.netlify.com/"
        default: return "https://github.com/"
        }
    }

    // MARK: Accent

    private var accentSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 5) {
                Text("Accent color").font(.caption).foregroundStyle(.secondary)
                HelpButton(title: "Accent color",
                           message: "A color that identifies this site in the switcher and dashboard. Colorless keeps the neutral glass look; Auto derives a stable color from the site name.")
            }
            HStack(spacing: 8) {
                // Colorless (default)
                Button { accentHex = nil } label: {
                    Text("Colorless")
                        .font(.caption.weight(.medium))
                        .padding(.horizontal, 10).padding(.vertical, 6)
                        .background(accentHex == nil ? AnyShapeStyle(Color.primary.opacity(0.16)) : AnyShapeStyle(Color.primary.opacity(0.08)),
                                    in: Capsule())
                        .overlay(accentHex == nil ? Capsule().strokeBorder(Color.primary.opacity(0.35)) : nil)
                        .foregroundStyle(.primary)
                }
                .buttonStyle(.plain)
                // Auto chip (name-derived)
                Button { accentHex = SiteWorkspace.autoAccent } label: {
                    Text("Auto")
                        .font(.caption.weight(.medium))
                        .padding(.horizontal, 10).padding(.vertical, 6)
                        .background(accentHex == SiteWorkspace.autoAccent ? AnyShapeStyle(Theme.brandGradient) : AnyShapeStyle(Color.primary.opacity(0.08)),
                                    in: Capsule())
                        .foregroundStyle(accentHex == SiteWorkspace.autoAccent ? .white : .primary)
                }
                .buttonStyle(.plain)
                ForEach(SiteWorkspace.accentPalette, id: \.self) { hex in
                    Button { accentHex = hex } label: {
                        Circle()
                            .fill(Color(hex: hex) ?? .gray)
                            .frame(width: 22, height: 22)
                            .overlay(Circle().strokeBorder(accentHex == hex ? .white : .clear, lineWidth: 2))
                            .overlay(Circle().strokeBorder(Color.primary.opacity(0.15)))
                            .scaleEffect(accentHex == hex ? 1.12 : 1)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    // MARK: Agent

    private var agentSection: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            HStack {
                SectionHeader(title: "Agent", systemImage: "sparkles")
                HelpButton(title: "Agent defaults",
                           message: "Optional per-site guidance. Set a preferred model and any rules the agent must always follow (brand voice, files to never touch, etc.).")
            }
            fieldWithHelp("Default model (optional)", text: $defaultModel,
                          placeholder: "Leave blank for the provider default",
                          help: HelpButton(title: "Default model",
                                           message: "The model used for this site, overriding your global provider choice. Leave blank to use the provider's default."))
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 5) {
                    Text("Custom rules (optional)").font(.caption).foregroundStyle(.secondary)
                    HelpButton(title: "Custom rules",
                               message: "Free-form instructions included in every request for this site — e.g. \"Keep the tone formal\", \"Never edit /config\", \"Use Tailwind classes only\".")
                }
                TextEditor(text: $customRules)
                    .font(.callout)
                    .frame(height: 70)
                    .padding(6)
                    .background(Theme.cardFill, in: RoundedRectangle(cornerRadius: Theme.Radius.small))
            }
        }
    }

    private var footer: some View {
        HStack {
            Button("Cancel") { dismiss() }
            if let validationMessage {
                Label(validationMessage, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(Theme.danger)
                    .lineLimit(2)
                    .frame(maxWidth: 280, alignment: .leading)
            }
            Spacer()
            Button("Add Website") { save() }
                .buttonStyle(.primary)
                .disabled(!canSave)
        }
        .padding(Theme.Space.l)
    }

    private var canSave: Bool {
        validationErrors.isEmpty
    }

    private var validationSignature: String {
        [name, owner, repo, branch, liveURL, deployHookURL, selectedCredentialID?.uuidString ?? ""]
            .joined(separator: "\u{1F}")
    }

    private var validationErrors: [String] {
        var errors: [String] = []
        if !hasToken { errors.append("Connect a GitHub account") }
        if name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            errors.append("Add a display name")
        }
        if !isGitHubIdentifier(owner) { errors.append("Enter a valid GitHub owner") }
        if !isGitHubIdentifier(repo) { errors.append("Enter a valid repository name") }
        let trimmedBranch = branch.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedBranch.isEmpty || trimmedBranch.contains(where: { $0.isWhitespace }) || trimmedBranch.contains("..") {
            errors.append("Enter a valid branch")
        }
        if !liveURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           SiteWorkspace.normalizedLiveURL(liveURL) == nil {
            errors.append("Use a valid http(s) live URL")
        }
        if !deployHookURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           SiteWorkspace.normalizedLiveURL(deployHookURL) == nil {
            errors.append("Use a valid http(s) deploy hook URL")
        }
        return errors
    }

    private func isGitHubIdentifier(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        return trimmed.allSatisfy { $0.isLetter || $0.isNumber || "-_.".contains($0) }
    }

    private func fieldWithHelp(_ label: String, text: Binding<String>, placeholder: String, help: HelpButton) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            FieldHeader(label: label, help: help)
            TextField(placeholder, text: text)
                .textFieldStyle(.roundedBorder)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func save() {
        guard validationErrors.isEmpty else {
            validationMessage = validationErrors.first
            return
        }
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedOwner = owner.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedRepo = repo.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedBranch = branch.trimmingCharacters(in: .whitespacesAndNewlines)
        var workspace = SiteWorkspace(
            name: trimmedName, gitOwner: trimmedOwner, gitRepo: trimmedRepo,
            gitBranch: trimmedBranch.isEmpty ? "main" : trimmedBranch,
            githubCredentialID: selectedCredentialID,
            techStack: techStack, deployment: deployment,
            defaultModel: defaultModel, customRules: customRules,
            accentHex: accentHex)
        let trimmedURL = liveURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if let normalizedURL = SiteWorkspace.normalizedLiveURL(trimmedURL) {
            workspace.deploymentConfig["liveURL"] = normalizedURL.absoluteString
        } else if let selectedRepo, let homepage = selectedRepo.homepage {
            if let normalizedHomepage = SiteWorkspace.normalizedLiveURL(homepage) {
                workspace.deploymentConfig["liveURL"] = normalizedHomepage.absoluteString
            }
        }
        settings.addWorkspace(workspace)
        let trimmedHook = deployHookURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if let normalizedHook = SiteWorkspace.normalizedLiveURL(trimmedHook) {
            DeploymentService.setHookURL(normalizedHook.absoluteString, for: workspace.id)
        }
        dismiss()
    }

    private func selectInitialAccount() {
        let options = settings.accountOptions
        guard !options.isEmpty,
              !options.contains(where: { $0.id == selectedCredentialID }) else { return }
        if let workspaceAccount = settings.activeWorkspace?.githubCredentialID,
           options.contains(where: { $0.id == workspaceAccount }) {
            selectedCredentialID = workspaceAccount
        } else {
            selectedCredentialID = options[0].id
        }
    }

    private func loadRepos() async {
        guard let token = await settings.tokenForCredentialAsync(selectedCredentialID), !token.isEmpty else {
            loadError = "Select a GitHub account with a token (add one in Settings → GitHub)."
            return
        }
        isLoadingRepos = true
        loadError = nil
        defer { isLoadingRepos = false }
        do {
            repos = try await GitHubClient(token: token).listRepos()
            if repos.isEmpty { loadError = "No repositories found for this account." }
        } catch {
            loadError = error.localizedDescription
        }
    }
}

// MARK: - Repo row

private struct RepoRow: View {
    let repo: GitHubRepoSummary
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: Theme.Space.s) {
                Image(systemName: repo.isPrivate ? "lock.fill" : "book.fill")
                    .foregroundStyle(Theme.accent)
                    .frame(width: 20)
                VStack(alignment: .leading, spacing: 1) {
                    Text(repo.displayTitle).font(.callout.weight(.medium))
                    Text(repo.fullName).font(.caption2).foregroundStyle(.secondary)
                }
                Spacer()
                if isSelected { Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.accent) }
            }
            .padding(.horizontal, Theme.Space.s)
            .padding(.vertical, 6)
            .background(isSelected ? Theme.accent.opacity(0.12) : .clear,
                        in: RoundedRectangle(cornerRadius: Theme.Radius.small))
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Labeled field

struct LabeledField: View {
    let label: String
    @Binding var text: String
    var placeholder: String = ""

    init(_ label: String, text: Binding<String>, placeholder: String = "") {
        self.label = label
        self._text = text
        self.placeholder = placeholder
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            TextField(placeholder, text: $text)
                .textFieldStyle(.roundedBorder)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
