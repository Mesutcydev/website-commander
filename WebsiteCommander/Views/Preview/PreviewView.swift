import SwiftUI
import WebKit

// MARK: - Inspector presentation colors (View-layer; keeps the model UI-free)

extension ConsoleLog.Level {
    var tint: Color {
        switch self {
        case .log: return .secondary
        case .info: return Theme.info
        case .warn: return Theme.warning
        case .error: return Theme.danger
        }
    }
}

extension NetworkRequest {
    var statusTint: Color {
        guard let status else { return .secondary }
        switch status {
        case 200..<300: return Theme.success
        case 300..<400: return Theme.info
        case 400..<500: return Theme.warning
        default: return Theme.danger
        }
    }
}

// MARK: - Instrumented web view

/// A WKWebView host that injects the inspector script, routes page messages
/// into the `BrowserController`'s inspector, and registers itself so the agent
/// can see and control it.
struct WebView: NSViewRepresentable {
    let url: URL?
    var reloadToken: UUID
    @ObservedObject var browser: BrowserController

    typealias NSViewType = WKWebView

    func makeCoordinator() -> Coordinator {
        Coordinator(inspector: browser.inspector)
    }

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        let controller = WKUserContentController()
        controller.add(context.coordinator.handler, name: "wcInspector")
        controller.addUserScript(WKUserScript(source: InspectorScript.source,
                                              injectionTime: .atDocumentStart,
                                              forMainFrameOnly: false))
        config.userContentController = controller
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.load(request(for: url))
        browser.register(webView)
        context.coordinator.lastToken = reloadToken
        context.coordinator.lastURL = url
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        browser.register(webView)
        // URL change or manual reload → reload and clear captured data.
        if context.coordinator.lastURL != url || context.coordinator.lastToken != reloadToken {
            webView.load(request(for: url))
            context.coordinator.lastURL = url
            context.coordinator.lastToken = reloadToken
            browser.inspector.reset()
        }
        // Inspect-mode toggle → notify the page.
        if context.coordinator.lastInspect != browser.inspector.inspectMode {
            context.coordinator.lastInspect = browser.inspector.inspectMode
            webView.evaluateJavaScript("window.__wcSetInspect && window.__wcSetInspect(\(browser.inspector.inspectMode));")
        }
    }

    private func request(for url: URL?) -> URLRequest {
        URLRequest(url: url ?? URL(string: "about:blank")!)
    }

    final class Coordinator {
        let handler: InspectorMessageHandler
        var lastInspect = false
        var lastToken: UUID?
        var lastURL: URL?

        init(inspector: WebInspectorModel) {
            self.handler = InspectorMessageHandler(model: inspector)
        }
    }
}

// MARK: - Preview view

/// Renders the live site in mobile / tablet / desktop viewports, with a web
/// inspector (console, network, performance, element picker), a site audit, and
/// Analyze / Fix-with-AI actions that hand the live page to the agent.
struct PreviewView: View {

    var embedded = false
    @EnvironmentObject var settings: SettingsStore
    @EnvironmentObject var engine: AgentEngine
    @EnvironmentObject var browser: BrowserController
    @Environment(\.destination) private var destination

    @AppStorage("preview.device") private var persistedDevice = Device.desktop.rawValue
    @State private var device: Device = .desktop
    @State private var reloadToken = UUID()
    @State private var showInspector = false
    @State private var auditIssues: [SiteAuditIssue] = []
    @State private var showAudit = false
    @State private var isAuditing = false
    @State private var isReloading = false
    @State private var showRefreshHighlight = false
    @State private var zoom: PreviewZoom = .fit

    /// The narrowest width a "Desktop" viewport is allowed to report to the
    /// page. Surfaces wider than this render 1:1 and fill; narrower ones render
    /// at this width and scale down so desktop breakpoints still apply.
    static let desktopViewportFloor: CGFloat = 900

    enum Device: String, CaseIterable, Identifiable {
        case mobile = "Mobile", tablet = "Tablet", desktop = "Desktop"
        var id: String { rawValue }
        var icon: String {
            switch self {
            case .mobile: return "iphone"
            case .tablet: return "ipad"
            case .desktop: return "macbook"
            }
        }
        var width: CGFloat? {
            switch self {
            case .mobile: return 390
            case .tablet: return 768
            case .desktop: return nil
            }
        }
    }

