import SwiftUI
import WebKit
import UniformTypeIdentifiers

struct SitePreviewView: View {
    let repo: RepoConfig
    let pendingChanges: [PendingChange]
    
    @EnvironmentObject var engine: AgentEngine
    @ObservedObject private var iap = IAPManager.shared
    
    @State private var localURL: URL?
    @State private var isLiveSiteFallback = false
    @State private var loading = true
    @State private var error: String?
    @State private var previewMode: PreviewMode = .mobile
    
    // Inspector states
    @State private var inspectorEnabled = false
    @State private var inspectModeActive = false
    @State private var webView: WKWebView?
    // True only after the preview page has finished a navigation. Used to gate
    // evaluateJavaScript so we never run JS against an uncommitted frame (which
    // logs `runJavaScriptInFrameInScriptWorld: Request to run JavaScript failed`).
    @State private var previewReady = false
    /// Every generation gets its own identity and temp directory. This prevents
    /// a cancelled preview for the previous site from publishing state into the
    /// newly selected site and prevents WebKit from reusing a stale local page.
    @State private var previewGeneration = UUID()
    
    // Inspector data captures
    @State private var consoleLogs: [ConsoleLog] = []
    @State private var networkRequests: [NetworkRequest] = []
    @State private var performanceMetrics: PerformanceMetrics?
    @State private var selectedElement: ElementInfo?
    @State private var auditIssues: [SiteAuditIssue] = []
    
    @State private var activeSheet: ActiveInspectorSheet?
    @State private var showPaywall = false

    // Staged loading view state (0=fetching,1=applying,2=building,3=checking,4=done)
    @State private var loadStep: Int = 0
    @State private var loadLogs: [String] = []
    @State private var loadFailedStep: Int? = nil
    @State private var isPreparingLiveSite = false

    @Environment(\.openURL) private var openURL
    
    enum PreviewMode {
        case mobile, tablet, desktop

        struct Layout {
            let viewportSize: CGSize
            let displayScale: CGFloat

            var displaySize: CGSize {
                CGSize(
                    width: floor(viewportSize.width * displayScale),
                    height: floor(viewportSize.height * displayScale)
                )
            }
        }

        /// Keeps the web page's CSS viewport at the selected device dimensions,
        /// then scales the rendered surface to fit the available app space. A
        /// WKWebView must not be laid out at `displaySize`: doing so changes CSS
        /// breakpoints and makes a 390 pt phone preview behave like a ~280 pt one.
        func layout(in container: CGSize) -> Layout {
            let safeContainer = CGSize(
                width: max(container.width, 1),
                height: max(container.height, 1)
            )
            guard self != .desktop else {
                return Layout(viewportSize: safeContainer, displayScale: 1)
            }

            let viewportSize: CGSize = self == .mobile
                ? CGSize(width: 390, height: 844)
                : CGSize(width: 768, height: 1024)
            let availableWidth = max(container.width - 32, 1)
            let availableHeight = max(container.height - 32, 1)
            let scale = min(
                availableWidth / viewportSize.width,
                availableHeight / viewportSize.height,
                1
            )
            return Layout(viewportSize: viewportSize, displayScale: scale)
        }
    }
    
    enum ActiveInspectorSheet: Identifiable {
        case console, network, performance, audit
        var id: Self { self }
    }

    private var inspectorActive: Bool { inspectorEnabled && iap.isPro }

    /// Human label for the selected preview device, reused in the loading copy.
    private var previewModeName: String {
        switch previewMode {
        case .mobile: return "Mobile"
        case .tablet: return "Tablet"
        case .desktop: return "Desktop"
        }
    }

    /// The configured live site URL for the active workspace, if any.
    private var liveURLString: String {
        engine.activeWorkspace?.configuredLiveURL ?? ""
    }

    /// The environment's active workspace is authoritative. The `repo` input is
    /// retained for the inline approval preview, but it can otherwise be one
    /// render behind while the user switches sites.
    private var previewRepo: RepoConfig {
        guard let workspace = engine.activeWorkspace else { return repo }
        return RepoConfig(
            owner: workspace.gitOwner,
            name: workspace.gitRepo,
            branch: workspace.gitBranch,
            githubCredentialID: workspace.githubCredentialID
        )
    }

    /// Include the actual staged content, not only its count. Replacing one
    /// staged file with another file of the same count must regenerate the
    /// preview, and a workspace switch must never keep the old web view alive.
    private var previewTaskID: String {
        var hasher = Hasher()
        if let workspace = engine.activeWorkspace {
            hasher.combine(workspace.id.uuidString)
            hasher.combine(workspace.configuredLiveURL)
            hasher.combine(workspace.deploymentConfig["rootDirectory"] ?? "")
        } else {
            hasher.combine("none")
        }
        hasher.combine(previewRepo.owner)
        hasher.combine(previewRepo.name)
        hasher.combine(previewRepo.branch)
        for change in pendingChanges.sorted(by: { $0.path < $1.path }) {
            hasher.combine(change.path)
            hasher.combine(change.newContent)
            hasher.combine(change.isDeletion)
            if let uploadData = change.uploadData {
                hasher.combine(uploadData)
            } else {
                hasher.combine(0)
            }
        }
        return String(hasher.finalize())
    }

    private var consoleBadge: String? {
        let issues = consoleLogs.filter { $0.level == "warn" || $0.level == "error" }.count
        return cappedBadge(issues > 0 ? issues : consoleLogs.count)
    }

    private var consoleTint: Color {
        if consoleLogs.contains(where: { $0.level == "error" }) { return Theme.danger }
        if consoleLogs.contains(where: { $0.level == "warn" }) { return Theme.warn }
        return Theme.brand
    }

    private var networkBadge: String? {
        cappedBadge(networkRequests.count)
    }

    private func cappedBadge(_ count: Int) -> String? {
        guard count > 0 else { return nil }
        return count > 99 ? "99+" : "\(count)"
    }
    
    var body: some View {
        VStack(spacing: 0) {
            // Preview mode picker
            Picker("Preview Device", selection: $previewMode) {
                Label("Mobile", systemImage: "iphone").tag(PreviewMode.mobile)
                Label("Tablet", systemImage: "ipad").tag(PreviewMode.tablet)
                Label("Desktop", systemImage: "macbook").tag(PreviewMode.desktop)
            }
            .pickerStyle(.segmented)
            .tint(CC.accent)
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 14)
            
            ZStack {
                if loading {
                    preparingPreviewView
                } else if let error {
                    errorView(error)
                } else if let localURL {
                    VStack(spacing: 0) {
                        previewStatusArea

                        // Render the WebView inside a simulated device frame
                        GeometryReader { geo in
                        let layout = previewMode.layout(in: geo.size)
                        let cornerRadius: CGFloat = {
                            switch previewMode {
                            case .mobile: return 38
                            case .tablet: return 24
                            case .desktop: return 0
                            }
                        }()
                        let border: CGFloat = {
                            switch previewMode {
                            case .mobile: return 12
                            case .tablet: return 10
                            case .desktop: return 0
                            }
                        }()
                        
                        ZStack {
                            WebViewContainer(
                                fileURL: localURL,
                                loadsRemoteURL: isLiveSiteFallback,
                                mode: previewMode,
                                inspectorEnabled: inspectorActive,
                                inspectModeActive: $inspectModeActive,
                                webView: $webView,
                                previewReady: $previewReady,
                                consoleLogs: $consoleLogs,
                                networkRequests: $networkRequests,
                                performanceMetrics: $performanceMetrics,
                                selectedElement: $selectedElement
                            )
                            // Rebuild the web view when the inspector is toggled so the
                            // hooks are only ever injected while the inspector is on, and
                            // when a fresh build produces a new localURL (workspace switch
                            // or staged-change regen) so the page actually reloads.
                            .id("\(previewMode)#\(inspectorActive)#\(previewGeneration.uuidString)#\(localURL.absoluteString)")
                            // Lay the page out at the real simulated-device viewport.
                            // Scale only after WebKit has resolved responsive CSS.
                            .frame(
                                width: layout.viewportSize.width,
                                height: layout.viewportSize.height
                            )
                            .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
                            .overlay(
                                RoundedRectangle(cornerRadius: cornerRadius)
                                    .stroke(Color.primary.opacity(0.15), lineWidth: border)
                            )
                            .scaleEffect(layout.displayScale)
                            .frame(
                                width: layout.displaySize.width,
                                height: layout.displaySize.height
                            )
                            .shadow(radius: previewMode == .desktop ? 0 : 15)

                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                        .appBackground(.grouped)
                        }
                    }
                }
            }
        }
        .background(CommandDeckBackground())
        .navigationTitle("Live Preview")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: previewTaskID) {
            await generatePreview()
        }
        .onAppear {
            loadInspectorState()
        }
        .onChange(of: engine.activeWorkspace?.id) { _, _ in
            previewGeneration = UUID()
            webView = nil
            localURL = nil
            previewReady = false
            isLiveSiteFallback = false
            isPreparingLiveSite = false
            loading = true
            error = nil
            loadInspectorState()
        }
        .onChange(of: inspectorEnabled) { _, newValue in
            if newValue && !iap.isPro {
                inspectorEnabled = false
                showPaywall = true
                return
            }
            saveInspectorState(newValue)
            if newValue {
                consoleLogs.removeAll()
                networkRequests.removeAll()
                performanceMetrics = nil
                selectedElement = nil
            }
        }
        .onChange(of: iap.isPro) { _, isPro in
            if isPro {
                loadInspectorState()
            } else {
                inspectorEnabled = false
                inspectModeActive = false
                activeSheet = nil
                selectedElement = nil
            }
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    Haptics.tap()
                    if iap.isPro {
                        withAnimation(Theme.spring) {
                            inspectorEnabled.toggle()
                            if !inspectorEnabled {
                                inspectModeActive = false
                            }
                        }
                    } else {
                        showPaywall = true
                    }
                } label: {
                    Image(systemName: inspectorActive ? "ant.circle.fill" : "ant.circle")
                        .font(.title3)
                        .foregroundStyle(inspectorActive ? Theme.brand : .secondary)
                }
                .accessibilityLabel("Inspector")
                .accessibilityValue(inspectorActive ? "On" : "Off")
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if inspectorActive && !loading && error == nil {
                inspectorControlBar
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .sheet(item: $activeSheet) { sheet in
            switch sheet {
            case .console:
                ConsoleSheet(
                    logs: $consoleLogs,
                    onExecuteJS: { command in
                        webView?.evaluateJavaScript(command) { result, error in
                            let response: String
                            if let error = error {
                                response = "❌ Error: \(error.localizedDescription)"
                            } else if let result = result {
                                response = "➜ \(result)"
                            } else {
                                response = "➜ undefined"
                            }
                            consoleLogs.append(ConsoleLog(level: "log", message: response, timestamp: Date()))
                        }
                    },
                    onClear: {
                        consoleLogs.removeAll()
                    },
                    onAskAgent: { prompt in askAgent(prompt) }
                )
                .presentationDetents([.fraction(0.45), .medium, .large])
                
            case .network:
                NetworkSheet(requests: $networkRequests)
                    .presentationDetents([.fraction(0.45), .medium, .large])
                
            case .performance:
                PerformanceSheet(metrics: performanceMetrics ?? PerformanceMetrics())
                    .presentationDetents([.fraction(0.45), .medium, .large])

            case .audit:
                AuditSheet(issues: auditIssues, onAskAgent: { prompt in askAgent(prompt) })
                    .presentationDetents([.fraction(0.45), .medium, .large])
            }
        }
        .sheet(item: $selectedElement) { element in
            ElementInspectorSheet(
                element: element,
                onHighlightPermanently: {
                    webView?.evaluateJavaScript("window.addPermanentHighlightForCurrent()")
                },
                onAskAgent: { prompt in askAgent(prompt) }
            )
            .presentationDetents([.fraction(0.45), .medium, .large])
        }
        .sheet(isPresented: $showPaywall) {
            ProPaywall(context: .inspector)
        }
    }

