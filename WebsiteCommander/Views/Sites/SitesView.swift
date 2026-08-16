import SwiftUI
import WebKit

/// Manages connected website workspaces: a visual card list with an active
/// indicator, context actions, and an add-workspace sheet.
struct SitesView: View {

    @EnvironmentObject var settings: SettingsStore
    @EnvironmentObject var engine: AgentEngine
    @State private var showingAdd = false
    @State private var search = ""
    @State private var sort = SiteSort.name
    @State private var selectedWorkspaceID: UUID?

    private enum SiteSort: String, CaseIterable, Identifiable {
        case name = "Name"
        case technology = "Technology"
        var id: String { rawValue }
    }

    private var visibleWorkspaces: [SiteWorkspace] {
        let needle = search.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let matches = settings.workspaces.filter {
            needle.isEmpty
                || $0.name.lowercased().contains(needle)
                || $0.slug.lowercased().contains(needle)
                || $0.techStack.rawValue.lowercased().contains(needle)
        }
        return matches.sorted {
            sort == .name
                ? $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
                : $0.techStack.rawValue.localizedCaseInsensitiveCompare($1.techStack.rawValue) == .orderedAscending
        }
    }

    var body: some View {
        GeometryReader { proxy in
            let gutter = AgentWorkspaceMetrics.gutter(for: proxy.size.width)
            VStack(spacing: 0) {
                sitesHeader(gutter: gutter)

                if settings.workspaces.isEmpty {
                    EmptyStateView(
                        systemImage: "folder.badge.plus",
                        title: "No websites yet",
                        message: "Connect a GitHub repository to start editing it with the agent.",
                        actionTitle: "Add Website"
                    ) { showingAdd = true }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if proxy.size.width >= 980 {
                    sitesMasterDetail(gutter: gutter)
                } else {
                    ScrollView {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 310, maximum: 370),
                                                     spacing: Theme.Space.l)],
                                  spacing: Theme.Space.l) {
                            ForEach(visibleWorkspaces) { workspace in
                                WorkspaceCard(workspace: workspace,
                                              isActive: workspace.id == settings.activeWorkspace?.id)
                            }
                        }
                        .padding(.horizontal, gutter)
                        .padding(.bottom, Theme.Space.xxl)
                        .frame(maxWidth: 1220, alignment: .leading)
                        .frame(minWidth: 0, maxWidth: .infinity, alignment: .center)
                    }
                }
            }
            .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
        }
        .sheet(isPresented: $showingAdd) {
            AddWorkspaceSheet()
                .presentationBackground(.regularMaterial)
        }
        .onReceive(NotificationCenter.default.publisher(for: .requestAddSite)) { _ in
            showingAdd = true
        }
        .onAppear { selectInitialWorkspace() }
        .onChange(of: settings.activeWorkspace?.id) { _, newID in
            if selectedWorkspaceID == nil { selectedWorkspaceID = newID }
        }
        .background { GlassWorkspaceBackground() }
    }

    private func selectInitialWorkspace() {
        guard selectedWorkspaceID == nil else { return }
        selectedWorkspaceID = settings.activeWorkspace?.id ?? visibleWorkspaces.first?.id
    }

    @ViewBuilder
    private func sitesMasterDetail(gutter: CGFloat) -> some View {
        HStack(spacing: 0) {
            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(visibleWorkspaces) { workspace in
                        SiteListRow(workspace: workspace,
                                    isSelected: selectedWorkspaceID == workspace.id,
                                    isActive: settings.activeWorkspace?.id == workspace.id) {
                            withAnimation(Motion.smooth) { selectedWorkspaceID = workspace.id }
                        }
                    }
                }
                .padding(Theme.Space.s)
            }
            .frame(width: 360)
            .background(Theme.standardSurface)

            Rectangle()
                .fill(Theme.divider)
                .frame(width: 1)

            if let selected = visibleWorkspaces.first(where: { $0.id == selectedWorkspaceID })
                ?? visibleWorkspaces.first {
                SiteInspector(workspace: selected)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Text("No matching websites")
                    .foregroundStyle(Theme.secondaryText)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(maxWidth: 1360, maxHeight: .infinity)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, gutter)
        .padding(.bottom, Theme.Space.xl)
    }

    private func sitesHeader(gutter: CGFloat) -> some View {
        HStack(spacing: Theme.Space.s) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Sites")
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundStyle(Theme.textHeading)
                Text("\(settings.workspaces.count) connected")
                    .font(Theme.ui(11.5))
                    .foregroundStyle(Theme.secondaryText)
            }
            Spacer(minLength: Theme.Space.m)
            WorkspaceSearchField(text: $search, prompt: "Search sites", width: 260)
            WorkspaceMenuControl(title: String(localized: "Sort"),
                                 value: sort.rawValue,
                                 systemImage: "arrow.up.arrow.down") {
                Picker("Sort", selection: $sort) {
                    ForEach(SiteSort.allCases) { option in
                        Text(option.rawValue).tag(option)
                    }
                }
                .pickerStyle(.inline)
                .labelsHidden()
            }
            WorkspaceActionButton(title: "Add Website", systemImage: "plus",
                                  isProminent: true) { showingAdd = true }
        }
        .padding(.horizontal, gutter)
        .padding(.top, 20)
        .padding(.bottom, Theme.Space.m)
        .frame(maxWidth: 1360)
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Wide master/detail workspace

