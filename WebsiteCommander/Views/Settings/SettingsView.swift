import SwiftUI
import AppKit

/// The Settings window: a tabbed form for GitHub auth, AI provider & keys,
/// behavior toggles, and about info.
struct SettingsView: View {

    @EnvironmentObject var settings: SettingsStore
    @EnvironmentObject var engine: AgentEngine

    var body: some View {
        TabView {
            GitHubSettingsTab()
                .tabItem { Label("GitHub", systemImage: "github") }
            ProviderSettingsTab()
                .tabItem { Label("AI Provider", systemImage: "cpu") }
            BehaviorSettingsTab()
                .tabItem { Label("Behavior", systemImage: "slider.horizontal.3") }
            OnDeviceSettingsTab()
                .tabItem { Label("On-Device", systemImage: "cpu.fill") }
            AboutSettingsTab()
                .tabItem { Label("About", systemImage: "info.circle") }
        }
        .environmentObject(settings)
        .environmentObject(engine)
    }
}

// MARK: - GitHub tab

struct GitHubSettingsTab: View {
    @EnvironmentObject var settings: SettingsStore
    @State private var newLabel = ""
    @State private var newToken = ""
    @State private var status: String?
    @State private var statusOK = false
    @State private var verifying = false

    private var hasDefault: Bool { !(settings.githubToken ?? "").isEmpty }

    var body: some View {
        Form {
            Section {
                if hasDefault {
                    accountRow(title: "Default account",
                               subtitle: "Used by sites with no specific account",
                               tint: Theme.accent,
                               removeLabel: "Clear") {
                        settings.setGitHubToken("")
                        status = "Default token removed."
                        statusOK = true
                    }
                }
                ForEach(settings.githubAccounts) { account in
                    let hasTok = !(settings.token(forCredential: account.id) ?? "").isEmpty
                    accountRow(title: account.displayName,
                               subtitle: hasTok ? "Personal access token stored" : "Token missing",
                               tint: hasTok ? Theme.success : Theme.warning,
                               removeLabel: "Remove") {
                        settings.removeGitHubAccount(account.id)
                        status = "Removed \(account.displayName)."
                        statusOK = true
                    }
                }
                if !hasDefault && settings.githubAccounts.isEmpty {
                    Text("No GitHub accounts yet. Add one below to connect your sites.")
                        .font(.callout).foregroundStyle(.secondary)
                }
            } header: {
                HStack {
                    Text("Accounts")
                    Spacer()
                    Text("\(settings.accountOptions.count)")
                        .foregroundStyle(.secondary)
                }
            } footer: {
                Text("Each site uses one account. Add as many as you need — e.g. one for work, one for personal repos. Tokens are stored only in the macOS Keychain.")
            }

            Section {
                HStack(spacing: Theme.Space.m) {
                    TextField("Label (e.g. Work)", text: $newLabel)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 140)
                    SecureField("ghp_… or github_pat_…", text: $newToken)
                        .textFieldStyle(.roundedBorder)
                }
                HStack {
                    Button {
                        Task { await verifyAndAdd() }
                    } label: {
                        if verifying { ProgressView().controlSize(.small) }
                        else { Label("Verify & Add", systemImage: "person.badge.plus") }
                    }
                    .buttonStyle(.primary)
                    .disabled(newToken.trimmingCharacters(in: .whitespaces).isEmpty || verifying)
                    HelpButton(title: "Creating a GitHub token",
                               message: "Generate a classic Personal Access Token with the `repo` scope so the agent can read and write your repositories. We verify it (and fetch your username) before storing it in the Keychain.",
                               links: [("github.com/settings/tokens", "https://github.com/settings/tokens")])
                }
                if let status {
                    Label(status, systemImage: statusOK ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .foregroundStyle(statusOK ? Theme.success : Theme.danger)
                        .font(.callout)
                }
            } header: {
                Text("Add Account")
            }
        }
        .formStyle(.grouped)
        .padding(Theme.Space.l)
    }

