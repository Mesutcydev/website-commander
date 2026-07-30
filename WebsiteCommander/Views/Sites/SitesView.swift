import SwiftUI

/// Manages connected website workspaces: a visual card list with an active
/// indicator, context actions, and an add-workspace sheet.
struct SitesView: View {

    @EnvironmentObject var settings: SettingsStore
    @EnvironmentObject var engine: AgentEngine
    @State private var showingAdd = false

    var body: some View {
        Group {
            if settings.workspaces.isEmpty {
                EmptyStateView(
                    systemImage: "folder.badge.plus",
                    title: "No websites yet",
                    message: "Connect a GitHub repository to start editing it with the agent.",
                    actionTitle: "Add Website"
                ) { showingAdd = true }
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 340), spacing: Theme.Space.m)],
                              spacing: Theme.Space.m) {
                        ForEach(settings.workspaces) { workspace in
                            WorkspaceCard(workspace: workspace,
                                          isActive: workspace.id == settings.activeWorkspace?.id)
                        }
                    }
                    .padding(Theme.Space.xl)
                    .frame(maxWidth: 1000)
                    .frame(maxWidth: .infinity)
                }
            }
        }
        .navigationTitle("Sites")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showingAdd = true
                } label: {
                    Label("Add Website", systemImage: "plus")
                }
                .buttonStyle(.primary)
            }
        }
        .sheet(isPresented: $showingAdd) {
            AddWorkspaceSheet()
        }
        .onReceive(NotificationCenter.default.publisher(for: .requestAddSite)) { _ in
            showingAdd = true
        }
    }
}

// MARK: - Workspace card

struct WorkspaceCard: View {
    @EnvironmentObject var settings: SettingsStore
    @EnvironmentObject var engine: AgentEngine
    let workspace: SiteWorkspace
    let isActive: Bool
    @State private var vscodeStatus: String?
    @State private var showingDeploy = false
    @State private var showingMemory = false

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            HStack(spacing: Theme.Space.m) {
                IconTile(systemImage: workspace.techStack.icon, size: 44)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(workspace.name).font(.title3.weight(.semibold))
                        if isActive { Badge(text: "Active", systemImage: "checkmark.circle.fill", tint: workspace.accentColor) }
                    }
                    Text(workspace.slug)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Menu {
                    Button("Set Active") { settings.setActive(workspace) }
                    Button("Open in VSCode") { openInVSCode() }
                    Button("Deployment…") { showingDeploy = true }
                    Button("Agent memory…") { showingMemory = true }
                    Divider()
                    Button("Delete", role: .destructive) { settings.deleteWorkspace(workspace) }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }

            HStack(spacing: Theme.Space.s) {
                Badge(text: workspace.techStack.rawValue, systemImage: workspace.techStack.icon, tint: Theme.accent)
                Badge(text: workspace.deployment.rawValue, systemImage: workspace.deployment.icon, tint: Theme.accentDeep)
            }

            HStack(spacing: Theme.Space.s) {
                Button {
                    settings.setActive(workspace)
                    engine.newChat()
                } label: {
                    Label("Open Agent", systemImage: "bubble.left.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.primarySoft)

                Button {
                    openInVSCode()
                } label: {
                    Label("VSCode", systemImage: "chevron.left.forwardslash.chevron.right")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.primarySoft)
            }

            if let vscodeStatus {
                Text(vscodeStatus)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .commandCard()
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.card)
                .strokeBorder(isActive ? workspace.accentColor.opacity(0.6) : .clear, lineWidth: 2)
        )
        .sheet(isPresented: $showingDeploy) {
            DeploymentSheet(workspace: workspace)
        }
        .sheet(isPresented: $showingMemory) {
            MemorySheet(workspace: workspace)
        }
    }

    private func openInVSCode() {
        guard let token = settings.resolvedGitHubToken(for: workspace) else {
            vscodeStatus = "Add a GitHub token first (Settings → GitHub)."
            return
        }
        vscodeStatus = "Preparing local copy…"
        Task {
            do {
                let path = try await LocalWorkspaceStore.ensureClone(workspace, token: token)
                let opened = VSCodeBridge.open(folder: path)
                vscodeStatus = opened ? "Opened in VSCode." : "Couldn't find VSCode — is the `code` CLI installed?"
            } catch {
                vscodeStatus = error.localizedDescription
            }
        }
    }
}
