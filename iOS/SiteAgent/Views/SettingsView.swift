import SwiftUI
import UIKit

private enum AppIconChoice: String, CaseIterable, Identifiable, Sendable {
    case grey
    case original
    case black
    case beige

    var id: Self { self }

    var alternateIconName: String? {
        switch self {
        case .grey: nil
        case .original: "AppIcon-Original"
        case .black: "AppIcon-Black"
        case .beige: "AppIcon-Beige"
        }
    }

    var previewAssetName: String {
        switch self {
        case .grey: "AppIconPreviewGrey"
        case .original: "AppIconPreviewOriginal"
        case .black: "AppIconPreviewBlack"
        case .beige: "AppIconPreviewBeige"
        }
    }

    var label: LocalizedStringResource {
        switch self {
        case .grey: "Grey"
        case .original: "Original"
        case .black: "Black"
        case .beige: "Beige"
        }
    }

    static func current(alternateIconName: String?) -> Self {
        allCases.first { $0.alternateIconName == alternateIconName } ?? .grey
    }
}

private struct AppIconPicker: View {
    @State private var selectedIcon: AppIconChoice = .grey
    @State private var changingIcon: AppIconChoice?
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("App icon")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 68), spacing: 10)],
                spacing: 10
            ) {
                ForEach(AppIconChoice.allCases) { icon in
                    Button {
                        select(icon)
                    } label: {
                        VStack(spacing: 7) {
                            ZStack {
                                Image(icon.previewAssetName)
                                    .resizable()
                                    .scaledToFill()
                                    .frame(width: 56, height: 56)
                                    .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))

                                if changingIcon == icon {
                                    RoundedRectangle(cornerRadius: 13, style: .continuous)
                                        .fill(.black.opacity(0.28))
                                        .frame(width: 56, height: 56)
                                    ProgressView()
                                        .tint(.white)
                                }
                            }
                            .overlay(alignment: .topTrailing) {
                                if selectedIcon == icon {
                                    Image(systemName: "checkmark.circle.fill")
                                        .font(.body.weight(.bold))
                                        .foregroundStyle(.white, Theme.brand)
                                        .background(.background, in: Circle())
                                        .offset(x: 5, y: -5)
                                }
                            }

                            Text(icon.label)
                                .font(.caption.weight(selectedIcon == icon ? .semibold : .regular))
                                .foregroundStyle(selectedIcon == icon ? Theme.brand : .primary)
                                .lineLimit(1)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .background(
                            selectedIcon == icon ? Theme.brand.opacity(0.10) : Theme.chip,
                            in: RoundedRectangle(cornerRadius: 14, style: .continuous)
                        )
                        .overlay {
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .strokeBorder(
                                    selectedIcon == icon ? Theme.brand.opacity(0.55) : Theme.separator,
                                    lineWidth: 1
                                )
                        }
                        .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .disabled(changingIcon != nil || !UIApplication.shared.supportsAlternateIcons)
                    .accessibilityLabel(Text(icon.label))
                    .accessibilityAddTraits(selectedIcon == icon ? .isSelected : [])
                }
            }

            if !UIApplication.shared.supportsAlternateIcons {
                Text("Alternate app icons are not available on this device.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
        .padding(.vertical, 10)
        .task {
            selectedIcon = AppIconChoice.current(
                alternateIconName: UIApplication.shared.alternateIconName
            )
        }
    }

    private func select(_ icon: AppIconChoice) {
        guard UIApplication.shared.supportsAlternateIcons,
              icon != selectedIcon,
              changingIcon == nil else { return }

        errorMessage = nil
        changingIcon = icon
        Haptics.tap()

        Task { @MainActor in
            do {
                try await UIApplication.shared.setAlternateIconName(icon.alternateIconName)
                selectedIcon = icon
                Haptics.success()
            } catch {
                errorMessage = "Could not change the app icon: \(error.localizedDescription)"
            }
            changingIcon = nil
        }
    }
}

struct DeploymentSettingsRoute: Identifiable, Hashable {
    let workspaceID: UUID

    var id: UUID { workspaceID }
}

struct SettingsView: View {
    @EnvironmentObject var engine: AgentEngine
    @ObservedObject private var iap = IAPManager.shared
    @AppStorage("hasCompletedOnboarding") var hasCompletedOnboarding: Bool = false

    // Secrets are mirrored into @State for editing, then written to Keychain.
    @State private var githubToken = ""
    @State private var anthropicKey = ""
    @State private var deepseekKey = ""
    @State private var openaiKey = ""
    @State private var grokKey = ""
    @State private var mistralKey = ""
    @State private var geminiKey = ""
    @State private var opencodeKey = ""
    @State private var openrouterKey = ""
    @State private var groqKey = ""
    @State private var qwenCodeKey = ""
    @State private var kimiCodeKey = ""
    @State private var longcatKey = ""
    @State private var customKey = ""

    @State private var verifyResult: String?
    @State private var verifying = false
    @State private var showPaywall = false
    @State private var paywallContext: PaywallContext = .general
    @State private var showGitHubHelp = false
    @State private var showManualGitHubToken = false
    @State private var showAdvancedBehavior = false
    @State private var restoreBusy = false
    /// Surfaced when a Keychain write fails (previously silent).
    @State private var keychainError: String?

    // GitHub Copilot device-flow sign-in state.
    private let copilot = CopilotAuth.shared
    @State private var copilotDevice: CopilotAuth.DeviceCode?
    @State private var copilotBusy = false
    @State private var copilotError: String?

    // Claude / OpenAI OAuth sign-in state.
    @State private var oauthBusyID: String?
    @State private var oauthError: String?
    @State private var oauthNeedsReAuth: Set<String> = []

    // GitHub *push* sign-in (OAuth device flow → repo-scoped token).
    private let gitHubAuth = GitHubAuth.shared

    @State private var showAddWorkspace = false
    @State private var showConnectWizard = false
    @State private var editingWorkspace: SiteWorkspace? = nil
    @State private var pendingDelete: SiteWorkspace? = nil
    @State private var showAssistantEditor = false
    @State private var deploymentSettingsRoute: DeploymentSettingsRoute?
    @State private var showRepositoryEditor = false
    @State private var showModelPicker = false

    /// Yearly-vs-monthly saving, for the "switch to yearly" upsell. nil until
    /// both products load.
    private var yearlySavingsPct: Int? {
        guard let y = iap.product(for: IAPManager.ProductID.yearly),
              let m = iap.product(for: IAPManager.ProductID.monthly) else { return nil }
        let yearOfMonthly = m.price * 12
        guard yearOfMonthly > 0 else { return nil }
        // NSDecimalNumber.intValue truncates a long-mantissa Decimal to 0; go via
        // Double so 49.79… → 49 instead of vanishing.
        let pct = Int(NSDecimalNumber(decimal: (1 - y.price / yearOfMonthly) * 100).doubleValue)
        return pct > 0 ? pct : nil
    }