    private enum PreviewZoom: String, CaseIterable, Identifiable {
        case fit = "Fit"
        case oneHundred = "100%"
        case oneTwentyFive = "125%"

        var id: String { rawValue }
        var factor: CGFloat {
            switch self {
            case .fit: return 1
            case .oneHundred: return 1
            case .oneTwentyFive: return 1.25
            }
        }
    }

    private var liveURL: URL? {
        guard let raw = settings.activeWorkspace?.configuredLiveURL, !raw.isEmpty else { return nil }
        return SiteWorkspace.normalizedLiveURL(raw)
    }

    var body: some View {
        Group {
            if embedded {
                embeddedPreview
            } else {
                previewContent
                    .navigationTitle("Preview")
                    .toolbar {
                        ToolbarItem(placement: .principal) {
                            devicePicker
                        }
                        ToolbarItemGroup(placement: .primaryAction) {
                            inspectorBadges
                            previewActionButtons
                        }
                    }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .refreshPreview)) { _ in
            reload()
        }
        .onAppear {
            device = Device(rawValue: persistedDevice) ?? .desktop
        }
        .onChange(of: device) { _, value in
            persistedDevice = value.rawValue
        }
        .sheet(isPresented: $showAudit) {
            AuditSheet(issues: auditIssues, url: liveURL?.absoluteString ?? "") {
                fixWithAI()
            }
        }
    }