private struct SiteListRow: View {
    let workspace: SiteWorkspace
    let isSelected: Bool
    let isActive: Bool
    let action: () -> Void
    @State private var previewState: SiteCardPreviewState = .loading

    var body: some View {
        Button(action: action) {
            HStack(spacing: Theme.Space.s) {
                ZStack {
                    Theme.recessedSurface
                    if let url = SiteWorkspace.normalizedLiveURL(workspace.configuredLiveURL) {
                        SiteCardWebPreview(url: url, state: $previewState)
                            .allowsHitTesting(false)
                    } else {
                        Image(systemName: workspace.techStack.icon)
                            .foregroundStyle(Theme.tertiaryText)
                    }
                }
                .frame(width: 68, height: 44)
                .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous))

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(workspace.name)
                            .font(Theme.ui(13, isSelected ? .semibold : .medium))
                            .foregroundStyle(Theme.textPrimary)
                            .lineLimit(1)
                        if isActive {
                            Circle().fill(Theme.success).frame(width: 5, height: 5)
                        }
                    }
                    Text(workspace.slug)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(Theme.tertiaryText)
                        .lineLimit(1)
                    Text(workspace.deployment.rawValue)
                        .font(Theme.ui(10.5))
                        .foregroundStyle(Theme.secondaryText)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(isSelected ? Theme.accent : Theme.tertiaryText)
            }
            .padding(.horizontal, Theme.Space.s)
            .frame(height: 64)
            .background(isSelected ? Theme.selectedSurface : Theme.surfaceHover.opacity(0),
                        in: RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous))
            .overlay(alignment: .leading) {
                if isSelected {
                    Capsule()
                        .fill(Theme.accent)
                        .frame(width: 2, height: 28)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Select \(workspace.name)")
    }
}

