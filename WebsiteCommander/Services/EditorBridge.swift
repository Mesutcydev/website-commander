import Foundation

/// Bridges Website Commander's debug brief to the developer's other tools.
///
/// Two kinds of destination:
/// * **GUI editors** (VS Code, Cursor) — we open the saved brief file directly,
///   which their agent extensions can read.
/// * **CLI agents** (Codex, Claude Code, opencode) — we write the brief into the
///   repository (`.website-commander/debug-brief.md`) so a running agent sees it,
///   and we can launch the agent in a Terminal window sitting in the repo dir.
///
/// Detection resolves CLIs through absolute candidates first, then a login-shell
/// `command -v` (so user-installed tools on a custom PATH are found). This type
/// is Foundation-only so the headless CLI can reuse it.
@MainActor
enum EditorBridge {

    struct GUIEditor: Identifiable {
        let id: String
        let displayName: String
        let icon: String
        let cliCandidates: [String]
        let cliNames: [String]
        let appBundles: [String]
    }

    struct CLIAgent: Identifiable {
        let id: String
        let displayName: String
        let icon: String
        let cliNames: [String]
    }

    static let guiEditors: [GUIEditor] = [
        GUIEditor(id: "vscode", displayName: "VS Code", icon: "chevron.left.forwardslash.chevron.right",
                  cliCandidates: [
                    "/Applications/Visual Studio Code.app/Contents/Resources/app/bin/code",
                    "/usr/local/bin/code", "/opt/homebrew/bin/code"
                  ],
                  cliNames: ["code"],
                  appBundles: ["Visual Studio Code.app"]),
        GUIEditor(id: "cursor", displayName: "Cursor", icon: "cursorarrow.rays",
                  cliCandidates: [
                    "/Applications/Cursor.app/Contents/Resources/app/bin/cursor",
                    "/usr/local/bin/cursor",
                    NSHomeDirectory() + "/.local/bin/cursor"
                  ],
                  cliNames: ["cursor"],
                  appBundles: ["Cursor.app"])
    ]

    static let cliAgents: [CLIAgent] = [
        CLIAgent(id: "codex", displayName: "Codex", icon: "terminal", cliNames: ["codex"]),
        CLIAgent(id: "claude", displayName: "Claude Code", icon: "terminal", cliNames: ["claude"]),
        CLIAgent(id: "opencode", displayName: "opencode", icon: "chevron.left.forwardslash.chevron.right",
                 cliNames: ["opencode"])
    ]

    // MARK: Detection (cached)

    private static var cliCache: [String: String?] = [:]

    /// Resolve a CLI name to an absolute path, checking candidates then the shell.
    static func resolveCLI(candidates: [String], names: [String]) async -> String? {
        for path in candidates where FileManager.default.isExecutableFile(atPath: path) {
            return path
        }
        for name in names {
            if let cached = cliCache[name] { if let cached { return cached } else { continue } }
            let resolved = await shellResolve(name)
            cliCache[name] = resolved
            if let resolved { return resolved }
        }
        return nil
    }

    private static func shellResolve(_ name: String) async -> String? {
        // Run the login-shell `command -v` off the main actor with a timeout, so
        // a slow shell startup (sourcing user rc files) can no longer stall the
        // debug-brief capture on the UI thread.
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/bin/zsh")
                process.arguments = ["-lc", "command -v \(name)"]
                let pipe = Pipe()
                process.standardOutput = pipe
                process.standardError = FileHandle.nullDevice
                do {
                    try process.run()
                    let deadline = Date().addingTimeInterval(3.0)
                    while process.isRunning && Date() < deadline {
                        Thread.sleep(forTimeInterval: 0.05)
                    }
                    if process.isRunning {
                        process.terminate()
                        continuation.resume(returning: nil)
                        return
                    }
                    let data = pipe.fileHandleForReading.readDataToEndOfFile()
                    let path = String(data: data, encoding: .utf8)?
                        .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    continuation.resume(returning: (process.terminationStatus == 0 && !path.isEmpty) ? path : nil)
                } catch {
                    continuation.resume(returning: nil)
                }
            }
        }
    }

    /// GUI editors that are installed (CLI or .app bundle present).
    static func detectedGUIEditors() async -> [(editor: GUIEditor, cli: String?)] {
        var results: [(editor: GUIEditor, cli: String?)] = []
        for editor in guiEditors {
            let cli = await resolveCLI(candidates: editor.cliCandidates, names: editor.cliNames)
            let hasApp = editor.appBundles.contains {
                FileManager.default.fileExists(atPath: "/Applications/\($0)")
            }
            if cli != nil || hasApp {
                results.append((editor, cli))
            }
        }
        return results
    }

    /// CLI agents that are installed on PATH.
    static func detectedCLIAgents() async -> [(agent: CLIAgent, cli: String)] {
        var results: [(agent: CLIAgent, cli: String)] = []
        for agent in cliAgents {
            if let cli = await resolveCLI(candidates: [], names: agent.cliNames) {
                results.append((agent, cli))
            }
        }
        return results
    }

    // MARK: Writing the brief

    /// Write the brief to the repo (preferred) or a temp folder. Returns nil when
    /// the write fails so callers can surface the error instead of opening a
    /// nonexistent file.
    @discardableResult
    static func writeBrief(_ brief: DebugBrief, repoPath: String?) -> URL? {
        let dir: URL
        if let repoPath, !repoPath.isEmpty {
            dir = URL(fileURLWithPath: repoPath).appendingPathComponent(".website-commander", isDirectory: true)
        } else {
            dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("WebsiteCommander", isDirectory: true)
        }
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let file = dir.appendingPathComponent("debug-brief.md")
            let text = brief.markdown(briefPath: file.path)
            try text.write(to: file, atomically: true, encoding: .utf8)
            return file
        } catch {
            return nil
        }
    }

    // MARK: Opening

    /// Open a file in a GUI editor (via its CLI, falling back to `open -a`).
    @discardableResult
    static func openGUI(_ url: URL, editor: GUIEditor, cli: String?) -> Bool {
        if let cli {
            return run(executable: cli, arguments: [url.path])
        }
        if let bundle = editor.appBundles.first,
           FileManager.default.fileExists(atPath: "/Applications/\(bundle)") {
            return run(executable: "/usr/bin/open", arguments: ["-a", bundle, url.path])
        }
        return false
    }

    /// Build the shell command that launches a CLI agent in the repo directory.
    static func terminalCommand(cli: String, repoPath: String?) -> String {
        let quotedCLI = singleQuoted(cli)
        if let repoPath, !repoPath.isEmpty {
            return "cd \(singleQuoted(repoPath)) && \(quotedCLI)"
        }
        return quotedCLI
    }

    /// Open a Terminal window running `command`. Used (with user confirmation) to
    /// hand off to a CLI agent sitting in the repo, where the brief file lives.
    @discardableResult
    static func runInTerminal(_ command: String) -> Bool {
        let escaped = command.replacingOccurrences(of: "\\", with: "\\\\")
                             .replacingOccurrences(of: "\"", with: "\\\"")
        let script = "tell application \"Terminal\"\nactivate\ndo script \"\(escaped)\"\nend tell"
        return run(executable: "/usr/bin/osascript", arguments: ["-e", script])
    }

    // MARK: Helpers

    @discardableResult
    private static func run(executable: String, arguments: [String]) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do { try process.run(); return true } catch { return false }
    }

    private static func singleQuoted(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