    private var ownerBinding: Binding<String> {
        Binding(
            get: { MainActor.assumeIsolated { engine.activeWorkspace?.gitOwner ?? "" } },
            set: { newValue in
                MainActor.assumeIsolated {
                    if var ws = engine.activeWorkspace { ws.gitOwner = newValue; engine.saveWorkspace(ws) }
                }
            }
        )
    }

    private var repoBinding: Binding<String> {
        Binding(
            get: { MainActor.assumeIsolated { engine.activeWorkspace?.gitRepo ?? "" } },
            set: { newValue in
                MainActor.assumeIsolated {
                    if var ws = engine.activeWorkspace { ws.gitRepo = newValue; engine.saveWorkspace(ws) }
                }
            }
        )
    }

    private var branchBinding: Binding<String> {
        Binding(
            get: { MainActor.assumeIsolated { engine.activeWorkspace?.gitBranch ?? "" } },
            set: { newValue in
                MainActor.assumeIsolated {
                    if var ws = engine.activeWorkspace { ws.gitBranch = newValue; engine.saveWorkspace(ws) }
                }
            }
        )
    }

    private var workspaceStatus: WorkspaceStatus { engine.workspaceStatus }

    var body: some View {
        NavigationStack {
            ScrollView {
                workspaceScrollContent
                    .padding(.horizontal, 16)
                    .padding(.vertical, 14)
                    .readableWidth(640)
            }
            .scrollDismissesKeyboard(.interactively)
            .commandBackground()
            .navigationTitle("Workspace")
            .accessibilityLabel("Settings")
            .onAppear {
                loadSecrets()
                reconcileProviderAccess()
                applyWorkspaceFocus()
                Task { await refreshOAuthStatus() }
            }
            .onChange(of: engine.requestedWorkspaceFocus) { _, _ in applyWorkspaceFocus() }
            .onChange(of: iap.isPro) { _, _ in reconcileProviderAccess() }
            .sheet(isPresented: $showPaywall) { ProPaywall(context: paywallContext) }
            .sheet(isPresented: $showAddWorkspace) { AddWorkspaceSheet().environmentObject(engine) }
            .sheet(isPresented: $showConnectWizard) { ConnectWebsiteWizardView().environmentObject(engine) }
            .sheet(item: $editingWorkspace) { ws in AddWorkspaceSheet(editingWorkspace: ws).environmentObject(engine) }
            .sheet(isPresented: $showGitHubHelp) { GitHubHelpView() }
            .sheet(isPresented: $showAssistantEditor) { assistantEditorSheet }
            // Settings itself is already a sheet. Pushing a navigation
            // destination from a button inside that sheet crashes on current
            // iOS. Present deployment as a nested sheet instead.
            .sheet(item: $deploymentSettingsRoute) { route in
                NavigationStack {
                    DeploymentSettingsView(
                        engine: engine,
                        workspaceID: route.workspaceID,
                        simpleMode: true
                    )
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Done") { deploymentSettingsRoute = nil }
                        }
                    }
                }
            }
            .sheet(isPresented: $showRepositoryEditor) { repositoryEditorSheet }
            .sheet(isPresented: $showModelPicker) {
                ChatModelPickerSheet { provider, model in
                    if !iap.isPro && AgentEngine.proOnlyProviderIDs.contains(provider.id) {
                        paywallContext = .premiumModel
                        showPaywall = true
                        return
                    }
                    Haptics.tap()
                    engine.smartRoutingEnabled = false
                    engine.activeProviderID = provider.id
                    engine.selectedModel = model
                    Task { await engine.refreshActiveProviderModels() }
                }
                .environmentObject(engine)
            }
            .confirmationDialog("Delete “\(pendingDelete?.name ?? "")”?",
                                isPresented: Binding(get: { pendingDelete != nil },
                                                     set: { if !$0 { pendingDelete = nil } }),
                                titleVisibility: .visible, presenting: pendingDelete) { ws in
                Button("Delete", role: .destructive) {
                    Haptics.error()
                    engine.deleteWorkspace(ws.id)
                }
                Button("Cancel", role: .cancel) {}
            } message: { _ in
                Text("Removes only Website Commander's connection to this site. Your GitHub repository and deployed site are untouched.")
            }
        }
    }

    @ViewBuilder
    private var workspaceScrollContent: some View {
        VStack(spacing: 20) {
            if let keychainError {
                Text(keychainError)
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
                    .background(Color.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            }

            workspaceGoalCards

            if !engine.workspaces.isEmpty {
                workspaceSwitcherSection
            }

            advancedWorkspaceSection
                .id(AgentEngine.WorkspaceFocusTarget.advanced.rawValue)

            tokenUsageSection
            appearanceSection
            behaviorSection
            legalStoreSection
            disclaimerSection
            aboutFooter

            #if DEBUG
            debugSection
            #endif
        }
    }

    @ViewBuilder
    private var workspaceGoalCards: some View {
        WebsiteSummaryCard(
            status: workspaceStatus,
            onEdit: {
                if let ws = engine.activeWorkspace {
                    editingWorkspace = ws
                } else {
                    showConnectWizard = true
                }
            },
            onConnect: { showConnectWizard = true }
        )
        .id(AgentEngine.WorkspaceFocusTarget.website.rawValue)

        ConnectionStatusCard(
            status: workspaceStatus,
            verifying: verifying,
            verifyResult: verifyResult,
            onVerify: { Task { await verifyToken() } },
            onFixGitHub: { showRepositoryEditor = true },
            onFixAssistant: { showAssistantEditor = true },
            onFixDeployment: { presentDeploymentSettings() }
        )
        .id(AgentEngine.WorkspaceFocusTarget.status.rawValue)

        AssistantSummaryCard(
            displayName: workspaceStatus.assistantDisplayName,
            modelLabel: engine.usingOnDevice ? "On-device" : engine.selectedModel,
            onChange: { showAssistantEditor = true }
        )
        .id(AgentEngine.WorkspaceFocusTarget.assistant.rawValue)

        DeploymentSummaryCard(
            status: workspaceStatus,
            onConfigure: { presentDeploymentSettings() }
        )
        .id(AgentEngine.WorkspaceFocusTarget.deployment.rawValue)
    }

    private var assistantEditorSheet: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) { aiSection }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 14)
                    .readableWidth(640)
            }
            .scrollDismissesKeyboard(.interactively)
            .commandBackground()
            .navigationTitle("Assistant")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { showAssistantEditor = false }
                }
            }
        }
    }

    private var repositoryEditorSheet: some View {
        NavigationStack {
            advancedRepositoryDestination
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { showRepositoryEditor = false }
                    }
                }
        }
    }

    private func applyWorkspaceFocus() {
        if let route = engine.requestedWorkspaceRoute {
            switch route {
            case .assistant: showAssistantEditor = true
            case .deployment: presentDeploymentSettings()
            case .repositoryAdvanced, .website, .github: showRepositoryEditor = true
            case .secrets:
                showRepositoryEditor = true
            case .status: break
            }
            engine.requestedWorkspaceRoute = nil
            engine.requestedWorkspaceFocus = nil
            return
        }
        guard let focus = engine.requestedWorkspaceFocus else { return }
        switch focus {
        case .assistant: showAssistantEditor = true
        case .deployment: presentDeploymentSettings()
        case .advanced, .website, .github, .secrets: showRepositoryEditor = true
        case .status: break
        }
        engine.requestedWorkspaceFocus = nil
    }

    private func presentDeploymentSettings() {
        guard let workspaceID = engine.activeWorkspace?.id else {
            // The Connect Deployment button is also visible on a fresh
            // workspace. Route that state into the existing setup flow rather
            // than silently doing nothing or constructing a sheet without a
            // workspace.
            showConnectWizard = true
            return
        }
        deploymentSettingsRoute = DeploymentSettingsRoute(workspaceID: workspaceID)
    }

    // MARK: - Workspace switcher (multi-site)

    private var workspaceSwitcherSection: some View {
        SettingsSection("Your Websites") {
            ForEach(Array(engine.workspaces.enumerated()), id: \.element.id) { index, ws in
                if index > 0 { SettingsDivider() }
                workspaceRow(ws)
            }
            SettingsDivider()
            SettingsButton("Add Website", systemImage: "plus.circle", kind: .secondary) {
                showConnectWizard = true
            }
        }
    }

    // MARK: - Advanced (repo, secrets, GitHub details)

    private var advancedWorkspaceSection: some View {
        SettingsSection("Advanced", footer: "Repository details, API keys, and developer tools. Most people never need these.") {
            navRow("Repository", systemImage: "internaldrive", trailing: engine.activeWorkspace?.slug) {
                advancedRepositoryDestination
            }
            SettingsDivider()
            navRow("Secrets & API Keys", systemImage: "key.horizontal") {
                allProvidersDestination
            }
            SettingsDivider()
            navRow("Developer Tools", systemImage: "wrench.and.screwdriver",
                   trailing: engine.activeWorkspace?.deployment.rawValue ?? "No site") {
                DeploymentSettingsView(engine: engine, simpleMode: false)
            }
            SettingsDivider()
            navRow("Extensibility", systemImage: "point.3.connected.trianglepath.dotted") {
                ExtensibilityView()
            }
            SettingsDivider()
            navRow("Workspace & Portability", systemImage: "externaldrive.connected.to.line.below") {
                WorkspacePortabilityView()
            }
            SettingsDivider()
            SettingsButton("Add website (templates)", systemImage: "square.stack.3d.up", kind: .secondary) {
                showAddWorkspace = true
            }
        }
    }

    private var advancedRepositoryDestination: some View {
        ScrollView {
            VStack(spacing: 20) {
                githubSection
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .readableWidth(640)
        }
        .scrollDismissesKeyboard(.interactively)
        .commandBackground()
        .navigationTitle("Repository")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func workspaceRow(_ ws: SiteWorkspace) -> some View {
        HStack {
            Button {
                Haptics.tap()
                withAnimation(Theme.snappy) { engine.selectWorkspace(ws) }
            } label: {
                HStack {
                    Image(systemName: engine.activeWorkspace?.id == ws.id ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(engine.activeWorkspace?.id == ws.id ? Theme.brand : .secondary)
                        .contentTransition(.symbolEffect(.replace))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(ws.name).fontWeight(.bold)
                        Text("\(ws.slug) (\(ws.techStack.rawValue))").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.primary)

            Button {
                Haptics.tap(); editingWorkspace = ws
            } label: {
                Image(systemName: "info.circle").foregroundStyle(Theme.brand)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Edit \(ws.name)")
        }
        .padding(.vertical, 10)
        .contextMenu {
            Button { editingWorkspace = ws } label: { Label("Edit", systemImage: "pencil") }
            Button(role: .destructive) { Haptics.tap(); pendingDelete = ws } label: { Label("Delete", systemImage: "trash") }
        }
    }

    // MARK: - 5. AI Model (provider + model + credential, all in one place)

    private var aiSection: some View {
        SettingsSection("Assistant", footer: "Pick which AI runs the agent and sign in right here. API keys for other providers live under Advanced → Secrets.") {
            if !iap.isPro {
                HStack {
                    Image(systemName: "lock.fill").foregroundStyle(.yellow)
                    Text("Free tier includes GitHub Copilot and OpenRouter Free. Other cloud providers require Super.")
                        .font(.footnote).foregroundStyle(.secondary)
                    Spacer()
                    Button("Unlock") { Haptics.tap(); paywallContext = .premiumModel; showPaywall = true }
                        .font(.footnote.weight(.semibold))
                }
                .padding(.vertical, 10)
                SettingsDivider()
            }

            Toggle("Enable Smart Auto-Routing", isOn: $engine.smartRoutingEnabled)
                .disabled(!iap.isPro)
                .padding(.vertical, 8)

            if engine.smartRoutingEnabled && iap.isPro {
                SettingsDivider()
                Picker("Routing Strategy", selection: $engine.routingStrategy) {
                    ForEach(RoutingStrategy.allCases) { strat in Text(strat.rawValue).tag(strat) }
                }
                .padding(.vertical, 6)
                SettingsDivider()
                navRow("Configure Smart Routing", systemImage: "slider.horizontal.3") {
                    smartRoutingDestination
                }
            } else {
                SettingsDivider()
                Picker("Active provider", selection: providerSelection) {
                    ForEach(engine.availableProviders, id: \.id) { p in
                        HStack {
                            Text(p.displayName)
                            if !iap.isPro && AgentEngine.proOnlyProviderIDs.contains(p.id) {
                                Image(systemName: "lock.fill").font(.caption2).foregroundStyle(.yellow)
                            }
                        }
                        .tag(p.id)
                    }
                }
                .padding(.vertical, 6)

                providerDetail   // model picker + the selected provider's credential
            }

            SettingsDivider()
            navRow("All providers & keys", systemImage: "key.horizontal") {
                allProvidersDestination
            }
        }
        .task(id: "\(engine.activeProviderID)#\(engine.secretsRevision)") {
            await engine.refreshActiveProviderModels(force: true)
        }
    }

    private var smartRoutingDestination: some View {
        List {
            Section {
                Picker("Routing goal", selection: $engine.routingStrategy) {
                    ForEach(RoutingStrategy.allCases) { strategy in
                        Text(strategy.rawValue).tag(strategy)
                    }
                }
            } footer: {
                Text("Quality favors deeper reasoning, Code favors implementation strength, and Budget favors fast, economical models.")
            }

            Section {
                ForEach(engine.availableProviders.filter {
                    AgentEngine.smartRoutingProviderIDs.contains($0.id)
                        && engine.isProviderConnectedForSmartRouting($0.id)
                }, id: \.id) { provider in
                    VStack(alignment: .leading, spacing: 8) {
                        Toggle(provider.displayName, isOn: Binding(
                            get: { engine.isProviderAllowedForSmartRouting(provider.id) },
                            set: { engine.setProviderAllowedForSmartRouting(provider.id, allowed: $0) }
                        ))

                        if engine.isProviderAllowedForSmartRouting(provider.id) {
                            Picker("Preferred model", selection: Binding(
                                get: { engine.preferredSmartRoutingModel(for: provider) },
                                set: { engine.setPreferredSmartRoutingModel($0, for: provider.id) }
                            )) {
                                ForEach(engine.availableModels(for: provider), id: \.self) {
                                    Text($0).tag($0)
                                }
                            }
                            .pickerStyle(.menu)
                            .font(.subheadline)
                        }
                    }
                    .padding(.vertical, 3)
                }

                if engine.hasCustomSmartRoutingProviders {
                    Button("Use All Connected Providers") {
                        Haptics.tap()
                        engine.resetSmartRoutingProviders()
                    }
                }
            } header: {
                Text("Allowed Providers")
            } footer: {
                Text("Only connected providers with a valid sign-in or API key can be selected. Image prompts automatically stay on models that support images.")
            }
        }
        .navigationTitle("Smart Routing")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            await engine.refreshAllProviderModels(force: true)
        }
    }

    /// Model selection + the credential for the *currently selected* provider,
    /// shown inline so "which AI" and "how to authenticate it" live together.
    @ViewBuilder private var providerDetail: some View {
        if engine.usingOnDevice {
            // On-device: the model list IS the picker — selecting an undownloaded
            // model downloads it right here (no separate menu). Model choice +
            // download + delete all happen in this list.
            SettingsDivider()
            OnDeviceModelList()
            SettingsDivider()
            navRow("On-Device status & storage", systemImage: "cpu", trailing: onDeviceStatusLabel) {
                OnDeviceSettingsView()
            }
        } else {
            SettingsDivider()
            SettingsButton(
                engine.selectedModel,
                systemImage: "sparkles",
                kind: .secondary
            ) {
                showModelPicker = true
            }
            .disabled(!iap.isPro && engine.isCurrentProviderProOnly)
            .id(engine.activeProviderID)
            if engine.activeModelCapability.supportsReasoningPreference {
                Picker("Effort", selection: $engine.reasoningPreference) {
                    ForEach(ReasoningPreference.allCases) { preference in
                        Text(preference.rawValue).tag(preference)
                    }
                }
                .padding(.vertical, 6)
            }

            // Refresh only for providers with a remote catalog (the Apple FM models
            // are a fixed list, so the network-flavoured refresh would be a no-op).
            if !engine.activeProviderID.hasPrefix("apple") {
                SettingsDivider()
                if engine.isRefreshingModels {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Updating model list…").font(.caption).foregroundStyle(.secondary)
                        Spacer()
                    }
                    .padding(.vertical, 12)
                } else {
                    SettingsButton("Refresh model list", systemImage: "arrow.clockwise", kind: .secondary) {
                        Task { await engine.refreshActiveProviderModels(force: true) }
                    }
                    .disabled(!engine.hasProviderKey)
                }
            }

            SettingsDivider()
            selectedProviderCredential
        }
    }

    /// The sign-in / key field for the active provider only.
    @ViewBuilder private var selectedProviderCredential: some View {
        switch engine.activeProviderID {
        case "copilot":  copilotControls
        case "custom":   customControls
        case "anthropic": oauthKeySection("Claude (Anthropic)", signInLabel: "Sign in with Claude",
                                          text: $anthropicKey, id: "anthropic",
                                          getURL: "https://console.anthropic.com/settings/keys")
        case "deepseek": keyRow("DeepSeek", text: $deepseekKey, id: "deepseek", getURL: "https://platform.deepseek.com/api_keys")
        case "opencode": keyRow("OpenCode Go", text: $opencodeKey, id: "opencode", getURL: "https://opencode.ai/zen", note: "Use the API key shown after subscribing to OpenCode Go; an OpenAI platform key will not work.")
        case "openai":   oauthKeySection("OpenAI", signInLabel: "Sign in with OpenAI",
                                          text: $openaiKey, id: "openai",
                                          getURL: "https://platform.openai.com/api-keys")
        case "grok":     keyRow("Grok (xAI)", text: $grokKey, id: "grok", getURL: "https://console.x.ai")
        case "mistral":  keyRow("Mistral", text: $mistralKey, id: "mistral", getURL: "https://console.mistral.ai/api-keys")
        case "openrouter-free": keyRow("OpenRouter Free", text: $openrouterKey, id: "openrouter", getURL: "https://openrouter.ai/keys")
        case "openrouter": keyRow("OpenRouter", text: $openrouterKey, id: "openrouter", getURL: "https://openrouter.ai/keys")
        case "groq":     keyRow("Groq", text: $groqKey, id: "groq", getURL: "https://console.groq.com/keys")
        case "qwen-code": keyRow("Qwen Token / Coding Plan", text: $qwenCodeKey, id: "qwen-code", getURL: "https://modelstudio.console.alibabacloud.com/")
        case "kimi-code": keyRow("Kimi Code", text: $kimiCodeKey, id: "kimi-code", getURL: "https://www.kimi.com/code/console")
        case "longcat": keyRow("LongCat", text: $longcatKey, id: "longcat", getURL: "https://longcat.chat/platform")
        case "gemini":   keyRow("Gemini (Google)", text: $geminiKey, id: "gemini", getURL: "https://aistudio.google.com/app/apikey")
        default:
            EmptyView()
            #if APPLE_FM
            if engine.activeProviderID.hasPrefix("apple") { appleStatusInline }
            #endif
        }
    }

    /// The full key list + custom provider, reachable from the AI section so keys
    /// for providers you haven't selected are still editable.
    private var allProvidersDestination: some View {
        ScrollView {
            VStack(spacing: 20) {
                keysSection
                customSection
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .readableWidth(640)
        }
        .scrollDismissesKeyboard(.interactively)
        .commandBackground()
        .navigationTitle("Providers & Keys")
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: - 4. GitHub Repository

    private var githubSection: some View {
        SettingsSection("Repository", footer: gitHubAuth.isConfigured
            ? "Sign in with GitHub for write access, or paste a classic token with the “repo” scope under Advanced."
            : "Use a classic Personal Access Token with the “repo” scope.\(engine.activeWorkspace == nil ? " Connect a website first." : "")") {
            labeledField("Owner", text: ownerBinding, placeholder: "owner")
            SettingsDivider()
            labeledField("Repo", text: repoBinding, placeholder: "repository")
            SettingsDivider()
            labeledField("Branch", text: branchBinding, placeholder: "main")
            SettingsDivider()
            Button { Haptics.tap(); showGitHubHelp = true } label: {
                Label("How to connect GitHub", systemImage: "questionmark.circle")
                    .font(.footnote.weight(.semibold))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 10)
            }
            SettingsDivider()
            GitHubSignInView(showsStatus: false) {
                githubToken = Keychain.get(Keychain.githubToken) ?? ""
                engine.noteSecretsChanged()
                Task { await verifyToken() }
            }
            .padding(.vertical, 4)
            SettingsDivider()
            DisclosureGroup("Advanced: manual token", isExpanded: $showManualGitHubToken) {
                secureRow("GitHub token", text: $githubToken) {
                    guard case .store(let token) = Keychain.commitAction(for: githubToken) else { return }
                    let ok = Keychain.set(token, for: Keychain.githubToken)
                        && Keychain.set("manual", for: Keychain.githubTokenSource)
                    keychainError = ok ? nil : "Could not save GitHub token to Keychain."
                    if ok { Task { await verifyToken() } }
                    engine.noteSecretsChanged()
                }
                if let tokenURL = URL(string: "https://github.com/settings/tokens/new?scopes=repo&description=Website%20Commander") {
                    Link(destination: tokenURL) {
                        Label("Create a token (classic, with “repo”)", systemImage: "arrow.up.forward.app").font(.footnote)
                    }
                    .padding(.top, 4)
                }
            }
            .tint(Theme.brand)
            .padding(.vertical, 8)
            SettingsButton("Verify Connection", systemImage: "checkmark.shield", kind: .secondary, loading: verifying) {
                Task { await verifyToken() }
            }
            .disabled(verifying)
            if let r = verifyResult {
                SettingsBanner(message: r, ok: r.hasPrefix("✓"), errorTint: .red)
            }
        }
    }

    // MARK: - GitHub Copilot (inline credential, shown when Copilot is selected)

    @ViewBuilder private var copilotControls: some View {
        Group {
            if copilot.isSignedIn {
                Label("Signed in to GitHub Copilot", systemImage: "checkmark.seal.fill")
                    .foregroundStyle(.green)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 10)
                SettingsButton("Sign out", systemImage: "rectangle.portrait.and.arrow.right", kind: .destructive) {
                    copilot.signOut(); engine.noteSecretsChanged()
                }
            } else if let device = copilotDevice {
                VStack(alignment: .leading, spacing: 10) {
                    Text("1. Copy this code").font(.footnote).foregroundStyle(.secondary)
                    HStack {
                        Text(device.userCode).font(.title3.weight(.bold).monospaced()).textSelection(.enabled)
                        Spacer()
                        Button { UIPasteboard.general.string = device.userCode; Haptics.tap() } label: {
                            Image(systemName: "doc.on.doc")
                        }
                        .accessibilityLabel("Copy code")
                    }
                    if let verificationURL = URL(string: device.verificationURI) {
                        Link(destination: verificationURL) {
                            Label("2. Open github.com/login/device", systemImage: "arrow.up.forward.app")
                        }
                    } else {
                        Text("GitHub returned an invalid verification link. Copy the code and open github.com/login/device manually.")
                            .font(.footnote)
                            .foregroundStyle(.orange)
                    }
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Waiting for you to authorize…").font(.footnote).foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 10)
            } else {
                SettingsButton("Sign in to GitHub Copilot", systemImage: "person.badge.key", kind: .secondary, loading: copilotBusy) {
                    Task { await startCopilotLogin() }
                }
                .disabled(copilotBusy)
            }
            if let copilotError {
                Text(copilotError).font(.footnote).foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 6)
            }
            Text("Uses your GitHub Copilot subscription instead of an API key. Requires an active Copilot plan.")
                .font(.caption).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading).padding(.bottom, 6)
        }
    }

    private func startCopilotLogin() async {
        copilotBusy = true; copilotError = nil
        defer { copilotBusy = false }
        do {
            let device = try await copilot.requestDeviceCode()
            UIPasteboard.general.string = device.userCode
            copilotDevice = device
            try await copilot.pollForToken(device)
            copilotDevice = nil
            engine.noteSecretsChanged()
            Haptics.success()
        } catch {
            copilotDevice = nil
            copilotError = error.localizedDescription
            Haptics.error()
        }
    }

    // MARK: - API Keys (sub-screen — every provider's key in one place)

    private var keysSection: some View {
        SettingsSection("API Keys", footer: "Keys are saved in iCloud Keychain when available and never sent to Website Commander servers. Claude and OpenAI also support OAuth sign-in (Settings → AI Model). The key for your selected provider is also editable inline under AI Model.") {
            oauthKeySection("Claude (Anthropic)", signInLabel: "Sign in with Claude",
                            text: $anthropicKey, id: "anthropic",
                            getURL: "https://console.anthropic.com/settings/keys")
            SettingsDivider()
            keyRow("DeepSeek", text: $deepseekKey, id: "deepseek", getURL: "https://platform.deepseek.com/api_keys")
            SettingsDivider()
            keyRow("OpenCode Go", text: $opencodeKey, id: "opencode", getURL: "https://opencode.ai/zen", note: "Use the API key shown after subscribing to OpenCode Go; an OpenAI platform key will not work.")
            SettingsDivider()
            // OpenAI hidden on the China storefront (Guideline 5 — no MIIT permit).
            if !StorefrontRegion.isChinaMainland {
                oauthKeySection("OpenAI", signInLabel: "Sign in with OpenAI",
                                text: $openaiKey, id: "openai",
                                getURL: "https://platform.openai.com/api-keys")
                SettingsDivider()
            }
            keyRow("Grok (xAI)", text: $grokKey, id: "grok", getURL: "https://console.x.ai")
            SettingsDivider()
            keyRow("Mistral", text: $mistralKey, id: "mistral", getURL: "https://console.mistral.ai/api-keys")
            SettingsDivider()
            keyRow("OpenRouter", text: $openrouterKey, id: "openrouter", getURL: "https://openrouter.ai/keys")
            SettingsDivider()
            keyRow("Groq", text: $groqKey, id: "groq", getURL: "https://console.groq.com/keys")
            SettingsDivider()
            keyRow("Qwen Token / Coding Plan", text: $qwenCodeKey, id: "qwen-code", getURL: "https://modelstudio.console.alibabacloud.com/")
            SettingsDivider()
            keyRow("Kimi Code", text: $kimiCodeKey, id: "kimi-code", getURL: "https://www.kimi.com/code/console")
            SettingsDivider()
            keyRow("LongCat", text: $longcatKey, id: "longcat", getURL: "https://longcat.chat/platform")
            SettingsDivider()
            keyRow("Gemini (Google)", text: $geminiKey, id: "gemini", getURL: "https://aistudio.google.com/app/apikey")
        }
        .disabled(!iap.isPro)
    }

    private func keyRow(_ title: String, text: Binding<String>, id: String, getURL: String,
                        note: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title).font(.subheadline.weight(.medium))
                Spacer()
                if let destination = URL(string: getURL) {
                    Link("Get a key", destination: destination).font(.caption)
                }
            }
            secureRow("Paste \(title) key", text: text) {
                // Empty commits preserve the existing key (see Keychain.commitAction).
                guard case .store = Keychain.commitAction(for: text.wrappedValue) else { return }
                let ok = Keychain.set(text.wrappedValue, for: Keychain.providerKey(id))
                keychainError = ok ? nil : "Could not save \(title) key to Keychain."
            }
            if let note {
                Text(note)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private func oauthKeySection(_ title: String, signInLabel: String, text: Binding<String>,
                                 id: String, getURL: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if OAuthManager.shared.isSignedIn(id) {
                Label("Signed in via \(title)", systemImage: "checkmark.seal.fill")
                    .foregroundStyle(.green)
                    .frame(maxWidth: .infinity, alignment: .leading)
                SettingsButton("Sign out", systemImage: "rectangle.portrait.and.arrow.right", kind: .destructive) {
                    OAuthManager.shared.signOut(id)
                    engine.noteSecretsChanged()
                    Task { await refreshOAuthStatus() }
                }
            } else if oauthNeedsReAuth.contains(id) {
                SettingsBanner(message: "Session expired — sign in again or paste an API key.", ok: false, errorTint: .orange)
                SettingsButton(signInLabel, systemImage: "person.badge.key", kind: .secondary, loading: oauthBusyID == id) {
                    Task { await startOAuthLogin(id) }
                }
                .disabled(oauthBusyID != nil)
            } else {
                SettingsButton(signInLabel, systemImage: "person.badge.key", kind: .secondary, loading: oauthBusyID == id) {
                    Task { await startOAuthLogin(id) }
                }
                .disabled(oauthBusyID != nil)
            }
            if let oauthError, oauthBusyID == nil || oauthBusyID == id {
                Text(oauthError).font(.footnote).foregroundStyle(.red)
            }
            Text("Or paste an API key below.")
                .font(.caption).foregroundStyle(.secondary)
            keyRow(title, text: text, id: id, getURL: getURL)
        }
        .padding(.vertical, 4)
    }

    private func startOAuthLogin(_ id: String) async {
        guard let config = OAuthConfig.builtin(for: id) else { return }
        oauthBusyID = id
        oauthError = nil
        defer { oauthBusyID = nil }
        do {
            try await OAuthManager.shared.signIn(config)
            oauthNeedsReAuth.remove(id)
            engine.noteSecretsChanged()
            Haptics.success()
        } catch {
            oauthError = error.localizedDescription
            Haptics.error()
        }
        await refreshOAuthStatus()
    }

    private func refreshOAuthStatus() async {
        var needsReAuth: Set<String> = []
        for id in ["anthropic", "openai"] {
            if case .needsReAuth = await ProviderCredentials.resolveDetailed(id) {
                needsReAuth.insert(id)
            }
        }
        oauthNeedsReAuth = needsReAuth
    }

    // MARK: - Custom provider

    private var customSection: some View {
        SettingsSection("Custom Provider (ext all)") {
            customControls
        }
        .disabled(!iap.isPro)
    }

    /// The custom-provider fields, usable both inline (when "Custom" is selected)
    /// and in the sub-screen.
    @ViewBuilder private var customControls: some View {
        TextField("Base URL (https://…/v1)", text: $engine.customBaseURL)
            .textInputAutocapitalization(.never).autocorrectionDisabled().padding(.vertical, 10)
        SettingsDivider()
        TextField("Model name", text: $engine.customModel)
            .textInputAutocapitalization(.never).autocorrectionDisabled().padding(.vertical, 10)
        SettingsDivider()
        secureRow("Custom API key", text: $customKey) {
            guard case .store = Keychain.commitAction(for: customKey) else { return }
            let ok = Keychain.set(customKey, for: Keychain.providerKey("custom"))
            keychainError = ok ? nil : "Could not save custom API key to Keychain."
        }
        .padding(.vertical, 10)
    }

    // MARK: - Apple Intelligence (inline status, shown when an Apple model is selected)

    #if APPLE_FM
    @ViewBuilder private var appleStatusInline: some View {
        appleStatusRow("On-Device", systemImage: "cpu",
                       status: AppleModels.onDeviceStatus, ok: AppleModels.onDeviceAvailable)
        SettingsDivider()
        appleStatusRow("Private Cloud", systemImage: "cloud",
                       status: AppleModels.privateCloudStatus, ok: AppleModels.privateCloudAvailable)
        Text("Free & private — no API key. Availability depends on your device, OS, and Apple account. These answer in a single turn and don't drive multi-step file edits.")
            .font(.caption).foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 6)
    }

    private func appleStatusRow(_ title: String, systemImage: String, status: String, ok: Bool) -> some View {
        HStack(spacing: 12) {
            Image(systemName: systemImage).foregroundStyle(Theme.brandGradient).frame(width: 24)
            Text(title)
            Spacer(minLength: 8)
            HStack(spacing: 6) {
                Circle().fill(ok ? Color.green : Color.orange).frame(width: 8, height: 8)
                Text(status).font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.trailing)
            }
        }
        .padding(.vertical, 8)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title): \(status)")
    }
    #endif

    private var onDeviceStatusLabel: String {
        if engine.usingOnDevice { return "Active" }
        return OnDeviceModelManager.shared.downloadedModels().isEmpty ? "Set up" : "Ready"
    }

    // MARK: - 10. Usage & Costs

    private var tokenUsageSection: some View {
        SettingsSection("API Usage & Costs") {
            Stepper(value: $engine.spendCapUSD, in: 0...200, step: 1) {
                HStack {
                    Label("Spend cap / session", systemImage: "gauge.with.dots.needle.bottom.50percent")
                    Spacer()
                    Text(engine.spendCapUSD == 0 ? "Off" : String(format: "$%.0f", engine.spendCapUSD))
                        .foregroundStyle(engine.spendCapUSD == 0 ? .secondary : Theme.brand)
                        .monospacedDigit()
                }
            }
            .padding(.vertical, 8)
            Text(engine.spendCapUSD == 0
                 ? "No limit — the agent runs until the task completes."
                 : "The agent stops automatically once a conversation's estimated cost reaches this. On-device and Copilot don't count.")
                .font(.caption).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.bottom, 8)

            let pid = engine.activeProviderID
            if pid == "copilot" {
                SettingsDivider()
                Text("Copilot is included in your GitHub Copilot subscription plan ($0.00).")
                    .font(.footnote).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 10)
            } else {
                let prompt = engine.promptTokens(for: pid)
                let completion = engine.completionTokens(for: pid)
                let cost = engine.estimatedCost(for: pid)
                SettingsDivider()
                VStack(alignment: .leading, spacing: 8) {
                    HStack { Text("Prompt Tokens"); Spacer(); Text("\(prompt)").monospacedDigit() }
                    HStack { Text("Completion Tokens"); Spacer(); Text("\(completion)").monospacedDigit() }
                    Divider()
                    HStack {
                        Text("Estimated Cost").font(.headline)
                        Spacer()
                        Text(String(format: "$%.4f", cost)).font(.headline).monospacedDigit().foregroundStyle(Theme.brand)
                    }
                }
                .font(.subheadline)
                .padding(.vertical, 10)
                SettingsButton("Reset Stats", systemImage: "arrow.counterclockwise", kind: .destructive) {
                    engine.resetTokenStats(); Haptics.tap()
                }
                .disabled(prompt == 0 && completion == 0)
            }
        }
    }

    // MARK: - Appearance (accent + theme)

    private var appearanceSection: some View {
        SettingsSection("Appearance", footer: "Choose the Home Screen icon, accent colour, light/dark theme, and surface style. Changes apply instantly across the app.") {
            AppIconPicker()
            SettingsDivider()
            HStack {
                Text("Accent colour").foregroundStyle(.secondary)
                Spacer(minLength: 12)
                Text(engine.accent.name)
                    .fontWeight(.semibold).foregroundStyle(Theme.brand)
            }
            .font(.subheadline)
            .padding(.vertical, 11)
            HStack(spacing: 0) {
                ForEach(Theme.Accent.allCases) { accent in
                    let selected = engine.accent == accent
                    Button {
                        engine.accent = accent; Haptics.tap()
                    } label: {
                        ZStack {
                            if selected {
                                Circle().stroke(accent.base, lineWidth: 2).frame(width: 38, height: 38)
                            }
                            Circle()
                                .fill(accent.isColorless ? AnyShapeStyle(.thinMaterial) : AnyShapeStyle(accent.base))
                                .frame(width: 28, height: 28)
                                .overlay {
                                    if accent.isColorless {
                                        Circle().strokeBorder(Color.primary.opacity(0.42), lineWidth: 1)
                                        Image(systemName: "circle.lefthalf.filled")
                                            .font(.system(size: 13, weight: .semibold))
                                            .foregroundStyle(.primary)
                                    }
                                }
                                .overlay {
                                    if selected {
                                        Image(systemName: "checkmark")
                                            .font(.system(size: 14, weight: .heavy))
                                            .foregroundStyle(accent.isColorless ? Color.primary : Color.white)
                                    }
                                }
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.pressable)
                    .accessibilityLabel(accent.name)
                    .accessibilityAddTraits(selected ? .isSelected : [])
                }
            }
            .padding(.vertical, 10)
            SettingsDivider()
            VStack(alignment: .leading, spacing: 8) {
                Text("Theme").foregroundStyle(.secondary).font(.subheadline)
                Picker("Theme", selection: Binding(
                    get: { engine.themeMode },
                    set: { engine.themeMode = $0; Haptics.tap() })) {
                    ForEach(ThemeMode.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
            }
            .padding(.vertical, 10)
            SettingsDivider()
            VStack(alignment: .leading, spacing: 8) {
                Text("Surface style").foregroundStyle(.secondary).font(.subheadline)
                Picker("Surface style", selection: Binding(
                    get: { engine.skin },
                    set: { engine.skin = $0; Haptics.tap() })) {
                    ForEach(AppSkin.allCases) { Text($0.label.localized).tag($0) }
                }
                .pickerStyle(.segmented)
            }
            .padding(.vertical, 10)
        }
    }

    // MARK: - 11. Behavior

    private var behaviorSection: some View {
        SettingsSection("Behavior", footer: engine.autoCommit
            ? "⚠️ The agent will commit (and deploy) changes immediately, without showing you a diff first."
            : "The agent stages every change so you can review the diff and approve before it goes live.") {
            navRow("User Guide", systemImage: "book.pages") { UserGuideView() }
            SettingsDivider()
            Toggle("Haptic Feedback", isOn: $engine.hapticsEnabled).padding(.vertical, 8)
            SettingsDivider()
            Picker("Agent effort", selection: $engine.reasoningPreference) {
                ForEach(ReasoningPreference.allCases) { preference in
                    Text(preference.rawValue).tag(preference)
                }
            }
            .padding(.vertical, 6)
            Text(engine.activeModelCapability.supportsReasoningPreference
                 ? "Controls how thoroughly the agent explores and verifies work in this session."
                 : "This model has no known native reasoning control; Website Commander applies the preference as an agent instruction.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.bottom, 6)
            SettingsDivider()
            Picker("Open Website Commander to", selection: $engine.launchPreference) {
                ForEach(LaunchPreference.allCases) { preference in
                    Text(preference.rawValue).tag(preference)
                }
            }
            .padding(.vertical, 6)
            SettingsDivider()
            Picker("Model fallback", selection: $engine.modelFallbackStrategy) {
                ForEach(ModelFallbackStrategy.allCases) { strategy in
                    Text(strategy.rawValue).tag(strategy)
                }
            }
            .padding(.vertical, 6)
            SettingsDivider()
            Toggle("Mask secrets in tool output", isOn: $engine.maskSecretsInToolOutput).padding(.vertical, 8)
            SettingsDivider()
            DisclosureGroup("Advanced behavior", isExpanded: $showAdvancedBehavior) {
                Toggle("Auto-commit without approval", isOn: $engine.autoCommit)
                Toggle("Branch + PR for larger changes", isOn: $engine.saferWorkflowMode)
                Toggle("Save full image context in chat history", isOn: $engine.persistFullImageHistory)
                    .padding(.top, 6)
                Text("Off by default: saved chats keep thumbnails, but model-history base64 images are removed.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.bottom, 6)
                SettingsDivider()
                Stepper(value: $engine.maxToolRounds, in: 5...100, step: 5) {
                    HStack {
                        Text("Max agent steps / turn")
                        Spacer()
                        Text("\(engine.maxToolRounds)")
                            .foregroundStyle(Theme.brand)
                            .monospacedDigit()
                    }
                }
                .padding(.vertical, 8)
                Text("Limits how many consecutive tool or command steps the agent can execute in one turn. Default is 25.")
                    .font(.caption).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.bottom, 8)
            }
            .tint(Theme.brand)
            .padding(.vertical, 8)
            SettingsButton("Replay Welcome Tour", systemImage: "play.circle", kind: .secondary) {
                hasCompletedOnboarding = false
            }
        }
    }

    // MARK: - 12. Legal & Store

    private var legalStoreSection: some View {
        SettingsSection("Legal & Store", footer: "Website Commander Super unlocks app features. Third-party AI providers and GitHub Copilot may require separate accounts, subscriptions, or API keys.") {
            // Annual upsell: monthly subscribers save by switching to yearly
            // (StoreKit crossgrades within the group, prorating the difference).
            if iap.isMonthlySubscriber {
                SettingsButton(
                    yearlySavingsPct.map { "Switch to Yearly — save \($0)%" } ?? "Switch to Yearly & save",
                    systemImage: "arrow.up.circle.fill", kind: .primary) {
                    Haptics.tap(); paywallContext = .switchToYearly; showPaywall = true
                }
                SettingsDivider()
            }
            linkRow("Terms of Use", systemImage: "doc.text", url: "https://www.apple.com/legal/internet-services/itunes/dev/stdeula/")
            SettingsDivider()
            linkRow("Privacy Policy", systemImage: "hand.raised", url: "https://mesut.uk/privacy")
            SettingsDivider()
            SettingsButton("Restore Website Commander Super", systemImage: "arrow.clockwise.circle", kind: .secondary, loading: restoreBusy) {
                restoreBusy = true
                Task { _ = await iap.restorePurchases(); restoreBusy = false }
            }
            .disabled(restoreBusy)
        }
    }

    // MARK: - 13. Disclaimers

    private var disclaimerSection: some View {
        SettingsSection("Legal & AI Disclaimers") {
            VStack(alignment: .leading, spacing: 10) {
                disclaimerBlock("AI Accuracy & Code Safety",
                    "Website Commander generates source code utilizing external and on-device language models. Artificial intelligence can make mistakes, introduce logical bugs, performance regressions, or security vulnerabilities (e.g. key exposure).")
                Divider()
                disclaimerBlock("User Accountability",
                    "You are solely responsible for reviewing, compiling, and testing all proposed changes via the visual diff interface before committing them to your production repository.")
                Divider()
                disclaimerBlock("Limitation of Liability",
                    "The developer of Website Commander shall not be held liable for any damages, repository corruption, broken production deployments, downtime, security breaches, data loss, or external LLM API billing charges incurred under any circumstances.")
            }
            .padding(.vertical, 10)
        }
    }

    private func disclaimerBlock(_ title: String, _ body: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title.localized).font(.subheadline.weight(.semibold))
            Text(body.localized).font(.caption).foregroundStyle(.secondary)
        }
    }

    private var aboutFooter: some View {
        Text(engine.activeWorkspace.map { "Website Commander manages \($0.slug). \($0.deployment.redeployNote)" }
             ?? "Connect a website in Settings to start managing it with the agent.")
            .font(.caption).foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .center)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 8).padding(.top, 4)
    }

    // MARK: - Reusable rows

    private func labeledField(_ label: String, text: Binding<String>, placeholder: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label.localized).font(.caption).foregroundStyle(.secondary)
            TextField(placeholder.localized, text: text)
                .font(.subheadline)
                .textInputAutocapitalization(.never).autocorrectionDisabled()
        }
        .padding(.vertical, 9)
    }

    private func navRow<Destination: View>(_ title: String, systemImage: String, trailing: String? = nil, @ViewBuilder destination: @escaping () -> Destination) -> some View {
        NavigationLink {
            destination()
        } label: {
            HStack {
                Label(title.localized, systemImage: systemImage)
                Spacer()
                if let trailing { Text(trailing.localized).font(.caption).foregroundStyle(.secondary) }
                Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
            }
            .padding(.vertical, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.primary)
    }

    @ViewBuilder
    private func linkRow(_ title: String, systemImage: String, url: String) -> some View {
        if let destination = URL(string: url) {
            Link(destination: destination) {
                HStack {
                    Label(title.localized, systemImage: systemImage)
                    Spacer()
                    Image(systemName: "arrow.up.forward").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
                }
                .padding(.vertical, 12)
                .contentShape(Rectangle())
            }
            .foregroundStyle(.primary)
        } else {
            Label(title.localized, systemImage: systemImage)
                .foregroundStyle(.secondary)
                .padding(.vertical, 12)
        }
    }

    private func secureRow(_ title: String, text: Binding<String>, onCommit: @escaping () -> Void) -> some View {
        DebouncedSecureField(placeholder: title.localized, text: text, onCommit: onCommit) {
            engine.noteSecretsChanged()
        }
    }

    // MARK: - Logic

    private func loadSecrets() {
        githubToken = Keychain.get(Keychain.githubToken) ?? ""
        anthropicKey = Keychain.get(Keychain.providerKey("anthropic")) ?? ""
        deepseekKey = Keychain.get(Keychain.providerKey("deepseek")) ?? ""
        opencodeKey = Keychain.get(Keychain.providerKey("opencode")) ?? ""
        openaiKey = Keychain.get(Keychain.providerKey("openai")) ?? ""
        grokKey = Keychain.get(Keychain.providerKey("grok")) ?? ""
        mistralKey = Keychain.get(Keychain.providerKey("mistral")) ?? ""
        openrouterKey = Keychain.get(Keychain.providerKey("openrouter")) ?? ""
        groqKey = Keychain.get(Keychain.providerKey("groq")) ?? ""
        qwenCodeKey = Keychain.get(Keychain.providerKey("qwen-code")) ?? ""
        kimiCodeKey = Keychain.get(Keychain.providerKey("kimi-code")) ?? ""
        longcatKey = Keychain.get(Keychain.providerKey("longcat")) ?? ""
        geminiKey = Keychain.get(Keychain.providerKey("gemini")) ?? ""
        customKey = Keychain.get(Keychain.providerKey("custom")) ?? ""
    }

    private var providerSelection: Binding<String> {
        Binding(
            get: { MainActor.assumeIsolated { engine.activeProviderID } },
            set: { newID in
                MainActor.assumeIsolated {
                    if !iap.isPro && AgentEngine.proOnlyProviderIDs.contains(newID) {
                        paywallContext = .premiumModel
                        showPaywall = true
                        engine.activeProviderID = AgentEngine.freeProviderID
                        engine.activeModelID = ""
                        return
                    }
                    engine.activeProviderID = newID
                    engine.activeModelID = ""
                }
            }
        )
    }

    private func reconcileProviderAccess() {
        guard !iap.isPro else { return }
        if engine.activeProviderID == "ondevice" && iap.canUseOnDevice {
            // On-device keeps its separate local trial entitlement.
        } else if AgentEngine.proOnlyProviderIDs.contains(engine.activeProviderID) {
            engine.activeProviderID = AgentEngine.freeProviderID
            engine.activeModelID = ""
        }
        engine.smartRoutingEnabled = false
    }

    private func verifyToken() async {
        verifying = true; verifyResult = nil
        defer { verifying = false }
        let diag = await GitHubClient(repo: engine.repo).diagnose()
        if let branch = diag.suggestedBranch {
            if var ws = engine.activeWorkspace {
                ws.gitBranch = branch
                engine.saveWorkspace(ws)
            }
        }
        withAnimation(Theme.snappy) { verifyResult = diag.message }
        diag.ok ? Haptics.success() : Haptics.error()
    }

    #if DEBUG
    private var debugSection: some View {
        SettingsSection("Debug / Developer") {
            SettingsButton(iap.isPro ? "Revoke Pro (Debug)" : "Grant Pro (Debug)",
                           systemImage: "ladybug", kind: iap.isPro ? .destructive : .secondary) {
                iap.setProForDebug(!iap.isPro)
            }
        }
    }
    #endif
}
