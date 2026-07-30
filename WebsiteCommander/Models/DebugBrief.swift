import Foundation

/// A consolidated, agent-ready snapshot of everything the app knows about a
/// problem with the live site: console errors, failed requests, performance,
/// the client-side audit, prompt-injection findings, the last agent error, and
/// the workspace context (including the local repo path so an external agent can
/// navigate straight to the code).
///
/// This type is UI-free and `Codable` so the headless CLI can build and export
/// the same brief the GUI produces.
struct DebugBrief: Codable {

    struct Finding: Codable, Equatable, Identifiable {
        var id = UUID()
        var severity: String   // "Critical" | "Warning" | "Info"
        var title: String
        var detail: String
    }

    struct Request: Codable, Equatable, Identifiable {
        var id = UUID()
        var method: String
        var url: String
        var status: Int
    }

    struct Context: Codable, Equatable {
        var siteName: String
        var slug: String
        var branch: String
        var liveURL: String
        /// Absolute path to the local clone, if one exists — lets an external
        /// agent open the real files regardless of where it's running.
        var repoPath: String?
        var techStack: String
        var deployment: String
    }

    var generatedAt: Date
    var appVersion: String
    var context: Context
    var consoleErrors: [String]
    var consoleWarnings: [String]
    var failedRequests: [Request]
    var loadMs: Int?
    var domReadyMs: Int?
    var transferKB: Int?
    var audit: [Finding]
    var injection: [String]
    var lastAgentError: String?
    var stagedChanges: Int

    // MARK: Derived

    /// 0–100 health score mirroring the audit sheet.
    var healthScore: Int {
        let critical = audit.filter { $0.severity == "Critical" }.count
        let warning = audit.filter { $0.severity == "Warning" }.count
        let info = audit.filter { $0.severity == "Info" }.count
        return max(0, min(100, 100 - critical * 20 - warning * 8 - info * 2))
    }

    var hasFindings: Bool {
        !consoleErrors.isEmpty || !failedRequests.isEmpty ||
        audit.contains { $0.severity != "Info" } || !injection.isEmpty
    }

    // MARK: Markdown export

    /// Full human- and agent-readable document.
    func markdown(briefPath: String? = nil) -> String {
        var lines: [String] = []
        lines.append("# Website Commander — Debug Brief")
        lines.append("")
        lines.append("- Generated: \(Self.fmt.string(from: generatedAt))")
        lines.append("- App version: \(appVersion)")
        lines.append("- Health score: \(healthScore)/100")
        lines.append("- Site: \(context.siteName) (`\(context.slug)` @ `\(context.branch)`)")
        lines.append("- Stack: \(context.techStack) · Deploy: \(context.deployment)")
        if !context.liveURL.isEmpty { lines.append("- Live URL: \(context.liveURL)") }
        if let repoPath = context.repoPath { lines.append("- Local repo path: `\(repoPath)`") }
        if stagedChanges > 0 { lines.append("- Staged (uncommitted) changes: \(stagedChanges)") }
        if let lastAgentError { lines.append("- Last agent error: \(SecretRedactor.redact(lastAgentError))") }

        lines.append("")
        lines.append("## Console errors (\(consoleErrors.count))")
        if consoleErrors.isEmpty { lines.append("_None captured._") }
        else { consoleErrors.forEach { lines.append("- \(SecretRedactor.redact($0))") } }

        lines.append("")
        lines.append("## Console warnings (\(consoleWarnings.count))")
        if consoleWarnings.isEmpty { lines.append("_None captured._") }
        else { consoleWarnings.prefix(20).forEach { lines.append("- \(SecretRedactor.redact($0))") } }

        lines.append("")
        lines.append("## Failed network requests (\(failedRequests.count))")
        if failedRequests.isEmpty { lines.append("_None captured._") }
        else { failedRequests.forEach { lines.append("- \($0.method) \(SecretRedactor.redact($0.url)) → \($0.status)") } }

        lines.append("")
        lines.append("## Performance")
        lines.append("- Load: \(loadMs.map { "\($0) ms" } ?? "n/a")")
        lines.append("- DOM ready: \(domReadyMs.map { "\($0) ms" } ?? "n/a")")
        lines.append("- Transferred: \(transferKB.map { "\($0) KB" } ?? "n/a")")

        lines.append("")
        lines.append("## Audit (\(audit.count))")
        if audit.isEmpty { lines.append("_No audit run._") }
        else { audit.forEach { lines.append("- [\($0.severity)] \(SecretRedactor.redact($0.title)): \(SecretRedactor.redact($0.detail))") } }

        if !injection.isEmpty {
            lines.append("")
            lines.append("## Prompt-injection findings (\(injection.count))")
            injection.forEach { lines.append("- \(SecretRedactor.redact($0))") }
        }

        if let briefPath {
            lines.append("")
            lines.append("---")
            lines.append("_This brief was saved to `\(briefPath)`._")
        }
        return lines.joined(separator: "\n")
    }

