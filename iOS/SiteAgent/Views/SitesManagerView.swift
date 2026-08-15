import SwiftUI
import UIKit
import WebKit

struct SitesManagerView: View {
    @EnvironmentObject var engine: AgentEngine
    @Environment(\.openURL) private var openURL
    @Environment(\.colorScheme) private var colorScheme
    @State private var showAddWorkspace = false
    @State private var showConnectWizard = false
    @State private var showAddWebsiteChoice = false
    @State private var showSitePicker = false
    @State private var editingWorkspace: SiteWorkspace? = nil
    @State private var showPaywall = false
    @State private var pendingDelete: SiteWorkspace? = nil
    @State private var showSettings = false
    @State private var deploymentSettingsRoute: DeploymentSettingsRoute?
    @State private var deploymentSettingsPresented = false

    // Additive deploy telemetry for the Repository Health card. Loaded lazily and
    // guarded so it never blocks the UI; empty/unavailable falls back to "—".
    @State private var deployments: [DeploymentRecord] = []
    /// Bumps when deployment config (especially liveURL) changes so preview reloads.
    @State private var previewRefreshToken = 0
    /// Legacy workspaces may not have a saved liveURL. Resolve the GitHub
    /// homepage once for the active site so the preview tile remains useful.
    @State private var discoveredLiveURLs: [UUID: URL] = [:]

    private var activeLiveSiteURL: String {
        engine.activeWorkspace?.configuredLiveURL ?? ""
    }

