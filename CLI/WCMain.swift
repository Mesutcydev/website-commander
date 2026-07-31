import Foundation

/// Website Commander CLI.
///
/// Lets another agent (or a script) drive Website Commander headlessly. It shares
/// the same settings file and Keychain as the GUI app, so once you've configured
/// a GitHub token and an AI provider in the app, the CLI works immediately.
///
///   wc sites                       List connected sites (JSON)
///   wc sites add --owner O --repo R [--name N] [--branch B] [--stack S]
///                [--deploy D] [--url U]
///   wc providers                   List AI providers (JSON)
///   wc use <site> <prompt…> [--approve] [--model M]
///                                  Run the agent on a site; --approve commits
///                                  staged changes, otherwise they're left staged.
///
/// Example an outer agent can run:
///   wc use "My Portfolio" add a new project called Aurora to the portfolio --approve
@main
struct WCMain {
    static func main() async {
        let args = Array(CommandLine.arguments.dropFirst())
        await Runner.run(args)
    }
}

@MainActor
enum Runner {

    static func run(_ args: [String]) async {
        guard let command = args.first else { printHelp(); return }
        let rest = Array(args.dropFirst())
        let settings = SettingsStore()

        switch command {
        case "sites":
            await sitesCommand(settings, rest)
        case "use", "run":
            await useCommand(settings, rest)
        case "providers":
            providersCommand()
        case "debug":
            debugCommand(settings, rest)
        case "help", "--help", "-h":
            printHelp()
        default:
            FileHandle.standardError.write(Data("Unknown command: \(command)\n\n".utf8))
            printHelp()
            exit(2)
        }
    }

    // MARK: sites

    private static func sitesCommand(_ settings: SettingsStore, _ args: [String]) async {
        let sub = args.first ?? "list"
        switch sub {
        case "list":
            let activeID = settings.activeWorkspace?.id
            let rows = settings.workspaces.map { ws -> [String: Any] in
                [
                    "name": ws.name,
                    "slug": ws.slug,
                    "branch": ws.gitBranch,
                    "techStack": ws.techStack.rawValue,
                    "deployment": ws.deployment.rawValue,
                    "liveURL": ws.configuredLiveURL,
                    "active": ws.id == activeID
                ]
            }
            emitJSON(["sites": rows])
        case "add":
            addSite(settings, parseFlags(Array(args.dropFirst())))
        default:
            FileHandle.standardError.write(Data("Unknown sites subcommand: \(sub)\n".utf8))
            exit(2)
        }
    }

    private static func addSite(_ settings: SettingsStore, _ flags: [String: String]) {
        let detected = RepoDetector.detect()
        let owner = flags["owner"] ?? detected?.owner
        let repo = flags["repo"] ?? detected?.repo
        guard let owner, let repo else {
            FileHandle.standardError.write(Data(
                "sites add: no git repo detected here. Pass --owner and --repo, or run inside a cloned repo.\n".utf8))
            exit(2)
        }
        let stack = TechStack(rawValue: flags["stack"] ?? "") ?? detected?.techStack ?? .vanillaHTML
        let deploy = DeploymentType(rawValue: flags["deploy"] ?? "") ?? detected?.deployment ?? .githubPages
        let branch = flags["branch"] ?? detected?.branch ?? "main"
        var workspace = SiteWorkspace(
            name: flags["name"] ?? detected?.name ?? repo,
            gitOwner: owner, gitRepo: repo, gitBranch: branch,
            techStack: stack, deployment: deploy,
            defaultModel: flags["model"] ?? "")
        let liveURL = flags["url"] ?? detected?.liveURL ?? ""
        if !liveURL.isEmpty { workspace.deploymentConfig["liveURL"] = liveURL }
        settings.addWorkspace(workspace)
        if let hook = flags["hook"], !hook.isEmpty {
            DeploymentService.setHookURL(hook, for: workspace.id)
        }
        emitJSON([
            "added": workspace.name, "slug": workspace.slug, "branch": workspace.gitBranch,
            "techStack": workspace.techStack.rawValue, "deployment": workspace.deployment.rawValue,
            "autoDetected": detected != nil
        ])
    }

    // MARK: use / run

    private static func useCommand(_ settings: SettingsStore, _ args: [String]) async {
        let flags = parseFlags(args)
        let positionals = parsePositionals(args)

        guard let site = positionals.first else {
            FileHandle.standardError.write(Data("Usage: wc use <site> <prompt…> [--approve]\n".utf8))
            exit(2)
        }
        let prompt: String
        if let explicit = flags["prompt"] {
            prompt = explicit
        } else {
            prompt = positionals.dropFirst().joined(separator: " ")
        }
        guard !prompt.isEmpty else {
            FileHandle.standardError.write(Data("No prompt provided.\n".utf8))
            exit(2)
        }

        // Resolve the target site by name or slug and make it active.
        let lowered = site.lowercased()
        guard let workspace = settings.workspaces.first(where: {
            $0.name.lowercased() == lowered || $0.slug.lowercased() == lowered
        }) else {
            emitJSON(["ok": false, "error": "No site named '\(site)'. Run `wc sites` to see sites."])
            exit(1)
        }
        settings.setActive(workspace)
        if let model = flags["model"] { settings.model = model }

        FileHandle.standardError.write(Data("▶ Running agent on \(workspace.name)…\n".utf8))

        let browser = BrowserController()
        let engine = AgentEngine(settings: settings, browserController: browser)
        // Headless runs are conversations too: autosave them into the same
        // store the app reads, so nothing is lost when the process exits.
        engine.conversationStore = ConversationStore()
        let approve = flags["approve"] != nil
        let result = await engine.runHeadless(prompt, autoApprove: approve)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(result), let json = String(data: data, encoding: .utf8) {
            print(json)
        }
        exit(result.ok ? 0 : 1)
    }

