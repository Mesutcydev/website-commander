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

    @EnvironmentObject var settings: SettingsStore
    @EnvironmentObject var engine: AgentEngine
    @EnvironmentObject var browser: BrowserController
    @Environment(\.sidebarSelection) private var sidebarSelection

    @State private var device: Device = .desktop
    @State private var reloadToken = UUID()
    @State private var showInspector = false
    @State private var auditIssues: [SiteAuditIssue] = []
    @State private var showAudit = false
    @State private var isAuditing = false

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

    private var liveURL: URL? {
        guard let raw = settings.activeWorkspace?.configuredLiveURL, !raw.isEmpty else { return nil }
        return SiteWorkspace.normalizedLiveURL(raw)
    }

    var body: some View {
        Group {
            if liveURL == nil {
                EmptyStateView(systemImage: "eye.slash",
                               title: "No live URL configured",
                               message: "Set a homepage/live URL on the workspace to preview it here.")
            } else {
                VSplitView {
                    previewCanvas.frame(minHeight: 320)
                    if showInspector {
                        InspectorPanel(inspector: browser.inspector)
                            .frame(minHeight: 180, idealHeight: 260)
                    }
                }
            }
        }
        .navigationTitle("Preview")
        .toolbar {
            ToolbarItem(placement: .principal) {
                Picker("", selection: $device) {
                    ForEach(Device.allCases) { d in Label(d.rawValue, systemImage: d.icon).tag(d) }
                }
                .pickerStyle(.segmented)
                .frame(width: 300)
            }
            ToolbarItemGroup(placement: .primaryAction) {
                inspectorBadges
                Button { Task { await runAudit() } } label: {
                    if isAuditing { ProgressView().controlSize(.small) }
                    else { Label("Audit", systemImage: "checkmark.shield") }
                }
                .disabled(!browser.isAvailable)
                Button { analyzeWithAI() } label: {
                    Label("Analyze with AI", systemImage: "sparkles")
                }
                .disabled(!browser.isAvailable)
                Button { NotificationCenter.default.post(name: .requestDebug, object: nil) } label: {
                    Label("Debug", systemImage: "ladybug.fill")
                }
                Button { reloadToken = UUID() } label: {
                    Label("Reload", systemImage: "arrow.clockwise")
                }
                Button { withAnimation { showInspector.toggle() } } label: {
                    Label("Inspector", systemImage: showInspector ? "wand.and.rays.inverse" : "wand.and.rays")
                }
                .tint(showInspector ? Theme.accent : nil)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .refreshPreview)) { _ in
            reloadToken = UUID()
        }
        .sheet(isPresented: $showAudit) {
            AuditSheet(issues: auditIssues, url: liveURL?.absoluteString ?? "") {
                fixWithAI()
            }
        }
    }

    private var inspectorBadges: some View {
        HStack(spacing: 6) {
            if browser.inspector.errorCount > 0 {
                Badge(text: "\(browser.inspector.errorCount)", systemImage: "xmark.octagon.fill", tint: Theme.danger)
            }
            if browser.inspector.warnCount > 0 {
                Badge(text: "\(browser.inspector.warnCount)", systemImage: "exclamationmark.triangle.fill", tint: Theme.warning)
            }
        }
    }

    // MARK: Actions

    /// Run the client-side audit against the live rendered page.
    private func runAudit() async {
        isAuditing = true
        defer { isAuditing = false }
        let html = await browser.snapshotHTML()
        auditIssues = SiteAuditor.audit(html: html, inspector: browser.inspector)
        showAudit = true
    }

    /// Hand the live page to the agent for a free-form analysis.
    private func analyzeWithAI() {
        engine.prefilledPrompt = SiteAuditor.analyzePrompt(url: liveURL?.absoluteString ?? "the preview")
        engine.newChat()
        sidebarSelection.wrappedValue = .agent
    }

    /// Send the current audit issues to the agent to fix.
    private func fixWithAI() {
        showAudit = false
        engine.prefilledPrompt = SiteAuditor.fixPrompt(for: auditIssues, url: liveURL?.absoluteString ?? "the preview")
        engine.newChat()
        sidebarSelection.wrappedValue = .agent
    }

    private var previewCanvas: some View {
        ScrollView {
            WebView(url: liveURL, reloadToken: reloadToken, browser: browser)
                .frame(width: device.width ?? 1200)
                .frame(minHeight: 600)
                .background(Color.white)
                .clipShape(RoundedRectangle(cornerRadius: device == .desktop ? 4 : 22))
                .overlay(RoundedRectangle(cornerRadius: device == .desktop ? 4 : 22)
                    .strokeBorder(Theme.hairline, lineWidth: 1))
                .shadow(color: .black.opacity(0.12), radius: 18, y: 8)
                .padding(Theme.Space.xl)
                .frame(maxWidth: .infinity)
        }
        .background(Color.primary.opacity(0.03))
        .overlay(alignment: .top) {
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
        .background(.regularMaterial)
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
                        .background(Theme.accent.opacity(0.15), in: Capsule())
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
