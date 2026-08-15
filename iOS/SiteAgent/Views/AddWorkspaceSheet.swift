import SwiftUI
import PhotosUI

struct AddWorkspaceSheet: View {
    @EnvironmentObject var engine: AgentEngine
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme

    var editingWorkspace: SiteWorkspace? = nil

    @State private var name = ""
    @State private var gitOwner = ""
    @State private var gitRepo = ""
    @State private var gitBranch = "main"
    @State private var techStack: TechStack = .vanillaHTML
    @State private var deployment: DeploymentType = .cloudflarePages
    @State private var defaultModel = ""
    @State private var customRules = ""
    @State private var liveURL = ""
    @State private var showGitHubHelp = false
    @FocusState private var focusedField: Field?

    // Create-mode state (a brand-new repo, vs. connecting an existing one).
    @State private var mode: Mode = .connect
    @State private var selectedTemplate: SiteTemplate = SiteTemplate.all[0]
    @State private var aiPrompt = ""
    @State private var isPrivate = false
    @State private var repoEdited = false        // stop auto-deriving repo once user edits it
    @State private var photoItems: [PhotosPickerItem] = []
    @State private var screenshot: Attachment?
    @State private var createPhase: CreatePhase = .idle
    @State private var useAnotherGitHubAccount = false
    @State private var alternateGitHubCredentialID = UUID()

    enum Mode: Hashable { case connect, create }

    /// Progress of the multi-step create flow, surfaced as an overlay.
    enum CreatePhase: Equatable {
        case idle
        case working(String)     // current step label
        case failed(String)      // error message
        case done(CreateDoneInfo)
    }

    struct CreateDoneInfo: Equatable {
        var liveURL: String
        var deployment: DeploymentType
        var needsDeploySetup: Bool
    }

    private enum Field: Hashable {
        case name, owner, repository, branch, rules, prompt
    }

    private var isEditing: Bool {
        editingWorkspace != nil
    }

    private var isCreating: Bool { mode == .create && !isEditing }
    private var selectedGitHubCredentialID: UUID? {
        if isEditing { return editingWorkspace?.githubCredentialID }
        return useAnotherGitHubAccount ? alternateGitHubCredentialID : nil
    }

    private var canCreate: Bool {
        !gitOwner.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !gitRepo.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var canSave: Bool {
        !gitOwner.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !gitRepo.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var repositorySlug: String {
        let owner = gitOwner.isEmpty ? "owner" : gitOwner
        let repository = gitRepo.isEmpty ? "repository" : gitRepo
        return "\(owner)/\(repository)"
    }

    private var footerBackground: Color {
        engine.oledMode && colorScheme == .dark ? Color(white: 0.04) : Color(.systemBackground)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    if !isEditing { modePicker }

                    introduction
                    if !isEditing { githubAccountSection }

                    if isCreating {
                        createBasicsSection
                        templateSection
                        createDeploySection
                        createAISection
                    } else {
                        if !isEditing {
                            guidedSetupCard
                        }
                        workspaceSection
                        repositorySection
                        environmentSection
                        agentSection
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 8)
                .padding(.bottom, 24)
            }
            .commandBackground()
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle(isEditing ? "Edit Workspace" : (isCreating ? "Create Site" : "New Workspace"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                saveBar
            }
            .onAppear(perform: loadWorkspace)
            .task {
                await engine.refreshActiveProviderModels()
                // Default the owner to the signed-in GitHub login for create mode.
                let accountRepo = RepoConfig(
                    owner: "", name: "", branch: "main",
                    githubCredentialID: selectedGitHubCredentialID
                )
                if !isEditing, gitOwner.isEmpty, let login = try? await GitHubClient(repo: accountRepo).verifyToken() {
                    await MainActor.run { if gitOwner.isEmpty { gitOwner = login } }
                }
            }
            // Auto-derive the repo name from the display name until the user edits it.
            .onChange(of: name) { _, newValue in
                guard isCreating, !repoEdited else { return }
                gitRepo = slugify(newValue)
            }
            .onChange(of: focusedField) { _, field in
                if field == .repository { repoEdited = true }
            }
            .onChange(of: photoItems) { _, items in
                Task { await loadScreenshot(items) }
            }
            .sheet(isPresented: $showGitHubHelp) {
                GitHubHelpView()
            }
            .overlay {
                if createPhase != .idle { createOverlay }
            }
        }
    }

    private var modePicker: some View {
        Picker("Mode", selection: $mode.animation(Theme.snappy)) {
            Text("Connect existing").tag(Mode.connect)
            Text("Create new").tag(Mode.create)
        }
        .pickerStyle(.segmented)
        // Create mode publishes via GitHub Pages (createSite() only runs the
        // publish step for .githubPages); the connect-mode default is Cloudflare.
        .onChange(of: mode) { _, newMode in
            guard !isEditing else { return }
            if newMode == .create { deployment = .githubPages }
            else { deployment = .cloudflarePages }
        }
    }

    /// Preferred path: dismiss this sheet and open the 4-step Connect wizard.
    private var guidedSetupCard: some View {
        SettingsSection("Guided setup", footer: "Recommended. Sign in, pick a site, connect hosting, choose AI — without filling owner/repo fields.") {
            SettingsButton("Connect Existing Website", systemImage: "sparkles", kind: .primary) {
                dismiss()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                    engine.openConnectWizard(step: .github)
                }
            }
        }
    }

