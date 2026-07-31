import SwiftUI

/// A compact developer-grade commit browser with search, date grouping, keyboard
/// selection, and an honest details inspector.
struct HistoryView: View {
    @EnvironmentObject var settings: SettingsStore
    @State private var selectedWorkspaceID: UUID?
    @State private var selectedCommit: CommitEntry?
    @State private var commits: [CommitEntry] = []
    @State private var search = ""
    @State private var isLoading = false
    @State private var errorMessage: String?

    private var workspace: SiteWorkspace? {
        if let id = selectedWorkspaceID {
            return settings.workspaces.first { $0.id == id }
        }
        return settings.activeWorkspace
    }

    private var filteredCommits: [CommitEntry] {
        let needle = search.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else { return commits }
        return commits.filter {
            $0.message.lowercased().contains(needle)
                || $0.author.lowercased().contains(needle)
                || $0.sha.lowercased().contains(needle)
        }
    }

    private var groupedCommits: [(String, [CommitEntry])] {
        let calendar = Calendar.current
        return Dictionary(grouping: filteredCommits) { commit -> String in
            if calendar.isDateInToday(commit.date) { return String(localized: "Today") }
            if calendar.isDateInYesterday(commit.date) { return String(localized: "Yesterday") }
            return commit.date.formatted(date: .abbreviated, time: .omitted)
        }
        .map { ($0.key, $0.value.sorted { $0.date > $1.date }) }
        .sorted { ($0.1.first?.date ?? .distantPast) > ($1.1.first?.date ?? .distantPast) }
    }