private struct SiteInspector: View {
    @EnvironmentObject var settings: SettingsStore
    @EnvironmentObject var engine: AgentEngine
    @Environment(\.destination) private var destination
    let workspace: SiteWorkspace
    @State private var previewState: SiteCardPreviewState = .loading
    @State private var vscodeStatus: String?
    @State private var showingDeploy = false
    @State private var showingMemory = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.xl) {
                if let url = SiteWorkspace.normalizedLiveURL(workspace.configuredLiveURL) {
                    SiteCardWebPreview(url: url, state: $previewState)
                        .frame(maxWidth: .infinity)
                        .frame(height: 280)
                        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
                } else {
                    ContentUnavailableView("No live preview", systemImage: "eye.slash",
                                           description: Text("Add a live URL in deployment settings to preview this site."))
                        .frame(maxWidth: .infinity)
                        .frame(height: 180)
                        .background(Theme.standardSurface,
                                    in: RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
                }

                HStack(alignment: .top, spacing: Theme.Space.m) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(workspace.name)
                            .font(.system(size: 20, weight: .semibold))
                            .foregroundStyle(Theme.textPrimary)
                        Text(workspace.slug)
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(Theme.secondaryText)
                    }
                    Spacer()
                    if settings.activeWorkspace?.id == workspace.id {
                        Badge(text: "Active", systemImage: "checkmark.circle.fill",
                              tint: Theme.success, surface: Theme.tealSoft)
                    } else {
                        Button("Set Active") { settings.setActive(workspace) }
                            .buttonStyle(.primarySoftCompact)
                    }
                }

                HStack(spacing: Theme.Space.s) {
                    WorkspaceActionButton(title: "Open Agent", systemImage: "bubble.left.fill",
                                          isProminent: true) {
                        settings.setActive(workspace)
                        engine.newChat()
                        destination.wrappedValue = .agent
                    }
                    WorkspaceActionButton(title: "Open Preview", systemImage: "eye") {
                        settings.setActive(workspace)
                        destination.wrappedValue = .preview
                    }
                    Menu {
                        Button("Open in VS Code") { openInVSCode() }
                        Button("Deployment…") { showingDeploy = true }
                        Button("Agent memory…") { showingMemory = true }
                        Divider()
                        Button("Delete", role: .destructive) { settings.deleteWorkspace(workspace) }
                    } label: {
                        Image(systemName: "ellipsis")
                            .frame(width: Theme.Height.input, height: Theme.Height.input)
                    }
                    .menuStyle(.borderlessButton)
                    .background(Theme.secondarySurface, in: RoundedRectangle(cornerRadius: Theme.Radius.small))
                }

                VStack(alignment: .leading, spacing: Theme.Space.s) {
                    Text("Site details")
                        .font(Theme.ui(13, .semibold))
                        .foregroundStyle(Theme.textPrimary)
                    detailRow("Repository", "\(workspace.gitOwner)/\(workspace.gitRepo)", monospaced: true)
                    detailRow("Branch", workspace.gitBranch, monospaced: true)
                    detailRow("Technology", workspace.techStack.rawValue, icon: workspace.techStack.icon)
                    detailRow("Deployment", workspace.deployment.rawValue, icon: workspace.deployment.icon)
                    if let url = SiteWorkspace.normalizedLiveURL(workspace.configuredLiveURL) {
                        detailRow("Live URL", url.absoluteString, icon: "link")
                    }
                }
                .padding(Theme.Space.l)
                .background(Theme.standardSurface,
                            in: RoundedRectangle(cornerRadius: Theme.Radius.panel, style: .continuous))

                if let vscodeStatus {
                    Text(vscodeStatus)
                        .font(Theme.ui(11.5))
                        .foregroundStyle(Theme.secondaryText)
                }
            }
            .padding(.horizontal, Theme.Space.xl)
            .padding(.top, Theme.Space.l)
            .padding(.bottom, Theme.Space.xxl)
            .frame(maxWidth: 860, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .center)
        }
        .sheet(isPresented: $showingDeploy) {
            DeploymentSheet(workspace: workspace).presentationBackground(.regularMaterial)
        }
        .sheet(isPresented: $showingMemory) {
            MemorySheet(workspace: workspace).presentationBackground(.regularMaterial)
        }
    }

    private func detailRow(_ label: String, _ value: String, icon: String? = nil,
                           monospaced: Bool = false) -> some View {
        HStack(spacing: Theme.Space.s) {
            if let icon {
                Image(systemName: icon)
                    .foregroundStyle(Theme.tertiaryText)
                    .frame(width: 16)
            }
            Text(label)
                .font(Theme.ui(11.5, .medium))
                .foregroundStyle(Theme.secondaryText)
                .frame(width: 90, alignment: .leading)
            Text(value)
                .font(monospaced ? .system(size: 11.5, design: .monospaced) : Theme.ui(12.5))
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 0)
        }
    }

    private func openInVSCode() {
        vscodeStatus = "Preparing local copy…"
        Task {
            guard let token = await settings.resolvedGitHubToken(forAsync: workspace), !token.isEmpty else {
                vscodeStatus = "Add a GitHub token first (Settings → GitHub)."
                return
            }
            do {
                let path = try await LocalWorkspaceStore.ensureClone(workspace, token: token)
                vscodeStatus = VSCodeBridge.open(folder: path)
                    ? "Opened in VS Code."
                    : "Couldn't find VS Code — is the code CLI installed?"
            } catch {
                vscodeStatus = error.localizedDescription
            }
        }
    }
}