    /// The preview surface on the shared workspace grid: one control row, then a
    /// canvas that fills every remaining point of width. The only thing allowed
    /// to reduce it is the standard workspace gutter.
    private var embeddedPreview: some View {
        GeometryReader { proxy in
            let gutter = AgentWorkspaceMetrics.gutter(for: proxy.size.width)
            VStack(spacing: 0) {
                embeddedControlBar(gutter: gutter)
                previewContent
                    .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
                    .background(Theme.previewWorkspace)
                    .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.medium, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: Theme.Radius.medium, style: .continuous)
                            .strokeBorder(Theme.Chrome.barControlBorder, lineWidth: 1)
                    }
                    .padding(.horizontal, gutter)
                    .padding(.bottom, 20)
            }
            .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
            .background { GlassPaneBackground() }
        }
    }

    @ViewBuilder
    private var previewContent: some View {
        if liveURL == nil {
            EmptyStateView(systemImage: "eye.slash",
                           title: "No live URL configured",
                           message: "Set a homepage/live URL on the workspace to preview it here.")
        } else if showInspector {
            VSplitView {
                previewCanvas.frame(minHeight: 320)
                InspectorPanel(inspector: browser.inspector)
                    .frame(minHeight: 180, idealHeight: 260)
            }
        } else {
            previewCanvas
        }
    }

    /// One row, on the workspace gutter: the real address, the viewport presets,
    /// real console counts, and the preview's own actions.
    private func embeddedControlBar(gutter: CGFloat) -> some View {
        HStack(spacing: Theme.Space.s) {
            HStack(spacing: 6) {
                if liveURL == nil {
                    Image(systemName: "lock.fill")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Theme.Chrome.textMuted)
                } else {
                    AmbientConnectionSignal(tint: Theme.success,
                                             mode: .breathing,
                                             active: true,
                                             label: "Live preview connected")
                }
                Text(liveURL?.absoluteString ?? String(localized: "No live URL"))
                    .font(Theme.ui(12, .medium))
                    .foregroundStyle(Theme.Chrome.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .padding(.horizontal, 9)
            .frame(height: TopBarMetrics.controlHeight)
            .frame(minWidth: 0, alignment: .leading)
            .background {
                let shape = RoundedRectangle(cornerRadius: TopBarMetrics.controlRadius,
                                             style: .continuous)
                shape
                    .fill(Theme.Chrome.barControlFill)
                    .overlay { shape.strokeBorder(Theme.Chrome.barControlBorder, lineWidth: 1) }
            }
            .accessibilityLabel("Preview address: \(liveURL?.absoluteString ?? String(localized: "none"))")

            Button {
                guard let liveURL else { return }
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(liveURL.absoluteString, forType: .string)
            } label: {
                Label("Copy URL", systemImage: "doc.on.doc")
            }
            .labelStyle(.iconOnly)
            .disabled(liveURL == nil)
            .help("Copy preview URL")

            Button {
                if let liveURL { NSWorkspace.shared.open(liveURL) }
            } label: {
                Label("Open in browser", systemImage: "arrow.up.right.square")
            }
            .labelStyle(.iconOnly)
            .disabled(liveURL == nil)
            .help("Open in the default browser")

            Spacer(minLength: 0)
            devicePicker
            Spacer(minLength: 0)
            zoomControls
            inspectorBadges
            previewActionButtons
                .labelStyle(.iconOnly)
        }
        .padding(.horizontal, gutter)
        .frame(height: 46)
        .frame(maxWidth: .infinity)
    }

    private var zoomControls: some View {
        HStack(spacing: 2) {
            ForEach([PreviewZoom.fit, .oneHundred], id: \.self) { option in
                Button(option.rawValue) { zoom = option }
                    .font(Theme.ui(11.5, zoom == option ? .semibold : .medium))
                    .foregroundStyle(zoom == option ? Theme.accent : Theme.secondaryText)
                    .padding(.horizontal, 7)
                    .frame(height: Theme.Height.compact)
                    .background(zoom == option ? Theme.accentSoft : .clear,
                                in: RoundedRectangle(cornerRadius: Theme.Radius.badge, style: .continuous))
                    .buttonStyle(.plain)
            }
            Menu {
                ForEach(PreviewZoom.allCases) { option in
                    Button(option.rawValue) { zoom = option }
                }
            } label: {
                Image(systemName: "plus.magnifyingglass")
                    .frame(width: Theme.Height.compact, height: Theme.Height.compact)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .help("Zoom preview")
        }
        .padding(2)
        .background(Theme.secondarySurface,
                    in: RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous))
    }

    private var devicePicker: some View {
        Picker("", selection: $device) {
            ForEach(Device.allCases) { d in
                Label(LocalizedStringKey(d.rawValue), systemImage: d.icon).tag(d)
            }
        }
        .labelsHidden()
        .pickerStyle(.segmented)
        .frame(width: 190)
        .help("Viewport preset")
    }

    @ViewBuilder
    private var previewActionButtons: some View {
        Button { Task { await runAudit() } } label: {
            if isAuditing { ProgressView().controlSize(.small) }
            else { Label("Audit", systemImage: "checkmark.shield") }
        }
        .disabled(liveURL == nil || isAuditing)
        .help(liveURL == nil ? "Add a valid live URL to audit this site" : "Run a local preview audit")

        Button { analyzeWithAI() } label: {
            Label("Analyze with AI", systemImage: "sparkles")
        }
        .disabled(liveURL == nil)
        .help(liveURL == nil ? "Add a valid live URL to analyze this site" : "Ask the agent to analyze the live site")

        Menu {
            Button { NotificationCenter.default.post(name: .requestDebug, object: nil) } label: {
                Label("Debug", systemImage: "ladybug.fill")
            }
            Button { withAnimation { showInspector.toggle() } } label: {
                Label(showInspector ? "Hide Inspector" : "Show Inspector",
                      systemImage: showInspector ? "wand.and.rays.inverse" : "wand.and.rays")
            }
        } label: {
            Label("Tools", systemImage: "ellipsis.circle")
        }
        .help("Debug and inspect the preview")

        Button { reload() } label: {
            if isReloading {
                ProgressView().controlSize(.small)
            } else {
                Label("Reload", systemImage: "arrow.clockwise")
            }
        }
        .disabled(isReloading || liveURL == nil)
        .help(isReloading ? "Reloading preview" : "Reload preview")
    }

    private var inspectorBadges: some View {
        HStack(spacing: 6) {
            if browser.inspector.errorCount > 0 || browser.inspector.warnCount > 0 {
                Button {
                    showInspector = true
                } label: {
                    HStack(spacing: 6) {
                        if browser.inspector.errorCount > 0 {
                            Badge(text: "\(browser.inspector.errorCount)", systemImage: "xmark.octagon.fill", tint: Theme.danger)
                        }
                        if browser.inspector.warnCount > 0 {
                            Badge(text: "\(browser.inspector.warnCount)", systemImage: "exclamationmark.triangle.fill", tint: Theme.warning)
                        }
                    }
                }
                .buttonStyle(.plain)
                .help("Open console issues")
            }
        }
    }

    // MARK: Actions

    /// Run the client-side audit against the live rendered page.
    private func runAudit() async {
        isAuditing = true
        defer { isAuditing = false }
        guard liveURL != nil else { return }
        guard await browser.ensureAvailable() else {
            auditIssues = [SiteAuditIssue(
                title: "Preview browser unavailable",
                detail: "Open the Preview tab and try again so the live page can be inspected.",
                severity: .critical
            )]
            showAudit = true
            return
        }
        let html = await browser.snapshotHTML()
        auditIssues = SiteAuditor.audit(html: html, inspector: browser.inspector)
        showAudit = true
    }

    private func reload() {
        guard !isReloading, liveURL != nil else { return }
        isReloading = true
        showRefreshHighlight = true
        reloadToken = UUID()
        Task {
            try? await Task.sleep(for: .milliseconds(700))
            isReloading = false
            try? await Task.sleep(for: .milliseconds(300))
            showRefreshHighlight = false
        }
    }

    /// Hand the live page to the agent for a free-form analysis.
    private func analyzeWithAI() {
        guard liveURL != nil else { return }
        engine.prefilledPrompt = SiteAuditor.analyzePrompt(url: liveURL?.absoluteString ?? "the preview")
        engine.newChat()
        destination.wrappedValue = .agent
    }

    /// Send the current audit issues to the agent to fix.
    private func fixWithAI() {
        showAudit = false
        engine.prefilledPrompt = SiteAuditor.fixPrompt(for: auditIssues, url: liveURL?.absoluteString ?? "the preview")
        engine.newChat()
        destination.wrappedValue = .agent
    }

    @ViewBuilder
    private var previewCanvas: some View {
        ZStack(alignment: .top) {
            Theme.previewWorkspace
            RadialGradient(colors: [Color.white.opacity(0.75),
                                     Color.white.opacity(0.18),
                                     .clear],
                           center: .center,
                           startRadius: 0,
                           endRadius: 520)
            PreviewTechnicalGrid()

            Group {
                if device == .desktop {
            // Desktop means "use the room we have". The viewport only becomes a
            // fixed, scaled-down 900pt canvas when the surface is genuinely
            // narrower than a desktop breakpoint — otherwise a responsive site
            // would switch to its mobile layout in the split pane despite
            // "Desktop" being selected. Above 900pt the web view simply fills
            // the width at 1:1, which is what stops a fixed 900pt viewport
            // leaving a blank white strip on the trailing edge.
            GeometryReader { proxy in
                let available = max(proxy.size.width, 1)
                let viewportWidth = max(Self.desktopViewportFloor, available)
                let fitScale = min(1, available / viewportWidth)
                let scale = zoom == .fit ? fitScale : zoom.factor
                let viewportHeight = scale < 1
                    ? max(proxy.size.height / scale, 720)
                    : max(proxy.size.height, 1)

                WebView(url: liveURL, reloadToken: reloadToken, browser: browser)
                    .frame(width: viewportWidth, height: viewportHeight)
                    .scaleEffect(scale, anchor: .topLeading)
                    .frame(width: proxy.size.width,
                           height: proxy.size.height,
                           alignment: .topLeading)
                    .clipped()
                    .background(Color.white)
                    .overlay(alignment: .top) {
                        inspectModeBanner
                    }
                }
                } else {
            ScrollView([.horizontal, .vertical]) {
                WebView(url: liveURL, reloadToken: reloadToken, browser: browser)
                    .frame(width: device.width)
                    .frame(minHeight: 600)
                    .background(Color.white)
                    .clipShape(RoundedRectangle(cornerRadius: 22))
                    .overlay(RoundedRectangle(cornerRadius: 22)
                        .strokeBorder(Theme.borderSubtle, lineWidth: 1))
                    .shadow(color: Theme.Shadow.ambientRaised, radius: 18, y: 8)
                    .padding(Theme.Space.xl)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.clear)
            .overlay(alignment: .top) {
                inspectModeBanner
            }
                }
            }
            .animation(Motion.layout, value: device)

            PreviewRefreshSweep(active: isReloading)
                .frame(height: 2)

            RoundedRectangle(cornerRadius: Theme.Radius.medium, style: .continuous)
                .stroke(Theme.accent.opacity(showRefreshHighlight ? 0.42 : 0), lineWidth: 1)
                .animation(Motion.gentle, value: showRefreshHighlight)
        }
    }

    @ViewBuilder
    private var inspectModeBanner: some View {
        if browser.inspector.inspectMode {
            Text("Inspect mode — click any element on the page")
                .font(.caption.weight(.semibold))
                .padding(.horizontal, 12).padding(.vertical, 5)
                .background(Theme.warning, in: Capsule())
                .foregroundStyle(.black)
                .padding(.top, Theme.Space.s)
        }
    }
}