    /// Status chrome lives in the preview column, above the device frame. It
    /// must not be layered over the site's own header or over the frame's
    /// top edge, especially when a tall phone/tablet preview is vertically
    /// centered in a short available area.
    @ViewBuilder private var previewStatusArea: some View {
        if isLiveSiteFallback || (inspectorActive && inspectModeActive) {
            VStack(spacing: 8) {
                if isLiveSiteFallback {
                    HStack(spacing: 6) {
                        Image(systemName: "network")
                        Text(
                            pendingChanges.isEmpty
                                ? "Showing live site"
                                : "Showing live site · unpublished edits not included"
                        )
                    }
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Theme.t1)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .adaptiveGlassSurface(
                        .badge,
                        cornerRadius: 999,
                        accentReflection: Theme.warn,
                        classicFill: CC.card
                    )
                    .accessibilityElement(children: .combine)
                }

                if inspectorActive && inspectModeActive {
                    HStack(spacing: 8) {
                        PulsingDot(color: .yellow, active: true)
                        Text("Tap any element on preview to inspect")
                            .font(.footnote.weight(.semibold))
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .glassSurface(.capsule, cornerRadius: 999, accentReflection: .yellow)
                    .accessibilityElement(children: .combine)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 4)
            .padding(.horizontal, 16)
            .padding(.bottom, 8)
            .allowsHitTesting(false)
            .transition(.move(edge: .top).combined(with: .opacity))
        }
    }
    
    // MARK: - Staged "Preparing Preview" loader

    private var activeLoadingTitle: String {
        switch loadStep {
        case 0:
            return isPreparingLiveSite ? "Resolving live deployment" : "Fetching repository"
        case 1:
            return "Applying staged changes"
        case 2:
            return "Building \(previewModeName) preview"
        case 3:
            return "Checking responsive layout"
        default:
            return "Preview ready"
        }
    }

    private var activeLoadingDetail: String {
        switch loadStep {
        case 0:
            return isPreparingLiveSite ? "Finding the current production URL" : "Reading repository tree"
        case 1:
            return pendingChanges.isEmpty ? "No unpublished changes" : "Applying patch"
        case 2:
            return isPreparingLiveSite ? "Opening deployed site" : "Installing dependencies & generating build…"
        case 3:
            return "Checking \(previewModeName.lowercased()) viewport"
        default:
            return "Ready to inspect"
        }
    }

    /// Derive a ChecklistRow state for step `index` from the current `loadStep`,
    /// surfacing a failure if `loadFailedStep` points at this row.
    private func stepState(_ index: Int) -> StepState {
        if loadFailedStep == index { return .failed }
        if loadStep > index { return .done }
        if loadStep == index { return .active }
        return .pending
    }

    @ViewBuilder private var preparingPreviewView: some View {
        ScrollView {
            VStack(spacing: 16) {
                preparingChecklistCard
                skeletonPhoneCard
                infoStripCard
                if !loadLogs.isEmpty {
                    recentLogsCard
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 16)
            .padding(.bottom, AppSize.scrollContentBottomSpacing)
            .readableWidth()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .commandBackground()
    }

    private var preparingChecklistCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                ProgressView()
                    .controlSize(.regular)
                    .tint(Theme.brand)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Preparing Preview")
                        .font(.display(20, .bold))
                        .foregroundStyle(Theme.t1)
                    Text(activeLoadingTitle)
                        .font(.ui(12))
                        .foregroundStyle(Theme.brand)
                }
                Spacer(minLength: 8)
                StatusPill(
                    text: isPreparingLiveSite ? "Live" : "Build",
                    tint: isPreparingLiveSite ? Theme.ok : Theme.brand,
                    kind: .soft
                )
            }

            Divider().overlay(Theme.separator)

            VStack(spacing: 10) {
                ChecklistRow(
                    title: "Fetching repository",
                    detail: loadStep > 0
                        ? "Completed"
                        : (isPreparingLiveSite ? "Resolving latest deployment" : "Reading repository tree"),
                    state: stepState(0)
                )
                ChecklistRow(
                    title: "Applying staged changes",
                    detail: pendingChanges.isEmpty
                        ? (isPreparingLiveSite ? "No unpublished changes" : "No changes detected")
                        : "Applying patch",
                    state: stepState(1),
                    trailing: pendingChanges.isEmpty ? "Up to date" : nil
                )
                ChecklistRow(
                    title: "Building \(previewModeName) preview",
                    detail: loadStep > 2 ? "Completed" : activeLoadingDetail,
                    state: stepState(2)
                )
                ChecklistRow(
                    title: "Checking responsive layout",
                    detail: loadStep > 3 ? "Completed" : (loadStep == 3 ? activeLoadingDetail : "Pending"),
                    state: stepState(3)
                )
            }
        }
        .padding(18)
        .commandCard(glow: true)
    }

    private var skeletonPhoneCard: some View {
        // Mirror the live device-frame sizing math so the placeholder matches.
        let width: CGFloat = {
            switch previewMode {
            case .mobile: return 190
            case .tablet: return 240
            case .desktop: return 280
            }
        }()
        let height: CGFloat = {
            switch previewMode {
            case .mobile: return 360
            case .tablet: return 320
            case .desktop: return 200
            }
        }()
        let cornerRadius: CGFloat = {
            switch previewMode {
            case .mobile: return 38
            case .tablet: return 24
            case .desktop: return 8
            }
        }()
        let border: CGFloat = {
            switch previewMode {
            case .mobile: return 12
            case .tablet: return 10
            case .desktop: return 2
            }
        }()

        return VStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(Theme.chip)
                    .overlay(
                        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                            .stroke(Theme.glassBorder, lineWidth: border)
                    )
                    .frame(width: width, height: height)

                VStack(alignment: .leading, spacing: 12) {
                    RoundedRectangle(cornerRadius: 6).frame(height: 24).shimmering()
                    RoundedRectangle(cornerRadius: 6).frame(height: 12).shimmering()
                    RoundedRectangle(cornerRadius: 6).frame(height: 12)
                        .padding(.trailing, 30).shimmering()
                    RoundedRectangle(cornerRadius: 10).frame(height: 70).shimmering()
                    HStack(spacing: 10) {
                        RoundedRectangle(cornerRadius: 8).frame(height: 44).shimmering()
                        RoundedRectangle(cornerRadius: 8).frame(height: 44).shimmering()
                    }
                    Spacer(minLength: 0)
                }
                .foregroundStyle(Theme.separator)
                .padding(18)
                .frame(width: width, height: height)
            }

            MetadataPill(text: "\(previewModeName) Preview", systemImage: "iphone", tint: Theme.t2)

            Text("Your site is being prepared for \(previewModeName)")
                .font(.ui(12))
                .foregroundStyle(Theme.t2)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(18)
        .commandCard()
    }

    @ViewBuilder private var infoStripCard: some View {
        HStack(spacing: 12) {
            Image(systemName: pendingChanges.isEmpty ? "checkmark.seal.fill" : "shippingbox.fill")
                .font(.title3)
                .foregroundStyle(pendingChanges.isEmpty ? Theme.ok : Theme.brand)
            VStack(alignment: .leading, spacing: 2) {
                if pendingChanges.isEmpty {
                    Text("No staged changes detected")
                        .font(.ui(14, .semibold))
                        .foregroundStyle(Theme.t1)
                    Text("Your live site is currently up to date.")
                        .font(.ui(12))
                        .foregroundStyle(Theme.t2)
                } else {
                    Text("\(pendingChanges.count) staged change(s) will be applied")
                        .font(.ui(14, .semibold))
                        .foregroundStyle(Theme.t1)
                    Text("Preview reflects your unpublished edits.")
                        .font(.ui(12))
                        .foregroundStyle(Theme.t2)
                }
            }
            Spacer(minLength: 4)
            if !liveURLString.isEmpty {
                Button {
                    Haptics.tap()
                    if let url = SiteWorkspace.normalizedLiveURL(liveURLString) { openURL(url) }
                } label: {
                    Text("View Site")
                        .font(.ui(13, .semibold))
                        .foregroundStyle(Theme.brand)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                        .background(Theme.brandSoft, in: Capsule())
                }
                .buttonStyle(.pressable)
                .accessibilityLabel("View live site")
            }
        }
        .padding(16)
        .commandCard()
    }

    private var recentLogsCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader("Recent Logs")
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(loadLogs.enumerated()), id: \.offset) { _, line in
                    HStack(alignment: .top, spacing: 8) {
                        Text("›")
                            .font(.mono(11))
                            .foregroundStyle(Theme.brand)
                        Text(line)
                            .font(.mono(11))
                            .foregroundStyle(Theme.t2)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
        }
        .padding(16)
        .commandCard()
    }

    @ViewBuilder private func errorView(_ message: String) -> some View {
        ScrollView {
            VStack(spacing: 16) {
                VStack(spacing: 14) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 40))
                        .foregroundStyle(Theme.danger)
                    Text("Preview Failed")
                        .font(.display(20, .bold))
                        .foregroundStyle(Theme.t1)
                    if let failed = loadFailedStep {
                        let labels = ["Fetching repository", "Applying staged changes", "Building preview", "Checking responsive layout"]
                        if failed >= 0 && failed < labels.count {
                            MetadataPill(text: "Failed at: \(labels[failed])", systemImage: "xmark.octagon", tint: Theme.danger)
                        }
                    }
                    Text(message)
                        .font(.ui(14))
                        .foregroundStyle(Theme.t2)
                        .multilineTextAlignment(.center)
                    Button {
                        Haptics.tap()
                        Task { await generatePreview() }
                    } label: {
                        Text("Retry")
                            .font(.ui(15, .semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 24)
                            .padding(.vertical, 11)
                            .background(Capsule().fill(Theme.brand))
                    }
                    .buttonStyle(.pressable)
                    .accessibilityLabel("Retry preview")
                }
                .padding(22)
                .commandCard()
            }
            .padding(16)
            .readableWidth()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .commandBackground()
    }

    private var inspectorControlBar: some View {
        HStack(spacing: 10) {
            InspectorToolbarButton(
                title: "Inspect",
                icon: inspectModeActive ? "hand.tap.fill" : "hand.tap",
                active: inspectModeActive,
                tint: .yellow
            ) {
                withAnimation(Theme.snappy) {
                    inspectModeActive.toggle()
                }
            }

            Spacer(minLength: 0)

            InspectorToolbarButton(
                title: "Console",
                icon: "terminal.fill",
                badge: consoleBadge,
                tint: consoleTint
            ) {
                activeSheet = .console
            }

            InspectorToolbarButton(
                title: "Network",
                icon: "network",
                badge: networkBadge,
                tint: Theme.brand
            ) {
                activeSheet = .network
            }

            InspectorToolbarButton(
                title: "Perf",
                icon: "gauge.with.needle.fill",
                active: performanceMetrics != nil,
                tint: .green
            ) {
                activeSheet = .performance
            }

            InspectorToolbarButton(
                title: "Audit",
                icon: "checklist.checked",
                active: !auditIssues.isEmpty,
                tint: .indigo
            ) {
                runAudit()
            }

            Spacer(minLength: 0)

            InspectorToolbarButton(
                title: "Close",
                icon: "xmark.circle.fill",
                tint: .red
            ) {
                withAnimation(Theme.snappy) {
                    inspectorEnabled = false
                    inspectModeActive = false
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .padding(.bottom, 8)
        .frame(maxWidth: .infinity)
        .background(.bar)
        .overlay(Divider(), alignment: .top)
    }


    
    private func loadInspectorState() {
        guard iap.isPro else {
            inspectorEnabled = false
            inspectModeActive = false
            return
        }
        if let slug = engine.activeWorkspace?.slug {
            inspectorEnabled = UserDefaults.standard.bool(forKey: "inspectorEnabled_\(slug)")
        } else {
            inspectorEnabled = false
        }
        inspectModeActive = false
    }
    
    private func saveInspectorState(_ val: Bool) {
        if let slug = engine.activeWorkspace?.slug {
            UserDefaults.standard.set(val, forKey: "inspectorEnabled_\(slug)")
        }
    }

    /// Hand a prefilled instruction to the chat tab (dismissing any inspector
    /// sheet first). The user reviews and sends it — no auto-spend.
    private func askAgent(_ prompt: String) {
        // Dismiss the inspector and switch to the chat tab FIRST, so ChatView is
        // the active, observing view, THEN hand it the prompt. Setting
        // prefilledPrompt while Chat is a background tab can be missed by its
        // onChange — which left the element context out of the composer.
        activeSheet = nil
        selectedElement = nil
        engine.requestedTab = .agent
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 350_000_000)
            engine.prefilledPrompt = prompt
        }
    }

    private func runAudit() {
        guard let webView, webView.url != nil, previewReady else {
            auditIssues = LightweightSiteAuditor.audit(
                html: "",
                metrics: performanceMetrics ?? PerformanceMetrics(),
                requests: networkRequests,
                logs: consoleLogs
            )
            activeSheet = .audit
            return
        }
        webView.evaluateJavaScript("document.documentElement.outerHTML") { result, _ in
            let html = result as? String ?? ""
            Task { @MainActor in
                auditIssues = LightweightSiteAuditor.audit(
                    html: html,
                    metrics: performanceMetrics ?? PerformanceMetrics(),
                    requests: networkRequests,
                    logs: consoleLogs
                )
                activeSheet = .audit
            }
        }
    }
    
    /// True when `fileURL` is `root` or a descendant. Both sides are canonicalized
    /// because iOS temp dirs surface as either `/var/…` or `/private/var/…` and no
    /// Foundation call reliably unifies them (`standardizedFileURL` ignores the
    /// symlink; `resolvingSymlinksInPath` bails on non-existent components), so
    /// the `/private` alias is stripped textually before the prefix check.
    static func isURLInsidePreviewRoot(_ fileURL: URL, root: URL) -> Bool {
        func canonical(_ url: URL) -> String {
            let path = url.standardizedFileURL.resolvingSymlinksInPath().path
            for alias in ["/private/var/", "/private/tmp/", "/private/etc/"] where path.hasPrefix(alias) {
                return String(path.dropFirst("/private".count))
            }
            return path
        }
        let filePath = canonical(fileURL)
        let rootPath = canonical(root)
        return filePath == rootPath || filePath.hasPrefix(rootPath + "/")
    }

    /// True when `relativePath` resolves inside `root` (no `..` component / absolute escape).
    /// Filenames containing ".." as a substring (e.g. `foo..bar.js`) are allowed.
    static func isSafePreviewRelativePath(_ relativePath: String, under root: URL) -> Bool {
        let trimmed = relativePath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        if trimmed.hasPrefix("/") { return false }
        if AgentEngine.pathContainsDotDotComponent(trimmed) { return false }
        let resolved = root.appendingPathComponent(trimmed).standardizedFileURL
        return isURLInsidePreviewRoot(resolved, root: root)
    }

    private func previewIsCurrent(_ generation: UUID, workspaceID: UUID?) -> Bool {
        guard !Task.isCancelled, previewGeneration == generation else { return false }
        return engine.activeWorkspace?.id == workspaceID
    }

    /// Resolve the production URL for a preview. `liveURL` is preferred, but
    /// the GitHub homepage fills the gap for older workspaces that predate the
    /// live-site field. This is particularly important for Next.js/SvelteKit
    /// repositories whose source tree has no static `index.html`.
    private func resolvedLiveSiteURL(for workspace: SiteWorkspace?, client: GitHubClient) async -> URL? {
        if let workspace,
           let configured = SiteWorkspace.normalizedLiveURL(workspace.configuredLiveURL) {
            return configured
        }

        // A workspace name is only a guess. Prefer the repository's configured
        // homepage before falling back to that guess; older workspaces can have
        // a stale repo/name domain even though their live site still exists.
        if !client.repo.isEmpty {
            do {
                if let homepage = try await client.repositoryHomepage(),
                   let url = SiteWorkspace.normalizedLiveURL(homepage) {
                    return url
                }
            } catch {
                // Fall through to the best-effort workspace candidate.
            }
        }

        let rootDirectory = workspace?.deploymentConfig["rootDirectory"] ?? ""
        if let repositoryURL = await client.repositoryConfiguredLiveURL(rootDirectory: rootDirectory) {
            return repositoryURL
        }

        // GitHub's homepage is optional. Hosting APIs and custom-domain
        // records are the next authoritative source, especially for older
        // Cloudflare Workers workspaces whose repository name is not their
        // public domain (for example elemanlar-m.net → elemanlazim.net).
        if let workspace,
           let deploymentClient = DeploymentClientFactory.client(for: workspace, repo: previewRepo) {
            if let latest = try? await deploymentClient.listDeployments(limit: 1, commitSHA: nil).first,
               let url = SiteWorkspace.normalizedLiveURL(latest.displayURL) {
                return url
            }
            if let domain = try? await deploymentClient.domains().first,
               let url = SiteWorkspace.normalizedLiveURL(domain.name) {
                return url
            }
        }

        return workspace?.previewURLCandidate
    }

    /// Give fast live-site resolution enough time to expose the same staged
    /// progress users see for a local build. Slow network work naturally keeps
    /// the loader visible longer; this is only the short transition between
    /// already-completed phases.
    private func waitForPreviewStage(
        _ milliseconds: UInt64 = 160,
        generation: UUID,
        workspaceID: UUID?
    ) async -> Bool {
        do {
            try await Task.sleep(nanoseconds: milliseconds * 1_000_000)
        } catch {
            return false
        }
        return previewIsCurrent(generation, workspaceID: workspaceID)
    }

    private func generatePreview() async {
        let generation = UUID()
        let workspace = engine.activeWorkspace
        let workspaceID = workspace?.id
        let currentRepo = previewRepo
        previewGeneration = generation
        // Tear down the previous WebKit instance before replacing its source.
        // A static `siteagentpreview://site/` URL otherwise lets WebKit keep a
        // previous site's document and cache when the active site changes.
        webView = nil
        previewReady = false
        localURL = nil
        loading = true
        error = nil
        isLiveSiteFallback = false
        isPreparingLiveSite = false
#if DEBUG
        // Marketing-screenshot mode: hold the "Preparing Preview" card with a
        // populated checklist instead of hitting the network. Never in release.
        if AgentEngine.screenshotDemo {
            withAnimation(Theme.snappy) {
                loadStep = 2
                loadFailedStep = nil
                loadLogs = ["Pulled from main", "No staged changes detected",
                            "Build started (mobile)", "Installing dependencies",
                            "Generating build output…"]
            }
            return // stay on the loader
        }
        #endif
        withAnimation(Theme.snappy) {
            loadStep = 0
            loadLogs = []
            loadFailedStep = nil
        }
        loadLogs.append("Pulled from " + currentRepo.branch)
        do {
            let client = GitHubClient(repo: currentRepo)

            // With no unpublished changes the live site is the most accurate
            // preview of what visitors see. It also avoids pretending that a
            // checked-in source snapshot is a built Next.js/Astro deployment.
            // Staged changes still take the local path below so the approval
            // preview reflects the user's edits.
            var liveSiteURL: URL?
            if pendingChanges.isEmpty {
                isPreparingLiveSite = true
                loadLogs.append("Resolving live deployment")
                liveSiteURL = await resolvedLiveSiteURL(for: workspace, client: client)
                guard previewIsCurrent(generation, workspaceID: workspaceID) else { return }
                if let liveSiteURL {
                    loadLogs.append("Resolved production URL")
                    withAnimation(Theme.snappy) { loadStep = 1 }
                    guard await waitForPreviewStage(generation: generation, workspaceID: workspaceID) else { return }

                    loadLogs.append("No unpublished changes")
                    withAnimation(Theme.snappy) { loadStep = 2 }
                    guard await waitForPreviewStage(generation: generation, workspaceID: workspaceID) else { return }

                    loadLogs.append("Opening deployed site")
                    withAnimation(Theme.snappy) { loadStep = 3 }
                    isLiveSiteFallback = true
                    localURL = liveSiteURL
                    loadLogs.append("Checking responsive layout")
                    guard await waitForPreviewStage(generation: generation, workspaceID: workspaceID) else { return }

                    withAnimation(Theme.snappy) { loadStep = 4 }
                    isPreparingLiveSite = false
                    loading = false
                    return
                }
                isPreparingLiveSite = false
            }

            guard previewIsCurrent(generation, workspaceID: workspaceID) else { return }
            let fileManager = FileManager.default

            // Optional workspace root (monorepo): strip prefix so preview is rooted
            // at apps/web etc. Paths outside the root are ignored.
            let configuredRoot = (workspace?.deploymentConfig["rootDirectory"] ?? "")
                .trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let rootPrefix: String = {
                guard !configuredRoot.isEmpty else { return "" }
                return configuredRoot.hasSuffix("/") ? configuredRoot : configuredRoot + "/"
            }()
            func remap(_ path: String) -> String? {
                guard !rootPrefix.isEmpty else { return path }
                if path == configuredRoot { return "" }
                guard path.hasPrefix(rootPrefix) else { return nil }
                return String(path.dropFirst(rootPrefix.count))
            }
            
            // 1. Create a generation-scoped temporary preview folder. Reusing
            // one directory let a cancelled site switch delete files that a
            // still-finishing download task was about to write, and also kept
            // the static scheme URL looking identical to WebKit.
            let previewRoot = fileManager.temporaryDirectory
                .appendingPathComponent("SiteAgentPreview", isDirectory: true)
                .standardizedFileURL
            let tempDir = previewRoot
                .appendingPathComponent(generation.uuidString, isDirectory: true)
                .standardizedFileURL
            try fileManager.createDirectory(at: tempDir, withIntermediateDirectories: true)
            
            // 2. Fetch recursive file listing
            let detailed = try await client.listRecursiveDetailed()
            guard previewIsCurrent(generation, workspaceID: workspaceID) else { return }
            if detailed.truncated {
                loadLogs.append("⚠ Repository tree truncated by GitHub — preview may be incomplete")
            }
            var entries = detailed.entries
            if !rootPrefix.isEmpty {
                entries = entries.compactMap { entry in
                    guard let rel = remap(entry.path) else { return nil }
                    var copy = entry
                    copy.path = rel
                    return copy
                }
                // Remap staged paths the same way when applying below.
                loadLogs.append("Using root directory \(configuredRoot)/ (\(entries.count) entries)")
            }
            withAnimation(Theme.snappy) { loadStep = 1 }
            loadLogs.append("Fetched repository (\(entries.count) entries)")

            // 3. Create the directory structure up front (cheap, local).
            for entry in entries where entry.type == .dir {
                guard !entry.path.isEmpty else { continue }
                let dirURL = tempDir.appendingPathComponent(entry.path)
                if !fileManager.fileExists(atPath: dirURL.path) {
                    try fileManager.createDirectory(at: dirURL, withIntermediateDirectories: true)
                }
            }

            // 4. Apply staged changes locally; collect remote files to fetch.
            //    Text assets render the page; image/font binaries are fetched so the
            //    preview isn't full of broken-image placeholders. Other binaries
            //    (video, archives) get a 0-byte placeholder to save bandwidth.
            let fetchExts: Set<String> = [
                "html", "htm", "css", "js", "mjs", "json", "svg", "txt", "md", "xml", "webmanifest",
                "png", "jpg", "jpeg", "gif", "webp", "avif", "bmp", "ico",
                "woff", "woff2", "ttf", "otf", "eot",
            ]
            // Map remapped local path → original GitHub path for downloads.
            func githubPath(forLocal local: String) -> String {
                rootPrefix.isEmpty ? local : rootPrefix + local
            }
            func localPath(forStaged stagedPath: String) -> String? {
                remap(stagedPath)
            }

            var toFetch: [(local: String, remote: String)] = []
            for entry in entries where entry.type == .file {
                // Reject traversal / absolute paths before writing into the preview temp dir.
                guard Self.isSafePreviewRelativePath(entry.path, under: tempDir) else { continue }
                let targetURL = tempDir.appendingPathComponent(entry.path).standardizedFileURL
                let parentDir = targetURL.deletingLastPathComponent()
                if !fileManager.fileExists(atPath: parentDir.path) {
                    try fileManager.createDirectory(at: parentDir, withIntermediateDirectories: true)
                }
                // Staged paths are repo-absolute; match via remapped local path.
                let stagedMatch = pendingChanges.first { change in
                    localPath(forStaged: change.path) == entry.path || change.path == entry.path
                }
                if let staged = stagedMatch {
                    if let uploadData = staged.uploadData {
                        try uploadData.write(to: targetURL)
                    } else if !staged.isDeletion {
                        try Data(staged.newContent.utf8).write(to: targetURL)
                    }
                    // staged deletion → leave the file absent
                } else {
                    toFetch.append((local: entry.path, remote: githubPath(forLocal: entry.path)))
                }
            }

            withAnimation(Theme.snappy) { loadStep = 2 }
            loadLogs.append(pendingChanges.isEmpty
                ? "No staged changes"
                : "Applied \(pendingChanges.count) staged change(s)")
            loadLogs.append("Build started")
            loadLogs.append("Installing dependencies")

            // 5. Download remote files concurrently. URLSession bounds itself to
            //    ~6 connections per host, so launching all tasks is naturally
            //    rate-limited while being far faster than the old serial loop.
            var downloadFailures = 0
            var emptyCriticalFiles: [String] = []
            await withTaskGroup(of: (URL, String, Data, Bool).self) { group in
                for item in toFetch {
                    guard Self.isSafePreviewRelativePath(item.local, under: tempDir) else { continue }
                    let targetURL = tempDir.appendingPathComponent(item.local).standardizedFileURL
                    let ext = (item.local as NSString).pathExtension.lowercased()
                    let remote = item.remote
                    let local = item.local
                    group.addTask {
                        if fetchExts.contains(ext) {
                            do {
                                let data = try await client.downloadData(path: remote)
                                return (targetURL, local, data, true)
                            } catch {
                                return (targetURL, local, Data(), false)
                            }
                        }
                        return (targetURL, local, Data(), true)   // non-previewable binary: placeholder
                    }
                }
                while let (url, path, data, ok) = await group.next() {
                    if !previewIsCurrent(generation, workspaceID: workspaceID) {
                        group.cancelAll()
                        return
                    }
                    // Re-check sandbox after concurrent resolve (must standardize
                    // both sides — raw tempDir.path is often /var while URLs are
                    // /private/var, which previously skipped every write).
                    guard Self.isURLInsidePreviewRoot(url, root: tempDir) else { continue }
                    if !ok {
                        downloadFailures += 1
                        let base = (path as NSString).lastPathComponent.lowercased()
                        if base == "index.html" || base == "index.htm"
                            || path.lowercased().hasSuffix(".css")
                            || path.lowercased().hasSuffix(".js") {
                            emptyCriticalFiles.append(path)
                        }
                        continue   // don't write empty stand-ins for failed critical fetches
                    }
                    do {
                        try data.write(to: url)
                    } catch {
                        downloadFailures += 1
                        loadLogs.append("Write failed: \(path)")
                    }
                }
            }
            guard previewIsCurrent(generation, workspaceID: workspaceID) else { return }
            if downloadFailures > 0 {
                loadLogs.append("\(downloadFailures) file download(s) failed")
            }
            if !emptyCriticalFiles.isEmpty {
                loadLogs.append("Missing critical assets: \(emptyCriticalFiles.prefix(5).joined(separator: ", "))")
            }

            // 5b. Staged NEW files (created by the agent, not yet in the remote
            //     tree) don't appear in `entries`, so the loop above skips them —
            //     meaning brand-new pages/components never showed in the preview.
            //     Write them here so the agent's most common output is visible.
            let localPaths = Set(entries.map { $0.path })
            for change in pendingChanges where !change.isDeletion {
                guard let local = localPath(forStaged: change.path) ?? (rootPrefix.isEmpty ? change.path : nil) else {
                    continue   // staged outside configured root — ignore for preview
                }
                guard !localPaths.contains(local) else { continue }
                guard Self.isSafePreviewRelativePath(local, under: tempDir) else { continue }
                let targetURL = tempDir.appendingPathComponent(local).standardizedFileURL
                try? fileManager.createDirectory(at: targetURL.deletingLastPathComponent(),
                                                  withIntermediateDirectories: true)
                if let uploadData = change.uploadData {
                    try? uploadData.write(to: targetURL)
                } else {
                    try? Data(change.newContent.utf8).write(to: targetURL)
                }
            }

            // 6. Locate an entry HTML file. Prefer the repo root, then common
            //    build-output directories, then the shallowest index.html anywhere
            //    — so previews work for sites whose entry isn't at the root. The
            //    scheme handler is rooted at the chosen file's directory, so the
            //    site's own absolute paths (`/css/app.css`) resolve correctly.
            let candidateIndexes = [
                "index.html", "index.htm",
                "public/index.html", "public/index.htm",
                "dist/index.html", "dist/index.htm",
                "build/index.html", "build/index.htm",
                "out/index.html", "_site/index.html", "docs/index.html",
                "site/index.html", "www/index.html",
            ]
            var indexURL: URL?
            for rel in candidateIndexes {
                let u = tempDir.appendingPathComponent(rel)
                if fileManager.fileExists(atPath: u.path) { indexURL = u; break }
            }
            if indexURL == nil {
                // Last resort: the shallowest index.html / index.htm anywhere in the tree.
                let shallow = entries
                    .filter { entry in
                        guard entry.type == .file else { return false }
                        let name = (entry.path as NSString).lastPathComponent.lowercased()
                        return name == "index.html" || name == "index.htm"
                    }
                    .min { $0.path.components(separatedBy: "/").count < $1.path.components(separatedBy: "/").count }
                if let p = shallow?.path {
                    let candidate = tempDir.appendingPathComponent(p)
                    // Only accept if the download actually landed (not a failed fetch).
                    if fileManager.fileExists(atPath: candidate.path) {
                        indexURL = candidate
                    }
                }
            }

            // GitHub truncates large recursive tree responses. In that case a
            // root index can be omitted even though it exists, and a failed
            // download can leave the same symptom. Probe the small set of
            // conventional entry paths directly through the Contents API so a
            // large repo does not turn into a misleading "no index.html" error.
            if indexURL == nil {
                let stagedDeletions = Set(pendingChanges.compactMap { change -> String? in
                    guard change.isDeletion else { return nil }
                    return change.path
                })
                for rel in candidateIndexes {
                    guard previewIsCurrent(generation, workspaceID: workspaceID) else { return }
                    let remotePath = rootPrefix + rel
                    if stagedDeletions.contains(remotePath) { continue }
                    do {
                        let data = try await client.downloadData(path: remotePath)
                        guard !data.isEmpty,
                              Self.isSafePreviewRelativePath(rel, under: tempDir) else { continue }
                        let candidate = tempDir.appendingPathComponent(rel).standardizedFileURL
                        guard Self.isURLInsidePreviewRoot(candidate, root: tempDir) else { continue }
                        try fileManager.createDirectory(at: candidate.deletingLastPathComponent(),
                                                         withIntermediateDirectories: true)
                        try data.write(to: candidate)
                        indexURL = candidate
                        loadLogs.append("Fetched \(remotePath) directly")
                        break
                    } catch {
                        // A missing candidate is expected; continue to the next
                        // conventional output directory.
                    }
                }
            }

            guard previewIsCurrent(generation, workspaceID: workspaceID) else { return }

            guard let resolvedIndex = indexURL, fileManager.fileExists(atPath: resolvedIndex.path) else {
                if liveSiteURL == nil {
                    liveSiteURL = await resolvedLiveSiteURL(for: workspace, client: client)
                    guard previewIsCurrent(generation, workspaceID: workspaceID) else { return }
                }
                if let liveURL = liveSiteURL {
                    loadLogs.append("No static build output in repository")
                    loadLogs.append(
                        workspace.flatMap { SiteWorkspace.normalizedLiveURL($0.configuredLiveURL) } != nil
                            ? "Using configured live site"
                            : "Using discovered production URL"
                    )
                    withAnimation(Theme.snappy) { loadStep = 3 }
                    self.isLiveSiteFallback = true
                    self.localURL = liveURL
                    withAnimation(Theme.snappy) { loadStep = 4 }
                    self.loading = false
                    return
                }
                var detail = "No index.html found to preview. Website Commander renders built/static HTML — if this is an Astro, Next.js, Hugo, Jekyll, or similar project, point the workspace at the branch or folder that contains the built site (e.g. dist/, public/, build/, or _site/)."
                if downloadFailures > 0 {
                    detail += " (\(downloadFailures) file download(s) failed — check network/GitHub rate limits and Retry.)"
                }
                throw NSError(domain: "SitePreview", code: 404, userInfo: [NSLocalizedDescriptionKey: detail])
            }

            loadLogs.append("Generating build output…")
            loadLogs.append("Located index.html")
            guard previewIsCurrent(generation, workspaceID: workspaceID) else { return }
            withAnimation(Theme.snappy) { loadStep = 3 }

            self.localURL = resolvedIndex
            withAnimation(Theme.snappy) { loadStep = 4 }
            self.loading = false
        } catch {
            guard previewIsCurrent(generation, workspaceID: workspaceID) else { return }
            loadFailedStep = loadStep
            self.error = error.localizedDescription
            self.loading = false
        }
    }
}

