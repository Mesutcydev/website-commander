import SwiftUI

@main
struct WebsiteCommanderApp: App {

    @StateObject private var settings: SettingsStore
    @StateObject private var browser: BrowserController
    @StateObject private var cloudSync: CloudSyncService
    @StateObject private var engine: AgentEngine
    @StateObject private var bridge: LocalBridge
    @StateObject private var conversations: ConversationStore
    @StateObject private var updater: UpdateChecker
    @StateObject private var ambientMotion: AmbientMotionCoordinator

    init() {
        let settings = SettingsStore()
        let browser = BrowserController()
        let cloudSync = CloudSyncService()
        let conversations = ConversationStore()
        let updater = UpdateChecker()
        let engine = AgentEngine(settings: settings, browserController: browser)
        engine.conversationStore = conversations
        let bridge = LocalBridge()
        bridge.settings = settings
        bridge.engine = engine
        bridge.browser = browser
        _settings = StateObject(wrappedValue: settings)
        _browser = StateObject(wrappedValue: browser)
        _cloudSync = StateObject(wrappedValue: cloudSync)
        _conversations = StateObject(wrappedValue: conversations)
        _updater = StateObject(wrappedValue: updater)
        _engine = StateObject(wrappedValue: engine)
        _bridge = StateObject(wrappedValue: bridge)
        _ambientMotion = StateObject(wrappedValue: AmbientMotionCoordinator())
        // Push to iCloud after every local persist (no-op unless sync is on).
        settings.onPersist = { [weak cloudSync, weak settings] in
            guard let cloudSync, let settings else { return }
            cloudSync.push(settings)
        }
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(settings)
                .environmentObject(browser)
                .environmentObject(cloudSync)
                .environmentObject(engine)
                .environmentObject(bridge)
                .environmentObject(conversations)
                .environmentObject(updater)
                .environmentObject(ambientMotion)
                // Low enough that the bar's narrowest density tier is a real
                // state a user can reach, not dead code.
                .frame(minWidth: 760, minHeight: 620)
                .preferredColorScheme(settings.themeMode.colorScheme)
                .tint(Theme.accent)
                .task {
                    cloudSync.startObserving(settings: settings)
                    cloudSync.pull(into: settings)
                    engine.restoreLastConversationIfNeeded()
                    if settings.localBridgeEnabled {
                        bridge.start(preferredPort: settings.localBridgePort)
                    }
                }
                .onChange(of: settings.localBridgeEnabled) { _, on in
                    if on { bridge.start(preferredPort: settings.localBridgePort) }
                    else { bridge.stop() }
                }
        }
        // The application bar *is* the titlebar band: hiding the native one is
        // what lets a 56pt bar be the app's only chrome instead of sitting under
        // an empty 28pt strip. The bar reserves leading room for the traffic
        // lights and makes its own background drag the window.
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Chat") { engine.newChat() }
                    .keyboardShortcut("n", modifiers: .command)
            }
            CommandGroup(after: .toolbar) {
                Button("Command Palette…") {
                    NotificationCenter.default.post(name: .requestPalette, object: nil)
                }
                .keyboardShortcut("k", modifiers: .command)
            }
            CommandMenu("Agent") {
                Button("Send Message") {
                    NotificationCenter.default.post(name: .requestAgentSendFromMenu, object: nil)
                }
                .keyboardShortcut(.return, modifiers: .command)
                Button("Stop") {
                    NotificationCenter.default.post(name: .requestAgentStopFromMenu, object: nil)
                }
                .keyboardShortcut(".", modifiers: .command)
                .disabled(!engine.isRunActive)
                Button("Approve All Changes") {
                    NotificationCenter.default.post(name: .requestApproveAllFromMenu, object: nil)
                }
                .keyboardShortcut("a", modifiers: [.command, .shift])
                .disabled(engine.pendingChanges.isEmpty)
            }
            CommandGroup(after: .appInfo) {
                Button(updater.checking ? "Checking for Updates…" : "Check for Updates…") {
                    Task { await updater.check(feedURL: settings.updateFeedURL, userInitiated: true) }
                }
                .disabled(updater.checking || updater.installing)
            }
            CommandMenu("Site") {
                Button("Open in VSCode") { NotificationCenter.default.post(name: .requestOpenInVSCode, object: nil) }
                    .keyboardShortcut("v", modifiers: [.command, .shift])
                Button("Refresh Preview") { NotificationCenter.default.post(name: .requestRefreshPreview, object: nil) }
                    .keyboardShortcut("r", modifiers: [.command, .shift])
                Button("Debug Current Site") { NotificationCenter.default.post(name: .requestDebug, object: nil) }
                    .keyboardShortcut("d", modifiers: [.command, .shift])
            }
        }

        Settings {
            SettingsView()
                .environmentObject(settings)
                .environmentObject(engine)
                .environmentObject(cloudSync)
                .environmentObject(bridge)
                .environmentObject(updater)
                .environmentObject(ambientMotion)
                // No height here: the window sizes to the selected page (see
                // `SettingsMetrics`), so a short form doesn't leave dead space.
                .preferredColorScheme(settings.themeMode.colorScheme)
                .tint(Theme.accent)
        }
    }
}