    var body: some View {
        GeometryReader { proxy in
            let gutter = AgentWorkspaceMetrics.gutter(for: proxy.size.width)
            VStack(spacing: 0) {
                WorkspaceCommandRow(gutter: gutter) {
                    WorkspaceMenuControl(title: String(localized: "Site"),
                                         value: scopeLabel,
                                         systemImage: "folder") {
                        Picker("Site", selection: $selectedWorkspaceID) {
                            Text("Active Site").tag(UUID?.none)
                            ForEach(settings.workspaces) { ws in
                                Text(ws.name).tag(UUID?.some(ws.id))
                            }
                        }
                        .pickerStyle(.inline)
                        .labelsHidden()
                    }
                    WorkspaceSearchField(text: $search, prompt: "Search commits")
                    Spacer(minLength: TopBarMetrics.groupGap)
                    WorkspaceActionButton(title: "Refresh",
                                          systemImage: "arrow.clockwise",
                                          isEnabled: !isLoading,
                                          isLoading: isLoading) { Task { await load() } }
                }

                if settings.workspaces.isEmpty {
                    EmptyStateView(
                        systemImage: "clock",
                        title: "No history yet",
                        message: "Connect a website to inspect its real commit activity."
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    content(gutter: gutter)
                }
            }
            .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
        }
        .inspector(isPresented: Binding(
            get: { selectedCommit != nil },
            set: { if !$0 { selectedCommit = nil } }
        )) {
            if let selectedCommit {
                CommitDetails(commit: selectedCommit, workspace: workspace)
                    .inspectorColumnWidth(min: 280, ideal: 340, max: 430)
            }
        }
        .task(id: workspace?.id) { await load() }
    }

    private var scopeLabel: String {
        guard let id = selectedWorkspaceID,
              let match = settings.workspaces.first(where: { $0.id == id })
        else { return String(localized: "Active Site") }
        return match.name
    }

    @ViewBuilder
    private func content(gutter: CGFloat) -> some View {
        if isLoading && commits.isEmpty {
            HistorySkeleton()
        } else if let errorMessage, commits.isEmpty {
            ErrorStateView(
                title: "History couldn't load",
                message: "\(errorMessage)\nYour repository and local work are unchanged.",
                retryTitle: "Try Again"
            ) { Task { await load() } }
        } else if filteredCommits.isEmpty {
            EmptyStateView(
                systemImage: search.isEmpty ? "clock" : "magnifyingglass",
                title: search.isEmpty ? "No commits found" : "No matching commits",
                message: search.isEmpty
                    ? "This branch has no commit activity yet."
                    : "Try a message, author, or commit hash."
            )
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: Theme.Space.l, pinnedViews: [.sectionHeaders]) {
                    ForEach(groupedCommits, id: \.0) { title, entries in
                        Section {
                            VStack(spacing: 0) {
                                ForEach(Array(entries.enumerated()), id: \.element.id) { index, commit in
                                    HistoryCommitRow(
                                        commit: commit,
                                        branch: workspace?.gitBranch ?? "",
                                        selected: selectedCommit?.id == commit.id
                                    ) {
                                        withAnimation(Motion.smooth) { selectedCommit = commit }
                                    }
                                    if index < entries.count - 1 {
                                        Divider().padding(.leading, 42)
                                    }
                                }
                            }
                            .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.medium))
                            .overlay {
                                RoundedRectangle(cornerRadius: Theme.Radius.medium)
                                    .strokeBorder(Theme.borderSubtle)
                            }
                        } header: {
                            Text(title)
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(Theme.secondaryText)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.vertical, Theme.Space.xs)
                                .background(Theme.canvas)
                        }
                    }
                }
                .padding(.horizontal, gutter)
                .padding(.bottom, 20)
                .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func load() async {
        guard let workspace else { commits = []; return }
        guard let token = await settings.resolvedGitHubToken(forAsync: workspace), !token.isEmpty else {
            errorMessage = "Add a GitHub token in Settings → GitHub."
            commits = []
            return
        }
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            commits = try await GitHubClient(token: token).commits(
                owner: workspace.gitOwner,
                repo: workspace.gitRepo,
                branch: workspace.gitBranch,
                limit: 100
            )
            if let selectedCommit, !commits.contains(selectedCommit) { self.selectedCommit = nil }
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

private struct HistoryCommitRow: View {
    let commit: CommitEntry
    let branch: String
    let selected: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: Theme.Space.m) {
                Image(systemName: "arrow.triangle.branch")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(selected ? Theme.accent : Theme.tertiaryText)
                    .frame(width: 18)
                VStack(alignment: .leading, spacing: 2) {
                    Text(commit.message.split(separator: "\n").first.map(String.init) ?? commit.message)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(1)
                    HStack(spacing: 5) {
                        Text(commit.author)
                        Text("·")
                        if !branch.isEmpty {
                            Text(branch).fontDesign(.monospaced)
                            Text("·")
                        }
                        Text(commit.date.formatted(.relative(presentation: .named)))
                    }
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.secondaryText)
                }
                Spacer()
                Text(commit.shortSHA)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Theme.secondaryText)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(Theme.raisedFill, in: RoundedRectangle(cornerRadius: 5))
                Image(systemName: "chevron.right")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(Theme.tertiaryText)
            }
            .padding(.horizontal, Theme.Space.m)
            .frame(height: 50)
            .background(selected ? Theme.surfaceSelected : (hovering ? Theme.surfaceHover : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

private struct CommitDetails: View {
    let commit: CommitEntry
    let workspace: SiteWorkspace?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.xl) {
                VStack(alignment: .leading, spacing: Theme.Space.s) {
                    Label("Commit details", systemImage: "arrow.triangle.branch")
                        .font(.headline)
                    Text(commit.message)
                        .font(.system(size: 14, weight: .medium))
                        .textSelection(.enabled)
                }
                detail("Author", commit.author)
                detail("Date", commit.date.formatted(date: .complete, time: .standard))
                detail("Branch", workspace?.gitBranch ?? "Unknown", monospaced: true)
                detail("Full hash", commit.sha, monospaced: true)
                Divider()
                VStack(alignment: .leading, spacing: Theme.Space.s) {
                    Text("Changed files").font(.caption.weight(.semibold)).foregroundStyle(Theme.secondaryText)
                    Text("File-level statistics are not returned by the current history request.")
                        .font(.callout)
                        .foregroundStyle(Theme.secondaryText)
                }
            }
            .padding(Theme.Space.l)
        }
        .background(Theme.sidebarFill)
    }

    private func detail(_ label: String, _ value: String, monospaced: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.caption.weight(.semibold)).foregroundStyle(Theme.secondaryText)
            Text(value)
                .font(monospaced ? .system(.callout, design: .monospaced) : .callout)
                .foregroundStyle(Theme.textPrimary)
                .textSelection(.enabled)
        }
    }
}

private struct HistorySkeleton: View {
    var body: some View {
        VStack(spacing: Theme.Space.s) {
            ForEach(0..<8, id: \.self) { index in
                HStack {
                    RoundedRectangle(cornerRadius: 3).fill(Theme.raisedFill).frame(width: 18, height: 18)
                    VStack(alignment: .leading, spacing: 6) {
                        RoundedRectangle(cornerRadius: 3).fill(Theme.raisedFill)
                            .frame(width: CGFloat(220 + index * 17), height: 11)
                        RoundedRectangle(cornerRadius: 3).fill(Theme.raisedFill)
                            .frame(width: 150, height: 8)
                    }
                    Spacer()
                }
                .frame(height: 50)
            }
        }
        .padding(Theme.Space.xl)
        .frame(maxWidth: 900)
        .frame(maxWidth: .infinity, alignment: .top)
        .accessibilityLabel("Loading commit history")
    }
}
