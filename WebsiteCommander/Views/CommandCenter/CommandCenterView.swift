import SwiftUI

/// The dashboard: at-a-glance stats, quick actions, AI suggestions, and recent
/// activity. Visual-first — almost everything is an icon tile or a card.
struct CommandCenterView: View {

    @EnvironmentObject var settings: SettingsStore
    @EnvironmentObject var engine: AgentEngine
    @Environment(\.destination) private var destination
    @State private var recentCommits: [CommitEntry] = []
    @State private var isLoadingCommits = false

    var body: some View {
        GeometryReader { proxy in
            let metrics = AgentWorkspaceMetrics(width: proxy.size.width)
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Space.xl) {
                    header
                    if settings.activeWorkspace == nil {
                        noSiteCard
                    } else {
                        statsGrid(metrics)
                        quickActions(metrics)
                        recommendations(metrics)
                        recentActivity
                    }
                }
                .padding(.horizontal, metrics.paddingX)
                .padding(.top, metrics.paddingTop)
                .padding(.bottom, metrics.paddingBottom)
                // No centered page wrapper: the dashboard uses the whole
                // workspace, on the same gutter as every other destination.
                .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
            }
            .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
        }
        .background(Theme.canvas)
        .task(id: settings.activeWorkspace?.id) { await loadCommits() }
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .center, spacing: Theme.Space.m) {
            VStack(alignment: .leading, spacing: 4) {
                Text(greeting)
                    .font(Theme.ui(11.5, .semibold))
                    .foregroundStyle(Theme.tertiaryText)
                Text(settings.activeWorkspace?.name ?? "Website Commander")
                    .font(.system(size: 27, weight: .semibold))
            }
            Spacer()
            if let ws = settings.activeWorkspace {
                Badge(text: ws.deployment.rawValue, systemImage: ws.deployment.icon,
                      tint: Theme.tertiaryText, surface: Theme.secondarySurface)
            }
        }
    }

    private var greeting: String {
        let hour = Calendar.current.component(.hour, from: Date())
        switch hour {
        case 5..<12: return "Good morning"
        case 12..<18: return "Good afternoon"
        default: return "Good evening"
        }
    }

    // MARK: Grid

    /// Flexible columns on the shared card gap, so a row of cards resolves to
    /// exactly the same left and right edges as the full-width sections.
    private func columns(_ count: Int) -> [GridItem] {
        Array(repeating: GridItem(.flexible(minimum: 0), spacing: Theme.Space.m),
              count: max(1, count))
    }

    // MARK: Stats

    private func statsGrid(_ metrics: AgentWorkspaceMetrics) -> some View {
        LazyVGrid(columns: columns(metrics.statColumns),
                  alignment: .leading,
                  spacing: Theme.Space.m) {
            StatTile(title: "Connected Sites", value: "\(settings.workspaces.count)",
                     systemImage: "folder.fill", tint: Theme.accent)
            StatTile(title: "Changes Staged", value: "\(engine.pendingChanges.count)",
                     systemImage: "tray.full.fill", tint: Theme.warning)
            StatTile(title: "AI Provider", value: providerName,
                     systemImage: providerIcon, tint: Theme.accentDeep,
                     brandID: BrandMarkID.from(providerID: settings.providerID),
                     compact: true,
                     caption: settings.smartRouting ? "Auto-routing · \(settings.routingStrategy.rawValue)" : nil)
            StatTile(
                title: "Session Cost",
                value: engine.sessionCostUSD > 0
                    ? String(format: "$%.3f", engine.sessionCostUSD)
                    : "Cost tracking unavailable",
                systemImage: "dollarsign.circle.fill",
                tint: Theme.success,
                compact: engine.sessionCostUSD == 0,
                caption: engine.sessionCostUSD == 0 ? "Appears after reported token usage" : nil
            )
        }
    }

    private var providerName: String {
        if settings.smartRouting { return "Auto" }
        return ProviderRegistry.info(for: settings.providerID)?.displayName ?? "—"
    }

    private var providerIcon: String {
        ProviderRegistry.info(for: settings.providerID)?.icon ?? "cpu.fill"
    }

    // MARK: Quick actions

    private func quickActions(_ metrics: AgentWorkspaceMetrics) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            SectionHeader(title: "Quick Actions", systemImage: "bolt.fill")
            LazyVGrid(columns: columns(metrics.quickActionColumns),
                      alignment: .leading,
                      spacing: Theme.Space.m) {
                ActionCard(title: "New Chat", subtitle: "Talk to the agent",
                           systemImage: "bubble.left.fill", tint: Theme.accent) {
                    engine.newChat()
                    destination.wrappedValue = .agent
                }
                ActionCard(title: "Add Site", subtitle: "Connect a repo",
                           systemImage: "plus.circle.fill", tint: Theme.accentDeep) {
                    destination.wrappedValue = .sites
                }
                ActionCard(title: "Open in VS Code", subtitle: "Edit locally",
                           systemImage: "chevron.left.forwardslash.chevron.right", tint: Theme.success) {
                    NotificationCenter.default.post(name: .openInVSCode, object: nil)
                }
                ActionCard(title: "Preview", subtitle: "See the live site",
                           systemImage: "eye.fill", tint: Theme.warning) {
                    destination.wrappedValue = .preview
                }
                ActionCard(title: "Debug & Fix", subtitle: "Export to any agent",
                           systemImage: "ladybug.fill", tint: Theme.danger) {
                    NotificationCenter.default.post(name: .requestDebug, object: nil)
                }
            }
        }
    }

    // MARK: Recommendations

    private let suggestions: [(title: String, prompt: String, icon: String)] = [
        ("Optimize for SEO", "Audit my site's meta tags and headings, then improve SEO.", "magnifyingglass"),
        ("Refresh the hero", "Improve the hero section copy and call-to-action.", "wand.and.stars"),
        ("Fix accessibility", "Find and fix accessibility issues (alt text, contrast, labels).", "accessibility"),
        ("Add a project", "Add a new project entry to the portfolio section.", "square.stack.3d.up")
    ]

    private func recommendations(_ metrics: AgentWorkspaceMetrics) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            SectionHeader(title: "Ask the Agent", systemImage: "sparkles")
            LazyVGrid(columns: columns(metrics.suggestionColumns),
                      alignment: .leading,
                      spacing: Theme.Space.m) {
                ForEach(suggestions, id: \.title) { item in
                    SuggestionCard(title: item.title, icon: item.icon) {
                        engine.prefilledPrompt = item.prompt
                        engine.newChat()
                        destination.wrappedValue = .agent
                    }
                }
            }
        }
    }

    // MARK: Recent activity

    private var recentActivity: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            SectionHeader(title: "Recent Activity", systemImage: "clock.fill") {
                if isLoadingCommits { ProgressView().controlSize(.small) }
            }
            if recentCommits.isEmpty {
                Text(isLoadingCommits ? "Loading commits…" : "No recent commits.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .commandCard()
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(recentCommits.prefix(5).enumerated()), id: \.element.id) { index, commit in
                        CommitRow(commit: commit)
                        if index < min(recentCommits.count, 5) - 1 { Divider() }
                    }
                }
                .commandCard(padding: 0)
            }
        }
    }

    // MARK: No site

    private var noSiteCard: some View {
        EmptyStateView(
            systemImage: "globe.badge.chevron.backward",
            title: "Connect your first website",
            message: "Add a GitHub repository and an AI provider key, then tell the agent what to build.",
            actionTitle: "Add a Site"
        ) {
            destination.wrappedValue = .sites
        }
        .frame(minHeight: 320)
        .commandCard()
    }

    // MARK: Data

    private func loadCommits() async {
        guard let ws = settings.activeWorkspace,
              let token = await settings.resolvedGitHubToken(forAsync: ws), !token.isEmpty else {
            recentCommits = []
            return
        }
        isLoadingCommits = true
        defer { isLoadingCommits = false }
        let client = GitHubClient(token: token)
        recentCommits = (try? await client.commits(owner: ws.gitOwner, repo: ws.gitRepo,
                                                   branch: ws.gitBranch, limit: 5)) ?? []
    }
}

