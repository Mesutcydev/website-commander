import SwiftUI

// MARK: - Command Center design tokens

enum CC {
    // Adaptive command-deck surfaces: OLED true-black + white ink in dark; native
    // grouped grays + near-black ink in light. The dark look is unchanged while
    // light mode becomes first-class. Accent tokens follow Theme.brand.
    static let bg      = Color(lightUI: .systemGroupedBackground, darkUI: .black)
    static let card    = Color(lightUI: .secondarySystemGroupedBackground,
                               darkUI: UIColor(red: 0x14/255, green: 0x17/255, blue: 0x19/255, alpha: 1))
    static let cardHi  = Color(lightUI: UIColor(red: 0.93, green: 0.975, blue: 0.945, alpha: 1),
                               darkUI: UIColor(red: 0x15/255, green: 0x1D/255, blue: 0x19/255, alpha: 1))
    static let stroke  = Color(lightUI: UIColor(white: 0, alpha: 0.08),
                               darkUI: UIColor(white: 1, alpha: 0.11))
    static let text    = Color(lightUI: UIColor(red: 20/255, green: 16/255, blue: 28/255, alpha: 0.96),
                               darkUI: UIColor(white: 1, alpha: 0.97))
    static let textSub = Color(lightUI: UIColor(red: 20/255, green: 16/255, blue: 28/255, alpha: 0.55),
                               darkUI: UIColor(white: 1, alpha: 0.55))
    static var accent: Color { Theme.brand }
    static var accentDim: Color { Theme.brand.opacity(0.16) }
    static var strokeGreen: Color { Theme.brand.opacity(0.40) }
    static var textGreen: Color { Theme.brandEnd }
}

// MARK: - Locked type + size scale (SF Pro / system font only, no custom fonts)

enum AppFont {
    static let screenTitle   = Font.system(size: 34, weight: .bold,      design: .rounded)
    static let navTitle      = Font.system(size: 22, weight: .bold,      design: .rounded)
    static let section       = Font.system(size: 10, weight: .semibold,  design: .monospaced)
    static let heroTitle     = Font.system(size: 20, weight: .bold,      design: .rounded)
    static let cardTitle     = Font.system(size: 12, weight: .semibold,  design: .rounded)
    static let actionTitle   = Font.system(size: 14, weight: .semibold,  design: .rounded)
    static let metricValue   = Font.system(size: 21, weight: .bold,      design: .rounded)
    static let providerValue = Font.system(size: 19, weight: .bold,      design: .rounded)
    static let body          = Font.system(size: 13, weight: .regular,   design: .rounded)
    static let subtitle      = Font.system(size: 10, weight: .regular,   design: .rounded)
    static let metadata      = Font.system(size: 10, weight: .medium,    design: .monospaced)
    static let pill          = Font.system(size: 10, weight: .semibold,  design: .monospaced)
    static let tab           = Font.system(size: 11, weight: .semibold,  design: .rounded)
}

enum AppSize {
    static let screenHorizontalPadding: CGFloat = 20
    static let sectionSpacing: CGFloat = 8
    static let cardSpacing: CGFloat = 7

    static let gearButton: CGFloat = 36
    static let siteSelectorHeight: CGFloat = 26

    static let heroHeight: CGFloat = 108
    static let heroCorner: CGFloat = 15
    static let heroPadding: CGFloat = 10
    static let heroAvatar: CGFloat = 44

    static let metadataPillHeight: CGFloat = 20
    static let statusPillHeight: CGFloat = 20

    static let metricCardHeight: CGFloat = 58
    static let metricCorner: CGFloat = 13
    static let metricIcon: CGFloat = 28

    static let actionCardHeight: CGFloat = 52
    static let actionCorner: CGFloat = 13
    static let actionIcon: CGFloat = 28

    static let recommendationHeight: CGFloat = 62
    static let deploymentCardMinHeight: CGFloat = 132
    static let recentActivityMinHeight: CGFloat = 130

    /// Visual breathing room after the final scroll item so content clears the
    /// floating Liquid Glass tab bar instead of sliding underneath it.
    static let scrollContentBottomSpacing: CGFloat = 104
}

// MARK: - Reusable compact pieces

private struct CommandCenterBackdrop: View {
    // Captured at init so a skin toggle re-runs the body (see CardSurfaceModifier).
    private let glass = Theme.isGlass

    var body: some View {
        ZStack(alignment: .top) {
            if glass {
                GlassBackground()
            } else {
                CC.bg
                RadialGradient(
                    colors: [CC.accent.opacity(0.10), CC.accent.opacity(0.025), .clear],
                    center: UnitPoint(x: 0.54, y: 0.18),
                    startRadius: 20,
                    endRadius: 245
                )
                .frame(height: 380)
                .blur(radius: 14)
                .opacity(0.48)
            }

            // Grid texture belongs to the classic command-deck skin only; glass
            // panes need a clean canvas, not a pattern showing through them.
            if !glass {
                CommandCenterGrid()
                    .opacity(0.48)
            }
        }
        .ignoresSafeArea()
    }
}

private struct CommandCenterGrid: View {
    var body: some View {
        Canvas { context, size in
            var path = Path()
            let step: CGFloat = 12
            var x: CGFloat = 0
            while x <= size.width {
                path.move(to: CGPoint(x: x, y: 0))
                path.addLine(to: CGPoint(x: x, y: size.height))
                x += step
            }
            var y: CGFloat = 0
            while y <= size.height {
                path.move(to: CGPoint(x: 0, y: y))
                path.addLine(to: CGPoint(x: size.width, y: y))
                y += step
            }
            context.stroke(path, with: .color(CC.accent.opacity(0.018)), lineWidth: 0.3)
        }
        .blendMode(.screen)
        .allowsHitTesting(false)
    }
}

private struct CCEyebrow: View {
    let text: String
    var trailing: String? = nil
    var action: (() -> Void)? = nil
    var body: some View {
        HStack {
            Text(text.uppercased())
                .font(AppFont.section).tracking(1.5)
                .foregroundStyle(CC.textSub)
            Spacer()
            if let trailing {
                Button { action?() } label: {
                    HStack(spacing: 3) {
                        Text(trailing).font(AppFont.subtitle)
                        Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold))
                    }
                    .foregroundStyle(CC.accent)
                }
                .buttonStyle(.plain)
            }
        }
    }
}