private struct InspectorToolbarButton: View {
    let title: String
    let icon: String
    var active: Bool = false
    var badge: String? = nil
    var tint: Color = Theme.brand
    let action: () -> Void

    var body: some View {
        Button {
            Haptics.tap()
            action()
        } label: {
            VStack(spacing: 3) {
                ZStack(alignment: .topTrailing) {
                    Image(systemName: icon)
                        .font(.system(size: 16, weight: .semibold))
                        .frame(width: 30, height: 22)

                    if let badge {
                        Text(badge)
                            .font(.system(size: 8, weight: .bold, design: .rounded))
                            .monospacedDigit()
                            .foregroundStyle(.white)
                            .padding(.horizontal, 4)
                            .frame(minWidth: 16, minHeight: 14)
                            .background(tint, in: Capsule())
                            .offset(x: 8, y: -5)
                    }
                }

                Text(title)
                    .font(.system(size: 10, weight: active ? .bold : .medium))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .foregroundStyle(active ? tint : .primary)
            .frame(width: 58, height: 44)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(active ? tint.opacity(0.14) : Color.clear)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(active ? tint.opacity(0.35) : Color.clear, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityValue(badge ?? (active ? "Active" : ""))
    }
}

struct WebViewContainer: UIViewRepresentable {
    let fileURL: URL
    let loadsRemoteURL: Bool
    let mode: SitePreviewView.PreviewMode
    /// Only inject the inspector hooks (and register the message handler) while
    /// the inspector is active. This keeps the `siteAgentInspector` channel out
    /// of the page entirely when previewing untrusted third-party scripts.
    let inspectorEnabled: Bool
    @Binding var inspectModeActive: Bool
    @Binding var webView: WKWebView?
    @Binding var previewReady: Bool
    @Binding var consoleLogs: [ConsoleLog]
    @Binding var networkRequests: [NetworkRequest]
    @Binding var performanceMetrics: PerformanceMetrics?
    @Binding var selectedElement: ElementInfo?
    
    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }
    
    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()

        // Serve the downloaded files through a custom URL scheme so the page loads
        // from a real web origin instead of file://. This makes the site's absolute
        // asset paths (`/css/app.css`), ES modules (`<script type="module">`), and
        // same-origin `fetch()` work — none of which load from a file:// origin in
        // WKWebView. The handler is sandboxed to the index file's directory.
        if !loadsRemoteURL {
            configuration.setURLSchemeHandler(
                PreviewSchemeHandler(rootDirectory: fileURL.deletingLastPathComponent()),
                forURLScheme: PreviewSchemeHandler.scheme)
        }

        // The inspector bridge is only wired up when the inspector is on, and only
        // for the main frame — so untrusted scripts in cross-origin iframes can't
        // reach `webkit.messageHandlers.siteAgentInspector`.
        if inspectorEnabled {
            configuration.userContentController.add(context.coordinator, name: "siteAgentInspector")
            let userScript = WKUserScript(source: WebViewContainer.inspectorJavaScript,
                                          injectionTime: .atDocumentStart, forMainFrameOnly: true)
            configuration.userContentController.addUserScript(userScript)
        }

        let webView = WKWebView(frame: .zero, configuration: configuration)
        // Browsers paint on white by default. With an opaque white backing, a site
        // that doesn't set its own `body` background renders correctly instead of
        // showing the dark app backdrop through a transparent web view — which made
        // ordinary static sites look blank/black. The rounded device frame clips it.
        webView.isOpaque = true
        webView.backgroundColor = .white
        webView.scrollView.backgroundColor = .white
        webView.navigationDelegate = context.coordinator
        
        if #available(iOS 16.4, *) {
            webView.isInspectable = inspectorEnabled
        }
        
        if mode == .mobile {
            webView.customUserAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1"
        } else if mode == .tablet {
            webView.customUserAgent = "Mozilla/5.0 (iPad; CPU OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1"
        } else {
            webView.customUserAgent = nil
        }
        
        context.coordinator.webView = webView
        
        DispatchQueue.main.async {
            self.webView = webView
        }
        
        return webView
    }
    
