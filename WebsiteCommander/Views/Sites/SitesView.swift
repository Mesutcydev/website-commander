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
                // The screen's own controls, which used to live in the native
                // window toolbar the shell no longer has.
                WorkspaceCommandRow(gutter: gutter) {
                    WorkspaceSearchField(text: $search, prompt: "Search sites")
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
                    Spacer(minLength: TopBarMetrics.groupGap)
                    WorkspaceActionButton(title: "Add Website",
                                          systemImage: "plus",
                                          isProminent: true) { showingAdd = true }
                }

                if settings.workspaces.isEmpty {
                    EmptyStateView(
                        systemImage: "folder.badge.plus",
                        title: "No websites yet",
                        message: "Connect a GitHub repository to start editing it with the agent.",
                        actionTitle: "Add Website"
                    ) { showingAdd = true }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 300, maximum: 430),
                                                     spacing: Theme.Space.m)],
                                  spacing: Theme.Space.m) {
                            ForEach(visibleWorkspaces) { workspace in
                                WorkspaceCard(workspace: workspace,
                                              isActive: workspace.id == settings.activeWorkspace?.id)
                            }
                        }
                        .padding(.horizontal, gutter)
                        .padding(.bottom, 20)
                        .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
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
    @Environment(\.destination) private var destination
    let workspace: SiteWorkspace
    let isActive: Bool
    @State private var vscodeStatus: String?
    @State private var showingDeploy = false
    @State private var showingMemory = false
    @State private var previewState: SiteCardPreviewState = .loading

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            sitePreview

            HStack(spacing: Theme.Space.m) {
                Image(systemName: workspace.techStack.icon)
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(workspace.accentColor)
                    .frame(width: 24)
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
                Badge(text: workspace.techStack.rawValue, systemImage: workspace.techStack.icon, tint: Theme.slateAccent)
                Badge(text: workspace.deployment.rawValue, systemImage: workspace.deployment.icon, tint: Theme.slateAccent)
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
                    Label("Open in VS Code", systemImage: "chevron.left.forwardslash.chevron.right")
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.icon)
                .help("Open in VS Code")
            }

            if let vscodeStatus {
                Text(vscodeStatus)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .commandCard()
        .overlay(alignment: .leading) {
            if isActive {
                Capsule()
                    .fill(Theme.brandGradient)
                    .frame(width: 3)
                    .padding(.vertical, Theme.Space.m)
            }
        }
        .sheet(isPresented: $showingDeploy) {
            DeploymentSheet(workspace: workspace)
        }
        .sheet(isPresented: $showingMemory) {
            MemorySheet(workspace: workspace)
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
                    SiteCardWebPreview(url: url, state: $previewState)
                        .allowsHitTesting(false)

                    if previewState == .loading {
                        ZStack {
                            Color(nsColor: .windowBackgroundColor)
                            ProgressView()
                                .controlSize(.small)
                        }
                    }

                    if case .failed = previewState {
                        ZStack {
                            Theme.brandWash
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
                        .padding(.vertical, 7)
                        .background(.black.opacity(0.68))
                    }
                }
                .aspectRatio(16 / 9, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.medium, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.Radius.medium, style: .continuous)
                        .strokeBorder(Theme.hairline, lineWidth: 1)
                )
                .contentShape(RoundedRectangle(cornerRadius: Theme.Radius.medium, style: .continuous))
            }
            .buttonStyle(.plain)
            .help("Open \(workspace.name) in Preview")
        } else {
            ZStack {
                Theme.brandWash
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
            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.medium, style: .continuous))
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
