import SwiftUI

@main
struct SiteAgentApp: App {
    /// Runs before `@StateObject` builds `AgentEngine`, so the classic emerald
    /// defaults are already in UserDefaults when AppStorage keys are read.
    private static let prepare: Void = {
        Fonts.register()          // must precede appearance config (UIFont(name:))
        Theme.restoreClassicCommandCenterDesignIfNeeded()
        configureChrome()
    }()

    @StateObject private var engine: AgentEngine = {
        _ = SiteAgentApp.prepare
        return AgentEngine()
    }()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(engine)
                .font(.ui(15))     // Geist as the default text font app-wide
                .tint(Theme.controlTint)
        }
        .commands {
            // Tab navigation via the existing requestedTab deep-link mechanism —
            // RootView observes it and switches tabs, so no new state is needed.
            CommandGroup(after: .toolbar) {
                Button("Home") { engine.requestedTab = .home }
                    .keyboardShortcut("1", modifiers: .command)
                Button("Sites") { engine.requestedTab = .sites }
                    .keyboardShortcut("2", modifiers: .command)
                Button("Chat") { engine.requestedTab = .agent }
                    .keyboardShortcut("3", modifiers: .command)
                Button("Preview") { engine.requestedTab = .preview }
                    .keyboardShortcut("4", modifiers: .command)
            }
        }
    }

    /// Glass-restyle the native nav + tab bars so the gradient backdrop shows
    /// through and titles use the display font. Set once via appearance proxies.
    private static func configureChrome() {
        // iOS 26+: leave UINavigationBarAppearance alone. Any custom appearance
        // proxy replaces the system Liquid Glass nav (the frosted refractive bar
        // in the reference shots) with a flat material/opaque strip.
        if #available(iOS 26.0, *) { return }

        // Pre-26: clear at rest so the header/gradient shows, then the default
        // translucent material once content scrolls under the bar.
        let applyFonts: (UINavigationBarAppearance) -> Void = { a in
            if let title = UIFont(name: "BricolageGrotesque-Bold", size: 17) {
                a.titleTextAttributes = [.font: title, .foregroundColor: UIColor.label]
            }
            if let large = UIFont(name: "BricolageGrotesque-ExtraBold", size: 32) {
                a.largeTitleTextAttributes = [.font: large, .foregroundColor: UIColor.label]
            }
        }
        let atRest = UINavigationBarAppearance()
        atRest.configureWithTransparentBackground()
        applyFonts(atRest)
        let scrolled = UINavigationBarAppearance()
        scrolled.configureWithDefaultBackground()
        applyFonts(scrolled)
        UINavigationBar.appearance().scrollEdgeAppearance = atRest
        UINavigationBar.appearance().standardAppearance = scrolled
        UINavigationBar.appearance().compactAppearance = scrolled

        // Intentionally NOT overriding UITabBarAppearance: let the system render
        // its native tab bar — on iOS 26 that's the Liquid Glass floating bar,
        // and the framework handles the safe-area inset so scroll content never
        // hides behind it.
    }
}

/// Tabs, with a shared selection so the setup card can jump.
enum AppTab: Int { case home, sites, agent, preview

    /// First tab on launch (.home normally). Marketing-screenshot mode can pick a
    /// tab via SCREENSHOT_TAB so each screen is captured on a clean simulator.
    static var initialTab: AppTab {
        #if DEBUG
        switch ProcessInfo.processInfo.environment["SCREENSHOT_TAB"] {
        case "sites": return .sites
        case "chat", "agent": return .agent
        case "preview": return .preview
        default: return .home
        }
        #else
        return .home
        #endif
    }
}

#if targetEnvironment(macCatalyst)
/// Mac window sizing. On iPhone/iPad the system owns window size; on Mac the user
/// can otherwise shrink the window until the readable-width content + tab bar
/// break. A minimum keeps the layout intact; we don't cap the maximum so power
/// users can go wide for big diffs. Returning users' saved size is preserved
/// (we only set the floor, never force-resize).
enum MacWindow {
    static func applySizing() {
        for case let scene as UIWindowScene in UIApplication.shared.connectedScenes {
            scene.sizeRestrictions?.minimumSize = CGSize(width: 600, height: 760)
        }
    }
}
#endif

struct RootView: View {
    @EnvironmentObject var engine: AgentEngine
    @Environment(\.scenePhase) private var scenePhase
    @State private var tab: AppTab = .initialTab
#if SIDELOAD_BUILD
    // The sideload build opens directly into the workspace. The circular reveal
    // can leave a black band over the home screen while it is in flight, making
    // a valid layout look broken immediately after install.
    @State private var showSplash = false
#else
    @State private var showSplash = true   // animated launch splash (once per cold launch)
#endif
    @AppStorage("hasCompletedOnboarding") var hasCompletedOnboarding: Bool = false