    private func accountRow(title: String, subtitle: String, tint: Color, removeLabel: String,
                            remove: @escaping () -> Void) -> some View {
        HStack(spacing: Theme.Space.m) {
            IconTile(systemImage: "person.crop.circle.fill", tint: tint, size: 34, gradient: false)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.body.weight(.medium))
                Text(subtitle).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            StatusDot(color: tint)
            Button(removeLabel, action: remove)
                .buttonStyle(.plain)
                .foregroundStyle(Theme.danger)
                .font(.callout)
        }
        .padding(.vertical, 2)
    }

    private func verifyAndAdd() async {
        verifying = true
        status = nil
        defer { verifying = false }
        let trimmed = newToken.trimmingCharacters(in: .whitespaces)
        do {
            let info = try await GitHubClient(token: trimmed).accountInfo()
            let label = newLabel.trimmingCharacters(in: .whitespaces).isEmpty ? info.login : newLabel.trimmingCharacters(in: .whitespaces)
            settings.addGitHubAccount(label: label, token: trimmed, login: info.login)
            newToken = ""
            newLabel = ""
            switch scopeVerdict(info.scopes) {
            case .full:
                status = "Added \(info.login) — full repo access."
                statusOK = true
            case .unknown:
                status = "Added \(info.login). Scopes not readable (fine-grained token?) — write access will be confirmed per site."
                statusOK = true
            case .noPush:
                status = "Added \(info.login), but this token can't push (no `repo` scope). The agent won't be able to commit — add a token with `repo`."
                statusOK = false
            }
        } catch {
            status = error.localizedDescription
            statusOK = false
        }
    }

    private enum ScopeVerdict { case full, unknown, noPush }
    private func scopeVerdict(_ scopes: [String]) -> ScopeVerdict {
        if scopes.isEmpty { return .unknown }            // fine-grained PAT
        return scopes.contains("repo") ? .full : .noPush  // classic PAT
    }
}

// MARK: - Provider tab

struct ProviderSettingsTab: View {
    @EnvironmentObject var settings: SettingsStore
    @State private var key = ""

    private var info: ProviderInfo? { ProviderRegistry.info(for: settings.providerID) }