private struct CCPill: View {
    let icon: String?
    let text: String
    var body: some View {
        HStack(spacing: 4) {
            if let icon { Image(systemName: icon).font(.system(size: 9, weight: .semibold)) }
            Text(text).font(.system(size: 9, weight: .medium, design: .monospaced)).lineLimit(1)
        }
        .foregroundStyle(CC.text)
        .padding(.horizontal, 7)
        .frame(height: AppSize.metadataPillHeight)
        .adaptiveGlassSurface(.capsule, cornerRadius: 10, classicFill: CC.card)
        .fixedSize()
    }
}

private struct CCIconChip: View {
    let icon: String
    private let glass = Theme.isGlass

    var body: some View {
        let image = Image(systemName: icon)
            .font(.system(size: 14, weight: .medium))
            .foregroundStyle(CC.accent)
            .frame(width: AppSize.metricIcon, height: AppSize.metricIcon)
        if glass {
            // Same 8pt radius as classic — glass changes material only, never geometry.
            image.liquidGlass(
                in: RoundedRectangle(cornerRadius: 8, style: .continuous),
                tint: CC.accent,
                thickness: .control
            )
        } else {
            image.background(CC.accentDim, in: RoundedRectangle(cornerRadius: 8))
        }
    }
}

private struct CCEmbeddedMetricIcon: View {
    let icon: String
    let tint: Color
    private let glass = Theme.isGlass

    var body: some View {
        let image = Image(systemName: icon)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(tint)
            .frame(width: AppSize.metricIcon, height: AppSize.metricIcon)

        if glass {
            image.liquidGlass(
                in: RoundedRectangle(cornerRadius: AppSize.metricIcon / 2, style: .continuous),
                tint: tint,
                thickness: .control
            )
        } else {
            image
                .background(tint.opacity(0.14), in: Circle())
                .overlay(Circle().stroke(tint.opacity(0.35), lineWidth: 1))
        }
    }
}

private struct DashboardDeploymentDisplay: Identifiable {
    let id: String
    let title: String
    let subtitle: String
    let state: DeploymentState
    let record: DeploymentRecord?
}

enum DeploymentHistoryNoticeModel: Equatable {
    case stale(fetchedAt: Date?)
    case failure(DeploymentClientError, hasCachedData: Bool)

    var icon: String {
        switch self {
        case .stale:
            return "clock.arrow.circlepath"
        case .failure(let error, _):
            if error.isAuthenticationFailure { return "key.slash" }
            if case .offline = error { return "wifi.exclamationmark" }
            if case .timedOut = error { return "clock.badge.exclamationmark" }
            return "exclamationmark.triangle"
        }
    }

    var title: String {
        switch self {
        case .stale:
            return "Couldn’t refresh deployments"
        case .failure(let error, let hasCachedData):
            if error.isAuthenticationFailure {
                return "Cloudflare connection needs attention"
            }
            if case .http(429, _) = error {
                return "Cloudflare is temporarily rate limiting requests"
            }
            return hasCachedData ? "Couldn’t refresh deployments" : "Deployment history unavailable"
        }
    }

    var message: String {
        switch self {
        case .stale(let fetchedAt):
            if let fetchedAt {
                let time = fetchedAt.formatted(date: .omitted, time: .shortened)
                return "Showing saved history from \(time)."
            }
            return "Showing the last saved history."
        case .failure(let error, let hasCachedData):
            if error.isAuthenticationFailure {
                return "Reconnect or update the API token in Settings."
            }
            if case .http(429, _) = error {
                return "We’ll retry shortly, or you can try again now."
            }
            if hasCachedData {
                return error.localizedDescription
            }
            return "Check your connection and try again."
        }
    }

    var actionTitle: String {
        switch self {
        case .failure(let error, _) where error.isAuthenticationFailure:
            return "Open Settings"
        default:
            return "Retry"
        }
    }

    var usesSettingsAction: Bool {
        if case .failure(let error, _) = self, error.isAuthenticationFailure { return true }
        return false
    }
}

