import AppIntents
import Foundation

/// Shortcuts/Siri entry point: queue an instruction for the website agent. The
/// approval gate is intentionally kept — the intent opens the app, selects the
/// site, and prefills/sends the prompt; the user still reviews staged changes.
// ponytail: `site` is a plain string, not an AppEntity picker. Upgrade to an
// AppEntity + EntityQuery over workspaces if users want a dropdown of sites.
struct RunPromptIntent: AppIntent {
    static var title: LocalizedStringResource = "Run Website Commander Prompt"
    static var description = IntentDescription("Send an instruction to your Website Commander website agent.")
    static var openAppWhenRun = true

    @Parameter(title: "Instruction")
    var prompt: String

    @Parameter(title: "Site name (optional)")
    var site: String?

    static var parameterSummary: some ParameterSummary {
        Summary("Tell Website Commander to \(\.$prompt) on \(\.$site)")
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        PendingIntent.store(prompt: prompt, site: site)
        return .result()
    }
}

/// One-shot hand-off from the (out-of-process) intent to the running app, read on
/// the next foreground via `AgentEngine.runPendingIntentIfNeeded()`.
enum PendingIntent {
    private static let promptKey = "pendingIntentPrompt"
    private static let siteKey = "pendingIntentSite"

    static func store(prompt: String, site: String?) {
        let defaults = UserDefaults.standard
        defaults.set(prompt, forKey: promptKey)
        defaults.set(site, forKey: siteKey)
    }

    static func take() -> (prompt: String, site: String?)? {
        let defaults = UserDefaults.standard
        guard let prompt = defaults.string(forKey: promptKey)?
                .trimmingCharacters(in: .whitespacesAndNewlines), !prompt.isEmpty else { return nil }
        let site = defaults.string(forKey: siteKey)
        defaults.removeObject(forKey: promptKey)
        defaults.removeObject(forKey: siteKey)
        return (prompt, site)
    }
}

/// Surfaces the intent to Siri/Spotlight/Shortcuts without any setup.
struct SiteAgentShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: RunPromptIntent(),
            phrases: [
                "Run a prompt in \(.applicationName)",
                "Ask \(.applicationName) to update my site",
            ],
            shortTitle: "Run Prompt",
            systemImageName: "sparkles"
        )
    }
}