    func updateUIView(_ uiView: WKWebView, context: Context) {
        if uiView.url == nil {
            let targetURL = loadsRemoteURL ? fileURL : PreviewSchemeHandler.entryURL
            var request = URLRequest(
                url: targetURL,
                cachePolicy: loadsRemoteURL ? .reloadIgnoringLocalCacheData : .useProtocolCachePolicy,
                timeoutInterval: 30
            )
            if loadsRemoteURL {
                // A live preview must reflect the current deployment, not a
                // previously cached HTML document for the same domain.
                request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
                request.setValue("no-cache", forHTTPHeaderField: "Pragma")
            }
            uiView.load(request)
        }

        guard inspectorEnabled else { return }

        // Only touch the page after a navigation has actually finished.
        // updateUIView fires on every SwiftUI state change — including the
        // first pass, right after makeUIView, when no frame/script world
        // exists yet — and evaluateJavaScript against an uncommitted page
        // fails with `runJavaScriptInFrameInScriptWorld: Request to run
        // JavaScript failed`. `isLoading` is false before the very first load
        // begins (with url nil) and can briefly read false mid-navigation, so
        // gate on the coordinator's didFinish flag instead.
        guard context.coordinator.hasFinishedNavigation else { return }

        // Sync inspect mode variable
        let inspectJS = "window.siteAgentInspectMode = \(inspectModeActive ? "true" : "false");"
        uiView.evaluateJavaScript(inspectJS, completionHandler: nil)

        if !inspectModeActive {
            let cleanupJS = """
            const hl = document.getElementById('site-agent-highlight');
            if (hl) hl.style.display = 'none';
            """
            uiView.evaluateJavaScript(cleanupJS, completionHandler: nil)
        }
    }
    