    private var onDeviceAvailable: Bool {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) { return OnDeviceProvider.isAvailable }
        #endif
        return false
    }

    private var onDeviceStatus: String {
        onDeviceAvailable ? "Apple Intelligence is available on this Mac."
                          : "Apple Intelligence isn't available (requires macOS 26 + Apple Intelligence)."
    }

    var body: some View {
        Form {
            Section("Provider") {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: Theme.Space.s)],
                          spacing: Theme.Space.s) {
                    ForEach(ProviderRegistry.catalog) { provider in
                        ProviderChip(provider: provider, isSelected: provider.id == settings.providerID) {
                            settings.providerID = provider.id
                            settings.model = ""
                            key = settings.apiKey(for: provider.id) ?? ""
                        }
                    }
                }
                .padding(.vertical, Theme.Space.xs)
            }

            if settings.providerID == "custom" {
                Section("Custom Endpoint") {
                    TextField("Base URL (https://…/v1)", text: $settings.customBaseURL)
                        .textFieldStyle(.roundedBorder)
                    TextField("Model name", text: $settings.customModel)
                        .textFieldStyle(.roundedBorder)
                }
            }

            Section("Model") {
                Picker("Model", selection: $settings.model) {
                    Text("Default (\(info?.defaultModel ?? "auto"))").tag("")
                    ForEach(modelList, id: \.self) { Text($0).tag($0) }
                }
            }

            if settings.providerID == "ondevice" {
                Section("On-Device AI") {
                    Label(onDeviceStatus, systemImage: onDeviceAvailable ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(onDeviceAvailable ? Theme.success : Theme.warning)
                    Text("Runs fully offline using Apple Intelligence. No API key required.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            } else {
                Section {
                    SecureField(info?.keyLabel ?? "API Key", text: $key)
                        .onAppear { key = settings.apiKey(for: settings.providerID) ?? "" }
                    Button("Save Key") {
                        settings.setAPIKey(key.trimmingCharacters(in: .whitespaces), for: settings.providerID)
                    }
                    .buttonStyle(.primary)
                    if let url = info?.keySourceURL, !url.isEmpty {
                        Link("Get a key →", destination: URL(string: url)!)
                            .font(.callout)
                    }
                } header: {
                    Text("API Key")
                } footer: {
                    Text("Stored only in the macOS Keychain. Direct API calls — no proxy servers.")
                }
            }

            Section("Smart Routing") {
                Toggle("Auto-route to the best model", isOn: $settings.smartRouting)
                if settings.smartRouting {
                    Picker("Strategy", selection: $settings.routingStrategy) {
                        ForEach(RoutingStrategy.allCases) { strategy in
                            Text(strategy.rawValue).tag(strategy)
                        }
                    }
                    .pickerStyle(.segmented)
                    Text(settings.routingStrategy.detail)
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .padding(Theme.Space.l)
    }

    private var modelList: [String] {
        if settings.providerID == "custom" {
            return settings.customModel.isEmpty ? [] : [settings.customModel]
        }
        return info?.models ?? []
    }
}

/// A selectable visual provider chip.
private struct ProviderChip: View {
    let provider: ProviderInfo
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: Theme.Space.s) {
                Group {
                    if let mark = BrandMarkID.from(providerID: provider.id) {
                        BrandMark(id: mark)
                            .fill(isSelected ? Color.white : Color.primary)
                    } else {
                        Image(systemName: provider.icon)
                            .foregroundStyle(isSelected ? .white : Theme.accent)
                    }
                }
                .frame(width: 18, height: 18)
                Text(provider.displayName)
                    .font(.callout.weight(.medium))
                    .foregroundStyle(isSelected ? .white : .primary)
                Spacer()
            }
            .padding(.horizontal, Theme.Space.m)
            .padding(.vertical, Theme.Space.s)
            .background(
                isSelected ? AnyShapeStyle(Theme.brandGradient) : AnyShapeStyle(Color.primary.opacity(0.05)),
                in: RoundedRectangle(cornerRadius: Theme.Radius.medium))
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Behavior tab

struct BehaviorSettingsTab: View {
    @EnvironmentObject var settings: SettingsStore
    @EnvironmentObject var cloudSync: CloudSyncService
    @EnvironmentObject var bridge: LocalBridge

    var body: some View {
        Form {
            Section("Agent") {
                Toggle("Auto-commit (skip the approval step)", isOn: $settings.autoCommit)
                Text("When on, approved edits commit immediately without a diff review. Recommended off.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Appearance") {
                Picker("Theme", selection: $settings.themeMode) {
                    ForEach(ThemeMode.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
            }
            Section {
                Toggle("Sync workspaces & preferences via iCloud", isOn: $settings.cloudSyncEnabled)
                    .onChange(of: settings.cloudSyncEnabled) { _, on in
                        if on { cloudSync.push(settings) }
                    }
                Label(CloudSyncService.isSignedIn
                      ? "Signed in to iCloud. Secrets (API keys, tokens) never sync."
                      : "Not signed in to iCloud — sync is inactive.",
                      systemImage: CloudSyncService.isSignedIn ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(CloudSyncService.isSignedIn ? Theme.success : Theme.warning)
            } header: {
                Text("iCloud Sync")
            }
            Section {
                Toggle("Allow local agent connections", isOn: $settings.localBridgeEnabled)
                if bridge.isRunning, let port = bridge.port {
                    Label("Listening on 127.0.0.1:\(port) (loopback only)",
                          systemImage: "lock.shield.fill")
                        .font(.caption).foregroundStyle(Theme.success)
                    HStack {
                        Text("Token file").font(.caption).foregroundStyle(.secondary)
                        Text(LocalBridge.tokenFileURL.path)
                            .font(.system(.caption2, design: .monospaced))
                            .textSelection(.enabled).lineLimit(1).truncationMode(.middle)
                        Spacer()
                        Button("Copy token") {
                            if let t = LocalBridge.readPublishedToken() {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(t, forType: .string)
                            }
                        }
                        .buttonStyle(.primarySoft)
                    }
                    Text("Any program on this Mac that reads the token file can drive the app. Keep it off when not in use.")
                        .font(.caption2).foregroundStyle(.secondary)
                } else if settings.localBridgeEnabled {
                    if let err = bridge.lastError {
                        Label(err, systemImage: "xmark.octagon.fill")
                            .font(.caption).foregroundStyle(Theme.danger)
                    } else {
                        Label("Starting…", systemImage: "hourglass").font(.caption).foregroundStyle(.secondary)
                    }
                } else {
                    Label("Off — no socket is open.", systemImage: "power")
                        .font(.caption).foregroundStyle(.secondary)
                }
                HStack(spacing: 6) {
                    Text("Port").font(.caption).foregroundStyle(.secondary)
                    TextField("0 = auto", value: $settings.localBridgePort, format: .number)
                        .textFieldStyle(.roundedBorder).frame(width: 90)
                    Text(settings.localBridgeEnabled ? "(restart to apply)" : "")
                        .font(.caption2).foregroundStyle(.tertiary)
                }
            } header: {
                Text("Local Agent Bridge")
            } footer: {
                Text("Lets Codex, Cursor, opencode, or scripts on this Mac list sites, run the agent, and pull debug briefs over a token-authenticated loopback socket. Off by default; never exposed to the network.")
            }
        }
        .formStyle(.grouped)
        .padding(Theme.Space.l)
    }
}

// MARK: - About tab

struct AboutSettingsTab: View {
    @EnvironmentObject var settings: SettingsStore
    @EnvironmentObject var updater: UpdateChecker

    var body: some View {
        VStack(spacing: Theme.Space.m) {
            IconTile(systemImage: "square.grid.2x2.fill", size: 64)
            Text("Website Commander").font(.title2.weight(.bold))
            Text("Version \(UpdateChecker.currentVersion)").font(.callout).foregroundStyle(.secondary)
            Text("The open-source, Mac-native website agent. Edit your sites with plain English, review every change, and ship.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)

            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 5) {
                    Text("Update feed URL").font(.caption).foregroundStyle(.secondary)
                    HelpButton(title: "Update feed",
                               message: "Point this at a JSON file on your website: {\"version\":\"1.1.0\",\"url\":\"…zip\",\"notes\":\"…\"}. The app only ever fetches it when you choose Check for Updates — never in the background. Use https (http is allowed only on loopback, for testing).",
                               links: [])
                }
                HStack {
                    TextField("https://example.com/wc-update.json", text: $settings.updateFeedURL)
                        .textFieldStyle(.roundedBorder)
                    Button(updater.checking ? "…" : "Check") {
                        Task { await updater.check(feedURL: settings.updateFeedURL) }
                    }
                    .buttonStyle(.primarySoft)
                    .disabled(updater.checking)
                }
                if let err = updater.lastError {
                    Text(err).font(.caption2).foregroundStyle(Theme.danger)
                } else if settings.updateFeedURL.trimmingCharacters(in: .whitespaces).isEmpty {
                    Text("No feed set — Check for Updates is inactive.").font(.caption2).foregroundStyle(.tertiary)
                }
            }
            .frame(maxWidth: 420)
            .padding(.top, Theme.Space.s)

            Spacer()
        }
        .padding(Theme.Space.xxl)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