private struct DeploymentHistoryNoticeView: View {
    let notice: DeploymentHistoryNoticeModel
    let onRetry: () -> Void
    let openSettings: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: notice.icon)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(CC.accent)
                .frame(width: 22, height: 22)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 4) {
                Text(notice.title)
                    .font(AppFont.cardTitle)
                    .foregroundStyle(CC.text)
                    .fixedSize(horizontal: false, vertical: true)
                Text(notice.message)
                    .font(AppFont.subtitle)
                    .foregroundStyle(CC.text.opacity(0.72))
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 8)

            Button {
                Haptics.tap()
                if notice.usesSettingsAction {
                    openSettings()
                } else {
                    onRetry()
                }
            } label: {
                Text(notice.actionTitle)
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundStyle(CC.accent)
                    .padding(.horizontal, 10)
                    .frame(minWidth: 44, minHeight: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(notice.actionTitle)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(CC.accent.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
        .accessibilityElement(children: .combine)
    }
}

private struct DashboardActivityDisplay: Identifiable {
    let id: String
    let title: String
    let metadata: String
    let hash: String
    let commit: CommitEntry?
}

private enum CCCardLayer {
    case hero, card, control

    var glassRole: GlassRole {
        switch self {
        case .hero: return .hero
        case .card: return .card
        case .control: return .button
        }
    }
}

private struct CCCardBG: View {
    var highlighted: Bool = false
    var corner: CGFloat = AppSize.metricCorner
    var layer: CCCardLayer = .card
    @Environment(\.colorScheme) private var colorScheme
    // Captured at init so a skin toggle re-runs the body (see CardSurfaceModifier).
    private let glass = Theme.isGlass

    var body: some View {
        if !glass {
            RoundedRectangle(cornerRadius: corner)
                .fill(
                    LinearGradient(
                        colors: highlighted
                            ? [CC.cardHi, CC.card.opacity(0.96)]
                            : (colorScheme == .dark
                               ? [Color.white.opacity(0.08), CC.card]
                               : [CC.card, CC.card]),
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .overlay(RoundedRectangle(cornerRadius: corner)
                    .stroke(highlighted ? CC.strokeGreen : CC.stroke, lineWidth: 1))
        } else {
            Color.clear
        }
    }
}

private struct CCCardSurfaceModifier: ViewModifier {
    var highlighted: Bool = false
    var corner: CGFloat = AppSize.metricCorner
    var layer: CCCardLayer = .card
    private let glass = Theme.isGlass

    @ViewBuilder
    func body(content: Content) -> some View {
        if glass {
            // Apply native glass to the actual card content, matching
            // MultiMindCouncil. A glassEffect on a flexible background view can
            // adopt the scroll view's unconstrained width and inflate the card.
            content.glassSurface(
                layer.glassRole,
                cornerRadius: corner,
                accentReflection: nil
            )
        } else {
            content.background(
                CCCardBG(highlighted: highlighted, corner: corner, layer: layer)
            )
        }
    }
}

struct HomeDashboardView: View {
    @EnvironmentObject var engine: AgentEngine
    @Binding var tab: AppTab
    @ObservedObject private var iap = IAPManager.shared
    @Environment(\.openURL) private var openURL
    @Environment(\.colorScheme) private var colorScheme

    @State private var showSettings = false
    @State private var showHistory = false
    @State private var showAddSite = false
    @State private var showConnectWizard = false
    @State private var showPaywall = false
    @State private var recentCommits: [CommitEntry] = []
    @State private var recentDeployments: [DeploymentRecord] = []
    @State private var deploymentLogs: [DeployLogLine] = []
    /// Modal alert for user-triggered deploy actions only (retry/rollback/logs/undo).
    @State private var deploymentActionAlert: String?
    /// Inline, non-blocking notice for passive deployment-history refresh failures.
    @State private var deploymentHistoryNotice: DeploymentHistoryNoticeModel?
    @State private var deploymentLoadGeneration = 0
    @State private var deploymentsWorkspaceID: UUID?
    @State private var loadingActivity = false
    @State private var loadingDeployments = false
    @State private var deploymentActionBusy = false
    @State private var busyDeployAction: String?
    @State private var commitToUndo: CommitEntry?
    @State private var showUndoConfirm = false
    @State private var undoing = false
    @State private var pendingRollback: DeploymentRecord?
    @State private var showRollbackConfirm = false

    private let cols = [GridItem(.flexible(), spacing: AppSize.cardSpacing),
                        GridItem(.flexible(), spacing: AppSize.cardSpacing)]

    // No UINavigationBar appearance overrides: the system renders its own native
    // Liquid Glass large-title bar (transparent at the top, glass materializing
    // on scroll) exactly like Apple Music / Settings — nothing custom.

    var body: some View {
        NavigationStack {
            ZStack {
                CommandCenterBackdrop()
                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: AppSize.sectionSpacing) {
                        header
                        if !engine.isReady {
                            // First run: one confident next step, not a dashboard of zeros.
                            SetupCard(onOpenSettings: { showSettings = true }, onStartDemo: {
                                engine.startGuidedDemo()
                                tab = .agent
                            }, onConnectSite: { showAddSite = true },
                               onConnectWizard: { showConnectWizard = true })
                        } else {
                            activeSiteSection
                            statGrid
                            quickActionsSection
                            recommendationsSection
                            deploymentsSection
                            recentActivitySection
                        }
                    }
                    .padding(.horizontal, AppSize.screenHorizontalPadding)
                    .padding(.top, 4)
                    .padding(.bottom, AppSize.scrollContentBottomSpacing)
                    // iOS 27 can otherwise honor the setup view's wide ideal
                    // size inside a vertical ScrollView and push its leading
                    // edge offscreen. Lock it to the visible container first;
                    // the inner padding then restores the original margins.
                    .containerRelativeFrame(.horizontal, alignment: .center) { width, _ in
                        min(width, 700)
                    }
                }
                .scrollContentBackground(.hidden)
            }
            .glassScrollEdge()
            // Keep the header in the scroll content instead of relying on the
            // native large-title renderer. On iOS 26, especially with Liquid
            // Glass/light appearance or larger text settings, that renderer can
            // place the title over the first card.
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar(.hidden, for: .navigationBar)
            .task(id: engine.activeWorkspace?.id) { await loadActivity() }
            .refreshable { await loadActivity() }
            .sheet(isPresented: $showSettings) { SettingsView().environmentObject(engine) }
            .sheet(isPresented: $showHistory) { HistoryTabView().environmentObject(engine) }
            .alert("Deployment", isPresented: Binding(
                get: { deploymentActionAlert != nil },
                set: { if !$0 { deploymentActionAlert = nil } }
            ), presenting: deploymentActionAlert) { _ in
                Button("OK", role: .cancel) { }
            } message: { Text($0) }
            .sheet(isPresented: $showAddSite) { AddWorkspaceSheet().environmentObject(engine) }
            .sheet(isPresented: $showConnectWizard) { ConnectWebsiteWizardView().environmentObject(engine) }
            .onChange(of: engine.requestedConnectWizard) { _, requested in
                guard requested else { return }
                engine.requestedConnectWizard = false
                showConnectWizard = true
            }
            .sheet(isPresented: $showPaywall) { ProPaywall() }
            .confirmationDialog("Undo last commit?", isPresented: $showUndoConfirm,
                                titleVisibility: .visible, presenting: commitToUndo) { c in
                Button("Undo “\(c.message.prefix(40))”", role: .destructive) {
                    Task {
                        undoing = true
                        let ok = await engine.revertLastCommit(expecting: c.sha)
                        await loadActivity()
                        undoing = false
                        if ok {
                            Haptics.success()
                        } else {
                            Haptics.error()
                            deploymentActionAlert = engine.lastError
                                ?? "Could not undo that commit. Refresh and try again."
                        }
                    }
                }
                Button("Cancel", role: .cancel) {}
            } message: { _ in
                Text("Creates a new commit restoring the previous version. Your site will redeploy.")
            }
            .confirmationDialog("Roll back to this deployment?", isPresented: $showRollbackConfirm,
                                titleVisibility: .visible, presenting: pendingRollback) { d in
                Button("Roll back", role: .destructive) {
                    guard let ws = engine.activeWorkspace,
                          let client = DeploymentClientFactory.client(for: ws, repo: engine.repo) else { return }
                    Task { await performDeployAction("rollback", "Rollback requested") { try await client.rollback(d) } }
                }
                Button("Cancel", role: .cancel) {}
            } message: { _ in
                Text("Production will switch back to this earlier deployment.")
            }
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            Text("Command Center")
                .font(.display(34, .bold, relativeTo: .largeTitle))
                .foregroundStyle(CC.text)
                .lineLimit(1)
                .minimumScaleFactor(0.72)
            Spacer(minLength: 8)
            Button {
                Haptics.tap()
                showSettings = true
            } label: {
                Image(systemName: "gearshape.fill")
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

    // MARK: Active site

    private var heroStatusText: String {
        recentDeployments.first?.state.label ?? (engine.isReady ? "Live" : "Setup")
    }
    private var dashboardSiteName: String {
        engine.activeWorkspace?.name ?? "No site selected"
    }
    private var dashboardRepoSlug: String {
        engine.repo.isEmpty ? "—" : engine.repo.slug
    }
    private var dashboardBranch: String {
        engine.repo.branch.isEmpty ? "main" : engine.repo.branch
    }
    private var dashboardLastDeployText: String {
        recentDeployments.first?.createdAt?.formatted(date: .abbreviated, time: .shortened) ?? "No deployments yet"
    }
    private var heroSiteURL: URL? {
        if let raw = recentDeployments.first?.displayURL, !raw.isEmpty,
           let u = SiteWorkspace.normalizedLiveURL(raw) { return u }
        if let raw = engine.activeWorkspace?.configuredLiveURL, !raw.isEmpty,
           let u = SiteWorkspace.normalizedLiveURL(raw) { return u }
        return nil
    }
    private var displayedDeployments: [DashboardDeploymentDisplay] {
        recentDeployments.prefix(3).map { deployment in
            DashboardDeploymentDisplay(
                id: deployment.id,
                title: "\(deployment.providerName) · \(deployment.projectName)",
                subtitle: deploymentSubtitle(deployment),
                state: deployment.state,
                record: deployment
            )
        }
    }
    private var displayedActivities: [DashboardActivityDisplay] {
        recentCommits.prefix(4).map { commit in
            DashboardActivityDisplay(
                id: commit.id,
                title: commit.message,
                metadata: "\(commit.authorName) · \(commit.formattedDate)",
                hash: commit.shortSHA,
                commit: commit
            )
        }
    }

    private var activeSiteSection: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text("ACTIVE SITE")
                    .font(AppFont.section)
                    .tracking(1.5)
                    .foregroundStyle(CC.textSub)
                Spacer(minLength: 8)
                siteSelector
            }
            activeSiteCard
        }
    }

    private var siteSelector: some View {
        Menu {
            ForEach(engine.workspaces) { ws in
                Button {
                    Haptics.tap()
                    engine.selectWorkspace(ws)
                } label: {
                    HStack {
                        Text(ws.name)
                        if engine.activeWorkspace?.id == ws.id { Image(systemName: "checkmark") }
                    }
                }
            }
        } label: {
            HStack(spacing: 6) {
                if Theme.isGlass { GlassLED(color: CC.accent, size: 5) }
                else { Circle().fill(CC.accent).frame(width: 7, height: 7) }
                Text(dashboardSiteName)
                    .font(.system(size: 11, weight: .medium, design: .rounded)).foregroundStyle(CC.text).lineLimit(1)
                Image(systemName: "chevron.down").font(.system(size: 10, weight: .semibold)).foregroundStyle(CC.textSub)
            }
            .padding(.horizontal, 9)
            .frame(height: AppSize.siteSelectorHeight)
            .adaptiveGlassSurface(.capsule, cornerRadius: 13, classicFill: CC.card)
        }
        .accessibilityLabel("Switch active site")
    }

    private var activeSiteCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 9) {
                Image(systemName: "globe")
                    .font(.system(size: 19, weight: .medium))
                    .foregroundStyle(.black)
                    .frame(width: AppSize.heroAvatar, height: AppSize.heroAvatar)
                    .background(CC.accent, in: Circle())
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 8) {
                        Text(dashboardSiteName)
                            .font(AppFont.heroTitle).foregroundStyle(CC.text)
                            .lineLimit(1).minimumScaleFactor(0.6)
                        HStack(spacing: 4) {
                            if Theme.isGlass { GlassLED(color: CC.accent, size: 4.5) }
                            else { Circle().fill(CC.accent).frame(width: 6, height: 6) }
                            Text(heroStatusText).font(AppFont.pill).foregroundStyle(CC.accent)
                        }
                        .padding(.horizontal, 8)
                        .frame(height: AppSize.statusPillHeight)
                        .adaptiveGlassSurface(
                            .badge,
                            cornerRadius: 10,
                            accentReflection: CC.accent,
                            classicFill: CC.accentDim
                        )
                        .fixedSize()
                    }
                    Text(dashboardRepoSlug)
                        .font(.system(size: 11, weight: .regular, design: .monospaced))
                        .foregroundStyle(CC.textSub)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                }
                Spacer(minLength: 4)
                ECGWaveform(color: CC.accent).frame(width: 68, height: 20)
                    .accessibilityHidden(true)
            }
            // chips row — horizontal scroll so nothing clips on narrow phones
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    CCPill(icon: "arrow.triangle.branch", text: dashboardBranch)
                    if let ws = engine.activeWorkspace {
                        CCPill(icon: "cloud", text: ws.deployment.rawValue)
                        CCPill(icon: "chevron.left.forwardslash.chevron.right", text: ws.techStack.rawValue)
                    } else {
                        CCPill(icon: "cloud", text: "Cloudflare Workers")
                        CCPill(icon: "chevron.left.forwardslash.chevron.right", text: "Vanilla HTML/JS")
                    }
                }
            }
            Divider().overlay(CC.stroke)
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Last deploy").font(.system(size: 9, weight: .semibold)).foregroundStyle(CC.textSub)
                    HStack(spacing: 5) {
                        Image(systemName: "checkmark.seal.fill").font(.system(size: 10)).foregroundStyle(CC.accent)
                        Text(dashboardLastDeployText)
                            .font(AppFont.metadata).foregroundStyle(CC.text).lineLimit(1).minimumScaleFactor(0.6)
                    }
                }
                Spacer(minLength: 6)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Environment").font(.system(size: 9, weight: .semibold)).foregroundStyle(CC.textSub)
                    HStack(spacing: 5) {
                        if Theme.isGlass { GlassLED(color: CC.accent, size: 4.5) }
                        else { Circle().fill(CC.accent).frame(width: 6, height: 6) }
                        Text("Production").font(AppFont.metadata).foregroundStyle(CC.text)
                    }
                }
                Spacer(minLength: 6)
                if let url = heroSiteURL {
                    Button {
                        Haptics.tap()
                        openURL(url)
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: "arrow.up.forward.square")
                            Text("Open Site")
                        }
                        .font(.system(size: 10, weight: .semibold, design: .rounded))
                        .foregroundStyle(CC.text)
                        .lineLimit(1).fixedSize()
                        .padding(.horizontal, 9).padding(.vertical, 6)
                        .adaptiveGlassSurface(.button, cornerRadius: 999, classicFill: CC.card)
                    }
                    .buttonStyle(.pressable)
                    .accessibilityLabel("Open site in browser")
                }
            }
        }
        .padding(AppSize.heroPadding)
        .frame(maxWidth: .infinity, minHeight: AppSize.heroHeight, alignment: .topLeading)
        .modifier(CCCardSurfaceModifier(highlighted: true, corner: AppSize.heroCorner, layer: .hero))
    }

    // MARK: Stat grid

    private func statCard(icon: String, badge: String, value: String, label: String,
                          caption: String, bigValue: Bool = true) -> some View {
        let iconColor = icon == "slash.circle" ? Color(hex: 0xFFB23E) : CC.accent
        // Badge lives IN the caption row (not floated over the card), so it can
        // never overlap the value ("OpenCode Go") at any width or text size.
        return HStack(alignment: .top, spacing: 10) {
            CCEmbeddedMetricIcon(icon: icon, tint: iconColor)
            VStack(alignment: .leading, spacing: 1) {
                Text(label).font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundStyle(CC.text)
                    .lineLimit(1).minimumScaleFactor(0.75)
                Text(value)
                    .font(bigValue ? AppFont.metricValue : AppFont.providerValue)
                    .foregroundStyle(CC.text)
                    .lineLimit(1)
                    .minimumScaleFactor(0.55)
                    .allowsTightening(true)
                HStack(alignment: .center, spacing: 6) {
                    Text(caption)
                        .font(.system(size: 9, weight: .medium, design: .rounded))
                        .foregroundStyle(CC.textGreen)
                        .lineLimit(1)
                        .minimumScaleFactor(0.72)
                    Spacer(minLength: 4)
                    Text(badge)
                        .font(.system(size: 8, weight: .medium, design: .rounded))
                        .foregroundStyle(CC.textSub)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .adaptiveGlassSurface(
                            .badge,
                            cornerRadius: 10,
                            classicFill: colorScheme == .dark ? Color.white.opacity(0.07) : Color.black.opacity(0.05)
                        )
                        .fixedSize()
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(9)
        .frame(maxWidth: .infinity, minHeight: AppSize.metricCardHeight, alignment: .topLeading)
        .modifier(CCCardSurfaceModifier())
    }

    private var statGrid: some View {
        let clean = engine.pendingChanges.isEmpty
        let latestDeployState = recentDeployments.first?.state
        let connectedBadge = hasDeployIntegration ? "Ready" : "Setup"
        let connectedCaption: String = {
            guard hasDeployIntegration else { return "No deploy target" }
            guard let state = latestDeployState else { return "No deploys yet" }
            switch state {
            case .success: return "Last deploy successful"
            case .failure: return "Last deploy failed"
            case .building: return "Deploying now"
            case .queued: return "Deploy queued"
            case .canceled, .unknown: return "Check deploy target"
            }
        }()
        #if DEBUG
        let isPro = AgentEngine.screenshotDemo || iap.isPro
        let providerLabel = AgentEngine.screenshotDemo ? "OpenCode Go" : engine.activeProvider.displayName
        #else
        let isPro = iap.isPro
        let providerLabel = engine.activeProvider.displayName
        #endif
        let sessionsCaption = iap.isPro ? "Active plan" : "Free plan"
        return LazyVGrid(columns: cols, spacing: 10) {
            statCard(icon: "globe", badge: connectedBadge, value: "\(engine.workspaces.count)",
                     label: "Connected Sites", caption: connectedCaption)
            statCard(icon: "slash.circle", badge: clean ? "Up to date" : "Review",
                     value: "\(engine.pendingChanges.count)", label: "Changes Staged",
                     caption: clean ? "Working tree clean" : "Changes pending")
            statCard(icon: "bolt.fill", badge: isPro ? "No limits" : "Free",
                     value: isPro ? "Unlimited" : "\(max(0, 8 - iap.freeSessionsUsedThisMonth)) left",
                     label: "Sessions", caption: sessionsCaption)
            statCard(icon: "cpu", badge: "Active", value: providerLabel,
                     label: "Provider", caption: "Fast · Secure · Private", bigValue: false)
        }
    }

    // MARK: Quick actions

    private func quickAction(icon: String, title: String, subtitle: String,
                             highlighted: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                CCIconChip(icon: icon)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(AppFont.actionTitle).foregroundStyle(CC.text)
                        .lineLimit(1).minimumScaleFactor(0.7)
                    Text(subtitle).font(AppFont.subtitle).foregroundStyle(CC.textSub).lineLimit(1).minimumScaleFactor(0.7)
                }
                Spacer(minLength: 2)
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(CC.textSub)
                    .frame(width: 25, height: 25)
                    .background(colorScheme == .dark ? Color.white.opacity(0.07) : Color.black.opacity(0.05), in: RoundedRectangle(cornerRadius: 6))
            }
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity, minHeight: AppSize.actionCardHeight, alignment: .leading)
            .modifier(CCCardSurfaceModifier(highlighted: highlighted, corner: AppSize.actionCorner, layer: .control))
        }
        .buttonStyle(.pressable)
        .accessibilityLabel(title)
        .accessibilityHint(subtitle)
    }

    private var quickActionsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            CCEyebrow(text: "Quick Actions")
            LazyVGrid(columns: cols, spacing: 8) {
                quickAction(icon: "message.fill", title: "New Chat", subtitle: "Talk to your agent", highlighted: true) {
                    Haptics.tap(); engine.resetConversation(); tab = .agent
                }
                quickAction(icon: "plus", title: "Add Site", subtitle: "Connect a new site") {
                    Haptics.tap()
                    if IAPManager.shared.isPro || engine.workspaces.isEmpty { showAddSite = true } else { showPaywall = true }
                }
                quickAction(icon: "eye.fill", title: "Preview", subtitle: "Live preview your site") {
                    Haptics.tap(); tab = .preview
                }
                quickAction(icon: "arrow.triangle.branch", title: "Preview PR", subtitle: "Preview pull request") {
                    Haptics.tap()
                    engine.resetConversation()
                    engine.prefilledPrompt = "Create a temporary preview branch for the next risky change and open a pull request before merging to production. Start by proposing a branch name and plan."
                    tab = .agent
                }
            }
        }
    }

    // MARK: AI recommendations

    private func recommendationCard(icon: String, title: String, body_: String,
                                    risk: String, impact: String, prompt: String) -> some View {
        Button {
            Haptics.tap()
            engine.resetConversation()
            engine.prefilledPrompt = prompt
            tab = .agent
        } label: {
            HStack(alignment: .top, spacing: 10) {
                CCIconChip(icon: icon)
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(AppFont.cardTitle).foregroundStyle(CC.text)
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                    Text(body_).font(AppFont.subtitle).foregroundStyle(CC.textSub).lineLimit(2)
                        .multilineTextAlignment(.leading)
                    HStack(spacing: 8) {
                        HStack(spacing: 4) {
                            Circle().fill(CC.accent).frame(width: 4, height: 4)
                            Text(risk).font(.system(size: 9)).foregroundStyle(CC.textSub)
                                .lineLimit(1)
                        }
                        HStack(spacing: 4) {
                            Image(systemName: "chart.bar.fill").font(.system(size: 8)).foregroundStyle(CC.textSub)
                            Text(impact).font(.system(size: 9)).foregroundStyle(CC.textSub)
                                .lineLimit(1)
                        }
                    }
                }
                Spacer(minLength: 4)
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(CC.textSub)
                    .frame(width: 22, height: 22)
                    .background(colorScheme == .dark ? Color.white.opacity(0.07) : Color.black.opacity(0.05), in: RoundedRectangle(cornerRadius: 6))
            }
            .padding(10)
            .frame(maxWidth: .infinity, minHeight: AppSize.recommendationHeight, alignment: .topLeading)
            .modifier(CCCardSurfaceModifier())
        }
        .buttonStyle(.pressable)
        .accessibilityLabel("\(title). \(risk), \(impact)")
    }

    private var recommendationsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            CCEyebrow(text: "AI Recommendations", trailing: "View all") { tab = .agent }
            LazyVGrid(columns: cols, spacing: 8) {
                recommendationCard(icon: "magnifyingglass", title: "Optimize for SEO",
                                   body_: "Audit search keywords and title tag formatting.",
                                   risk: "Low Risk", impact: "High Impact",
                                   prompt: "Audit this workspace for SEO and present a recommendation list.")
                recommendationCard(icon: "sparkles", title: "Improve Hero",
                                   body_: "Make the first screen clearer and more action-oriented.",
                                   risk: "Low Risk", impact: "Medium Impact",
                                   prompt: "Improve the homepage hero section for clarity, conversion, and mobile readability.")
            }
        }
    }

    // MARK: Deployments (timeline)

    private var deploymentsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            CCEyebrow(text: "Deployments")
            VStack(spacing: 0) {
                if let notice = deploymentHistoryNotice {
                    DeploymentHistoryNoticeView(notice: notice) {
                        Task { await loadDeployments(force: true) }
                    } openSettings: {
                        showSettings = true
                    }
                    .padding(.bottom, displayedDeployments.isEmpty && !loadingDeployments ? 0 : 10)
                }

                if loadingDeployments && recentDeployments.isEmpty {
                    SkeletonRows(count: 3).transition(.opacity)
                } else if displayedDeployments.isEmpty {
                    if deploymentHistoryNotice == nil {
                        emptyDeployRow(icon: "paperplane", text: "No deployments yet")
                    }
                } else {
                    let shown = displayedDeployments
                    ForEach(Array(shown.enumerated()), id: \.element.id) { idx, deployment in
                        deploymentTimelineRow(deployment, isLast: idx == shown.count - 1)
                    }
                }

                if !deploymentLogs.isEmpty {
                    Divider().overlay(CC.stroke)
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text("LATEST LOGS").font(.system(size: 10, weight: .semibold)).tracking(1).foregroundStyle(CC.textSub)
                            Spacer()
                            Button("Diagnose with AI") { Haptics.tap(); askAgentToDiagnose() }
                                .font(.system(size: 12, weight: .semibold)).foregroundStyle(CC.accent)
                        }
                        ForEach(deploymentLogs.suffix(6)) { line in
                            Text(line.text)
                                .font(.system(size: 11, design: .monospaced)).foregroundStyle(CC.textSub)
                                .lineLimit(2).textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .padding(.top, 10)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, minHeight: AppSize.deploymentCardMinHeight, alignment: .topLeading)
            .modifier(CCCardSurfaceModifier())
        }
    }

    private func deploymentTimelineRow(_ deployment: DashboardDeploymentDisplay, isLast: Bool) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 10) {
                VStack(spacing: 0) {
                    Image(systemName: deploymentIcon(deployment.state))
                        .font(.system(size: 15)).foregroundStyle(deploymentColor(deployment.state))
                        .glassGlow(deploymentColor(deployment.state))
                    if !isLast {
                        Rectangle().fill(CC.accent.opacity(0.4)).frame(width: 2).frame(maxHeight: .infinity)
                    }
                }
                .frame(width: 18)
                VStack(alignment: .leading, spacing: 2) {
                    Text(deployment.title)
                        .font(AppFont.cardTitle).foregroundStyle(CC.text).lineLimit(1)
                    Text(deployment.subtitle)
                        .font(AppFont.subtitle).foregroundStyle(CC.textSub).lineLimit(1)
                    if let record = deployment.record, record == recentDeployments.first {
                        deployActions(record).padding(.top, 4)
                    }
                }
                .padding(.bottom, isLast ? 0 : 9)
                Spacer(minLength: 6)
                Text(deployment.state.label)
                    .font(AppFont.pill).foregroundStyle(deploymentColor(deployment.state))
                    .padding(.horizontal, 8)
                    .frame(height: AppSize.statusPillHeight)
                    .background(deploymentColor(deployment.state).opacity(0.16), in: Capsule())
                    .fixedSize()
            }
        }
        .accessibilityElement(children: .contain)
    }

    // MARK: Recent activity

    private var recentActivitySection: some View {
        VStack(alignment: .leading, spacing: 10) {
            CCEyebrow(text: "Recent Activity", trailing: "View all") { showHistory = true }
            VStack(spacing: 0) {
                if loadingActivity {
                    SkeletonRows(count: 4).transition(.opacity)
                } else if displayedActivities.isEmpty {
                    emptyDeployRow(icon: "clock", text: "No recent activity")
                } else {
                    ForEach(displayedActivities) { activity in
                        HStack(spacing: 9) {
                            Image(systemName: "arrow.triangle.branch")
                                .font(.system(size: 12)).foregroundStyle(CC.accent)
                                .frame(width: 24, height: 24)
                                .background(CC.accentDim, in: RoundedRectangle(cornerRadius: 8))
                            VStack(alignment: .leading, spacing: 2) {
                                Text(activity.title).font(AppFont.cardTitle).foregroundStyle(CC.text).lineLimit(1)
                                Text(activity.metadata).font(AppFont.subtitle).foregroundStyle(CC.textSub).lineLimit(1)
                            }
                            Spacer(minLength: 6)
                            if let commit = activity.commit, commit.id == recentCommits.first?.id {
                                Button {
                                    Haptics.tap(); commitToUndo = commit; showUndoConfirm = true
                                } label: {
                                    Group {
                                        if undoing { ProgressView().controlSize(.small) }
                                        else { Image(systemName: "arrow.uturn.backward").foregroundStyle(Color(hex: 0xFFB23E)) }
                                    }
                                    .frame(width: 30, height: 30).contentShape(Rectangle())
                                }
                                .buttonStyle(.plain).disabled(undoing)
                                .accessibilityLabel("Undo last commit")
                            }
                            Text(activity.hash).font(AppFont.metadata).foregroundStyle(CC.textSub)
                        }
                        .padding(.vertical, 4)
                        if activity.id != displayedActivities.last?.id { Divider().overlay(CC.stroke) }
                    }
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, minHeight: AppSize.recentActivityMinHeight, alignment: .topLeading)
            .modifier(CCCardSurfaceModifier())
        }
    }

    // MARK: - Data + deploy actions (unchanged behavior)

    private var hasDeployIntegration: Bool {
        #if DEBUG
        if AgentEngine.screenshotDemo { return true }
        #endif
        guard let ws = engine.activeWorkspace else { return false }
        return DeploymentClientFactory.client(for: ws, repo: engine.repo) != nil
            || DeploymentClientFactory.deployHookURL(for: ws) != nil
    }

    private func emptyDeployRow(icon: String, text: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon).foregroundStyle(CC.textSub)
            Text(text).font(.system(size: 14)).foregroundStyle(CC.textSub)
            Spacer()
        }
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private func deployActionButton(_ key: String, _ title: String, _ systemImage: String,
                                    role: ButtonRole? = nil, action: @escaping () -> Void) -> some View {
        Button(role: role) {
            Haptics.tap(); action()
        } label: {
            if busyDeployAction == key {
                ProgressView().controlSize(.small)
            } else {
                Label(title, systemImage: systemImage)
            }
        }
        .disabled(deploymentActionBusy)
    }

    private func deployActions(_ deployment: DeploymentRecord) -> some View {
        HStack(spacing: 14) {
            deployActionButton("logs", "Logs", "doc.text.magnifyingglass") {
                Task { await loadLogs(for: deployment) }
            }
            if let ws = engine.activeWorkspace,
               let client = DeploymentClientFactory.client(for: ws, repo: engine.repo) {
                if client.supportsRetry {
                    deployActionButton("retry", "Retry", "arrow.clockwise") {
                        Task { await performDeployAction("retry", "Retry requested") { try await client.retry(deployment) } }
                    }
                }
                if client.supportsRollback {
                    deployActionButton("rollback", "Rollback", "arrow.uturn.backward", role: .destructive) {
                        pendingRollback = deployment; showRollbackConfirm = true
                    }
                }
                if client.supportsPurgeBuildCache {
                    deployActionButton("purge", "Purge Cache", "trash") {
                        Task { await performDeployAction("purge", "Build cache purged") { try await client.purgeBuildCache() } }
                    }
                }
            }
            if let ws = engine.activeWorkspace,
               DeploymentClientFactory.deployHookURL(for: ws) != nil {
                deployActionButton("hook", "Hook", "paperplane") {
                    Task { await performDeployAction("hook", "Deploy hook triggered") { try await DeploymentClientFactory.triggerDeployHook(for: ws) } }
                }
            }
        }
        .font(.system(size: 12, weight: .semibold))
        .tint(CC.accent)
        .buttonStyle(.borderless)
    }

    private func deploymentIcon(_ state: DeploymentState) -> String {
        switch state {
        case .queued: return "clock.fill"
        case .building: return "hammer.fill"
        case .success: return "checkmark.circle.fill"
        case .failure: return "xmark.octagon.fill"
        case .canceled: return "minus.circle.fill"
        case .unknown: return "questionmark.circle.fill"
        }
    }

    private func deploymentColor(_ state: DeploymentState) -> Color {
        switch state {
        case .success: return CC.accent
        case .failure: return Color(hex: 0xFF6B6B)
        case .canceled: return Color(hex: 0xFFB23E)
        case .building: return Color(hex: 0x3BA7FF)
        case .queued, .unknown: return CC.textSub
        }
    }

    private func deploymentSubtitle(_ deployment: DeploymentRecord) -> String {
        var pieces: [String] = []
        if let date = deployment.createdAt { pieces.append(date.formatted(date: .abbreviated, time: .shortened)) }
        if let message = deployment.message, !message.isEmpty { pieces.append(message) }
        else if !deployment.shortSHA.isEmpty { pieces.append(deployment.shortSHA) }
        return pieces.isEmpty ? "No deployment metadata" : pieces.joined(separator: " · ")
    }

    private func loadActivity() async {
        guard engine.activeWorkspace != nil else {
            recentCommits = []
            recentDeployments = []
            return
        }
        #if DEBUG
        if AgentEngine.screenshotDemo {
            recentCommits = Self.demoCommits
            recentDeployments = Self.demoDeployments
            loadingActivity = false
            loadingDeployments = false
            return
        }
        #endif
        if engine.hasGitHubToken {
            withAnimation(Theme.spring) { loadingActivity = true }
            let commits = (try? await GitHubClient(repo: engine.repo).commits(limit: 4)) ?? []
            withAnimation(Theme.spring) {
                recentCommits = commits
                loadingActivity = false
            }
        } else {
            recentCommits = []
        }
        await loadDeployments()
    }

    private func loadDeployments(force: Bool = false) async {
        guard let ws = engine.activeWorkspace,
              let client = DeploymentClientFactory.client(for: ws, repo: engine.repo) else {
            recentDeployments = []
            deploymentLogs = []
            deploymentHistoryNotice = nil
            deploymentsWorkspaceID = nil
            return
        }

        deploymentLoadGeneration += 1
        let generation = deploymentLoadGeneration
        let workspaceID = ws.id.uuidString

        if deploymentsWorkspaceID != ws.id {
            recentDeployments = []
            deploymentLogs = []
            deploymentHistoryNotice = nil
            deploymentsWorkspaceID = ws.id
        }

        // Stale-while-revalidate: paint cached rows immediately.
        if let cached = DeploymentHistoryCache.records(for: workspaceID), !cached.isEmpty {
            recentDeployments = cached
        } else if force {
            // Manual retry with no cache: keep section interactive without wiping other UI.
        }

        if recentDeployments.isEmpty {
            withAnimation(Theme.spring) { loadingDeployments = true }
        }

        do {
            let deps = try await client.listDeployments(limit: 5, commitSHA: nil)
            guard generation == deploymentLoadGeneration else { return }
            let meta = DeploymentHistoryCache.consumeLastServe(for: workspaceID)
            withAnimation(Theme.spring) {
                recentDeployments = deps
                loadingDeployments = false
                if meta.servedFromCache {
                    deploymentHistoryNotice = .stale(fetchedAt: meta.fetchedAt)
                } else {
                    deploymentHistoryNotice = nil
                }
            }
        } catch {
            guard generation == deploymentLoadGeneration else { return }
            let mapped = DeploymentClientError.map(error)
            if mapped.isCancellation {
                withAnimation(Theme.spring) { loadingDeployments = false }
                return
            }
            withAnimation(Theme.spring) {
                loadingDeployments = false
                // Keep any previously loaded / cached rows visible.
                deploymentHistoryNotice = .failure(mapped, hasCachedData: !recentDeployments.isEmpty)
            }
        }
    }

    private func loadLogs(for deployment: DeploymentRecord) async {
        guard let ws = engine.activeWorkspace,
              let client = DeploymentClientFactory.client(for: ws, repo: engine.repo) else { return }
        busyDeployAction = "logs"
        deploymentActionBusy = true
        defer { deploymentActionBusy = false; busyDeployAction = nil }
        do {
            deploymentLogs = try await client.logs(for: deployment, limit: 40)
            let diagnosis = DeploymentLogDiagnosis.summarize(deployment, logs: deploymentLogs)
            deploymentActionAlert = diagnosis.isEmpty ? "Loaded \(deploymentLogs.count) log line\(deploymentLogs.count == 1 ? "" : "s")." : diagnosis
        } catch {
            let mapped = DeploymentClientError.map(error)
            if mapped.isCancellation { return }
            deploymentActionAlert = mapped.localizedDescription
        }
    }

    private func performDeployAction(_ key: String, _ success: String, action: () async throws -> Void) async {
        busyDeployAction = key
        deploymentActionBusy = true
        defer { deploymentActionBusy = false; busyDeployAction = nil }
        do {
            try await action()
            deploymentActionAlert = success
            Haptics.success()
            await loadDeployments(force: true)
        } catch {
            let mapped = DeploymentClientError.map(error)
            if mapped.isCancellation { return }
            deploymentActionAlert = mapped.localizedDescription
            Haptics.error()
        }
    }

    private func askAgentToDiagnose() {
        let logText = deploymentLogs.map(\.text).joined(separator: "\n")
        engine.prefilledPrompt = "Diagnose this deployment failure and propose the smallest safe fix. Use the repository files if needed.\n\nDeployment logs:\n\(logText)"
        tab = .agent
    }
}