    private var previewTaskID: String {
        let wsID = engine.activeWorkspace?.id.uuidString ?? "none"
        return "\(wsID)|\(activeLiveSiteURL)|\(previewRefreshToken)"
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    header

                    if let active = engine.activeWorkspace {
                        heroCard(active)
                        repositoryHealthCard(active)
                        latestPreviewCard(active)
                            .id(previewTaskID)
                        activeRepositoryTools(active)
                    } else {
                        connectPromptCard
                    }

                    addNewWebsiteCard
                }
                .padding(.horizontal, 16)
                .padding(.top, 2)
                .padding(.bottom, AppSize.scrollContentBottomSpacing)
                .readableWidth()
            }
            .commandBackground()
            // iOS 26 Liquid Glass renders the hidden-nav-bar shell edge-to-edge;
            // keep the first card below the status bar so nothing overlaps it.
            .safeAreaPadding(.top, 10)
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar(.hidden, for: .navigationBar)
            .task(id: previewTaskID) {
                await loadPreviewMetadata()
                await loadDeployments()
            }
            .onAppear { engine.refreshActiveWorkspaceFromDisk() }
            .onChange(of: activeLiveSiteURL) { _, _ in
                previewRefreshToken += 1
            }
            .onChange(of: engine.activeWorkspace?.id) { _, _ in
                previewRefreshToken += 1
            }
            .onChange(of: deploymentSettingsRoute) { _, route in
                guard route == nil else { return }
                engine.refreshActiveWorkspaceFromDisk()
                previewRefreshToken += 1
            }
            .sheet(isPresented: $showSettings) {
                SettingsView()
                    .environmentObject(engine)
            }
            .sheet(isPresented: $showAddWorkspace) {
                AddWorkspaceSheet().environmentObject(engine)
            }
            .sheet(isPresented: $showConnectWizard) {
                ConnectWebsiteWizardView().environmentObject(engine)
            }
            .sheet(isPresented: $showSitePicker) {
                SitePickerSheet(
                    workspaces: engine.workspaces,
                    activeWorkspaceID: engine.activeWorkspace?.id,
                    previewURLs: discoveredLiveURLs,
                    onSelect: { workspace in
                        Haptics.tap()
                        engine.selectWorkspace(workspace)
                        showSitePicker = false
                    },
                    onEdit: { workspace in
                        showSitePicker = false
                        editingWorkspace = workspace
                    },
                    onDelete: { workspace in
                        showSitePicker = false
                        pendingDelete = workspace
                    },
                    onAdd: {
                        showSitePicker = false
                        showAddWebsiteChoice = true
                    }
                )
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
            }
            .confirmationDialog(
                "Add a website",
                isPresented: $showAddWebsiteChoice,
                titleVisibility: .visible
            ) {
                Button("Create New Site") {
                    Haptics.tap()
                    showAddWorkspace = true
                }
                Button("Connect Existing Site") {
                    Haptics.tap()
                    showConnectWizard = true
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Start a new GitHub site from a template, or connect a repository you already have.")
            }
            .sheet(item: $editingWorkspace) { ws in
                AddWorkspaceSheet(editingWorkspace: ws).environmentObject(engine)
            }
            .sheet(isPresented: $showPaywall) {
                ProPaywall()
            }
            // isPresented-based push: the deprecated item-based variant can crash
            // on current iOS when set from a button inside a presented sheet.
            .navigationDestination(isPresented: $deploymentSettingsPresented) {
                if let route = deploymentSettingsRoute {
                    DeploymentSettingsView(
                        engine: engine,
                        workspaceID: route.workspaceID,
                        simpleMode: true
                    )
                }
            }
            .onChange(of: deploymentSettingsPresented) { _, presented in
                if !presented { deploymentSettingsRoute = nil }
            }
            .onChange(of: engine.requestedDeploymentSettings) { _, requested in
                guard requested else { return }
                engine.requestedDeploymentSettings = false
                presentDeploymentSettings()
            }
            .onChange(of: engine.requestedConnectWizard) { _, requested in
                guard requested else { return }
                engine.requestedConnectWizard = false
                showConnectWizard = true
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

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Sites Manager")
                    .font(.display(34, .bold, relativeTo: .largeTitle))
                    .foregroundStyle(CC.text)
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)
                SectionHeader("Manage your connected websites")
            }
            Spacer(minLength: 8)
            Button {
                Haptics.tap()
                showSettings = true
            } label: {
                Image(systemName: "gearshape")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(CC.accent)
                    .frame(width: 46, height: 46)
                    .adaptiveGlassSurface(
                        .toolbarButton,
                        cornerRadius: 23,
                        accentReflection: nil,
                        classicFill: CC.card
                    )
            }
            .buttonStyle(.glassPress)
            .accessibilityLabel("Settings")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Connect prompt (no active workspace)

    private var connectPromptCard: some View {
        Button {
            Haptics.tap()
            showConnectWizard = true
        } label: {
            VStack(spacing: 14) {
                GlobeAvatar(systemImage: "globe.badge.chevron.backward", size: 56)
                VStack(spacing: 4) {
                    Text("No site connected")
                        .font(.display(18, .semibold, relativeTo: .headline))
                        .foregroundStyle(Theme.t1)
                    Text("Connect a website in a few steps — GitHub, hosting, and AI.")
                        .font(.ui(13))
                        .foregroundStyle(Theme.t2)
                        .multilineTextAlignment(.center)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(24)
            .commandCard(glow: true)
        }
        .buttonStyle(.pressable)
        .accessibilityLabel("Connect a website")
    }

    // MARK: - Connected workspace hero

    private func heroCard(_ ws: SiteWorkspace) -> some View {
        let liveURL = ws.configuredLiveURL
        let lastEdited = lastDeployDateText

        return VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top, spacing: 14) {
                siteHeroAvatar(systemImage: iconForStack(ws.techStack))
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        Text(ws.name)
                            .font(.display(20, .bold, relativeTo: .title3))
                            .foregroundStyle(CC.text)
                            .lineLimit(1).minimumScaleFactor(0.7)
                        siteHeroStatusPill("Active")
                    }
                    Text(ws.slug)
                        .font(.mono(12))
                        .foregroundStyle(CC.textSub)
                        .lineLimit(1).minimumScaleFactor(0.7)
                }
                Spacer(minLength: 6)
                if engine.workspaces.count > 1 {
                    Button {
                        Haptics.tap()
                        showSitePicker = true
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "arrow.up.arrow.down")
                                .font(.system(size: 11, weight: .bold))
                            Text("Switch")
                                .font(.ui(12, .semibold))
                        }
                        .foregroundStyle(CC.text)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 9)
                        .adaptiveGlassSurface(.button, cornerRadius: 999, classicFill: CC.card)
                    }
                    .buttonStyle(.glassPress)
                    .accessibilityLabel("Switch active site")
                    .accessibilityHint("\(engine.workspaces.count) sites available")
                } else {
                    ECGWaveform(color: CC.accent)
                        .frame(width: 90, height: 34)
                        .opacity(0.85)
                }
            }

            HStack(spacing: 8) {
                siteHeroMetadataPill(text: ws.techStack.rawValue, systemImage: iconForStack(ws.techStack))
                siteHeroMetadataPill(text: ws.deployment.rawValue, systemImage: "arrow.up.forward.app")
            }

            Divider().overlay(CC.stroke)
                .padding(.vertical, 2)

            HStack(alignment: .center, spacing: 16) {
                if let lastEdited {
                    siteHeroFooterItem(icon: "clock", label: "Last edited", value: lastEdited)
                }
                if !liveURL.isEmpty {
                    HStack(spacing: 6) {
                        Circle().fill(CC.accent).frame(width: 7, height: 7)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("LIVE URL")
                                .font(.mono(9, .medium)).kerning(0.6)
                                .foregroundStyle(CC.textSub)
                            Text(prettyURL(liveURL))
                                .font(.mono(12, .medium))
                                .foregroundStyle(CC.accent)
                                .lineLimit(1).truncationMode(.middle)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                Spacer(minLength: 0)
                if !liveURL.isEmpty {
                    Button {
                        Haptics.tap()
                        openExternal(liveURL)
                    } label: {
                        HStack(spacing: 6) {
                            Text("Open Site").font(.ui(13, .semibold))
                            Image(systemName: "arrow.up.right.square")
                                .font(.system(size: 13, weight: .semibold))
                        }
                        .foregroundStyle(CC.text)
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                        .padding(.horizontal, 14).padding(.vertical, 9)
                        .adaptiveGlassSurface(.button, cornerRadius: 999, classicFill: CC.card)
                    }
                    .buttonStyle(.glassPress)
                    .accessibilityLabel("Open site in browser")
                }
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        // Do not `.clipShape` after glass — clipping kills Liquid Glass sampling.
        .background { siteHeroSurface(cornerRadius: 22) }
        .shadow(color: Theme.isGlass ? .clear : CC.accent.opacity(0.14), radius: 18, y: 0)
    }

    @ViewBuilder
    private func siteHeroSurface(cornerRadius: CGFloat) -> some View {
        if Theme.isGlass {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(.clear)
                .glassSurface(.hero, cornerRadius: cornerRadius, accentReflection: nil)
        } else {
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [
                                colorScheme == .dark ? Color.white.opacity(0.075) : CC.cardHi,
                                CC.cardHi.opacity(0.96),
                                CC.card
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                RadialGradient(
                    colors: [CC.accent.opacity(0.10), .clear],
                    center: .center,
                    startRadius: 0,
                    endRadius: 170
                )
                .frame(width: 250, height: 150)
                .offset(x: -72, y: -64)
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(CC.strokeGreen, lineWidth: 1)
            }
        }
    }

    private func siteHeroAvatar(systemImage: String) -> some View {
        Group {
            if Theme.isGlass {
                Image(systemName: systemImage)
                    .font(.system(size: 24, weight: .semibold))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(CC.accent)
                    .frame(width: 54, height: 54)
                    .glassSurface(.icon, cornerRadius: 27, accentReflection: nil)
            } else {
                ZStack {
                    Circle()
                        .fill(
                            LinearGradient(
                                colors: [CC.textGreen, CC.accent],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                    Image(systemName: systemImage)
                        .font(.system(size: 24, weight: .semibold))
                        .foregroundStyle(.white)
                }
                .frame(width: 54, height: 54)
                .overlay(Circle().strokeBorder(Color.white.opacity(0.12), lineWidth: 1))
                .shadow(color: CC.accent.opacity(0.25), radius: 14, y: 5)
            }
        }
        .accessibilityHidden(true)
    }

    private func siteHeroStatusPill(_ text: String) -> some View {
        HStack(spacing: 5) {
            Circle().fill(CC.accent).frame(width: 6, height: 6)
            Text(text)
                .font(.mono(11, .semibold))
                .lineLimit(1)
        }
        .foregroundStyle(CC.accent)
        .padding(.horizontal, 9)
        .padding(.vertical, 4)
        .adaptiveGlassSurface(.badge, cornerRadius: 999,
                              accentReflection: CC.accent, classicFill: CC.accentDim)
        .fixedSize()
        .accessibilityElement(children: .combine)
    }

    private func siteHeroMetadataPill(text: String, systemImage: String) -> some View {
        HStack(spacing: 5) {
            Image(systemName: systemImage)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(CC.textSub)
            Text(text)
                .font(.mono(11, .medium))
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        }
        .foregroundStyle(CC.text)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .adaptiveGlassSurface(.capsule, cornerRadius: 999, classicFill: CC.card)
        .accessibilityElement(children: .combine)
    }

    private func siteHeroFooterItem(icon: String, label: String, value: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(CC.accent)
                .frame(width: 26, height: 26)
                .adaptiveGlassSurface(.icon, cornerRadius: 13,
                                      accentReflection: CC.accent, classicFill: CC.accentDim)
            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                    .font(.ui(11))
                    .foregroundStyle(CC.textSub)
                Text(value)
                    .font(.ui(12, .medium))
                    .foregroundStyle(CC.text)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(label): \(value)")
    }

    // MARK: - Repository health

    private func repositoryHealthCard(_ ws: SiteWorkspace) -> some View {
        let staged = engine.pendingChanges.count
        let cleanText = staged == 0 ? "Clean" : "\(staged) staged"
        let cleanTint: Color = staged == 0 ? Theme.ok : Theme.warn

        return VStack(alignment: .leading, spacing: 14) {
            SectionHeader("Repository Health")
            HStack(alignment: .top, spacing: 0) {
                LabeledStat(icon: "arrow.triangle.branch",
                            label: "Branch",
                            value: engine.repo.branch.isEmpty ? "—" : engine.repo.branch)
                LabeledStat(icon: "tray.full",
                            label: "Staged",
                            value: cleanText,
                            valueTint: cleanTint)
                LabeledStat(icon: "icloud.and.arrow.up",
                            label: "Deploys today",
                            value: deploysTodayText)
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .commandCard()
    }

    // MARK: - Latest preview

    private func latestPreviewCard(_ ws: SiteWorkspace) -> some View {
        let resolved = resolvedPreviewURL(for: ws)
        let displayURL = resolved?.absoluteString ?? ""
        return VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Image(systemName: "eye")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(CC.accent)
                Text("Latest Preview")
                    .font(.ui(14, .medium))
                    .foregroundStyle(CC.text)
                Spacer(minLength: 8)
                if let url = resolved {
                    Button {
                        Haptics.tap()
                        openURL(url)
                    } label: {
                        HStack(spacing: 5) {
                            Text("View Live")
                                .font(.ui(12, .semibold))
                            Image(systemName: "arrow.up.right.square")
                                .font(.system(size: 12, weight: .semibold))
                        }
                        .foregroundStyle(CC.accent)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("View live site")
                }
            }

            ViewThatFits(in: .horizontal) {
                HStack(alignment: .center, spacing: 16) {
                    latestPreviewThumbnail(url: resolved)
                        .frame(width: 178, height: 112)
                    latestPreviewDetails(ws: ws, liveURL: displayURL)
                }

                VStack(alignment: .leading, spacing: 14) {
                    latestPreviewThumbnail(url: resolved)
                        .aspectRatio(16 / 10, contentMode: .fit)
                    latestPreviewDetails(ws: ws, liveURL: displayURL)
                }
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .commandCard()
    }

    @ViewBuilder
    private func latestPreviewThumbnail(url: URL?) -> some View {
        if let url {
            LiveSiteThumbnail(
                url: url,
                refreshID: "\(previewTaskID)|\(url.absoluteString)"
            )
        } else {
            LatestPreviewEmptyState(configuredURL: activeLiveSiteURL)
        }
    }

    private func latestPreviewDetails(ws: SiteWorkspace, liveURL: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(ws.name)
                .font(.display(20, .semibold, relativeTo: .title3))
                .foregroundStyle(CC.text)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            if !liveURL.isEmpty {
                Text(prettyURL(liveURL))
                    .font(.mono(13, .medium))
                    .foregroundStyle(CC.accent)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            if let date = lastDeployDateText {
                HStack(spacing: 6) {
                    Circle().fill(CC.accent).frame(width: 7, height: 7)
                    Text("Deployed \(date)")
                        .font(.ui(12))
                        .foregroundStyle(CC.textSub)
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                }
            }
            Text("Production")
                .font(.ui(12, .medium))
                .foregroundStyle(CC.accent)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    // MARK: - Active repository tools

    @ViewBuilder
    private func activeRepositoryTools(_ ws: SiteWorkspace) -> some View {
        let columns = [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)]
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader("Active Repository")
            LazyVGrid(columns: columns, spacing: 12) {
                // Keep the existing gate: only reachable with an active workspace
                // and a GitHub token.
                if engine.hasGitHubToken {
                    NavigationLink {
                        FileBrowserView()
                    } label: {
                        ToolTile(title: "Browse Files",
                                 subtitle: "Files & history",
                                 icon: "folder")
                    }
                    .buttonStyle(.pressable)
                    .accessibilityLabel("Browse files and history")
                }

                NavigationLink {
                    DeploymentSettingsView(engine: engine)
                } label: {
                    ToolTile(title: "Deploy Settings",
                             subtitle: "Build & publish",
                             icon: "paperplane",
                             tint: Theme.info)
                }
                .buttonStyle(.pressable)
                .accessibilityLabel("Deploy settings")

                NavigationLink {
                    DeploymentSettingsView(engine: engine, scrollTo: "domains")
                } label: {
                    ToolTile(title: "Domain",
                             subtitle: "Custom domain",
                             icon: "globe",
                             tint: Theme.brand)
                }
                .buttonStyle(.pressable)
                .accessibilityLabel("Domain settings")

                NavigationLink {
                    DeploymentSettingsView(engine: engine, scrollTo: "environment")
                } label: {
                    ToolTile(title: "Secrets",
                             subtitle: "Env vars & tokens",
                             icon: "key.fill",
                             tint: Theme.warn)
                }
                .buttonStyle(.pressable)
                .accessibilityLabel("Secrets and environment variables")

                if engine.hasGitHubToken {
                    NavigationLink {
                        FileBrowserView(initialMode: 1)
                    } label: {
                        ToolTile(title: "Activity",
                                 subtitle: "Commit history",
                                 icon: "clock.arrow.circlepath",
                                 tint: Theme.ok)
                    }
                    .buttonStyle(.pressable)
                    .accessibilityLabel("Activity and commit history")
                }
            }
        }
    }

    // MARK: - Add new website

    private var addNewWebsiteCard: some View {
        Button {
            Haptics.tap()
            if IAPManager.shared.isPro || engine.workspaces.isEmpty {
                showAddWebsiteChoice = true
            } else {
                showPaywall = true
            }
        } label: {
            HStack(spacing: 14) {
                ZStack {
                    if Theme.isGlass {
                        Image(systemName: "plus")
                            .font(.system(size: 18, weight: .bold))
                            .foregroundStyle(Theme.brand)
                            .frame(width: 46, height: 46)
                            .glassSurface(.icon, cornerRadius: 23, accentReflection: nil)
                    } else {
                        Circle().fill(Theme.brand.opacity(0.16)).frame(width: 46, height: 46)
                        Image(systemName: "plus")
                            .font(.system(size: 18, weight: .bold))
                            .foregroundStyle(Theme.brand)
                    }
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text("Add New Website")
                        .font(.ui(16, .semibold))
                        .foregroundStyle(Theme.t1)
                    Text("Create or connect a site and deploy")
                        .font(.ui(12))
                        .foregroundStyle(Theme.t2)
                        .lineLimit(1).minimumScaleFactor(0.7)
                }
                Spacer(minLength: 4)
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(Theme.t3)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                if !Theme.isGlass {
                    RoundedRectangle(cornerRadius: Theme.corner, style: .continuous)
                        .strokeBorder(Theme.brand.opacity(0.4),
                                      style: StrokeStyle(lineWidth: 1.2, dash: [6, 5]))
                }
            }
            .commandCard(glow: true)
        }
        .buttonStyle(.pressable)
        .accessibilityLabel("Add new website")
        .accessibilityHint("Create or connect a site and deploy")
    }

    // MARK: - Deploy telemetry (additive, guarded)

    /// Count of deployments created today; "—" when no client / no data.
    private var deploysTodayText: String {
        guard !deployments.isEmpty else { return "—" }
        let today = deployments.filter {
            guard let created = $0.createdAt else { return false }
            return Calendar.current.isDateInToday(created)
        }
        return "\(today.count)"
    }

    /// Most recent deploy date (e.g. "Jun 28"), used for "Last edited" / "Deployed".
    private var lastDeployDateText: String? {
        let dates = deployments.compactMap { $0.createdAt }
        guard let latest = dates.max() else { return nil }
        let fmt = DateFormatter()
        fmt.dateFormat = "MMM d"
        return fmt.string(from: latest)
    }

    private func loadDeployments() async {
        #if DEBUG
        if AgentEngine.screenshotDemo { deployments = HomeDashboardView.demoDeployments; return }
        #endif
        guard let ws = engine.activeWorkspace,
              let client = DeploymentClientFactory.client(for: ws, repo: engine.repo) else {
            deployments = []
            return
        }
        let workspaceID = ws.id.uuidString
        if let cached = DeploymentHistoryCache.records(for: workspaceID), !cached.isEmpty {
            deployments = cached
        }
        do {
            let records = try await client.listDeployments(limit: 10, commitSHA: nil)
            deployments = records
        } catch {
            if DeploymentClientError.map(error).isCancellation { return }
            // Keep cached rows on transient failure; only clear when nothing is available.
            if deployments.isEmpty {
                deployments = DeploymentHistoryCache.records(for: workspaceID) ?? []
            }
        }
    }

    private func loadPreviewMetadata() async {
        // Resolve every connected site, not only the active one. The site
        // picker needs the same preview metadata before a user switches.
        for workspace in engine.workspaces {
            guard !Task.isCancelled,
                  SiteWorkspace.normalizedLiveURL(workspace.configuredLiveURL) == nil else { continue }
            let repo = RepoConfig(
                owner: workspace.gitOwner,
                name: workspace.gitRepo,
                branch: workspace.gitBranch,
                githubCredentialID: workspace.githubCredentialID
            )
            var resolved: URL?

            if !repo.isEmpty {
                do {
                    if let homepage = try await GitHubClient(repo: repo).repositoryHomepage() {
                        resolved = SiteWorkspace.normalizedLiveURL(homepage)
                    }
                } catch {
                    // Continue with the hosting provider's deployment metadata.
                }
            }

            if resolved == nil {
                let rootDirectory = workspace.deploymentConfig["rootDirectory"] ?? ""
                resolved = await GitHubClient(repo: repo)
                    .repositoryConfiguredLiveURL(rootDirectory: rootDirectory)
            }

            // A repository homepage is not always configured. Provider records
            // and custom domains are the next authoritative sources; this also
            // prevents the picker from showing a blank card for a deployed site.
            if resolved == nil, let client = DeploymentClientFactory.client(for: workspace, repo: repo) {
                if let latest = try? await client.listDeployments(limit: 1, commitSHA: nil).first,
                   let url = SiteWorkspace.normalizedLiveURL(latest.displayURL) {
                    resolved = url
                }
                if resolved == nil,
                   let domain = try? await client.domains().first,
                   let url = SiteWorkspace.normalizedLiveURL(domain.name) {
                    resolved = url
                }
            }

            if resolved == nil {
                resolved = derivedWorkersPreviewURL(for: workspace)
            }

            if let resolved, !Task.isCancelled {
                discoveredLiveURLs[workspace.id] = resolved
            }
        }
    }

    // MARK: - Helpers

    private func openExternal(_ raw: String) {
        if let url = SiteWorkspace.normalizedLiveURL(raw) {
            openURL(url)
        }
    }

    private func presentDeploymentSettings() {
        guard let workspaceID = engine.activeWorkspace?.id else {
            showConnectWizard = true
            return
        }
        deploymentSettingsRoute = DeploymentSettingsRoute(workspaceID: workspaceID)
        deploymentSettingsPresented = true
    }

    /// Best-effort production URL for the preview thumbnail. Workers deployments
    /// expose no public URL in the API, so liveURL (or a derived workers.dev URL)
    /// must be configured. Recomputes when `deployments` finishes loading.
    private func resolvedPreviewURL(for ws: SiteWorkspace) -> URL? {
        if let configured = SiteWorkspace.normalizedLiveURL(ws.configuredLiveURL) {
            return configured
        }

        if let discovered = discoveredLiveURLs[ws.id] { return discovered }

        // Deployment history belongs to the active workspace. Never use it as
        // another site's thumbnail URL in the site switcher.
        if ws.id == engine.activeWorkspace?.id {
            let deploymentURL = (deployments.first?.displayURL ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if !deploymentURL.isEmpty, let url = SiteWorkspace.normalizedLiveURL(deploymentURL) { return url }
        }

        return ws.previewURLCandidate
    }

    /// `{worker}.{subdomain}.workers.dev` when both names are known.
    private func derivedWorkersPreviewURL(for ws: SiteWorkspace) -> URL? {
        let worker = (ws.deploymentConfig["cloudflareWorkerName"] ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !worker.isEmpty else { return nil }
        let subdomain = (ws.deploymentConfig["cloudflareAccountSubdomain"] ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !subdomain.isEmpty {
            return SiteWorkspace.normalizedLiveURL("\(worker).\(subdomain).workers.dev")
        }
        return nil
    }

    private func prettyURL(_ raw: String) -> String {
        var s = raw
        for prefix in ["https://", "http://"] where s.hasPrefix(prefix) {
            s.removeFirst(prefix.count)
        }
        if s.hasSuffix("/") { s.removeLast() }
        return s
    }

    private func iconForStack(_ stack: TechStack) -> String {
        stack.icon
    }
}

private enum SitePreviewLoadPhase: Equatable {
    case loading
    case ready
    case failed
}

/// Snapshot-based live preview — loads the URL in an offscreen WKWebView, captures
/// a still image, and displays that. Avoids Mac Catalyst layout fights where a scaled
/// embedded WKWebView renders as a black box in a tiny thumbnail frame.
private struct LiveSiteThumbnail: View {
    let url: URL
    var refreshID: String = ""
    @Environment(\.openURL) private var openURL
    @State private var snapshot: UIImage?
    @State private var phase: SitePreviewLoadPhase = .loading

    var body: some View {
        ZStack {
            Color.black

            if let snapshot, phase == .ready {
                Image(uiImage: snapshot)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .transition(.opacity)
            }

            if phase == .loading {
                SitePreviewPlaceholder()
                    .transition(.opacity)
            }

            if phase == .failed {
                SitePreviewUnavailableState(url: url, openURL: openURL)
                    .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(CC.stroke, lineWidth: 1))
        .clipped()
        .background(Color.black, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            SitePreviewSnapshotLoader(
                url: url,
                reloadID: refreshID.isEmpty ? url.absoluteString : refreshID
            ) { image in
                snapshot = image
                phase = .ready
            } onFailure: {
                phase = .failed
            }
            // Offscreen loader — non-zero frame so WebKit can paint before snapshot.
            .frame(width: 820, height: 512)
            .opacity(0.01)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
        .task(id: refreshID.isEmpty ? url.absoluteString : refreshID) {
            snapshot = nil
            phase = .loading
        }
        .accessibilityLabel(phase == .ready ? "Live site preview" : "Site preview loading")
    }
}

private struct SitePreviewSnapshotLoader: UIViewRepresentable {
    let url: URL
    let reloadID: String
    let onSnapshot: (UIImage) -> Void
    let onFailure: () -> Void

    private static let viewport = CGSize(width: 820, height: 512)

    func makeCoordinator() -> Coordinator {
        Coordinator(onSnapshot: onSnapshot, onFailure: onFailure)
    }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.suppressesIncrementalRendering = false
        let frame = CGRect(origin: .zero, size: Self.viewport)
        let webView = WKWebView(frame: frame, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.isOpaque = true
        webView.backgroundColor = .black
        webView.scrollView.backgroundColor = .black
        webView.scrollView.isScrollEnabled = false
        webView.scrollView.bounces = false
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        webView.isUserInteractionEnabled = false
        webView.customUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 14_0) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15"
        context.coordinator.attach(webView)
        context.coordinator.load(url, reloadID: reloadID, in: webView)
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        context.coordinator.load(url, reloadID: reloadID, in: webView)
    }

    static func dismantleUIView(_ webView: WKWebView, coordinator: Coordinator) {
        coordinator.cancelPendingCapture()
        webView.navigationDelegate = nil
        webView.stopLoading()
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        let onSnapshot: (UIImage) -> Void
        let onFailure: () -> Void
        private var currentURL: URL?
        private var currentReloadID: String?
        private var captured = false
        private var captureWorkItem: DispatchWorkItem?
        private weak var webView: WKWebView?

        init(onSnapshot: @escaping (UIImage) -> Void, onFailure: @escaping () -> Void) {
            self.onSnapshot = onSnapshot
            self.onFailure = onFailure
        }

        func attach(_ webView: WKWebView) {
            self.webView = webView
        }

        func cancelPendingCapture() {
            captureWorkItem?.cancel()
            captureWorkItem = nil
        }

        func load(_ url: URL, reloadID: String, in webView: WKWebView) {
            guard currentURL != url || currentReloadID != reloadID else { return }
            currentURL = url
            currentReloadID = reloadID
            captured = false
            cancelPendingCapture()
            scheduleLoadTimeout()
            webView.load(URLRequest(
                url: url,
                cachePolicy: .reloadRevalidatingCacheData,
                timeoutInterval: 25
            ))
        }

        private func scheduleLoadTimeout() {
            cancelPendingCapture()
            let work = DispatchWorkItem { [weak self] in
                guard let self, !self.captured else { return }
                self.captured = true
                DispatchQueue.main.async { self.onFailure() }
            }
            captureWorkItem = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 30, execute: work)
        }

        private func scheduleCapture(in webView: WKWebView, delay: TimeInterval) {
            guard !captured else { return }
            cancelPendingCapture()
            let work = DispatchWorkItem { [weak self, weak webView] in
                guard let self, let webView, !self.captured else { return }
                self.capture(from: webView)
            }
            captureWorkItem = work
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
        }

        private func capture(from webView: WKWebView) {
            guard !captured else { return }
            captured = true
            cancelPendingCapture()
            webView.takeSnapshot(with: nil) { [weak self] image, error in
                DispatchQueue.main.async {
                    guard let self else { return }
                    if let image {
                        self.onSnapshot(image)
                    } else {
                        _ = error
                        self.onFailure()
                    }
                }
            }
        }

        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            captured = false
            cancelPendingCapture()
            // didStart cancels the initial timer; restart it for redirects or
            // pages that never reach didCommit/didFinish so a thumbnail cannot
            // remain in its loading state forever.
            scheduleLoadTimeout()
        }

        func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
            scheduleCapture(in: webView, delay: 0.35)
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            scheduleCapture(in: webView, delay: 0.15)
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            guard !captured else { return }
            captured = true
            cancelPendingCapture()
            DispatchQueue.main.async { self.onFailure() }
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            guard !captured else { return }
            captured = true
            cancelPendingCapture()
            DispatchQueue.main.async { self.onFailure() }
        }
    }
}

private struct SitePickerSheet: View {
    @Environment(\.dismiss) private var dismiss

    let workspaces: [SiteWorkspace]
    let activeWorkspaceID: UUID?
    let previewURLs: [UUID: URL]
    let onSelect: (SiteWorkspace) -> Void
    let onEdit: (SiteWorkspace) -> Void
    let onDelete: (SiteWorkspace) -> Void
    let onAdd: () -> Void

    @State private var focusedWorkspaceID: UUID?

    init(
        workspaces: [SiteWorkspace],
        activeWorkspaceID: UUID?,
        previewURLs: [UUID: URL],
        onSelect: @escaping (SiteWorkspace) -> Void,
        onEdit: @escaping (SiteWorkspace) -> Void,
        onDelete: @escaping (SiteWorkspace) -> Void,
        onAdd: @escaping () -> Void
    ) {
        self.workspaces = workspaces
        self.activeWorkspaceID = activeWorkspaceID
        self.previewURLs = previewURLs
        self.onSelect = onSelect
        self.onEdit = onEdit
        self.onDelete = onDelete
        self.onAdd = onAdd
        _focusedWorkspaceID = State(initialValue: activeWorkspaceID ?? workspaces.first?.id)
    }

    private var focusedWorkspace: SiteWorkspace? {
        workspaces.first { $0.id == focusedWorkspaceID } ?? workspaces.first
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    HStack {
                        Text("\(workspaces.count) connected sites")
                            .font(.subheadline)
                            .foregroundStyle(Theme.t2)
                        Spacer()
                        Button(action: onAdd) {
                            Label("Add Site", systemImage: "plus")
                                .font(.subheadline.weight(.semibold))
                        }
                    }

                    TabView(selection: $focusedWorkspaceID) {
                        ForEach(workspaces) { workspace in
                            VisualSiteCard(
                                workspace: workspace,
                                isActive: workspace.id == activeWorkspaceID,
                                previewURL: previewURLs[workspace.id] ?? workspace.previewURLCandidate
                            )
                            .padding(.horizontal, 2)
                            .tag(Optional(workspace.id))
                        }
                    }
                    .tabViewStyle(.page(indexDisplayMode: .never))
                    .frame(height: 338)

                    SiteThumbnailStrip(
                        workspaces: workspaces,
                        activeWorkspaceID: activeWorkspaceID,
                        previewURLs: previewURLs,
                        focusedWorkspaceID: $focusedWorkspaceID
                    )

                    if let workspace = focusedWorkspace {
                        HStack(spacing: 12) {
                            Button {
                                onSelect(workspace)
                            } label: {
                                Label(
                                    workspace.id == activeWorkspaceID ? "Current Site" : "Switch to \(workspace.name)",
                                    systemImage: workspace.id == activeWorkspaceID
                                        ? "checkmark.circle.fill"
                                        : "arrow.left.arrow.right"
                                )
                                .font(.headline)
                                .frame(maxWidth: .infinity)
                                .frame(height: 48)
                            }
                            .buttonStyle(.borderedProminent)
                            .buttonBorderShape(.roundedRectangle(radius: 15))
                            .tint(Theme.brand)
                            .disabled(workspace.id == activeWorkspaceID)

                            Menu {
                                Button { onEdit(workspace) } label: {
                                    Label("Edit Site", systemImage: "pencil")
                                }
                                Button(role: .destructive) { onDelete(workspace) } label: {
                                    Label("Remove Site", systemImage: "trash")
                                }
                            } label: {
                                Image(systemName: "ellipsis")
                                    .font(.system(size: 18, weight: .semibold))
                                    .frame(width: 48, height: 48)
                                    .adaptiveGlassSurface(
                                        .button,
                                        cornerRadius: 15,
                                        classicFill: Theme.chip
                                    )
                            }
                            .buttonStyle(.glassPress)
                            .accessibilityLabel("More actions for \(workspace.name)")
                        }
                    }
                }
                .padding(.horizontal, 18)
                .padding(.top, 8)
                .padding(.bottom, 30)
            }
            .commandBackground()
            .navigationTitle("Switch Site")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Close") { dismiss() }
                }
            }
        }
    }
}

private struct VisualSiteCard: View {
    let workspace: SiteWorkspace
    let isActive: Bool
    let previewURL: URL?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ZStack(alignment: .topTrailing) {
                Group {
                    if let previewURL {
                        LiveSiteThumbnail(
                            url: previewURL,
                            refreshID: "switch-card|\(workspace.id.uuidString)|\(previewURL.absoluteString)"
                        )
                    } else {
                        ZStack {
                            LinearGradient(
                                colors: [
                                    Theme.brand.opacity(0.24),
                                    Theme.chip,
                                    CC.accent.opacity(0.12)
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                            Image(systemName: workspace.techStack.icon)
                                .font(.system(size: 46, weight: .medium))
                                .symbolRenderingMode(.hierarchical)
                                .foregroundStyle(Theme.brand)
                        }
                    }
                }
                .frame(height: 205)
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))

                if isActive {
                    Label("Active", systemImage: "checkmark.circle.fill")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(Theme.ok)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 7)
                        .adaptiveGlassSurface(
                            .badge,
                            cornerRadius: 999,
                            accentReflection: Theme.ok,
                            classicFill: CC.card
                        )
                        .padding(12)
                }
            }

            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(workspace.name)
                        .font(.title2.weight(.bold))
                        .foregroundStyle(Theme.t1)
                        .lineLimit(1)
                    Text(workspace.slug)
                        .font(.caption.monospaced())
                        .foregroundStyle(Theme.t3)
                        .lineLimit(1)
                }
                Spacer()
                Text(workspace.deployment.rawValue)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(Theme.t2)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 6)
                    .background(Theme.chip, in: Capsule())
            }
        }
        .padding(14)
        .commandCard(glow: isActive)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "\(workspace.name), \(workspace.slug), \(isActive ? "active site" : "available site")"
        )
    }
}

