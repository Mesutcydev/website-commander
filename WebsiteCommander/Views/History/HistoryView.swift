import SwiftUI

/// Commit history for a workspace, with a workspace filter.
struct HistoryView: View {

    @EnvironmentObject var settings: SettingsStore
    @State private var selectedWorkspaceID: UUID?
    @State private var commits: [CommitEntry] = []
    @State private var isLoading = false
    @State private var errorMessage: String?

    private var workspace: SiteWorkspace? {
        if let id = selectedWorkspaceID {
            return settings.workspaces.first { $0.id == id }
        }
        return settings.activeWorkspace
    }

    var body: some View {
        Group {
            if settings.workspaces.isEmpty {
                EmptyStateView(systemImage: "clock",
                               title: "No history yet",
                               message: "Connect a website to see its commit history.")
            } else {
                content
            }
        }
        .navigationTitle("History")
        .toolbar {
            ToolbarItem(placement: .principal) {
                Picker("Workspace", selection: $selectedWorkspaceID) {
                    Text("Active Site").tag(UUID?.none)
                    ForEach(settings.workspaces) { ws in
                        Text(ws.name).tag(UUID?.some(ws.id))
                    }
                }
                .frame(width: 240)
            }
            ToolbarItem(placement: .primaryAction) {
                Button { Task { await load() } } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
            }
        }
        .task(id: workspace?.id) { await load() }
    }

    private var content: some View {
        ScrollView {
            VStack(spacing: 0) {
                if isLoading {
                    ProgressView().padding(Theme.Space.xxl)
                } else if let errorMessage {
                    Text(errorMessage).foregroundStyle(Theme.danger).padding(Theme.Space.xl)
                } else if commits.isEmpty {
                    Text("No commits found.").foregroundStyle(.secondary).padding(Theme.Space.xl)
                } else {
                    ForEach(Array(commits.enumerated()), id: \.element.id) { index, commit in
                        CommitRow(commit: commit)
                        if index < commits.count - 1 { Divider().padding(.leading, Theme.Space.l) }
                    }
                }
            }
            .commandCard(padding: 0)
            .padding(Theme.Space.xl)
            .frame(maxWidth: 820)
            .frame(maxWidth: .infinity)
        }
    }

    private func load() async {
        guard let workspace else { commits = []; return }
        guard let token = settings.resolvedGitHubToken(for: workspace), !token.isEmpty else {
            errorMessage = "Add a GitHub token in Settings → GitHub."
            commits = []
            return
        }
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            commits = try await GitHubClient(token: token).commits(
                owner: workspace.gitOwner, repo: workspace.gitRepo,
                branch: workspace.gitBranch, limit: 50)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
