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
                        quickActions()
                        recommendations(metrics)
                        recentActivity
                    }
                }
                .padding(.horizontal, metrics.paddingX)
                .padding(.top, metrics.paddingTop)
                .padding(.bottom, metrics.paddingBottom)
                .frame(maxWidth: 1180, alignment: .leading)
                .frame(minWidth: 0, maxWidth: .infinity, alignment: .center)
            }
            .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
        }
        .background { GlassWorkspaceBackground() }
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
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundStyle(Theme.textHeading)
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

    /// Flexible columns on the shared card gap, so a row resolves to exactly the
    /// same left and right edges as the full-width sections.
    private func columns(_ count: Int) -> [GridItem] {
        Array(repeating: GridItem(.flexible(minimum: 0), spacing: Theme.Space.m),
              count: max(1, count))
    }

    // MARK: Stats

    private func statsGrid(_ metrics: AgentWorkspaceMetrics) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            SectionHeader(title: "Overview", systemImage: "chart.bar.fill")
            ZStack(alignment: .bottom) {
                Group {
                    if metrics.statColumns == 4 {
                        HStack(spacing: 0) {
                            metricCell(title: "Connected Sites", value: "\(settings.workspaces.count)",
                                       systemImage: "folder.fill", tint: Theme.secondaryText)
                            metricDivider
                            metricCell(title: "Changes Staged", value: "\(engine.pendingChanges.count)",
                                       systemImage: "tray.full.fill", tint: Theme.secondaryText)
                            metricDivider
                            metricCell(title: "AI Provider", value: providerName,
                                       systemImage: providerIcon, tint: Theme.accentDeep,
                                       caption: settings.smartRouting ? "Auto-routing" : nil)
                            metricDivider
                            metricCell(title: "Session Cost",
                                       value: engine.sessionCostUSD > 0
                                           ? String(format: "$%.3f", engine.sessionCostUSD)
                                           : "—",
                                       systemImage: "dollarsign.circle.fill",
                                       tint: Theme.success,
                                       caption: engine.sessionCostUSD == 0 ? "After the first run" : nil)
                        }
                    } else {
                        LazyVGrid(columns: columns(metrics.statColumns), alignment: .leading, spacing: 0) {
                            metricCell(title: "Connected Sites", value: "\(settings.workspaces.count)",
                                       systemImage: "folder.fill", tint: Theme.secondaryText)
                            metricCell(title: "Changes Staged", value: "\(engine.pendingChanges.count)",
                                       systemImage: "tray.full.fill", tint: Theme.secondaryText)
                            metricCell(title: "AI Provider", value: providerName,
                                       systemImage: providerIcon, tint: Theme.accentDeep,
                                       caption: settings.smartRouting ? "Auto-routing" : nil)
                            metricCell(title: "Session Cost",
                                       value: engine.sessionCostUSD > 0
                                           ? String(format: "$%.3f", engine.sessionCostUSD)
                                           : "—",
                                       systemImage: "dollarsign.circle.fill",
                                       tint: Theme.success,
                                       caption: engine.sessionCostUSD == 0 ? "After the first run" : nil)
                        }
                    }
                }
                if settings.activeWorkspace != nil {
                    AmbientTelemetryLine(tint: Theme.accent, active: true)
                        .padding(.horizontal, Theme.Space.s)
                        .padding(.bottom, 1)
                }
            }
            .padding(.horizontal, Theme.Space.s)
            .background(Theme.cardFill, in: RoundedRectangle(cornerRadius: Theme.Radius.medium,
                                                              style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: Theme.Radius.medium, style: .continuous)
                    .strokeBorder(Theme.borderSubtle, lineWidth: 1)
            }
            .overlay(alignment: .top) {
                RoundedRectangle(cornerRadius: Theme.Radius.medium, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.82), lineWidth: 1)
                    .mask(LinearGradient(colors: [.white, .clear],
                                          startPoint: .top,
                                          endPoint: .center))
            }
            .cardElevation()
        }
    }

    @ViewBuilder
    private func metricCell(title: String, value: String, systemImage: String,
                            tint: Color, caption: String? = nil) -> some View {
        CompactMetricCell(title: title, value: value, systemImage: systemImage,
                          tint: tint, caption: caption)
            .frame(maxWidth: .infinity)
    }

    private var metricDivider: some View {
        Divider()
            .frame(height: 44)
            .foregroundStyle(Theme.divider)
    }

    private var providerName: String {
        if settings.smartRouting { return "Auto" }
        return ProviderRegistry.info(for: settings.providerID)?.displayName ?? "—"
    }

    private var providerIcon: String {
        ProviderRegistry.info(for: settings.providerID)?.icon ?? "cpu.fill"
    }

    // MARK: Quick actions

    private func quickActions() -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            SectionHeader(title: "Quick Actions", systemImage: "bolt.fill")
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: Theme.Space.s) {
                    ActionCard(title: "New Chat", subtitle: "Talk to the agent",
                               systemImage: "bubble.left.fill", tint: Theme.accent,
                               isProminent: true) {
                        engine.newChat()
                        destination.wrappedValue = .agent
                    }
                    ActionCard(title: "Add Site", subtitle: "Connect a repo",
                               systemImage: "plus.circle.fill", tint: Theme.accentDeep) {
                        destination.wrappedValue = .sites
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) {
                            NotificationCenter.default.post(name: .requestAddSite, object: nil)
                        }
                    }
                    ActionCard(title: "Open in VS Code", subtitle: "Edit locally",
                               systemImage: "chevron.left.forwardslash.chevron.right", tint: Theme.success) {
                        NotificationCenter.default.post(name: .requestOpenInVSCode, object: nil)
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
            ChipFlowLayout(itemSpacing: Theme.Space.s, rowSpacing: Theme.Space.s) {
                ForEach(Array(suggestions.enumerated()), id: \.element.title) { index, item in
                    SuggestionCard(title: item.title, icon: item.icon) {
                        engine.prefilledPrompt = item.prompt
                        engine.newChat()
                        destination.wrappedValue = .agent
                    }
                    .wcAppear(delay: Double(index) * 0.024)
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

/// A compact action-strip control. These stay at one visual level so the
/// dashboard does not turn every action into a competing card.
struct ActionCard: View {
    let title: String
    let subtitle: String
    let systemImage: String
    var tint: Color = Theme.accent
    var isProminent = false
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: Theme.Space.s) {
                Image(systemName: systemImage)
                    .font(.system(size: Theme.IconSize.regular, weight: .semibold))
                    .frame(width: Theme.IconSize.regular)
                    .offset(y: isHovering ? -1 : 0)
                Text(LocalizedStringKey(title))
                    .font(Theme.ui(12.5, .semibold))
                    .lineLimit(1)
            }
            .foregroundStyle(isProminent ? Theme.textInverse : Theme.textPrimary)
            .padding(.horizontal, Theme.Space.m)
            .frame(height: Theme.Height.prominent)
            .background(isProminent
                        ? (isHovering ? Theme.accentHover : Theme.accent)
                        : (isHovering ? Theme.tertiarySurface : Theme.secondarySurface),
                        in: RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous)
                    .strokeBorder(isProminent ? .clear : Theme.borderHairline, lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
        .animation(Motion.interaction, value: isHovering)
        .onHover { isHovering = $0 }
        .help(LocalizedStringKey(subtitle))
    }
}

private struct CompactMetricCell: View {
    let title: String
    let value: String
    let systemImage: String
    let tint: Color
    var caption: String?

    var body: some View {
        HStack(spacing: Theme.Space.s) {
            Image(systemName: systemImage)
                .font(.system(size: Theme.IconSize.regular, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: Theme.IconSize.tile, height: Theme.IconSize.tile)
                .background(Theme.recessedSurface,
                            in: RoundedRectangle(cornerRadius: Theme.Radius.icon, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(LocalizedStringKey(title))
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(Theme.secondaryText)
                    .lineLimit(1)
                Text(value)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                    .contentTransition(.numericText())
                    .animation(Motion.gentle, value: value)
                if let caption {
                    Text(caption)
                        .font(.system(size: 9.5))
                        .foregroundStyle(Theme.tertiaryText)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, Theme.Space.m)
        .padding(.horizontal, Theme.Space.s)
        .frame(height: 80, alignment: .leading)
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
                    .font(.system(size: Theme.IconSize.metadata, weight: .semibold))
                    .foregroundStyle(Theme.accent)
                    .frame(width: Theme.IconSize.regular)
                Text(LocalizedStringKey(title))
                    .font(Theme.ui(12, .medium))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
            }
            .padding(.horizontal, Theme.Space.m)
            .frame(height: Theme.Height.control, alignment: .leading)
            .fixedSize(horizontal: true, vertical: false)
            .background(Theme.secondarySurface,
                        in: RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous)
                .strokeBorder(Theme.borderHairline, lineWidth: 1))
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
                .font(.system(size: 11, design: .monospaced))
                .padding(.horizontal, 6)
                .frame(height: Theme.Height.badge)
                .background(Theme.secondarySurface,
                            in: RoundedRectangle(cornerRadius: Theme.Radius.badge, style: .continuous))
                .foregroundStyle(.secondary)
            Image(systemName: "chevron.right")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Theme.tertiaryText)
        }
        .padding(.horizontal, Theme.Space.m)
        .frame(height: Theme.Height.detailedRow)
    }
}

/// A content-sized wrapping layout for prompt chips. Short prompts stay short;
/// they do not stretch into equal-width dashboard cards.
private struct ChipFlowLayout: Layout {
    let itemSpacing: CGFloat
    let rowSpacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews,
                      cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .greatestFiniteMagnitude
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        var usedWidth: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > maxWidth {
                y += rowHeight + rowSpacing
                x = 0
                rowHeight = 0
            }
            x += size.width
            usedWidth = max(usedWidth, x)
            x += itemSpacing
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: proposal.width ?? usedWidth, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize,
                       subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX {
                y += rowHeight + rowSpacing
                x = bounds.minX
                rowHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), anchor: .topLeading,
                          proposal: ProposedViewSize(size))
            x += size.width + itemSpacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}