#if DEBUG
// Sample data for marketing-screenshot mode (SCREENSHOT_DEMO=1). Never in release.
extension HomeDashboardView {
    static func demoDate(_ iso: String) -> Date {
        ISO8601DateFormatter().date(from: iso) ?? Date(timeIntervalSince1970: 0)
    }

    static var demoCommits: [CommitEntry] {
        [
            CommitEntry(sha: "b378f20a1b2c3d", message: "Update 2 files…", authorName: "Cesur2000", dateString: "2026-06-27T19:44:00Z", avatarURL: nil),
            CommitEntry(sha: "30862a7e4f5061", message: "Vamp Remote 1.3.6 (build 14)", authorName: "Mesutcy", dateString: "2026-06-27T10:09:00Z", avatarURL: nil),
            CommitEntry(sha: "8397019b9c0d1e", message: "Vamp Host 3.8.11 (build 35)", authorName: "Mesutcy", dateString: "2026-06-27T09:32:00Z", avatarURL: nil),
            CommitEntry(sha: "615e8a8f7a8b9c", message: "Vamp Host 3.8.10 (build 34)", authorName: "Mesutcy", dateString: "2026-06-27T09:18:00Z", avatarURL: nil),
        ]
    }
    static var demoDeployments: [DeploymentRecord] {
        [
            DeploymentRecord(id: "d1", providerID: .cloudflareWorkers, providerName: "Cloudflare Workers", projectName: "website", state: .success, branch: "main", commitSHA: "b378f20a1b2c3d", url: "https://mesut.uk", createdAt: demoDate("2026-06-27T19:45:00Z"), finishedAt: demoDate("2026-06-27T19:46:00Z"), message: "Worker deployment", logsURL: "https://dash.cloudflare.com"),
            DeploymentRecord(id: "d2", providerID: .cloudflareWorkers, providerName: "Cloudflare Workers", projectName: "website", state: .success, branch: "main", commitSHA: "30862a7e4f5061", url: "https://mesut.uk", createdAt: demoDate("2026-06-27T10:10:00Z"), finishedAt: demoDate("2026-06-27T10:11:00Z"), message: "Worker deployment", logsURL: nil),
            DeploymentRecord(id: "d3", providerID: .cloudflareWorkers, providerName: "Cloudflare Workers", projectName: "website", state: .success, branch: "main", commitSHA: "8397019b9c0d1e", url: "https://mesut.uk", createdAt: demoDate("2026-06-27T09:33:00Z"), finishedAt: demoDate("2026-06-27T09:34:00Z"), message: "Worker deployment", logsURL: nil),
        ]
    }
}
#endif