    private var introduction: some View {
        HStack(alignment: .center, spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Theme.brandGradient)
                    .frame(width: 52, height: 52)

                Image(systemName: isEditing ? "square.and.pencil" : (isCreating ? "wand.and.stars" : "folder.badge.plus"))
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .shadow(color: Theme.brand.opacity(0.2), radius: 10, y: 5)

            VStack(alignment: .leading, spacing: 3) {
                Text(isEditing ? "Update your workspace" : (isCreating ? "Create a new website" : "Connect a website"))
                    .font(.ui(20, .bold))
                    .foregroundStyle(CC.text)

                Text(isCreating
                     ? "We'll make a new GitHub repo, add a starter template, and publish it live."
                     : "Link a GitHub repository and set the defaults Website Commander should use.")
                    .font(.ui(14))
                    .foregroundStyle(CC.textSub)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var workspaceSection: some View {
        WorkspaceFormSection(
            title: "Workspace",
            subtitle: "A friendly name shown throughout the app.",
            icon: "rectangle.3.group.fill"
        ) {
            WorkspaceTextField(
                label: "Display name",
                prompt: "My Portfolio",
                icon: "textformat",
                text: $name
            )
            .focused($focusedField, equals: .name)
            .submitLabel(.next)
            .onSubmit { focusedField = .owner }
        }
    }

    private var repositorySection: some View {
        WorkspaceFormSection(
            title: "GitHub Repository",
            subtitle: "Website Commander reads and commits files in this repository.",
            icon: "chevron.left.forwardslash.chevron.right"
        ) {
            VStack(spacing: 0) {
                WorkspaceTextField(
                    label: "Owner or organization",
                    prompt: "github-username",
                    icon: "person.fill",
                    text: $gitOwner
                )
                .focused($focusedField, equals: .owner)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.next)
                .onSubmit { focusedField = .repository }

                WorkspaceDivider()

                WorkspaceTextField(
                    label: "Repository",
                    prompt: "website",
                    icon: "folder.fill",
                    text: $gitRepo
                )
                .focused($focusedField, equals: .repository)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.next)
                .onSubmit { focusedField = .branch }

                WorkspaceDivider()

                WorkspaceTextField(
                    label: "Branch",
                    prompt: "main",
                    icon: "arrow.triangle.branch",
                    text: $gitBranch
                )
                .focused($focusedField, equals: .branch)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.done)
                .onSubmit { focusedField = nil }

                // Connect GitHub here so the agent can actually commit to this
                // repo. Gated on sign-in being configured: the control only ever
                // shows the OAuth button or a provably-writable "connected" state,
                // so it never claims push access it can't back up.
                if GitHubAuth.shared.isConfigured {
                    WorkspaceDivider()
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("Push access")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Spacer()
                            Button {
                                Haptics.tap(); showGitHubHelp = true
                            } label: {
                                Label("How does this work?", systemImage: "questionmark.circle")
                                    .font(.caption.weight(.semibold))
                            }
                        }
                        GitHubSignInView { engine.noteSecretsChanged() }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 13)
                }
            }

            Label(
                canSave ? repositorySlug : "Owner and repository required",
                systemImage: canSave ? "link" : "info.circle"
            )
                .font(.caption.weight(.medium))
                .foregroundStyle(canSave ? Theme.brand : Color.secondary)
                .lineLimit(1)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(
                    (canSave ? Theme.brand.opacity(0.1) : Color.primary.opacity(0.05)),
                    in: Capsule()
                )
                .padding(.horizontal, 14)
                .padding(.bottom, 12)
        }
    }

    private var environmentSection: some View {
        WorkspaceFormSection(
            title: "Build & Deploy",
            subtitle: "These choices help the agent generate compatible changes.",
            icon: "shippingbox.fill"
        ) {
            VStack(spacing: 0) {
                selectionMenu(
                    title: "Tech stack",
                    value: techStack.rawValue,
                    icon: techStackIcon
                ) {
                    ForEach(TechStack.allCases) { stack in
                        Button {
                            techStack = stack
                        } label: {
                            if techStack == stack {
                                Label(stack.rawValue, systemImage: "checkmark")
                            } else {
                                Text(stack.rawValue)
                            }
                        }
                    }
                }

                WorkspaceDivider()

                selectionMenu(
                    title: "Deployment",
                    value: deployment.rawValue,
                    icon: "icloud.and.arrow.up.fill"
                ) {
                    ForEach(DeploymentType.allCases) { target in
                        Button {
                            deployment = target
                        } label: {
                            if deployment == target {
                                Label(target.rawValue, systemImage: "checkmark")
                            } else {
                                Text(target.rawValue)
                            }
                        }
                    }
                }

                WorkspaceDivider()

                // Used to verify a deploy actually went live after a commit, and to
                // open the site from the preview. Optional.
                WorkspaceTextField(
                    label: "Live site URL (optional)",
                    prompt: "https://example.com",
                    icon: "globe",
                    text: $liveURL
                )
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.URL)
            }
        }
    }

    private var agentSection: some View {
        WorkspaceFormSection(
            title: "Agent Defaults",
            subtitle: "Choose the model and add any repository-specific guidance.",
            icon: "sparkles"
        ) {
            selectionMenu(
                title: "Default model",
                // Don't show a perpetual "Loading…" when nothing is actually
                // loading — before a provider key exists the list is just empty.
                value: !defaultModel.isEmpty ? defaultModel
                    : (engine.isRefreshingModels ? "Loading models…" : "Add an AI provider in Settings first"),
                icon: "cpu.fill"
            ) {
                ForEach(engine.availableModels(for: engine.activeProvider), id: \.self) { model in
                    Button {
                        defaultModel = model
                    } label: {
                        if defaultModel == model {
                            Label(model, systemImage: "checkmark")
                        } else {
                            Text(model)
                        }
                    }
                }
            }
            .disabled(engine.availableModels(for: engine.activeProvider).isEmpty)

            WorkspaceDivider()

            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Image(systemName: "text.alignleft")
                        .foregroundStyle(Theme.brand)
                        .frame(width: 22)

                    Text("Workspace instructions")
                        .font(.subheadline.weight(.semibold))

                    Spacer()

                    Text("\(customRules.count)/2000")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.tertiary)
                }

                ZStack(alignment: .topLeading) {
                    if customRules.isEmpty {
                        Text("Brand voice, design rules, framework conventions, or files the agent should avoid...")
                            .font(.subheadline)
                            .foregroundStyle(.tertiary)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 8)
                            .allowsHitTesting(false)
                    }

                    TextEditor(text: $customRules)
                        .focused($focusedField, equals: .rules)
                        .font(.subheadline)
                        .scrollContentBackground(.hidden)
                        .frame(minHeight: 104)
                        .onChange(of: customRules) { _, newValue in
                            if newValue.count > 2000 {
                                customRules = String(newValue.prefix(2000))
                            }
                        }
                }
                .padding(7)
                .background(
                    Color.primary.opacity(0.045),
                    in: RoundedRectangle(cornerRadius: 14, style: .continuous)
                )
            }
            .padding(14)
        }
    }

    private var saveBar: some View {
        Button(action: isCreating ? createSite : saveWorkspace) {
            HStack(spacing: 8) {
                Image(systemName: isCreating ? "wand.and.stars" : (isEditing ? "checkmark" : "plus"))
                Text(isCreating ? "Create Site" : (isEditing ? "Save Changes" : "Add Workspace"))
            }
            .font(.headline)
            .frame(maxWidth: .infinity)
            .frame(height: 50)
        }
        .buttonStyle(.borderedProminent)
        .buttonBorderShape(.roundedRectangle(radius: 15))
        .tint(Theme.brand)
        .disabled(isCreating ? !canCreate : !canSave)
        .padding(.horizontal, 20)
        .padding(.top, 10)
        .padding(.bottom, 8)
        .background(footerBackground)
        .overlay(alignment: .top) {
            Divider()
        }
    }

    private func selectionMenu<Content: View>(
        title: String,
        value: String,
        icon: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        Menu(content: content) {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.brand)
                    .frame(width: 24)

                VStack(alignment: .leading, spacing: 3) {
                    Text(title.localized)
                        .font(.ui(11, .medium))
                        .foregroundStyle(CC.textSub)

                    Text(value)
                        .font(.ui(15, .semibold))
                        .foregroundStyle(CC.text)
                        .lineLimit(1)
                }

                Spacer(minLength: 12)

                Image(systemName: "chevron.up.chevron.down")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
            .padding(.horizontal, 16)
            .padding(.vertical, 13)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(title), \(value)")
    }

    private var techStackIcon: String {
        switch techStack {
        case .vanillaHTML: return "globe"
        case .hugo: return "doc.text.fill"
        case .jekyll: return "book.closed.fill"
        case .nextjs: return "app.window.reference"
        case .astro: return "sparkles"
        case .sveltekit: return "s.square.fill"
        case .eleventy: return "11.square.fill"
        case .custom: return "terminal.fill"
        }
    }

    private func loadWorkspace() {
        if let workspace = editingWorkspace {
            name = workspace.name
            gitOwner = workspace.gitOwner
            gitRepo = workspace.gitRepo
            gitBranch = workspace.gitBranch
            techStack = workspace.techStack
            deployment = workspace.deployment
            defaultModel = workspace.defaultModel
            customRules = workspace.customRules
            liveURL = workspace.deploymentConfig["liveURL"] ?? ""
        } else {
            if engine.workspaces.isEmpty {
                mode = .create
            }
            if defaultModel.isEmpty {
                defaultModel = engine.activeProvider.defaultModel
            }
        }
    }

    private func saveWorkspace() {
        // Preserve any other deploymentConfig keys; set/clear just liveURL.
        var config = editingWorkspace?.deploymentConfig ?? [:]
        let trimmedURL = liveURL.trimmingCharacters(in: .whitespacesAndNewlines)
        config["liveURL"] = trimmedURL.isEmpty ? nil : trimmedURL

        let workspace = SiteWorkspace(
            id: editingWorkspace?.id ?? UUID(),
            name: name.isEmpty ? "\(gitOwner)/\(gitRepo)" : name,
            gitOwner: gitOwner,
            gitRepo: gitRepo,
            gitBranch: gitBranch,
            githubCredentialID: selectedGitHubCredentialID,
            techStack: techStack,
            deployment: deployment,
            defaultModel: defaultModel,
            customRules: customRules,
            deploymentConfig: config
        )
        engine.saveWorkspace(workspace)
        Haptics.success()

        // Connect mode: best-effort auto-detect stack + deploy hints (same as
        // Deploy Integrations "Auto-detect"). Save succeeds even if this fails.
        if !isCreating, engine.hasGitHubToken {
            engine.selectWorkspace(workspace)
            Task { _ = await engine.detectActiveRepositorySettings() }
        }

        dismiss()
    }

    // MARK: - Create mode

    private var githubAccountSection: some View {
        WorkspaceFormSection(
            title: "GitHub account",
            subtitle: "Each website remembers the account it belongs to.",
            icon: "person.crop.circle.badge.checkmark"
        ) {
            VStack(spacing: 12) {
                Picker("GitHub account", selection: $useAnotherGitHubAccount) {
                    Text("Current").tag(false)
                    Text("Add another").tag(true)
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 14)
                .padding(.top, 14)
                .onChange(of: useAnotherGitHubAccount) { _, _ in
                    gitOwner = ""
                    repoEdited = false
                }

                if useAnotherGitHubAccount || !Keychain.hasGitHubToken(credentialID: nil) {
                    GitHubSignInView(
                        style: .card,
                        showsStatus: true,
                        credentialID: selectedGitHubCredentialID
                    ) {
                        Task {
                            let config = RepoConfig(
                                owner: "", name: "", branch: "main",
                                githubCredentialID: selectedGitHubCredentialID
                            )
                            if let login = try? await GitHubClient(repo: config).verifyToken() {
                                await MainActor.run { gitOwner = login }
                            }
                        }
                    }
                    .padding(.horizontal, 14)
                } else {
                    Label("Current GitHub account connected", systemImage: "checkmark.seal.fill")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.green)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 16)
                }

                Text(useAnotherGitHubAccount
                     ? "Sign in to the GitHub account that will own this website."
                     : "Use the GitHub account already connected to Website Commander.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 14)
            }
        }
    }

    private var createBasicsSection: some View {
        WorkspaceFormSection(
            title: "Your site",
            subtitle: "A name and where it lives on GitHub.",
            icon: "rectangle.3.group.fill"
        ) {
            VStack(spacing: 0) {
                WorkspaceTextField(label: "Site name", prompt: "My Portfolio", icon: "textformat", text: $name)
                    .focused($focusedField, equals: .name)
                    .submitLabel(.next)
                    .onSubmit { focusedField = .repository }

                WorkspaceDivider()

                WorkspaceTextField(label: "Repository name", prompt: "my-portfolio", icon: "folder.fill", text: $gitRepo)
                    .focused($focusedField, equals: .repository)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.next)
                    .onSubmit { focusedField = .owner }

                WorkspaceDivider()

                WorkspaceTextField(label: "Owner or organization", prompt: "github-username", icon: "person.fill", text: $gitOwner)
                    .focused($focusedField, equals: .owner)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.done)
                    .onSubmit { focusedField = nil }

                if GitHubAuth.shared.isConfigured {
                    WorkspaceDivider()
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("GitHub access")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Spacer()
                            Button { Haptics.tap(); showGitHubHelp = true } label: {
                                Label("How does this work?", systemImage: "questionmark.circle")
                                    .font(.caption.weight(.semibold))
                            }
                        }
                        GitHubSignInView { engine.noteSecretsChanged() }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 13)
                }
            }

            Label(
                canCreate ? "\(gitOwner)/\(gitRepo)" : "Name and owner required",
                systemImage: canCreate ? "link" : "info.circle"
            )
            .font(.caption.weight(.medium))
            .foregroundStyle(canCreate ? Theme.brand : Color.secondary)
            .lineLimit(1)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background((canCreate ? Theme.brand.opacity(0.1) : Color.primary.opacity(0.05)), in: Capsule())
            .padding(.horizontal, 14)
            .padding(.bottom, 12)
        }
    }

    private var templateSection: some View {
        WorkspaceFormSection(
            title: "Starter template",
            subtitle: "Pick a starting point — the AI can restyle it afterwards.",
            icon: "square.grid.2x2.fill"
        ) {
            VStack(spacing: 0) {
                ForEach(Array(SiteTemplate.all.enumerated()), id: \.element.id) { index, template in
                    Button {
                        Haptics.tap()
                        withAnimation(Theme.snappy) { selectedTemplate = template }
                    } label: {
                        templateRow(template)
                    }
                    .buttonStyle(.plain)

                    if index < SiteTemplate.all.count - 1 { WorkspaceDivider() }
                }
            }
        }
    }

    private func templateRow(_ template: SiteTemplate) -> some View {
        let selected = selectedTemplate.id == template.id
        return HStack(spacing: 12) {
            Image(systemName: template.icon)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Theme.brand)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 3) {
                Text(template.name)
                    .font(.body.weight(.medium))
                    .foregroundStyle(.primary)
                Text(template.tagline)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 12)

            Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                .font(.title3)
                .foregroundStyle(selected ? Theme.brand : Color.secondary.opacity(0.4))
        }
        .contentShape(Rectangle())
        .padding(.horizontal, 16)
        .padding(.vertical, 13)
    }

    private var createDeploySection: some View {
        WorkspaceFormSection(
            title: "Deploy",
            subtitle: "GitHub Pages publishes instantly — no extra account needed.",
            icon: "shippingbox.fill"
        ) {
            VStack(spacing: 0) {
                selectionMenu(title: "Deployment", value: deployment.rawValue, icon: "icloud.and.arrow.up.fill") {
                    ForEach(DeploymentType.allCases) { target in
                        Button {
                            deployment = target
                        } label: {
                            if deployment == target {
                                Label(target.rawValue, systemImage: "checkmark")
                            } else {
                                Text(target.rawValue)
                            }
                        }
                    }
                }

                if deployment != .githubPages {
                    deployNote("Only GitHub Pages is set up automatically. For \(deployment.rawValue), connect your hosting account afterwards in Deploy Integrations.")
                }

                WorkspaceDivider()

                HStack(spacing: 12) {
                    Image(systemName: "lock.fill")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Theme.brand)
                        .frame(width: 24)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Private repository")
                            .font(.body.weight(.medium))
                        Text(deployment == .githubPages
                             ? "GitHub Pages needs a public repo on free plans."
                             : "Only you can see the source code.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 12)
                    Toggle("", isOn: $isPrivate)
                        .labelsHidden()
                        .tint(Theme.brand)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 13)
            }
        }
    }

    private func deployNote(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "info.circle")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(text)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.bottom, 10)
    }

    private var createAISection: some View {
        WorkspaceFormSection(
            title: "Build with AI",
            subtitle: "Optional. Describe your site or attach a screenshot — we'll open the agent to build it after creating.",
            icon: "sparkles"
        ) {
            VStack(spacing: 0) {
                ZStack(alignment: .topLeading) {
                    if aiPrompt.isEmpty {
                        Text("e.g. “a dark portfolio for a photographer named Mesut”")
                            .font(.subheadline)
                            .foregroundStyle(.tertiary)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 16)
                            .allowsHitTesting(false)
                    }
                    TextEditor(text: $aiPrompt)
                        .focused($focusedField, equals: .prompt)
                        .font(.subheadline)
                        .scrollContentBackground(.hidden)
                        .frame(minHeight: 80)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 8)
                }

                WorkspaceDivider()

                PhotosPicker(selection: $photoItems, maxSelectionCount: 1, matching: .images) {
                    HStack(spacing: 12) {
                        Image(systemName: screenshot == nil ? "photo.badge.plus" : "checkmark.circle.fill")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(Theme.brand)
                            .frame(width: 24)
                        Text(screenshot == nil ? "Attach a screenshot to rebuild" : "Screenshot attached — tap to replace")
                            .font(.body.weight(.medium))
                            .foregroundStyle(.primary)
                        Spacer(minLength: 12)
                    }
                    .contentShape(Rectangle())
                    .padding(.horizontal, 16)
                    .padding(.vertical, 13)
                }
                .buttonStyle(.plain)

                if screenshot != nil {
                    WorkspaceDivider()
                    Button {
                        Haptics.tap()
                        screenshot = nil
                        photoItems = []
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "xmark.circle")
                                .font(.subheadline.weight(.semibold))
                                .frame(width: 24)
                            Text("Remove screenshot")
                                .font(.body.weight(.medium))
                            Spacer()
                        }
                        .foregroundStyle(.secondary)
                        .contentShape(Rectangle())
                        .padding(.horizontal, 16)
                        .padding(.vertical, 13)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    // MARK: - Create progress overlay

    @ViewBuilder private var createOverlay: some View {
        ZStack {
            Color.black.opacity(0.45).ignoresSafeArea()
            Group {
                switch createPhase {
                case .idle:
                    EmptyView()
                case .working(let step):
                    overlayCard {
                        ProgressView()
                            .controlSize(.large)
                        Text(step)
                            .font(.headline)
                            .multilineTextAlignment(.center)
                        Text("This usually takes a few seconds.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                case .failed(let message):
                    overlayCard {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.largeTitle)
                            .foregroundStyle(.orange)
                        Text("Couldn't create the site")
                            .font(.headline)
                        Text(message)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                        if GitHubAuth.shared.isConfigured {
                            GitHubSignInView { createSite() }
                        }
                        HStack(spacing: 10) {
                            Button("Cancel") { withAnimation(Theme.snappy) { createPhase = .idle } }
                                .buttonStyle(.bordered)
                            Button("Try Again") { createSite() }
                                .buttonStyle(.borderedProminent)
                                .tint(Theme.brand)
                        }
                    }
                case .done(let info):
                    overlayCard {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.largeTitle)
                            .foregroundStyle(Theme.ok)
                        Text("Site created 🎉")
                            .font(.headline)
                        if info.liveURL.isEmpty {
                            Text("Your repository is ready and selected.")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                        } else {
                            VStack(spacing: 4) {
                                if let liveURL = SiteWorkspace.normalizedLiveURL(info.liveURL) {
                                    Link(info.liveURL, destination: liveURL)
                                        .font(.subheadline.weight(.medium))
                                        .lineLimit(1)
                                } else {
                                    Text(info.liveURL)
                                        .font(.subheadline.weight(.medium))
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                                Text("Publishing… the first build can take a minute.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .multilineTextAlignment(.center)
                        }
                        if info.needsDeploySetup {
                            Text(String(format: String(localized: "create.deploy_hint"), info.deployment.rawValue))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        VStack(spacing: 10) {
                            if info.needsDeploySetup {
                                Button {
                                    Haptics.tap()
                                    engine.requestedTab = .sites
                                    engine.requestedDeploymentSettings = true
                                    dismiss()
                                } label: {
                                    Label("Open Deploy Integrations", systemImage: "shippingbox")
                                        .frame(maxWidth: .infinity)
                                }
                                .buttonStyle(.borderedProminent)
                                .tint(Theme.brand)
                            }
                            if !aiPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || screenshot != nil {
                                Button {
                                    Haptics.tap()
                                    startAIBuild()
                                } label: {
                                    Label("Build with AI", systemImage: "wand.and.stars")
                                        .frame(maxWidth: .infinity)
                                }
                                .buttonStyle(.borderedProminent)
                                .tint(Theme.brand)
                            }
                            Button("Done") {
                                Haptics.tap()
                                dismiss()
                            }
                            .buttonStyle(.bordered)
                            .frame(maxWidth: .infinity)
                        }
                    }
                }
            }
        }
        .transition(.opacity)
    }

    private func overlayCard<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(spacing: 14) { content() }
            .padding(24)
            .frame(maxWidth: 320)
            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            .padding(.horizontal, 32)
    }

    // MARK: - Create actions

    private func createSite() {
        let owner = gitOwner.trimmingCharacters(in: .whitespacesAndNewlines)
        let repoName = slugify(gitRepo)
        guard !owner.isEmpty, !repoName.isEmpty else { return }
        let template = selectedTemplate
        let deploy = deployment
        let siteName = name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? repoName : name
        let makePrivate = isPrivate
        let model = defaultModel.isEmpty ? engine.activeProvider.defaultModel : defaultModel
        let rules = customRules

        focusedField = nil
        Haptics.tap()
        withAnimation(Theme.snappy) { createPhase = .working("Creating repository…") }

        Task {
            do {
                let creator = GitHubClient(repo: RepoConfig(
                    owner: owner, name: repoName, branch: "main",
                    githubCredentialID: selectedGitHubCredentialID
                ))
                let (branch, _) = try await creator.createRepo(owner: owner, name: repoName, isPrivate: makePrivate)

                await MainActor.run { createPhase = .working("Adding starter files…") }
                let client = GitHubClient(repo: RepoConfig(
                    owner: owner, name: repoName, branch: branch,
                    githubCredentialID: selectedGitHubCredentialID
                ))
                var fileMap = template.files(siteName: siteName)
                if deploy != .githubPages {
                    for (path, content) in HostConfigFiles.files(deployment: deploy, techStack: template.techStack) {
                        fileMap[path] = content
                    }
                    if deploy == .cloudflareWorkers {
                        fileMap["README.md"] = HostConfigFiles.workersReadme(siteName: siteName)
                    }
                }
                let changes = fileMap.map {
                    GitHubClient.FileChange(path: $0.key, kind: .write(content: $0.value))
                }
                let hostNote = deploy != .githubPages && !HostConfigFiles.files(deployment: deploy, techStack: template.techStack).isEmpty
                    ? " with \(deploy.rawValue) config"
                    : (deploy == .cloudflareWorkers ? " with Workers README" : "")
                _ = try await client.commitBatch(changes, message: "Initial \(template.name) site\(hostNote) (Website Commander)")

                var liveURLValue = ""
                if deploy == .githubPages {
                    await MainActor.run { createPhase = .working("Publishing with GitHub Pages…") }
                    // Best-effort: a Pages failure (e.g. private repo on a free plan)
                    // shouldn't lose the repo we just built — the site still exists.
                    liveURLValue = (try? await client.enablePages(owner: owner, name: repoName, branch: branch)) ?? ""
                }

                var config: [String: String] = [:]
                if !liveURLValue.isEmpty { config["liveURL"] = liveURLValue }
                if let build = HostConfigFiles.buildSettings(for: template.techStack).command {
                    config["buildCommand"] = build
                }
                let outputDir = HostConfigFiles.buildSettings(for: template.techStack).publish
                if outputDir != "." { config["outputDirectory"] = outputDir }
                let workspace = SiteWorkspace(
                    name: siteName, gitOwner: owner, gitRepo: repoName, gitBranch: branch,
                    githubCredentialID: selectedGitHubCredentialID,
                    techStack: template.techStack, deployment: deploy,
                    defaultModel: model, customRules: rules, deploymentConfig: config
                )
                let repo = RepoConfig(
                    owner: owner, name: repoName, branch: branch,
                    githubCredentialID: selectedGitHubCredentialID
                )
                let needsDeploySetup = deploy != .githubPages
                    && DeploymentClientFactory.client(for: workspace, repo: repo) == nil
                    && DeploymentClientFactory.deployHookURL(for: workspace) == nil

                await MainActor.run {
                    engine.saveWorkspace(workspace)
                    engine.selectWorkspace(workspace)
                    Haptics.success()
                    withAnimation(Theme.snappy) {
                        createPhase = .done(CreateDoneInfo(
                            liveURL: liveURLValue,
                            deployment: deploy,
                            needsDeploySetup: needsDeploySetup
                        ))
                    }
                }
            } catch {
                let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                await MainActor.run {
                    Haptics.error()
                    withAnimation(Theme.snappy) { createPhase = .failed(message) }
                }
            }
        }
    }

    /// Hand the new site off to the chat agent: prefill the prompt (and screenshot)
    /// so the user reviews before sending — same "no surprise spend" flow the rest
    /// of the app uses.
    private func startAIBuild() {
        let trimmed = aiPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        if let shot = screenshot {
            engine.prefilledAttachments = [shot]
            engine.prefilledPrompt = trimmed.isEmpty
                ? "Rebuild this screenshot as a responsive static website, editing the starter files."
                : trimmed
        } else {
            engine.prefilledPrompt = trimmed.isEmpty
                ? "Improve this starter site: refine the content, layout, and styling."
                : trimmed
        }
        engine.requestedTab = .agent
        dismiss()
    }

    private func loadScreenshot(_ items: [PhotosPickerItem]) async {
        guard let item = items.first,
              let data = try? await item.loadTransferable(type: Data.self) else { return }
        let type = item.supportedContentTypes.first
        let ext = type?.preferredFilenameExtension ?? "png"
        let mime = type?.preferredMIMEType ?? "image/png"
        await MainActor.run {
            screenshot = Attachment(filename: "screenshot.\(ext)", mimeType: mime, data: data)
            photoItems = []
            Haptics.tap()
        }
    }

    /// GitHub-safe repo slug: ASCII alphanumerics, hyphen-separated, no doubles.
    private func slugify(_ raw: String) -> String {
        let mapped = raw.lowercased().map { ch -> Character in
            (ch.isASCII && (ch.isLetter || ch.isNumber)) ? ch : "-"
        }
        var slug = String(mapped)
        while slug.contains("--") { slug = slug.replacingOccurrences(of: "--", with: "-") }
        return slug.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }
}

private struct WorkspaceFormSection<Content: View>: View {
    let title: String
    let subtitle: String
    let icon: String
    @ViewBuilder let content: Content

    init(
        title: String,
        subtitle: String,
        icon: String,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.subtitle = subtitle
        self.icon = icon
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(CC.accent)
                    .frame(width: 28, height: 28)
                    .background(CC.accentDim, in: RoundedRectangle(cornerRadius: 9, style: .continuous))

                VStack(alignment: .leading, spacing: 2) {
                    Text(title.localized)
                        .font(.ui(16, .bold))
                        .foregroundStyle(CC.text)

                    Text(subtitle.localized)
                        .font(.ui(12))
                        .foregroundStyle(CC.textSub)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.horizontal, 4)

            VStack(spacing: 0) {
                content
            }
            .commandCard(cornerRadius: 18)
        }
    }
}

private struct WorkspaceTextField: View {
    let label: String
    let prompt: String
    let icon: String
    @Binding var text: String

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Theme.brand)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 3) {
                Text(label.localized)
                    .font(.ui(11, .medium))
                    .foregroundStyle(CC.textSub)

                TextField(prompt.localized, text: $text)
                    .font(.ui(15, .medium))
                    .foregroundStyle(CC.text)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 13)
    }
}

private struct WorkspaceDivider: View {
    var body: some View {
        Divider()
            .padding(.leading, 52)
    }
}