    var body: some View {
        ZStack {
        Group {
            if !hasCompletedOnboarding {
                OnboardingView(onDismiss: {
                    hasCompletedOnboarding = true
                    // Activation nudge: if they finish onboarding but never run the
                    // agent, invite them back tomorrow. Cancelled on first run.
                    // No permission cold-request here — send() asks at the first
                    // real run, the genuine value moment (harmless if unauthorized:
                    // the nudge just won't fire).
                    NotificationManager.schedule(
                        id: NotificationManager.Nudge.activation,
                        title: "Ready to ship your first change?".localized,
                        body: "Connect a repo and tell the agent what to build — it deploys for you.".localized,
                        at: Date().addingTimeInterval(24 * 3600))
                }, splashActive: showSplash)
            } else {
                // Always let the platform own tab-bar material and selection.
                // iOS 26+ supplies the real Liquid Glass bar; older systems use
                // their native translucent tab bar and safe-area behavior.
                TabView(selection: $tab) {
                    HomeDashboardView(tab: $tab)
                        .tabItem { Label("Home", systemImage: "house") }
                        .tag(AppTab.home)
                    SitesManagerView()
                        .tabItem { Label("Sites", systemImage: "folder") }
                        .tag(AppTab.sites)
                    ChatView(tab: $tab, role: .page)
                        .tabItem { Label("Chat", systemImage: "message") }
                        .tag(AppTab.agent)
                    StandalonePreviewView()
                        .tabItem { Label("Preview", systemImage: "eye") }
                        .tag(AppTab.preview)
                }
                .modifier(RootChatComposerLayerModifier(tab: $tab))
                .tint(Theme.controlTint)
                .nativeTabBarBehavior()
                .onChange(of: tab) { _, _ in Haptics.tap() }
                // Guarded internally so this is a no-op after the first cold-launch
                // application, even if the TabView re-appears during this session.
                .task { engine.applyLaunchPreferenceOnColdLaunch() }
                // Notification permission is requested at first agent run (see
                // AgentEngine.send) — not here, so we don't cold-ask before value.
            }
        }
        .preferredColorScheme(engine.themeMode.colorScheme)
        .onChange(of: scenePhase, initial: true) { _, phase in
            engine.handleScenePhase(phase)
            #if targetEnvironment(macCatalyst)
            if phase == .active { MacWindow.applySizing() }
            #endif
        }
        // App Intents and the preview inspector ask the root to switch tabs.
        // `initial: true` so a value set during the same render pass as a cold
        // Shortcuts launch (scenePhase → .active → runPendingIntentIfNeeded) isn't
        // missed; the nil guard makes the initial fire a no-op.
        .onChange(of: engine.requestedTab, initial: true) { _, requested in
            guard let requested else { return }
            tab = requested
            engine.requestedTab = nil
        }
        #if DEBUG
        // Screenshot harness: `SCREENSHOT_PAYWALL=1` renders the paywall full-screen
        // so App Store review screenshots can be captured deterministically. The
        // plan to preselect comes from `SCREENSHOT_PLAN` (read in ProPaywall). Never
        // compiled into release.
        .overlay {
            if ProcessInfo.processInfo.environment["SCREENSHOT_PAYWALL"] == "1" {
                ProPaywall()
            }
        }
        #endif

            // Animated launch splash on top; its wipe reveals the screen beneath,
            // then it removes itself. Skipped in the screenshot harness.
            if showSplash && ProcessInfo.processInfo.environment["SCREENSHOT_TAB"] == nil
                && ProcessInfo.processInfo.environment["SCREENSHOT_PAYWALL"] == nil {
                SplashView(onFinish: { showSplash = false },
                           isReady: { engine.isLaunchReady })
                    .ignoresSafeArea()
                    .zIndex(1)
            }
        }
    }
}

/// Owns the complete Chat composer outside the Chat page hierarchy. The system
/// accessory host is intentionally not used: its compact fixed height clips the
/// model pill + full input row. This root overlay preserves the full composer
/// and gives it an independent z-layer above the unchanged system tab bar.
struct RootChatComposerHeightEnvironmentKey: EnvironmentKey {
    static let defaultValue: CGFloat = 112
}

extension EnvironmentValues {
    var rootChatComposerHeight: CGFloat {
        get { self[RootChatComposerHeightEnvironmentKey.self] }
        set { self[RootChatComposerHeightEnvironmentKey.self] = newValue }
    }
}

private struct RootChatComposerHeightPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = 112

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

private struct RootChatComposerLayerModifier: ViewModifier {
    @Binding var tab: AppTab
    @State private var keyboardVisible = false
    @State private var composerHeight: CGFloat = 112

    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content
                .environment(\.rootChatComposerHeight, composerHeight)
                .overlay(alignment: .bottom) {
                if tab == .agent {
                    ChatView(tab: $tab, role: .accessory)
                        .frame(maxWidth: .infinity)
                        .background {
                            GeometryReader { geometry in
                                Color.clear.preference(
                                    key: RootChatComposerHeightPreferenceKey.self,
                                    value: geometry.size.height
                                )
                            }
                        }
                        // The overlay already follows the keyboard and system
                        // tab-bar safe areas. Add only a small optical separation;
                        // a full tab-bar-height offset creates a duplicate gap.
                        .padding(.bottom, keyboardVisible ? 8 : 48)
                        .zIndex(10)
                }
            }
            .onPreferenceChange(RootChatComposerHeightPreferenceKey.self) { height in
                guard height.isFinite, height > 0, abs(height - composerHeight) > 0.5 else { return }
                composerHeight = height
            }
            .onReceive(NotificationCenter.default.publisher(
                for: UIResponder.keyboardWillShowNotification
            )) { _ in
                keyboardVisible = true
            }
            .onReceive(NotificationCenter.default.publisher(
                for: UIResponder.keyboardWillHideNotification
            )) { _ in
                keyboardVisible = false
            }
        } else {
            content
        }
    }
}

private extension View {
    @ViewBuilder
    func nativeTabBarBehavior() -> some View {
        if #available(iOS 26.0, *) {
            // Keep Apple's native Liquid Glass tab bar at its full, stable size.
            // Scroll-driven minimization hides the destinations behind one icon.
            self.tabBarMinimizeBehavior(.never)
        } else {
            self
        }
    }
}