    /// A bounded inline summary suitable for pasting into a chat-based agent.
    func compactSummary() -> String {
        var lines: [String] = []
        lines.append("Site \(context.siteName) (\(context.slug)@\(context.branch)), health \(healthScore)/100.")
        if let repoPath = context.repoPath { lines.append("Repo on disk: \(repoPath)") }
        if !context.liveURL.isEmpty { lines.append("Live: \(context.liveURL)") }
        if !consoleErrors.isEmpty {
            lines.append("Console errors: " + SecretRedactor.redact(Array(consoleErrors.prefix(8))).joined(separator: " | "))
        }
        if !failedRequests.isEmpty {
            lines.append("Failed requests: " + failedRequests.prefix(8).map { "\($0.method) \(SecretRedactor.redact($0.url)) (\($0.status))" }.joined(separator: " | "))
        }
        let bad = audit.filter { $0.severity != "Info" }
        if !bad.isEmpty {
            lines.append("Audit: " + bad.prefix(8).map { "[\($0.severity)] \(SecretRedactor.redact($0.title))" }.joined(separator: " | "))
        }
        if let loadMs { lines.append("Load \(loadMs)ms.") }
        if !injection.isEmpty { lines.append("Injection flags: \(injection.count).") }
        if let lastAgentError { lines.append("Last agent error: \(SecretRedactor.redact(lastAgentError))") }
        return lines.joined(separator: "\n")
    }

    /// A prompt tailored to a destination agent. Always inlines the compact
    /// summary and points at the saved brief file (which lives in the repo when
    /// possible, so an agent pointed at the same repo can read it directly).
    func prompt(for target: AgentTarget, briefPath: String?) -> String {
        let fileRef = briefPath.map { "A full debug brief is saved at `\($0)` (also at `.website-commander/debug-brief.md` inside the repo) — read it for the complete console/network/audit detail." } ?? ""
        let head: String
        switch target {
        case .inApp:
            head = "Use your browser tools (browser_look, browser_screenshot) to confirm the issues below on the live site, then locate the responsible file(s) in the repo and fix them with write_file. Keep edits minimal and explain each change."
        case .codex:
            head = "You are working in the Website Commander debug handoff. Diagnose and fix the issues below in this repository with minimal, correct edits. \(fileRef)"
        case .claude:
            head = "Diagnose and fix the following live-site issues in this repo with minimal edits. \(fileRef)"
        case .cursor, .opencode:
            head = "Fix the live-site issues below. The full debug brief (console errors, failed requests, audit, performance) is attached as `.website-commander/debug-brief.md` in this repo — read it first, then make minimal edits. \(fileRef)"
        case .vscode:
            head = "Debug brief for the open file/folder. See `.website-commander/debug-brief.md` for the captured console/network/audit data. \(fileRef)"
        case .clipboard:
            head = "Please fix these issues on my website. Full debug brief below."
        }
        return """
        \(head)

        \(compactSummary())
        """
    }

    private static let fmt: DateFormatter = {
        let f = DateFormatter(); f.dateStyle = .medium; f.timeStyle = .medium; return f
    }()
}

/// Where a debug brief can be sent. File-based editors open the saved brief;
/// chat/CLI agents receive a tailored prompt (copied to the clipboard, or handed
/// to the in-app agent directly).
enum AgentTarget: String, CaseIterable, Identifiable {
    case inApp, codex, claude, cursor, opencode, vscode, clipboard

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .inApp: return "Website Commander agent"
        case .codex: return "Codex"
        case .claude: return "Claude Code"
        case .cursor: return "Cursor"
        case .opencode: return "opencode"
        case .vscode: return "VS Code"
        case .clipboard: return "Clipboard"
        }
    }

    var icon: String {
        switch self {
        case .inApp: return "sparkles"
        case .clipboard: return "doc.on.clipboard"
        case .codex: return "terminal"
        case .claude: return "terminal"
        case .cursor: return "cursorarrow.rays"
        case .opencode: return "chevron.left.forwardslash.chevron.right"
        case .vscode: return "chevron.left.forwardslash.chevron.right"
        }
    }
}