// MARK: - Workspace card

struct WorkspaceCard: View {
    @EnvironmentObject var settings: SettingsStore
    @EnvironmentObject var engine: AgentEngine
    @Environment(\.destination) private var destination
    let workspace: SiteWorkspace
    let isActive: Bool
    @State private var vscodeStatus: String?
    @State private var showingDeploy = false
    @State private var showingMemory = false
    @State private var previewState: SiteCardPreviewState = .loading
    @State private var isHovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            sitePreview

            HStack(spacing: Theme.Space.s) {
                Image(systemName: workspace.techStack.icon)
                    .font(.system(size: Theme.IconSize.large, weight: .medium))
                    .foregroundStyle(isActive ? workspace.accentColor : Theme.secondaryText)
                    .frame(width: Theme.IconSize.tile, height: Theme.IconSize.tile)
                    .background(Theme.secondarySurface,
                                in: RoundedRectangle(cornerRadius: Theme.Radius.icon, style: .continuous))
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(workspace.name)
                            .font(Theme.ui(13.5, .medium))
                            .foregroundStyle(Theme.textHeading)
                        if isActive {
                            HStack(spacing: 4) {
                                AmbientConnectionSignal(tint: Theme.success,
                                                         mode: .breathing,
                                                         active: true,
                                                         label: "Active site")
                                Badge(text: "Active", systemImage: "checkmark.circle.fill",
                                      tint: Theme.accent, surface: Theme.accentSoft)
                            }
                        }
                    }
                    Text(workspace.slug)
                        .font(.caption)
                        .foregroundStyle(Theme.tertiaryText)
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

            HStack(spacing: Theme.Space.xs) {
                Badge(text: workspace.techStack.rawValue, systemImage: workspace.techStack.icon,
                      tint: Theme.tertiaryText, surface: Theme.secondarySurface)
                Badge(text: workspace.deployment.rawValue, systemImage: workspace.deployment.icon,
                      tint: Theme.tertiaryText, surface: Theme.secondarySurface)
            }

            HStack(spacing: Theme.Space.s) {
                Button {
                    settings.setActive(workspace)
                    engine.newChat()
                    destination.wrappedValue = .agent
                } label: {
                    Label("Open Agent", systemImage: "bubble.left.fill")
                        .frame(maxWidth: .infinity)
                        .frame(height: Theme.Height.input)
                }
                .buttonStyle(.primarySoftCompact)
            }