// MARK: - Preview motion

/// A deliberately faint grid that lives behind the device/web surface. It adds
/// depth to the preview canvas without ever painting over the rendered site.
private struct PreviewTechnicalGrid: View {
    @EnvironmentObject private var motion: AmbientMotionCoordinator
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { proxy in
            let step: CGFloat = 24
            let phase = motion.phase(period: 28)
            let shift = reduceMotion || !motion.isRunning ? 0 : CGFloat(phase) * 10
            Canvas { context, size in
                var path = Path()
                for x in stride(from: -step + shift, through: size.width + step, by: step) {
                    path.move(to: CGPoint(x: x, y: 0))
                    path.addLine(to: CGPoint(x: x, y: size.height))
                }
                for y in stride(from: -step + shift, through: size.height + step, by: step) {
                    path.move(to: CGPoint(x: 0, y: y))
                    path.addLine(to: CGPoint(x: size.width, y: y))
                }
                context.stroke(path,
                               with: .color(Theme.previewGrid.opacity(reduceMotion ? 0.70 : 1)),
                               lineWidth: 0.5)
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// One refresh sweep, tied to the real reload action. It never repeats while
/// idle and becomes a static accent under Reduce Motion.
private struct PreviewRefreshSweep: View {
    let active: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var progress: CGFloat = 0

    var body: some View {
        GeometryReader { proxy in
            Capsule()
                .fill(Theme.accent.opacity(active ? 0.55 : 0))
                .frame(width: max(32, proxy.size.width * 0.18), height: 2)
                .offset(x: reduceMotion ? 0 : progress * proxy.size.width)
        }
        .clipped()
        .allowsHitTesting(false)
        .onAppear {
            if active { run() }
        }
        .onChange(of: active) { _, isActive in
            if isActive { run() }
        }
    }

    private func run() {
        progress = reduceMotion ? 0 : -0.18
        guard !reduceMotion else { return }
        withAnimation(.linear(duration: 0.7)) { progress = 1.0 }
    }
}

// MARK: - Inspector panel

/// The docked inspector: Console / Network / Performance tabs plus an element
/// inspect toggle and the inspected-element detail.
struct InspectorPanel: View {
    @ObservedObject var inspector: WebInspectorModel

    enum Tab: String, CaseIterable, Identifiable {
        case console = "Console", network = "Network", performance = "Performance"
        var id: String { rawValue }
        var icon: String {
            switch self {
            case .console: return "terminal.fill"
            case .network: return "antenna.radiowaves.left.and.right"
            case .performance: return "gauge.with.needle.fill"
            }
        }
    }

    @State private var tab: Tab = .console

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: Theme.Space.m) {
                Picker("", selection: $tab) {
                    ForEach(Tab.allCases) { t in Label(t.rawValue, systemImage: t.icon).tag(t) }
                }
                .pickerStyle(.segmented)
                .frame(width: 360)

                Spacer()

                Toggle(isOn: $inspector.inspectMode) {
                    Label("Inspect", systemImage: "cursorarrow.rays")
                }
                .toggleStyle(.switch)

                Button { inspector.reset() } label: {
                    Label("Clear", systemImage: "trash")
                }
                .buttonStyle(.icon)
            }
            .padding(.horizontal, Theme.Space.m)
            .padding(.vertical, Theme.Space.s)

            Divider()

            Group {
                switch tab {
                case .console: ConsolePanel(inspector: inspector)
                case .network: NetworkPanel(inspector: inspector)
                case .performance: PerformancePanel(inspector: inspector)
                }
            }
        }
        .background(Theme.elevatedSurface)
    }
}