    class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
        var parent: WebViewContainer
        weak var webView: WKWebView?
        /// True only after `didFinish` for the current navigation. Used to gate
        /// evaluateJavaScript so it never runs against an uncommitted frame.
        var hasFinishedNavigation = false

        /// Caps so an untrusted page can't flood/balloon the inspector state.
        private let maxStoredEvents = 500
        private let maxStringLength = 8_000

        init(_ parent: WebViewContainer) {
            self.parent = parent
        }

        /// Truncate any string coming from page JS before we store/display it.
        private func clamp(_ s: String) -> String {
            s.count > maxStringLength ? String(s.prefix(maxStringLength)) + "…[truncated]" : s
        }

        private func clampedStringArray(_ values: [String], maxCount: Int = 40) -> [String] {
            values.prefix(maxCount).map(clamp)
        }

        private func clampedDictionary(_ values: [String: String], maxCount: Int = 60) -> [String: String] {
            var output: [String: String] = [:]
            for (key, value) in values.prefix(maxCount) {
                output[clamp(key)] = clamp(value)
            }
            return output
        }

        private func doubleValue(_ val: Any?) -> Double {
            if let d = val as? Double { return d }
            if let f = val as? Float { return Double(f) }
            if let i = val as? Int { return Double(i) }
            if let s = val as? String, let d = Double(s) { return d }
            return 0
        }

