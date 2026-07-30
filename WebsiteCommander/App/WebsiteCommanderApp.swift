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
        _settings = StateObject(wrappedValue: settings)
        _browser = StateObject(wrappedValue: browser)
        _cloudSync = StateObject(wrappedValue: cloudSync)
        _conversations = StateObject(wrappedValue: conversations)
        _updater = StateObject(wrappedValue: updater)
        _engine = StateObject(wrappedValue: engine)
        _bridge = StateObject(wrappedValue: bridge)
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
                .frame(minWidth: 1080, minHeight: 700)
                .preferredColorScheme(settings.themeMode.colorScheme)
                .tint(Theme.accent)
                .task {
                    cloudSync.startObserving(settings: settings)
                    cloudSync.pull(into: settings)
                    if settings.localBridgeEnabled {
                        bridge.start(preferredPort: settings.localBridgePort)
                    }
                }
                .onChange(of: settings.localBridgeEnabled) { _, on in
                    if on { bridge.start(preferredPort: settings.localBridgePort) }
                    else { bridge.stop() }
                }
        }
        .windowStyle(.automatic)
        .windowToolbarStyle(.unified)
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
            CommandGroup(after: .appInfo) {
                Button(updater.checking ? "Checking for Updates…" : "Check for Updates…") {
                    Task { await updater.check(feedURL: settings.updateFeedURL) }
                }
                .disabled(updater.checking)
            }
            CommandMenu("Site") {
                Button("Open in VSCode") { NotificationCenter.default.post(name: .openInVSCode, object: nil) }
                    .keyboardShortcut("v", modifiers: [.command, .shift])
                Button("Refresh Preview") { NotificationCenter.default.post(name: .refreshPreview, object: nil) }
                    .keyboardShortcut("r", modifiers: [.command, .shift])
                Button("Debug Current Site") { NotificationCenter.default.post(name: .requestDebug, object: nil) }
                    .keyboardShortcut("d", modifiers: [.command, .shift])
            }
            CommandMenu("View") {
                ForEach(ThemeMode.allCases) { mode in
                    Button {
                        settings.themeMode = mode
                    } label: {
                        Label(mode.rawValue, systemImage: mode.icon)
                    }
                    .disabled(settings.themeMode == mode)
                }
            }
        }

        Settings {
            SettingsView()
                .environmentObject(settings)
                .environmentObject(engine)
                .frame(width: 620, height: 560)
        }
    }
}

extension Notification.Name {
    static let openInVSCode = Notification.Name("openInVSCode")
    static let refreshPreview = Notification.Name("refreshPreview")
    static let requestAddSite = Notification.Name("requestAddSite")
    static let requestDebug = Notification.Name("requestDebug")
    static let requestPalette = Notification.Name("requestPalette")
}