// MARK: - Console panel

private struct ConsolePanel: View {
    @ObservedObject var inspector: WebInspectorModel

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: Theme.Space.s) {
                Picker("", selection: $inspector.consoleFilter) {
                    ForEach(WebInspectorModel.ConsoleFilter.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .frame(width: 320)
                Spacer()
                if let element = inspector.inspectedElement {
                    Text("<\(element.tag)>")
                        .font(.system(.caption, design: .monospaced))
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .foregroundStyle(Theme.accent)
                        .background(Theme.accentSoft, in: Capsule())
                }
            }
            .padding(.horizontal, Theme.Space.m).padding(.vertical, 6)

            Divider()

            if inspector.filteredLogs.isEmpty {
                Text("No console output.").foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(inspector.filteredLogs) { log in
                            HStack(alignment: .top, spacing: 8) {
                                Image(systemName: log.level.icon)
                                    .font(.caption2)
                                    .foregroundStyle(log.level.tint)
                                    .frame(width: 16)
                                Text(log.text)
                                    .font(.system(.caption, design: .monospaced))
                                    .textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .padding(.horizontal, Theme.Space.m).padding(.vertical, 3)
                            Divider().opacity(0.4)
                        }
                    }
                }
            }
        }
    }
}

// MARK: - Network panel

