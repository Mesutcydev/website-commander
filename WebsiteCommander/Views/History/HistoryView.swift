import SwiftUI

/// A compact developer-grade commit browser with search, date grouping, keyboard
/// selection, and an honest details inspector.
struct HistoryView: View {
    @EnvironmentObject var settings: SettingsStore
    @State private var selectedWorkspaceID: UUID?
    @State private var selectedCommit: CommitEntry?
    @State private var selectedDetail: CommitDetail?
    @State private var detailLoading = false
    @State private var detailError: String?
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
                historyHeader(gutter: gutter)

                if settings.workspaces.isEmpty {
                    EmptyStateView(
                        systemImage: "clock",
                        title: "No history yet",
                        message: "Connect a website to inspect its real commit activity."
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    // The inspector is attached below the command row, not around
                    // the whole destination: it brings an AppKit split container
                    // with it, and a split container laid out around the row
                    // ignores the shell's top inset and slides it under the bar.
                    content(gutter: gutter)
                        .inspector(isPresented: Binding(
                            get: { selectedCommit != nil },
                            set: { if !$0 { selectedCommit = nil } }
                        )) {
                            if let selectedCommit {
                                CommitDetails(commit: selectedCommit,
                                              workspace: workspace,
                                              detail: selectedDetail,
                                              isLoading: detailLoading,
                                              error: detailError,
                                              onRetry: { Task { await loadDetails(for: selectedCommit) } })
                                    .inspectorColumnWidth(min: 280, ideal: 340, max: 430)
                            }
                        }
                }
            }
            .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
        }
        .task(id: workspace?.id) { await load() }
        .background { GlassWorkspaceBackground() }
    }

    private var scopeLabel: String {
        guard let id = selectedWorkspaceID,
              let match = settings.workspaces.first(where: { $0.id == id })
        else { return String(localized: "Active Site") }
        return match.name
    }

    private func historyHeader(gutter: CGFloat) -> some View {
        HStack(spacing: Theme.Space.s) {
            VStack(alignment: .leading, spacing: 2) {
                Text("History")
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundStyle(Theme.textHeading)
                Text("\(filteredCommits.count) commits")
                    .font(Theme.ui(11.5))
                    .foregroundStyle(Theme.secondaryText)
            }
            Spacer(minLength: Theme.Space.m)
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
            WorkspaceSearchField(text: $search, prompt: "Search commits", width: 260)
            WorkspaceActionButton(title: "Refresh", systemImage: "arrow.clockwise",
                                  isEnabled: !isLoading, isLoading: isLoading) {
                Task { await load() }
            }
        }
        .padding(.horizontal, gutter)
        .padding(.top, 20)
        .padding(.bottom, Theme.Space.m)
        .frame(maxWidth: 1220)
        .frame(maxWidth: .infinity)
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
                LazyVStack(alignment: .leading, spacing: Theme.Space.m, pinnedViews: [.sectionHeaders]) {
                    ForEach(groupedCommits, id: \.0) { title, entries in
                        Section {
                            VStack(spacing: 0) {
                                ForEach(Array(entries.enumerated()), id: \.element.id) { index, commit in
                                    HistoryCommitRow(
                                        commit: commit,
                                        branch: workspace?.gitBranch ?? "",
                                        selected: selectedCommit?.id == commit.id,
                                        isNewest: commit.id == commits.first?.id
                                    ) {
                                        withAnimation(Motion.smooth) {
                                            selectedCommit = commit
                                            selectedDetail = nil
                                            detailError = nil
                                        }
                                        Task { await loadDetails(for: commit) }
                                    }
                                    if index < entries.count - 1 {
                                        Divider().padding(.leading, 42)
                                    }
                                }
                            }
                            .background(Theme.standardPanelGradient,
                                        in: RoundedRectangle(cornerRadius: Theme.Radius.small))
                            .overlay {
                                RoundedRectangle(cornerRadius: Theme.Radius.small)
                                    .strokeBorder(Theme.borderSubtle)
                            }
                            .overlay(alignment: .top) {
                                RoundedRectangle(cornerRadius: Theme.Radius.small)
                                    .strokeBorder(Color.white.opacity(0.82), lineWidth: 1)
                                    .mask(LinearGradient(colors: [.white, .clear],
                                                          startPoint: .top,
                                                          endPoint: .center))
                            }
                            .cardElevation()
                        } header: {
                            Text(title)
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(Theme.secondaryText)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.vertical, Theme.Space.xs)
                                .background(Theme.workspaceSurface)
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
            if let selectedCommit, !commits.contains(selectedCommit) {
                self.selectedCommit = nil
                self.selectedDetail = nil
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func loadDetails(for commit: CommitEntry) async {
        guard let workspace else { return }
        guard let token = await settings.resolvedGitHubToken(forAsync: workspace), !token.isEmpty else {
            detailError = "Connect GitHub to inspect the changed files."
            return
        }
        detailLoading = true
        detailError = nil
        defer { detailLoading = false }
        do {
            let detail = try await GitHubClient(token: token).commitDetail(
                owner: workspace.gitOwner, repo: workspace.gitRepo, sha: commit.sha)
            guard selectedCommit?.id == commit.id else { return }
            selectedDetail = detail
        } catch {
            guard selectedCommit?.id == commit.id else { return }
            detailError = error.localizedDescription
        }
    }
}

private struct HistoryCommitRow: View {
    let commit: CommitEntry
    let branch: String
    let selected: Bool
    let isNewest: Bool
    let action: () -> Void
    @State private var hovering = false
    @State private var fresh = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: Theme.Space.m) {
                Image(systemName: "arrow.triangle.branch")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(selected ? Theme.accent : Theme.tertiaryText)
                    .frame(width: 18)
                if fresh {
                    AmbientConnectionSignal(tint: Theme.success,
                                             mode: .breathing,
                                             active: true,
                                             label: "Newest commit")
                }
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
                    .foregroundStyle(Theme.tertiaryText)
                }
                Spacer()
                Text(commit.shortSHA)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(selected ? Theme.accentText : Theme.tertiaryText)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(Theme.recessedSurface, in: RoundedRectangle(cornerRadius: 5))
                Image(systemName: "chevron.right")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(Theme.tertiaryText)
            }
            .padding(.horizontal, Theme.Space.m)
            .frame(height: Theme.Height.detailedRow)
            .background(selected
                        ? AnyShapeStyle(Theme.selectedPanelGradient)
                        : AnyShapeStyle(hovering ? Theme.hoverSurface : Color.clear))
            .overlay(alignment: .leading) {
                if selected {
                    Rectangle()
                        .fill(Theme.accent)
                        .frame(width: 2)
                        .padding(.vertical, 8)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .wcAppear()
        .onAppear {
            guard isNewest else { return }
            fresh = true
            Task {
                try? await Task.sleep(for: .seconds(5))
                fresh = false
            }
        }
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

private struct CommitDetails: View {
    let commit: CommitEntry
    let workspace: SiteWorkspace?
    let detail: CommitDetail?
    let isLoading: Bool
    let error: String?
    let onRetry: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.l) {
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
                    HStack {
                        Text("Changed files").font(.caption.weight(.semibold)).foregroundStyle(Theme.secondaryText)
                        Spacer()
                        if let detail {
                            Text("+\(detail.additions)").foregroundStyle(Theme.success)
                            Text("−\(detail.deletions)").foregroundStyle(Theme.danger)
                        }
                    }
                    if isLoading {
                        ProgressView("Loading file summary…")
                            .controlSize(.small)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } else if let error {
                        VStack(alignment: .leading, spacing: Theme.Space.s) {
                            Text(error).font(.callout).foregroundStyle(Theme.secondaryText)
                            Button("Try Again", action: onRetry)
                                .buttonStyle(.primarySoftCompact)
                        }
                    } else if let detail, !detail.files.isEmpty {
                        ForEach(detail.files) { file in
                            HStack(spacing: Theme.Space.s) {
                                Image(systemName: statusIcon(file.status))
                                    .foregroundStyle(statusTint(file.status))
                                    .frame(width: 18)
                                Text(file.path)
                                    .font(.system(.caption, design: .monospaced))
                                    .lineLimit(1)
                                Spacer(minLength: 8)
                                Text("+\(file.additions)").foregroundStyle(Theme.success)
                                Text("−\(file.deletions)").foregroundStyle(Theme.danger)
                            }
                            .accessibilityElement(children: .combine)
                        }
                    } else if detail != nil {
                        Text("No file statistics were returned for this commit.")
                            .font(.callout)
                            .foregroundStyle(Theme.secondaryText)
                    } else {
                        Text("Select a commit to load its changed files.")
                            .font(.callout)
                            .foregroundStyle(Theme.secondaryText)
                    }
                    if let htmlURL = detail?.htmlURL, let url = URL(string: htmlURL) {
                        Link(destination: url) {
                            Label("Open commit on GitHub", systemImage: "arrow.up.right.square")
                        }
                        .font(.caption.weight(.medium))
                    }
                }
            }
            .padding(Theme.Space.l)
        }
        .background(Theme.elevatedSurface)
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

    private func statusIcon(_ status: String) -> String {
        switch status.lowercased() {
        case "added": return "plus.circle.fill"
        case "removed": return "minus.circle.fill"
        case "renamed": return "arrow.left.arrow.right.circle.fill"
        default: return "pencil.circle.fill"
        }
    }

    private func statusTint(_ status: String) -> Color {
        switch status.lowercased() {
        case "added": return Theme.success
        case "removed": return Theme.danger
        case "renamed": return Theme.info
        default: return Theme.accent
        }
    }
}

private struct HistorySkeleton: View {
    var body: some View {
        VStack(spacing: Theme.Space.s) {
            ForEach(0..<8, id: \.self) { index in
                HStack {
                    RoundedRectangle(cornerRadius: 3).fill(Theme.secondarySurface).frame(width: 18, height: 18)
                    VStack(alignment: .leading, spacing: 6) {
                        RoundedRectangle(cornerRadius: 3).fill(Theme.secondarySurface)
                            .frame(width: CGFloat(220 + index * 17), height: 11)
                        RoundedRectangle(cornerRadius: 3).fill(Theme.secondarySurface)
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