            if let vscodeStatus {
                Text(vscodeStatus)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(Theme.Space.m)
        .background(isActive ? Theme.selectedSurface : Theme.standardSurface,
                    in: RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
        .overlay(alignment: .leading) {
            if isActive {
                Capsule()
                    .fill(Theme.accent)
                    .frame(width: 2, height: 36)
            }
        }
        .animation(Motion.interaction, value: isActive)
        .onHover { isHovering = $0 }
        .sheet(isPresented: $showingDeploy) {
            DeploymentSheet(workspace: workspace)
                .presentationBackground(.regularMaterial)
        }
        .sheet(isPresented: $showingMemory) {
            MemorySheet(workspace: workspace)
                .presentationBackground(.regularMaterial)
        }
    }

    @ViewBuilder
    private var sitePreview: some View {
        if let url = SiteWorkspace.normalizedLiveURL(workspace.configuredLiveURL) {
            Button {
                settings.setActive(workspace)
                destination.wrappedValue = .preview
            } label: {
                ZStack {
                    Theme.recessedSurface
                    SiteCardWebPreview(url: url, state: $previewState)
                        .allowsHitTesting(false)

                    if previewState == .loading {
                        SitePreviewSkeleton()
                    }

                    if case .failed = previewState {
                        ZStack {
                            Theme.recessedSurface
                            VStack(spacing: Theme.Space.s) {
                                Image(systemName: "exclamationmark.icloud")
                                    .font(.title2)
                                Text("Preview unavailable")
                                    .font(.callout.weight(.medium))
                                Text("Open the full preview to try again")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }

                    VStack {
                        Spacer()
                        HStack(spacing: 6) {
                            Image(systemName: "lock.fill")
                            Text(url.host ?? url.absoluteString)
                                .lineLimit(1)
                            Spacer()
                            Text("Open Preview")
                            Image(systemName: "arrow.up.right")
                        }
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.white)
                        .padding(.horizontal, Theme.Space.s)
                        .frame(height: 28)
                        .padding(.vertical, 0)
                        .background {
                            LinearGradient(colors: [.clear, Color.black.opacity(0.70)],
                                           startPoint: .top, endPoint: .bottom)
                        }
                    }
                }
                .aspectRatio(16 / 9, contentMode: .fit)
                .wcPreviewDrift(active: isActive || isHovering)
                .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                        .strokeBorder(Theme.borderSubtle, lineWidth: 1)
                )
                .contentShape(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
            }
            .buttonStyle(.plain)
            .help("Open \(workspace.name) in Preview")
        } else {
            ZStack {
                Theme.recessedSurface
                VStack(spacing: Theme.Space.s) {
                    Image(systemName: "globe.badge.chevron.backward")
                        .font(.title2)
                    Text("Add a live URL to show a preview")
                        .font(.callout.weight(.medium))
                    Button("Deployment Settings…") { showingDeploy = true }
                        .buttonStyle(.link)
                }
            }
            .aspectRatio(16 / 9, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
        }
    }

    private func openInVSCode() {
        vscodeStatus = "Preparing local copy…"
        Task {
            guard let token = await settings.resolvedGitHubToken(forAsync: workspace) else {
                vscodeStatus = "Add a GitHub token first (Settings → GitHub)."
                return
            }
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

// MARK: - Live card preview

private enum SiteCardPreviewState: Equatable {
    case loading
    case loaded
    case failed
}

private struct SitePreviewSkeleton: View {
    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(Theme.surfaceHover)
                .frame(width: 132, height: 12)
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(Theme.surfaceHover)
                .frame(width: 210, height: 9)
            Spacer()
            HStack(spacing: Theme.Space.s) {
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(Theme.surfaceHover)
                    .frame(width: 58, height: 8)
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(Theme.surfaceHover)
                    .frame(width: 84, height: 8)
            }
        }
        .padding(Theme.Space.l)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .overlay { ProgressView().controlSize(.small) }
        .accessibilityLabel("Loading site preview")
    }
}

/// A deliberately non-interactive browser used as the visual face of a site
/// card. The surrounding button opens the full, instrumented Preview screen.
private struct SiteCardWebPreview: NSViewRepresentable {
    let url: URL
    @Binding var state: SiteCardPreviewState

    typealias NSViewType = NonInteractiveWebView

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> NonInteractiveWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()

        let webView = NonInteractiveWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.underPageBackgroundColor = .clear
        webView.allowsMagnification = false
        webView.load(URLRequest(url: url, cachePolicy: .returnCacheDataElseLoad))
        context.coordinator.lastURL = url
        return webView
    }

    func updateNSView(_ webView: NonInteractiveWebView, context: Context) {
        context.coordinator.parent = self
        guard context.coordinator.lastURL != url else { return }
        context.coordinator.lastURL = url
        state = .loading
        webView.load(URLRequest(url: url, cachePolicy: .returnCacheDataElseLoad))
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        var parent: SiteCardWebPreview
        var lastURL: URL?

        init(parent: SiteCardWebPreview) {
            self.parent = parent
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            parent.state = .loaded
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!,
                     withError error: Error) {
            if (error as NSError).code != NSURLErrorCancelled {
                parent.state = .failed
            }
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!,
                     withError error: Error) {
            if (error as NSError).code != NSURLErrorCancelled {
                parent.state = .failed
            }
        }
    }
}

/// WebKit owns an internal scroll view that can otherwise win mouse hit tests
/// even when SwiftUI marks the representable as non-interactive. Returning nil
/// here guarantees sidebar and card controls continue receiving clicks.
private final class NonInteractiveWebView: WKWebView {
    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }
}