        private func intValue(_ val: Any?) -> Int {
            if let i = val as? Int { return i }
            if let d = val as? Double { return Int(d) }
            if let f = val as? Float { return Int(f) }
            if let s = val as? String, let i = Int(s) { return i }
            return 0
        }

        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            hasFinishedNavigation = false
            parent.previewReady = false
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            hasFinishedNavigation = true
            parent.previewReady = true
            guard parent.inspectorEnabled else { return }
            webView.evaluateJavaScript("if (window.siteAgentReportInspectorSnapshot) { window.siteAgentReportInspectorSnapshot(); }", completionHandler: nil)
        }

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard message.name == "siteAgentInspector" else { return }
            guard let body = message.body as? [String: Any],
                  let type = body["type"] as? String,
                  let data = body["data"] as? [String: Any] else { return }

            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                switch type {
                case "consoleLog":
                    let level = data["level"] as? String ?? "log"
                    let messageStr = self.clamp(data["message"] as? String ?? "")
                    let ts = self.doubleValue(data["timestamp"])
                    let date = ts > 0 ? Date(timeIntervalSince1970: ts / 1000) : Date()
                    let log = ConsoleLog(level: level, message: messageStr, timestamp: date)
                    self.parent.consoleLogs.append(log)
                    if self.parent.consoleLogs.count > self.maxStoredEvents {
                        self.parent.consoleLogs.removeFirst(self.parent.consoleLogs.count - self.maxStoredEvents)
                    }

                case "networkStart":
                    let url = self.clamp(data["url"] as? String ?? "")
                    let method = data["method"] as? String ?? "GET"
                    let ts = self.doubleValue(data["timestamp"])
                    let date = ts > 0 ? Date(timeIntervalSince1970: ts / 1000) : Date()
                    let req = NetworkRequest(url: url, method: method, status: 0, statusText: "Pending...", type: "Pending", size: 0, time: 0, timestamp: date, headers: [:], responsePreview: "")
                    self.parent.networkRequests.append(req)
                    if self.parent.networkRequests.count > self.maxStoredEvents {
                        self.parent.networkRequests.removeFirst(self.parent.networkRequests.count - self.maxStoredEvents)
                    }

                case "networkComplete", "networkStatic":
                    let url = self.clamp(data["url"] as? String ?? "")
                    let status = self.intValue(data["status"])
                    let statusText = self.clamp(data["statusText"] as? String ?? "OK")
                    let typeStr = self.clamp(data["type"] as? String ?? "Unknown")
                    let size = self.intValue(data["size"])
                    let time = self.intValue(data["time"])
                    let headers = self.clampedDictionary(data["headers"] as? [String: String] ?? [:])
                    let responsePreview = self.clamp(data["responsePreview"] as? String ?? "")

                    if let index = self.parent.networkRequests.firstIndex(where: { $0.url == url && $0.statusText == "Pending..." }) {
                        self.parent.networkRequests[index].status = status
                        self.parent.networkRequests[index].statusText = statusText
                        self.parent.networkRequests[index].type = typeStr
                        self.parent.networkRequests[index].size = size
                        self.parent.networkRequests[index].time = time
                        self.parent.networkRequests[index].headers = headers
                        self.parent.networkRequests[index].responsePreview = responsePreview
                    } else {
                        if !self.parent.networkRequests.contains(where: { $0.url == url }) {
                            let req = NetworkRequest(url: url, method: "GET", status: status, statusText: statusText, type: typeStr, size: size, time: time, timestamp: Date(), headers: headers, responsePreview: responsePreview)
                            self.parent.networkRequests.append(req)
                            if self.parent.networkRequests.count > self.maxStoredEvents {
                                self.parent.networkRequests.removeFirst(self.parent.networkRequests.count - self.maxStoredEvents)
                            }
                        }
                    }
                    
                case "performanceMetrics":
                    let loadTime = self.doubleValue(data["loadTime"])
                    let domReady = self.doubleValue(data["domReady"])
                    let redirectCount = self.intValue(data["redirectCount"])
                    let jsHeapSize = self.doubleValue(data["jsHeapSize"])
                    let jsHeapLimit = self.doubleValue(data["jsHeapLimit"])
                    
                    self.parent.performanceMetrics = PerformanceMetrics(
                        loadTime: loadTime,
                        domReady: domReady,
                        redirectCount: redirectCount,
                        jsHeapSize: jsHeapSize,
                        jsHeapLimit: jsHeapLimit
                    )
                    
                case "elementInfo":
                    let tag = self.clamp(data["tag"] as? String ?? "")
                    let idAttr = self.clamp(data["id"] as? String ?? "")
                    let classes = self.clampedStringArray(data["classes"] as? [String] ?? [])
                    let dimensions = self.clamp(data["dimensions"] as? String ?? "")
                    let styles = self.clampedDictionary(data["styles"] as? [String: String] ?? [:])
                    let selector = self.clamp(data["selector"] as? String ?? "")
                    let xpath = self.clamp(data["xpath"] as? String ?? "")
                    
                    self.parent.selectedElement = ElementInfo(
                        tag: tag,
                        idAttribute: idAttr,
                        classes: classes,
                        dimensions: dimensions,
                        styles: styles,
                        selector: selector,
                        xpath: xpath
                    )
                default:
                    break
                }
            }
        }
    }
}