private struct SiteThumbnailStrip: View {
    let workspaces: [SiteWorkspace]
    let activeWorkspaceID: UUID?
    let previewURLs: [UUID: URL]
    @Binding var focusedWorkspaceID: UUID?

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(workspaces) { workspace in
                    Button {
                        withAnimation(.spring(response: 0.35, dampingFraction: 1)) {
                            focusedWorkspaceID = workspace.id
                        }
                    } label: {
                        ZStack(alignment: .bottomLeading) {
                            if let previewURL = previewURLs[workspace.id] ?? workspace.previewURLCandidate {
                                LiveSiteThumbnail(
                                    url: previewURL,
                                    refreshID: "switch-strip|\(workspace.id.uuidString)|\(previewURL.absoluteString)"
                                )
                            } else {
                                Theme.chip
                            }

                            LinearGradient(
                                colors: [.clear, .black.opacity(0.78)],
                                startPoint: .top,
                                endPoint: .bottom
                            )

                            VStack(alignment: .leading, spacing: 3) {
                                HStack {
                                    Image(systemName: workspace.techStack.icon)
                                        .font(.caption.weight(.semibold))
                                    Spacer()
                                    if workspace.id == activeWorkspaceID {
                                        Circle()
                                            .fill(Theme.ok)
                                            .frame(width: 7, height: 7)
                                    }
                                }
                                Text(workspace.name)
                                    .font(.caption.weight(.semibold))
                                    .lineLimit(1)
                                Text(workspace.slug)
                                    .font(.caption2.monospaced())
                                    .foregroundStyle(.white.opacity(0.72))
                                    .lineLimit(1)
                            }
                            .foregroundStyle(.white)
                            .padding(12)
                        }
                        .containerRelativeFrame(
                            .horizontal,
                            count: 2,
                            span: 1,
                            spacing: 10
                        )
                        .frame(height: 88, alignment: .leading)
                        .background(Theme.chip, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                        .overlay {
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .strokeBorder(
                                    workspace.id == focusedWorkspaceID
                                        ? Theme.brand.opacity(0.65)
                                        : Theme.t3.opacity(0.14),
                                    lineWidth: 1
                                )
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Show \(workspace.name)")
                    .accessibilityAddTraits(
                        workspace.id == focusedWorkspaceID ? .isSelected : []
                    )
                }
            }
            .scrollTargetLayout()
            .padding(.vertical, 1)
        }
        .scrollTargetBehavior(.viewAligned)
    }
}

