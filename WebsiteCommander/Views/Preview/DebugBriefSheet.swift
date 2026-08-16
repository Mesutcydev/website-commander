import SwiftUI
import AppKit

/// The smart debugger: consolidates the live breadcrumbs the app already
/// captures (console errors, failed requests, performance, the client-side audit
/// and prompt-injection scan, the last agent error, the repo path) into one
/// agent-ready brief, then exports it to whichever tool the developer uses —
/// opening it in VS Code / Cursor, copying a tailored prompt for Codex / Claude /
/// opencode, launching a CLI agent in Terminal, or handing it to the in-app agent.
struct DebugBriefSheet: View {

    @EnvironmentObject var settings: SettingsStore
    @EnvironmentObject var browser: BrowserController
    @EnvironmentObject var engine: AgentEngine
    @Environment(\.dismiss) private var dismiss

    /// Called with a ready prompt when the user sends the brief to the in-app agent.
    var onSendToAgent: (String) -> Void

    @State private var brief: DebugBrief?
    @State private var briefPath: String?
    @State private var repoPath: String?
    @State private var guiEditors: [(editor: EditorBridge.GUIEditor, cli: String?)] = []
    @State private var cliAgents: [(agent: EditorBridge.CLIAgent, cli: String)] = []
    @State private var status: String?
    @State private var confirmTerminal: (name: String, command: String)?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
            Divider()
            footer
        }
        .frame(minWidth: 560, idealWidth: 640, minHeight: 520, idealHeight: 640)
        .background { GlassPaneBackground() }
        .task { await capture() }
        .onExitCommand { dismiss() }
        .alert("Run agent in Terminal?", isPresented: Binding(
            get: { confirmTerminal != nil },
            set: { if !$0 { confirmTerminal = nil } })) {
            Button("Cancel", role: .cancel) { confirmTerminal = nil }
            Button("Launch") {
                guard let c = confirmTerminal else { return }
                let ok = EditorBridge.runInTerminal(c.command)
                flash(ok ? "Launched \(c.name) in Terminal — the prompt is on your clipboard."
                         : "Couldn't open Terminal.")
                confirmTerminal = nil
            }
        } message: {
            if let c = confirmTerminal {
                Text("This opens a Terminal window running `\(c.command)`. The debug brief is in the repo and a tailored prompt is on your clipboard — paste it to start. The agent will have edit access to the repo.")
            }
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: Theme.Space.l) {
            ZStack {
                Circle().stroke(Theme.borderSubtle, lineWidth: 8)
                Circle()
                    .trim(from: 0, to: CGFloat(brief?.healthScore ?? 0) / 100)
                    .stroke(scoreTint, style: StrokeStyle(lineWidth: 8, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                Text("\(brief?.healthScore ?? 0)")
                    .font(Theme.display(24, weight: .heavy))
            }
            .frame(width: 64, height: 64)

            VStack(alignment: .leading, spacing: 3) {
                Text("Debug Brief").font(.title3.weight(.semibold))
                Text(brief?.context.siteName ?? "—")
                    .font(.callout).foregroundStyle(Theme.secondaryText)
                if let brief {
                    Text("Captured \(brief.generatedAt.formatted(date: .omitted, time: .standard))")
                        .font(.caption2).foregroundStyle(Theme.tertiaryText)
                }
            }
            Spacer()
            if brief?.hasFindings == false {
                Badge(text: "All clear", systemImage: "checkmark.shield.fill", tint: Theme.success)
            }
            Button {
                dismiss()
            } label: {
                Label("Close Debug Brief", systemImage: "xmark")
                    .frame(width: 28, height: 28)
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.plain)
            .background(Theme.cardFill, in: Circle())
            .overlay(Circle().stroke(Theme.borderSubtle, lineWidth: 1))
            .help("Close Debug Brief (Esc)")
            .keyboardShortcut(.cancelAction)
        }
        .padding(Theme.Space.l)
    }

    private var scoreTint: Color {
        switch brief?.healthScore ?? 0 {
        case 80...: return Theme.success
        case 50..<80: return Theme.warning
        default: return Theme.danger
        }
    }

    // MARK: Content

    private var content: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.m) {
                if brief == nil {
                    ProgressView("Capturing live data…").padding(.top, Theme.Space.xl)
                } else {
                    section("Console errors", icon: "xmark.octagon.fill", tint: Theme.danger,
                            rows: brief?.consoleErrors ?? [], empty: "No console errors.")
                    section("Failed requests", icon: "antenna.radiowaves.left.and.right", tint: Theme.warning,
                            rows: (brief?.failedRequests ?? []).map { "\($0.method) \($0.url) → \($0.status)" },
                            empty: "No failed requests.")
                    section("Audit findings", icon: "checkmark.shield.fill", tint: Theme.accent,
                            rows: (brief?.audit ?? []).filter { $0.severity != "Info" }
                                .map { "[\($0.severity)] \($0.title) — \($0.detail)" },
                            empty: "No critical or warning findings.")
                    section("Prompt-injection flags", icon: "exclamationmark.shield.fill", tint: Theme.danger,
                            rows: brief?.injection ?? [],
                            empty: "No injection patterns in the page.")
                    contextCard
                }
            }
            .padding(Theme.Space.l)
        }
    }

    private func section(_ title: String, icon: String, tint: Color, rows: [String], empty: String) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            HStack(spacing: 6) {
                Image(systemName: icon).foregroundStyle(tint)
                Text(title).font(.subheadline.weight(.semibold))
                Text("\(rows.count)").font(.caption2).foregroundStyle(.secondary)
                Spacer()
            }
            VStack(alignment: .leading, spacing: 4) {
                if rows.isEmpty {
                    Text(empty).font(.caption).foregroundStyle(.secondary)
                } else {
                    ForEach(rows.prefix(12), id: \.self) { row in
                        Text(row).font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
        }
        .commandCard()
    }

    private var contextCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "folder.fill").foregroundStyle(Theme.accent)
                Text("Context").font(.subheadline.weight(.semibold))
                Spacer()
            }
            if let brief {
                row("Repo", brief.context.slug + " @ " + brief.context.branch)
                if let repoPath { row("On disk", repoPath) }
                if !brief.context.liveURL.isEmpty { row("Live", brief.context.liveURL) }
                if brief.stagedChanges > 0 { row("Staged", "\(brief.stagedChanges) uncommitted change(s)") }
                if let e = brief.lastAgentError { row("Last error", e) }
            }
        }
        .commandCard()
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack(alignment: .top, spacing: Theme.Space.s) {
            Text(label).font(.caption).foregroundStyle(.secondary).frame(width: 70, alignment: .leading)
            Text(value).font(.caption).textSelection(.enabled)
            Spacer()
        }
    }

    // MARK: Footer

    private var footer: some View {
        VStack(spacing: Theme.Space.s) {
            if let status {
                Label(status, systemImage: "checkmark.circle.fill")
                    .font(.caption).foregroundStyle(Theme.success)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            ViewThatFits(in: .horizontal) {
                footerActions(showLabels: true)
                footerActions(showLabels: false)
            }
        }
        .padding(Theme.Space.l)
    }

    private func footerActions(showLabels: Bool) -> some View {
        HStack(spacing: Theme.Space.s) {
            Menu {
                if guiEditors.isEmpty {
                    Text("No editors detected").font(.caption)
                } else {
                    ForEach(guiEditors, id: \.editor.id) { item in
                        Button("Open in \(item.editor.displayName)") {
                            openInGUI(item.editor, cli: item.cli)
                        }
                    }
                }
            } label: {
                footerMenuLabel("Open in editor", systemImage: "square.and.arrow.up", showTitle: showLabels)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .disabled(brief == nil)
            .help("Open the debug brief in an editor")

            Menu {
                if cliAgents.isEmpty {
                    Text("No CLI agents on PATH").font(.caption)
                } else {
                    ForEach(cliAgents, id: \.agent.id) { item in
                        Button("Run \(item.agent.displayName) in Terminal") {
                            askTerminal(item.agent, cli: item.cli)
                        }
                        .disabled(repoPath == nil)
                    }
                }
            } label: {
                footerMenuLabel("Run in Terminal", systemImage: "terminal", showTitle: showLabels)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .disabled(brief == nil || repoPath == nil)
            .help("Run a detected coding agent in Terminal")

            Menu {
                ForEach([AgentTarget.codex, .claude, .opencode, .cursor, .vscode, .clipboard]) { target in
                    Button("Copy for \(target.displayName)") { copyPrompt(target) }
                }
            } label: {
                footerMenuLabel("Copy prompt", systemImage: "doc.on.clipboard", showTitle: showLabels)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .disabled(brief == nil)
            .help("Copy a prompt tailored for another agent")

            Spacer(minLength: Theme.Space.s)

            Button {
                guard let brief else { return }
                onSendToAgent(brief.prompt(for: .inApp, briefPath: briefPath))
            } label: {
                Label("Send to agent", systemImage: "sparkles")
            }
            .buttonStyle(.primary)
            .disabled(brief == nil)
            .help("Close this brief and continue in Agent Chat")

            if !showLabels {
                Button("Close") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
            }
        }
    }

    @ViewBuilder
    private func footerMenuLabel(_ title: String, systemImage: String, showTitle: Bool) -> some View {
        if showTitle {
            Label(title, systemImage: systemImage)
        } else {
            Image(systemName: systemImage)
                .accessibilityLabel(title)
                .frame(width: 28, height: 28)
        }
    }

    // MARK: Actions

    private func capture() async {
        let ws = settings.activeWorkspace
        let hasLiveURL = ws.flatMap { SiteWorkspace.normalizedLiveURL($0.configuredLiveURL) } != nil
        let ready = hasLiveURL ? await browser.ensureAvailable() : false
        let html = ready ? await browser.snapshotHTML() : ""
        // Do not attribute breadcrumbs from the previously selected site to a
        // missing or failed navigation for the current site.
        let inspector = ready ? browser.inspector : nil
        let audit = ready
            ? SiteAuditor.audit(html: html, inspector: browser.inspector)
            : [SiteAuditIssue(title: "Preview unavailable",
                              detail: browser.navigationError ?? "The live preview could not finish loading.",
                              severity: .critical)]
        let injection = PromptGuard.injectionFindings(in: html)
        let path = ws.flatMap { LocalWorkspaceStore.isCloned($0) ? LocalWorkspaceStore.localPath(for: $0).path : nil }
        repoPath = path
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
        let b = DebugBrief(
            generatedAt: Date(), appVersion: version,
            context: .init(siteName: ws?.name ?? "—", slug: ws?.slug ?? "—", branch: ws?.gitBranch ?? "—",
                           liveURL: ws?.configuredLiveURL ?? "", repoPath: path,
                           techStack: ws?.techStack.rawValue ?? "—", deployment: ws?.deployment.rawValue ?? "—"),
            consoleErrors: inspector?.consoleLogs.filter { $0.level == .error }.map { $0.text } ?? [],
            consoleWarnings: inspector?.consoleLogs.filter { $0.level == .warn }.map { $0.text } ?? [],
            failedRequests: inspector?.networkRequests.compactMap { request in
                guard let status = request.status, status == 0 || status >= 400 else { return nil }
                return DebugBrief.Request(method: request.method, url: request.url, status: status)
            } ?? [],
            loadMs: inspector?.performance.loadTimeMs,
            domReadyMs: inspector?.performance.domReadyMs,
            transferKB: inspector?.performance.transferKB,
            audit: audit.map { DebugBrief.Finding(severity: $0.severity.rawValue, title: $0.title, detail: $0.detail) },
            injection: injection,
            lastAgentError: engine.lastError,
            stagedChanges: engine.pendingChanges.count)
        brief = b
        briefPath = EditorBridge.writeBrief(b, repoPath: path)?.path
        guiEditors = await EditorBridge.detectedGUIEditors()
        cliAgents = await EditorBridge.detectedCLIAgents()
    }

    private func openInGUI(_ editor: EditorBridge.GUIEditor, cli: String?) {
        guard let briefPath else { return }
        let ok = EditorBridge.openGUI(URL(fileURLWithPath: briefPath), editor: editor, cli: cli)
        flash(ok ? "Opened in \(editor.displayName)." : "Couldn't open \(editor.displayName).")
    }

    private func copyPrompt(_ target: AgentTarget) {
        guard let brief, let briefPath else { return }
        let prompt = brief.prompt(for: target, briefPath: briefPath)
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(prompt, forType: .string)
        flash("Prompt copied for \(target.displayName).")
    }

    private func askTerminal(_ agent: EditorBridge.CLIAgent, cli: String) {
        let command = EditorBridge.terminalCommand(cli: cli, repoPath: repoPath)
        // Stage the prompt on the clipboard so it's ready to paste in the agent.
        if let brief {
            let pb = NSPasteboard.general; pb.clearContents()
            pb.setString(brief.prompt(for: AgentTarget(rawValue: agent.id) ?? .clipboard, briefPath: briefPath), forType: .string)
        }
        confirmTerminal = (agent.displayName, command)
    }

    private func flash(_ message: String) {
        status = message
    }
}