extension WebViewContainer {
    static var inspectorJavaScript: String {
        #"""
        (function() {
            if (window.siteAgentInspectorInjected) return;
            window.siteAgentInspectorInjected = true;
            
            window.siteAgentInspectMode = false;
            window.siteAgentLastSelectedElement = null;
            
            function installInspectorStyles() {
                if (document.getElementById('site-agent-inspector-styles')) return;
                const style = document.createElement('style');
                style.id = 'site-agent-inspector-styles';
                style.innerHTML = `
                    .site-agent-highlight-overlay {
                        position: absolute;
                        pointer-events: none;
                        border: 2px solid rgba(250, 204, 21, 0.9) !important;
                        background-color: rgba(59, 130, 246, 0.15) !important;
                        z-index: 2147483647 !important;
                        box-sizing: border-box !important;
                        transition: all 0.05s ease-out;
                    }
                    .site-agent-highlight-permanent {
                        position: absolute;
                        pointer-events: none;
                        border: 2px dashed rgba(239, 68, 68, 0.8) !important;
                        background-color: rgba(239, 68, 68, 0.08) !important;
                        z-index: 2147483646 !important;
                        box-sizing: border-box !important;
                    }
                `;
                if (document.head) {
                    document.head.appendChild(style);
                } else if (document.body) {
                    document.body.appendChild(style);
                } else {
                    document.documentElement.appendChild(style);
                }
            }

            function getCssSelector(el) {
                if (!el || el.nodeType !== Node.ELEMENT_NODE) return '';
                if (el.id) return '#' + el.id;
                let path = [];
                while (el && el.nodeType === Node.ELEMENT_NODE) {
                    let selector = el.nodeName.toLowerCase();
                    if (el.id) {
                        selector += '#' + el.id;
                        path.unshift(selector);
                        break;
                    } else {
                        let sibling = el;
                        let sibIndex = 1;
                        let hasSiblings = false;
                        while (sibling = sibling.previousElementSibling) {
                            if (sibling.nodeName === el.nodeName) sibIndex++;
                            hasSiblings = true;
                        }
                        sibling = el;
                        while (sibling = sibling.nextElementSibling) {
                            if (sibling.nodeName === el.nodeName) hasSiblings = true;
                        }
                        if (hasSiblings) {
                            selector += ':nth-of-type(' + sibIndex + ')';
                        }
                    }
                    path.unshift(selector);
                    el = el.parentNode;
                }
                return path.join(' > ');
            }

            function getXPath(el) {
                if (!el || el.nodeType !== Node.ELEMENT_NODE) return '';
                let path = [];
                while (el && el.nodeType === Node.ELEMENT_NODE) {
                    let index = 0;
                    let sibling = el.previousSibling;
                    while (sibling) {
                        if (sibling.nodeType === Node.ELEMENT_NODE && sibling.nodeName === el.nodeName) {
                            index++;
                        }
                        sibling = sibling.previousSibling;
                    }
                    let tagName = el.nodeName.toLowerCase();
                    let pathIndex = (index > 0 || (el.nextSibling || el.previousSibling)) ? '[' + (index + 1) + ']' : '';
                    path.unshift(tagName + pathIndex);
                    el = el.parentNode;
                }
                return '/' + path.join('/');
            }

            document.addEventListener('click', function(e) {
                if (window.siteAgentInspectMode) {
                    e.preventDefault();
                    e.stopPropagation();
                    
                    window.siteAgentLastSelectedElement = e.target;
                    
                    let highlight = document.getElementById('site-agent-highlight');
                    if (!highlight) {
                        highlight = document.createElement('div');
                        highlight.id = 'site-agent-highlight';
                        highlight.className = 'site-agent-highlight-overlay';
                        document.body.appendChild(highlight);
                    }
                    
                    const rect = e.target.getBoundingClientRect();
                    highlight.style.left = (rect.left + window.scrollX) + 'px';
                    highlight.style.top = (rect.top + window.scrollY) + 'px';
                    highlight.style.width = rect.width + 'px';
                    highlight.style.height = rect.height + 'px';
                    highlight.style.display = 'block';
                    
                    const info = {
                        tag: e.target.tagName,
                        id: e.target.id || '',
                        classes: Array.from(e.target.classList),
                        dimensions: e.target.offsetWidth + '×' + e.target.offsetHeight,
                        styles: {
                            color: getComputedStyle(e.target).color || '',
                            background: getComputedStyle(e.target).backgroundColor || '',
                            fontSize: getComputedStyle(e.target).fontSize || '',
                            padding: getComputedStyle(e.target).padding || '',
                            margin: getComputedStyle(e.target).margin || ''
                        },
                        selector: getCssSelector(e.target),
                        xpath: getXPath(e.target)
                    };
                    
                    window.webkit.messageHandlers.siteAgentInspector.postMessage({
                        type: 'elementInfo',
                        data: info
                    });
                }
            }, true);

            window.addPermanentHighlightForCurrent = function() {
                if (window.siteAgentLastSelectedElement) {
                    const el = window.siteAgentLastSelectedElement;
                    const permanent = document.createElement('div');
                    permanent.className = 'site-agent-highlight-permanent';
                    const rect = el.getBoundingClientRect();
                    permanent.style.left = (rect.left + window.scrollX) + 'px';
                    permanent.style.top = (rect.top + window.scrollY) + 'px';
                    permanent.style.width = rect.width + 'px';
                    permanent.style.height = rect.height + 'px';
                    document.body.appendChild(permanent);
                    return true;
                }
                return false;
            };

            var __saLastMsg = null, __saLastLevel = null, __saDup = 0, __saLastFlush = 0;

            function __saPost(level, message) {
                // Never let logging throw: a throw here is an uncaught error that
                // re-fires the window 'error' listener below -> logToSwift -> throw
                // -> infinite "Script error." loop (e.g. a cross-origin script
                // failing repeatedly). The try/catch is the loop breaker.
                try {
                    window.webkit.messageHandlers.siteAgentInspector.postMessage({
                        type: 'consoleLog',
                        data: { level: level, message: message, timestamp: Date.now() }
                    });
                } catch (e) {}
            }

            function logToSwift(level, args) {
                try {
                    const message = args.map(arg => {
                        if (arg === null) return 'null';
                        if (arg === undefined) return 'undefined';
                        if (typeof arg === 'object') {
                            try { return JSON.stringify(arg); } catch(e) { return String(arg); }
                        }
                        return String(arg);
                    }).join(' ');

                    // Collapse identical consecutive messages (a script throwing in
                    // a loop floods the console) to at most one line per second,
                    // tagged with the repeat count.
                    const now = Date.now();
                    if (message === __saLastMsg && level === __saLastLevel) {
                        __saDup++;
                        if (now - __saLastFlush < 1000) return;
                        __saPost(level, message + ' (×' + (__saDup + 1) + ')');
                        __saLastFlush = now; __saDup = 0;
                        return;
                    }
                    __saLastMsg = message; __saLastLevel = level;
                    __saDup = 0; __saLastFlush = now;
                    __saPost(level, message);
                } catch (e) {}
            }

            const orgLog = console.log;
            console.log = function(...args) {
                orgLog.apply(console, args);
                logToSwift('log', args);
            };
            const orgWarn = console.warn;
            console.warn = function(...args) {
                orgWarn.apply(console, args);
                logToSwift('warn', args);
            };
            const orgError = console.error;
            console.error = function(...args) {
                orgError.apply(console, args);
                logToSwift('error', args);
            };
            const orgInfo = console.info;
            console.info = function(...args) {
                orgInfo.apply(console, args);
                logToSwift('log', args);
            };
            const orgDebug = console.debug;
            console.debug = function(...args) {
                orgDebug.apply(console, args);
                logToSwift('log', args);
            };

            window.addEventListener('error', function(e) {
                logToSwift('error', [e.message, e.filename, e.lineno, e.colno].filter(Boolean));
            });
            window.addEventListener('unhandledrejection', function(e) {
                logToSwift('error', ['Unhandled Promise Rejection:', e.reason]);
            });

            const orgFetch = window.fetch;
            window.fetch = function(input, init) {
                const url = typeof input === 'string' ? input : (input instanceof URL ? input.href : (input ? input.url : ''));
                const method = (init && init.method) || 'GET';
                const startTime = performance.now();
                
                window.webkit.messageHandlers.siteAgentInspector.postMessage({
                    type: 'networkStart',
                    data: { url: url, method: method, timestamp: Date.now() }
                });
                
                return orgFetch.apply(this, arguments).then(response => {
                    const duration = performance.now() - startTime;
                    const clone = response.clone();
                    clone.text().then(text => {
                        window.webkit.messageHandlers.siteAgentInspector.postMessage({
                            type: 'networkComplete',
                            data: {
                                url: url,
                                status: response.status,
                                statusText: response.statusText,
                                type: response.headers.get('content-type') || 'Unknown',
                                size: text.length,
                                time: Math.round(duration),
                                headers: Object.fromEntries(Array.from(response.headers.entries())),
                                responsePreview: text.substring(0, 1000)
                            }
                        });
                    }).catch(() => {
                        window.webkit.messageHandlers.siteAgentInspector.postMessage({
                            type: 'networkComplete',
                            data: {
                                url: url,
                                status: response.status,
                                statusText: response.statusText,
                                type: response.headers.get('content-type') || 'Unknown',
                                size: 0,
                                time: Math.round(duration),
                                headers: Object.fromEntries(Array.from(response.headers.entries())),
                                responsePreview: '[Binary Data]'
                            }
                        });
                    });
                    return response;
                }).catch(err => {
                    const duration = performance.now() - startTime;
                    window.webkit.messageHandlers.siteAgentInspector.postMessage({
                        type: 'networkComplete',
                        data: {
                            url: url,
                            status: 0,
                            statusText: 'Failed',
                            type: 'Unknown',
                            size: 0,
                            time: Math.round(duration),
                            headers: {},
                            responsePreview: err.message || 'Error'
                        }
                    });
                    throw err;
                });
            };

            const orgXHROpen = XMLHttpRequest.prototype.open;
            const orgXHRSend = XMLHttpRequest.prototype.send;
            
            XMLHttpRequest.prototype.open = function(method, url) {
                this._method = method;
                this._url = url;
                this._startTime = performance.now();
                return orgXHROpen.apply(this, arguments);
            };
            
            XMLHttpRequest.prototype.send = function() {
                const self = this;
                window.webkit.messageHandlers.siteAgentInspector.postMessage({
                    type: 'networkStart',
                    data: { url: self._url, method: self._method, timestamp: Date.now() }
                });
                
                this.addEventListener('load', function() {
                    const duration = performance.now() - self._startTime;
                    let size = 0;
                    try { size = self.responseText.length; } catch(e) {}
                    let preview = '';
                    try { preview = self.responseText.substring(0, 1000); } catch(e) {}
                    
                    const headerStr = self.getAllResponseHeaders();
                    const headers = {};
                    headerStr.split('\r\n').forEach(line => {
                        const parts = line.split(': ');
                        if (parts.length >= 2) {
                            headers[parts[0]] = parts.slice(1).join(': ');
                        }
                    });
                    
                    window.webkit.messageHandlers.siteAgentInspector.postMessage({
                        type: 'networkComplete',
                        data: {
                            url: self._url,
                            status: self.status,
                            statusText: self.statusText,
                            type: self.getResponseHeader('content-type') || 'XHR',
                            size: size,
                            time: Math.round(duration),
                            headers: headers,
                            responsePreview: preview
                        }
                    });
                });
                
                this.addEventListener('error', function() {
                    const duration = performance.now() - self._startTime;
                    window.webkit.messageHandlers.siteAgentInspector.postMessage({
                        type: 'networkComplete',
                        data: {
                            url: self._url,
                            status: 0,
                            statusText: 'Error',
                            type: 'XHR',
                            size: 0,
                            time: Math.round(duration),
                            headers: {},
                            responsePreview: ''
                        }
                    });
                });
                
                return orgXHRSend.apply(this, arguments);
            };

            function reportStaticResources() {
                // Report the main document
                window.webkit.messageHandlers.siteAgentInspector.postMessage({
                    type: 'networkStatic',
                    data: {
                        url: window.location.href,
                        status: 200,
                        statusText: 'OK',
                        type: 'document',
                        size: document.documentElement.outerHTML.length,
                        time: 0,
                        headers: {},
                        responsePreview: document.documentElement.outerHTML.substring(0, 1000)
                    }
                });

                const resources = performance.getEntriesByType('resource');
                resources.forEach(res => {
                    window.webkit.messageHandlers.siteAgentInspector.postMessage({
                        type: 'networkStatic',
                        data: {
                            url: res.name,
                            status: 200,
                            statusText: 'OK',
                            type: res.initiatorType || 'Static Asset',
                            size: res.transferSize || 0,
                            time: Math.round(res.duration),
                            headers: {},
                            responsePreview: 'Static asset loaded from cache/network.'
                        }
                    });
                });
            }
            
            function reportPerformance() {
                const navigation = performance.getEntriesByType('navigation')[0];
                const timing = performance.timing;
                const loadTime = navigation
                    ? (navigation.loadEventEnd || navigation.duration || performance.now())
                    : (timing ? (timing.loadEventEnd - timing.navigationStart) : 0);
                const domReady = navigation
                    ? (navigation.domContentLoadedEventEnd || navigation.domComplete || performance.now())
                    : (timing ? (timing.domContentLoadedEventEnd - timing.navigationStart) : 0);
                const redirectCount = navigation
                    ? navigation.redirectCount
                    : ((window.performance && window.performance.navigation)
                        ? performance.navigation.redirectCount
                        : 0);
                
                let jsHeapSize = 0;
                let jsHeapLimit = 0;
                if (window.performance && window.performance.memory) {
                    jsHeapSize = window.performance.memory.usedJSHeapSize;
                    jsHeapLimit = window.performance.memory.jsHeapLimit;
                }
                
                window.webkit.messageHandlers.siteAgentInspector.postMessage({
                    type: 'performanceMetrics',
                    data: {
                        loadTime: loadTime > 0 ? loadTime : 0,
                        domReady: domReady > 0 ? domReady : 0,
                        redirectCount: redirectCount,
                        jsHeapSize: jsHeapSize,
                        jsHeapLimit: jsHeapLimit
                    }
                });
            }

            window.siteAgentReportInspectorSnapshot = function() {
                installInspectorStyles();
                reportStaticResources();
                reportPerformance();
            };

            if (document.readyState === 'complete') {
                setTimeout(window.siteAgentReportInspectorSnapshot, 100);
            } else {
                window.addEventListener('load', function() {
                    setTimeout(window.siteAgentReportInspectorSnapshot, 100);
                });
            }
        })();
        """#
    }
}

// MARK: - Local preview scheme handler

/// Serves the downloaded preview directory over a custom URL scheme so the page
/// loads from a real web origin (`siteagentpreview://…`) rather than `file://`.
/// A real origin is what makes the site's absolute asset paths (`/css/app.css`),
/// ES module scripts (`<script type="module">`), and same-origin `fetch()` work —
/// all of which WKWebView blocks or mis-resolves under `file://`. This is the same
/// approach Capacitor/Ionic use to host local SPAs.
///
/// The handler is sandboxed to `rootDirectory`; any request that resolves outside
/// it is rejected, so a page can't read arbitrary files off the device.
final class PreviewSchemeHandler: NSObject, WKURLSchemeHandler {
    static let scheme = "siteagentpreview"
    static let entryURL = URL(string: "\(scheme)://site/")!
    private let rootDirectory: URL

    init(rootDirectory: URL) {
        self.rootDirectory = rootDirectory.standardizedFileURL
    }

    func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
        guard let url = task.request.url else {
            task.didFailWithError(URLError(.badURL)); return
        }

        var relativePath = (url.path.removingPercentEncoding ?? url.path)
        if relativePath.hasPrefix("/") { relativePath.removeFirst() }
        if relativePath.isEmpty { relativePath = "index.html" }

        let fm = FileManager.default
        var fileURL = rootDirectory.appendingPathComponent(relativePath).standardizedFileURL

        // Directory request → serve its index.html.
        var isDir: ObjCBool = false
        if fm.fileExists(atPath: fileURL.path, isDirectory: &isDir), isDir.boolValue {
            fileURL = fileURL.appendingPathComponent("index.html").standardizedFileURL
        }

        // Sandbox: the resolved path must stay inside rootDirectory.
        guard fileURL.path == rootDirectory.path
                || fileURL.path.hasPrefix(rootDirectory.path + "/") else {
            task.didFailWithError(URLError(.noPermissionsToReadFile)); return
        }

        if let data = try? Data(contentsOf: fileURL) {
            respond(task, url: url, status: 200, data: data,
                    mime: Self.mimeType(for: fileURL))
            return
        }

        // Missing file. For an extension-less path (a client-side route) fall back
        // to index.html so SPA deep-links resolve; for a missing asset, 404 (never
        // serve HTML in place of a stylesheet/script).
        if fileURL.pathExtension.isEmpty,
           let indexData = try? Data(contentsOf: rootDirectory.appendingPathComponent("index.html")) {
            respond(task, url: url, status: 200, data: indexData, mime: "text/html; charset=utf-8")
        } else {
            respond(task, url: url, status: 404, data: Data(), mime: "text/plain; charset=utf-8")
        }
    }

    func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) {}

    private func respond(_ task: WKURLSchemeTask, url: URL, status: Int, data: Data, mime: String) {
        let headers = [
            "Content-Type": mime,
            "Content-Length": String(data.count),
            "Access-Control-Allow-Origin": "*",
            "Cache-Control": "no-store",
        ]
        let response = HTTPURLResponse(url: url, statusCode: status,
                                       httpVersion: "HTTP/1.1", headerFields: headers)
            ?? HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)!
        task.didReceive(response)
        task.didReceive(data)
        task.didFinish()
    }

    /// MIME type for the web-critical extensions, with a UTType fallback. An
    /// explicit table is used because correct `Content-Type` for `.js`/`.css`/
    /// `.mjs` is what lets modules and stylesheets load at all.
    static func mimeType(for url: URL) -> String {
        switch url.pathExtension.lowercased() {
        case "html", "htm": return "text/html; charset=utf-8"
        case "css": return "text/css; charset=utf-8"
        case "js", "mjs": return "text/javascript; charset=utf-8"
        case "json", "map", "webmanifest": return "application/json; charset=utf-8"
        case "svg": return "image/svg+xml"
        case "png": return "image/png"
        case "jpg", "jpeg": return "image/jpeg"
        case "gif": return "image/gif"
        case "webp": return "image/webp"
        case "avif": return "image/avif"
        case "ico": return "image/x-icon"
        case "woff": return "font/woff"
        case "woff2": return "font/woff2"
        case "ttf": return "font/ttf"
        case "otf": return "font/otf"
        case "xml": return "application/xml; charset=utf-8"
        case "txt", "md": return "text/plain; charset=utf-8"
        default:
            let ext = url.pathExtension.lowercased()
            return UTType(filenameExtension: ext)?.preferredMIMEType ?? "application/octet-stream"
        }
    }
}