private struct SitePreviewUnavailableState: View {
    let url: URL
    let openURL: OpenURLAction

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(CC.textSub)
            Text("Preview unavailable")
                .font(.ui(11, .semibold))
                .foregroundStyle(CC.textSub)
            Button("Open in browser") {
                Haptics.tap()
                openURL(url)
            }
            .font(.ui(11, .medium))
            .foregroundStyle(CC.accent)
            .buttonStyle(.plain)
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black.opacity(0.72))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Preview unavailable. Open in browser.")
    }
}

private struct SitePreviewPlaceholder: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .fill(Color.white.opacity(0.22))
                    .frame(width: 44, height: 6)
                Spacer()
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .fill(CC.accent.opacity(0.45))
                    .frame(width: 52, height: 5)
            }
            Spacer(minLength: 8)
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(Color.white.opacity(0.28))
                .frame(width: 100, height: 12)
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(Color.white.opacity(0.16))
                .frame(width: 74, height: 6)
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(Color.white.opacity(0.16))
                .frame(width: 58, height: 6)
            Spacer(minLength: 8)
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(CC.accent.opacity(0.55))
                .frame(width: 54, height: 16)
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .background {
            ZStack {
                CC.card
                LinearGradient(colors: [.clear, CC.accent.opacity(0.18)],
                               startPoint: .topLeading,
                               endPoint: .bottomTrailing)
            }
        }
        .shimmering()
        .accessibilityHidden(true)
    }
}

private struct LatestPreviewEmptyState: View {
    var configuredURL: String = ""

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "globe.badge.chevron.backward")
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(CC.accent)
            Text("Add a live URL in Deployment Settings to see a preview")
                .font(.ui(11, .medium))
                .foregroundStyle(CC.textSub)
                .multilineTextAlignment(.center)
                .lineLimit(3)
                .minimumScaleFactor(0.8)
            #if DEBUG
            Text("Configured URL: \(configuredURL.isEmpty ? "(none)" : configuredURL)")
                .font(.mono(10))
                .foregroundStyle(CC.textSub.opacity(0.8))
                .lineLimit(1)
            #endif
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .adaptiveGlassSurface(.listRow, cornerRadius: 10, classicFill: CC.card)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("No live preview. Add a live URL in Deployment Settings to see a preview.")
    }
}
