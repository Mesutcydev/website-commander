import SwiftUI
import AppKit

/// The Mac shell: one compact application bar over a full-width workspace.
///
/// There is no sidebar and no reserved sidebar width — the bar carries the
/// brand, the project, the five destinations, agent status, the model, the view
/// controls, the primary action, and overflow, and the workspace beneath it owns
/// the entire window width. The bar is the shell's top safe-area inset rather
/// than an absolutely positioned layer, so the rows really are `[68, flexible]`
/// and the bar can still draw its popovers over the workspace.
struct RootView: View {

    @EnvironmentObject var settings: SettingsStore
    @EnvironmentObject var engine: AgentEngine
    @EnvironmentObject var updater: UpdateChecker

    /// Persisted destination. Settable from `defaults` so the app can be
    /// launched straight into a destination for inspection.
    @AppStorage("shell.destination") private var persistedDestination = Destination.commandCenter.rawValue
    /// The Agent workspace's split state, driven from the bar's view controls
    /// and read back by the workspace through the same key.
    @AppStorage("workspace.previewVisible") private var showsPreview = true

    @State private var destination: Destination? = .commandCenter
    @State private var shellSize: CGSize = .zero
    @State private var openPopover: TopBarPopoverKind?
    @State private var showDebug = false
    @State private var showPalette = false
    @State private var showConversations = false
    @State private var showUpdateAlert = false
    @State private var showUpdateError = false
    @State private var showUpToDate = false

    private var current: Destination { destination ?? .commandCenter }

    private var metrics: TopBarMetrics {
        // Before the first measurement, assume a roomy window rather than the
        // narrowest tier so the bar does not open in its most reduced form.
        TopBarMetrics(width: shellSize.width > 0 ? shellSize.width : 1440)
    }