private struct NetworkPanel: View {
    @ObservedObject var inspector: WebInspectorModel

    var body: some View {
        if inspector.networkRequests.isEmpty {
            Text("No network requests captured. Interact with the page to see traffic.")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(inspector.networkRequests) { request in
                        HStack(spacing: Theme.Space.m) {
                            Text(request.method)
                                .font(.system(.caption2, design: .monospaced).weight(.bold))
                                .frame(width: 44, alignment: .leading)
                                .foregroundStyle(.secondary)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(request.path).font(.caption).lineLimit(1)
                                Text(request.host).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                            }
                            Spacer()
                            if let size = request.sizeBytes {
                                Text(byteString(size)).font(.caption2).foregroundStyle(.secondary)
                            }
                            if let duration = request.durationMs {
                                Text("\(duration)ms").font(.caption2).foregroundStyle(.secondary)
                                    .frame(width: 56, alignment: .trailing)
                            }
                            Text(request.status.map(String.init) ?? "…")
                                .font(.system(.caption2, design: .monospaced).weight(.semibold))
                                .foregroundStyle(request.statusTint)
                                .frame(width: 34, alignment: .trailing)
                        }
                        .padding(.horizontal, Theme.Space.m).padding(.vertical, 4)
                        Divider().opacity(0.4)
                    }
                }
            }
        }
    }

    private func byteString(_ bytes: Int) -> String {
        bytes > 1024 ? String(format: "%.1f KB", Double(bytes) / 1024) : "\(bytes) B"
    }
}

// MARK: - Performance panel

private struct PerformancePanel: View {
    @ObservedObject var inspector: WebInspectorModel

    var body: some View {
        HStack(spacing: Theme.Space.m) {
            metric("Load Time", value: inspector.performance.loadTimeMs, unit: "ms",
                   icon: "clock.fill", tint: Theme.accent)
            metric("DOM Ready", value: inspector.performance.domReadyMs, unit: "ms",
                   icon: "doc.fill", tint: Theme.accentDeep)
            metric("Transferred", value: inspector.performance.transferKB, unit: "KB",
                   icon: "arrow.down.circle.fill", tint: Theme.success)
            Spacer()
        }
        .padding(Theme.Space.l)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func metric(_ title: String, value: Int?, unit: String, icon: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: icon).foregroundStyle(tint)
                Text(title).font(.caption).foregroundStyle(.secondary)
            }
            Text(value.map { "\($0) \(unit)" } ?? "—")
                .font(Theme.display(22, weight: .heavy))
        }
        .frame(minWidth: 150, alignment: .leading)
        .commandCard()
    }
}