    // MARK: providers

    private static func providersCommand() {
        let rows = ProviderRegistry.catalog.map { p -> [String: Any] in
            [
                "id": p.id,
                "name": p.displayName,
                "models": p.models,
                "supportsVision": p.supportsVision,
                "requiresKey": !p.keyLabel.isEmpty
            ]
        }
        emitJSON(["providers": rows])
    }

    // MARK: debug

    /// Emit an agent-ready debug brief for the current checkout. The brief file
    /// is written into the repo (`.website-commander/debug-brief.md`) and the
    /// actionable prompt + full brief are printed to stdout, so a calling agent
    /// (Codex, Claude, Cursor, opencode…) can read it straight off the pipe and
    /// also find the file in the repo it already has open.
    private static func debugCommand(_ settings: SettingsStore, _ args: [String]) {
        let flags = parseFlags(args)
        let detected = RepoDetector.detect()
        let repoPath = FileManager.default.currentDirectoryPath
        let ws = settings.workspaces.first { w in
            detected.map { w.gitOwner == $0.owner && w.gitRepo == $0.repo } ?? false
        }
        let brief = DebugBrief(
            generatedAt: Date(), appVersion: "wc-cli",
            context: .init(
                siteName: ws?.name ?? detected?.name ?? "current repo",
                slug: ws?.slug ?? detected?.slug ?? "—",
                branch: ws?.gitBranch ?? detected?.branch ?? "—",
                liveURL: ws?.configuredLiveURL ?? detected?.liveURL ?? "",
                repoPath: repoPath,
                techStack: ws?.techStack.rawValue ?? detected?.techStack.rawValue ?? "—",
                deployment: ws?.deployment.rawValue ?? detected?.deployment.rawValue ?? "—"),
            consoleErrors: [], consoleWarnings: [], failedRequests: [],
            loadMs: nil, domReadyMs: nil, transferKB: nil,
            audit: [], injection: [], lastAgentError: nil, stagedChanges: 0)
        let file = EditorBridge.writeBrief(brief, repoPath: repoPath)
        FileHandle.standardError.write(Data("Debug brief written to \(file.path)\n".utf8))
        let target = AgentTarget(rawValue: flags["for"] ?? "") ?? .codex
        print(brief.prompt(for: target, briefPath: file.path))
        print("")
        print(brief.markdown(briefPath: file.path))
    }

    // MARK: helpers

    /// Parse `--key value` and bare `--flag` tokens into a dictionary.
    private static func parseFlags(_ args: [String]) -> [String: String] {
        var flags: [String: String] = [:]
        var i = 0
        while i < args.count {
            let token = args[i]
            if token.hasPrefix("--") {
                let key = String(token.dropFirst(2))
                if i + 1 < args.count && !args[i + 1].hasPrefix("--") {
                    flags[key] = args[i + 1]
                    i += 2
                } else {
                    flags[key] = ""   // bare flag (e.g. --approve)
                    i += 1
                }
            } else {
                i += 1
            }
        }
        return flags
    }

    /// Positional (non-flag) tokens; a flag's value is skipped with its flag.
    private static func parsePositionals(_ args: [String]) -> [String] {
        var positionals: [String] = []
        var i = 0
        while i < args.count {
            let token = args[i]
            if token.hasPrefix("--") {
                i += (i + 1 < args.count && !args[i + 1].hasPrefix("--")) ? 2 : 1
            } else {
                positionals.append(token)
                i += 1
            }
        }
        return positionals
    }

    private static func emitJSON(_ object: [String: Any]) {
        if let data = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]),
           let string = String(data: data, encoding: .utf8) {
            print(string)
        }
    }

    private static func printHelp() {
        print("""
        Website Commander CLI

        USAGE:
          wc sites                                   List connected sites (JSON)
          wc sites add [options]                     Connect a repo (auto-detects from
                                                     the current checkout when --owner/
                                                     --repo are omitted)
              options: --owner --repo --name --branch --stack --deploy --url --model --hook
          wc providers                               List AI providers (JSON)
          wc use <site> <prompt…> [--approve] [--model M]
                                                     Run the in-app agent on a site
          wc debug [--for codex|claude|opencode|cursor|vscode|clipboard]
                                                     Write a debug brief into the repo
                                                     and print an agent-ready prompt
          wc help                                    Show this help

        EXAMPLES (for an outer agent in a repo directory):
          wc sites add --name "My Portfolio"         # detects owner/repo/stack/deploy
          wc debug                                   # hand the current site's brief to you
          wc use "My Portfolio" add a contact form --approve

        NOTES:
          Shares the GUI app's settings and Keychain. Configure a GitHub token and an
          AI provider in the app before `wc use`. Without --approve, the agent stages
          changes but does NOT commit them. `wc debug` writes
          .website-commander/debug-brief.md so any agent with the repo open can read it.
        """)
    }
}