    var body: some View {
        Group {
            if !settings.hasCompletedOnboarding {
                OnboardingView()
            } else {
                appShell
            }
        }
        .environment(\.destination, $destination)
        .onAppear {
            destination = Destination(rawValue: persistedDestination) ?? .commandCenter
        }
        .onChange(of: destination) { _, value in
            if let value { persistedDestination = value.rawValue }
        }
        .onChange(of: engine.state) { oldState, newState in
            guard settings.notificationSoundsEnabled, oldState.isActive else { return }
            switch newState {
            case .done, .awaitingApproval:
                AudioNotificationPlayer.play(settings.completionSound)
            case .failed:
                AudioNotificationPlayer.play(settings.errorSound)
            default:
                break
            }
        }
        .sheet(isPresented: $showDebug) {
            DebugBriefSheet(onSendToAgent: { prompt in
                showDebug = false
                engine.prefilledPrompt = prompt
                destination = .agent
            })
        }
        .onReceive(NotificationCenter.default.publisher(for: .requestDebug)) { _ in
            showDebug = true
        }
        .sheet(isPresented: $showPalette) {
            CommandPaletteView(
                selection: $destination,
                onNewChat: { engine.newChat() },
                onDebug: {
                    // Let the palette dismiss first, then open the debug sheet.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) { showDebug = true }
                },
                onAddSite: {
                    destination = .sites
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) {
                        NotificationCenter.default.post(name: .requestAddSite, object: nil)
                    }
                }
            )
        }
        .onReceive(NotificationCenter.default.publisher(for: .requestPalette)) { _ in
            showPalette = true
        }
        .sheet(isPresented: $showConversations) {
            ConversationsSheet()
        }
        .onReceive(NotificationCenter.default.publisher(for: .requestConversations)) { _ in
            showConversations = true
        }
        .onChange(of: updater.available) { _, new in if new != nil { showUpdateAlert = true } }
        .onChange(of: updater.lastError) { _, new in
            if new != nil && updater.available == nil && !updater.installing { showUpdateError = true }
        }
        .onChange(of: updater.upToDate) { _, isCurrent in
            if isCurrent { showUpToDate = true }
        }
        .alert("Update available", isPresented: $showUpdateAlert, presenting: updater.available) { rel in
            if canInstall(rel) {
                Button(updater.installing ? "Installing…" : "Install & Relaunch") {
                    Task { await updater.installAndRelaunch(rel) }
                }
                .disabled(updater.installing)
            }
            if !rel.url.isEmpty {
                Button("Download \(rel.version)") {
                    if let u = URL(string: rel.url) { NSWorkspace.shared.open(u) }
                }
            }
            Button("Later", role: .cancel) { updater.available = nil }
        } message: { rel in
            let body = rel.notes.isEmpty ? "Version \(rel.version) is available." : rel.notes
            if canInstall(rel) {
                Text("\(body)\n\nInstall verifies the ZIP checksum, replaces this app, and relaunches. No Apple Developer account required.")
            } else {
                Text(body)
            }
        }
        .alert("You're up to date", isPresented: $showUpToDate) {
            Button("OK", role: .cancel) { updater.upToDate = false }
        } message: {
            Text("Website Commander \(UpdateChecker.currentVersion) is the latest release.")
        }
        .alert("Couldn't check for updates", isPresented: $showUpdateError) {
            Button("OK", role: .cancel) { updater.lastError = nil }
        } message: {
            Text(updater.lastError ?? "")
        }
        .task(id: settings.hasCompletedOnboarding) {
            guard settings.hasCompletedOnboarding else { return }
            // One quiet check after launch — never polls, never errors loudly.
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            await updater.check(feedURL: settings.updateFeedURL, userInitiated: false)
        }
    }

    private func canInstall(_ rel: UpdateChecker.Release) -> Bool {
        rel.sha256.count == 64 && rel.url.lowercased().hasSuffix(".zip")
    }

    // MARK: App shell

    private var appShell: some View {
        workspace
            .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
            .background(Theme.canvas)
            .safeAreaInset(edge: .top, spacing: 0) {
                TopBar(
                    metrics: metrics,
                    destination: destinationBinding,
                    showsPreview: $showsPreview,
                    showsViewControls: current == .agent,
                    openPopover: $openPopover
                )
            }
            // The bar's menus are drawn here, not inside the bar: this overlay
            // spans the whole window, so an open popover is above the workspace
            // for hit-testing as well as for drawing.
            .overlayPreferenceValue(TopBarTriggerAnchorKey.self) { anchors in
                TopBarPopoverLayer(
                    metrics: metrics,
                    shellSize: shellSize,
                    anchors: anchors,
                    open: $openPopover,
                    destination: destinationBinding,
                    showsPreview: $showsPreview,
                    showsViewControls: current == .agent
                )
            }
            .background {
                GeometryReader { proxy in
                    Color.clear
                        // Defer size→state writes so AppKit is not asked for
                        // another constraints pass while still inside one.
                        .onAppear {
                            DispatchQueue.main.async { shellSize = proxy.size }
                        }
                        .onChange(of: proxy.size) { _, size in
                            DispatchQueue.main.async { shellSize = size }
                        }
                }
            }
            // No `.toolbar(.hidden, for: .windowToolbar)`: with a hidden titlebar
            // there is no toolbar to hide, and asking SwiftUI to hide it takes
            // the window's traffic lights with it.
            .ignoresSafeArea(.container, edges: .top)
    }

    private var destinationBinding: Binding<Destination> {
        Binding(get: { current }, set: { destination = $0 })
    }

    /// The workspace fills everything under the bar. Each destination owns its
    /// own scroll region; the shell never scrolls.
    @ViewBuilder
    private var workspace: some View {
        switch current {
        case .commandCenter: CommandCenterView()
        case .sites:         SitesView()
        case .agent:         AgentWorkspaceView()
        case .preview:       PreviewView(embedded: true)
        case .history:       HistoryView()
        }
    }
}