// MARK: - Action card

/// A tappable visual action: icon tile, title, subtitle.
struct ActionCard: View {
    let title: String
    let subtitle: String
    let systemImage: String
    var tint: Color = Theme.accent
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: Theme.Space.m) {
                IconTile(systemImage: systemImage, tint: tint, size: 38)
                VStack(alignment: .leading, spacing: 2) {
                    Text(LocalizedStringKey(title)).font(.body.weight(.semibold))
                    Text(LocalizedStringKey(subtitle)).font(.caption).foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .commandCard()
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Suggestion card

/// A compact, tappable AI prompt suggestion.
struct SuggestionCard: View {
    let title: String
    let icon: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: Theme.Space.s) {
                Image(systemName: icon)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Theme.violet)
                    .frame(width: 32, height: 32)
                    .background(Theme.violetSoft,
                                in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                Text(LocalizedStringKey(title))
                    .font(.callout.weight(.medium))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, Theme.Space.m)
            .padding(.vertical, Theme.Space.s + 2)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.cardFill, in: Capsule())
            .overlay(Capsule().strokeBorder(Theme.borderSubtle, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Commit row

struct CommitRow: View {
    let commit: CommitEntry

    var body: some View {
        HStack(spacing: Theme.Space.m) {
            Image(systemName: "arrow.triangle.branch")
                .foregroundStyle(Theme.tertiaryText)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(commit.message.split(separator: "\n").first.map(String.init) ?? commit.message)
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
                Text("\(commit.author) · \(commit.date.formatted(.relative(presentation: .named)))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text(commit.shortSHA)
                .font(.system(.caption, design: .monospaced))
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 5))
                .foregroundStyle(.secondary)
        }
        .padding(Theme.Space.m)
    }
}
