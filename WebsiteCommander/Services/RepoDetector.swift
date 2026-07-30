import Foundation

/// The repository facts we can infer from a local checkout, with no network.
/// Used by the CLI (`wc add` / `wc debug`) so an outer agent sitting in a repo
/// directory can hand the current site to Website Commander without being told
/// the owner/repo, and by the GUI where useful.
struct DetectedRepo: Equatable {
    var owner: String
    var repo: String
    var branch: String
    var techStack: TechStack
    var deployment: DeploymentType
    var liveURL: String
    var name: String

    var slug: String { "\(owner)/\(repo)" }
}

enum RepoDetector {

    /// Inspect the git checkout at `dir` (defaults to the current directory).
    static func detect(at dir: URL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)) -> DetectedRepo? {
        guard let remote = git(["-C", dir.path, "config", "--get", "remote.origin.url"]),
              let parsed = parseRemote(remote) else { return nil }
        let branch = git(["-C", dir.path, "rev-parse", "--abbrev-ref", "HEAD"]) ?? "main"
        let stack = detectStack(at: dir)
        let deploy = detectDeployment(at: dir)
        let cname = readFile(dir.appendingPathComponent("CNAME"))?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let liveURL = cname.isEmpty ? "" : "https://\(cname)"
        return DetectedRepo(owner: parsed.owner, repo: parsed.repo, branch: branch,
                            techStack: stack, deployment: deploy, liveURL: liveURL,
                            name: parsed.repo)
    }

    // MARK: Remote parsing

    static func parseRemote(_ remote: String) -> (owner: String, repo: String)? {
        let r = remote.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: ".git", with: "")
        // SSH:  git@github.com:owner/repo
        if let range = r.range(of: ":") , r.contains("@") {
            let tail = String(r[range.upperBound...])
            let parts = tail.split(separator: "/")
            if parts.count >= 2 { return (String(parts[parts.count - 2]), String(parts[parts.count - 1])) }
        }
        // HTTPS: https://github.com/owner/repo
        if let url = URL(string: r) {
            let comps = url.pathComponents.filter { $0 != "/" }
            if comps.count >= 2 { return (comps[comps.count - 2], comps[comps.count - 1]) }
        }
        return nil
    }

    // MARK: Tech stack heuristics

    private static func detectStack(at dir: URL) -> TechStack {
        let pkg = readFile(dir.appendingPathComponent("package.json"))?.lowercased() ?? ""
        let deps = pkg
        if deps.contains("\"next\"") { return .nextjs }
        if deps.contains("\"astro\"") { return .astro }
        if deps.contains("\"@sveltejs/kit\"") || deps.contains("\"svelte\"") { return .sveltekit }
        if deps.contains("\"@11ty/eleventy\"") { return .eleventy }
        if fileExists(dir, "hugo.toml") || fileExists(dir, "hugo.yaml") || fileExists(dir, "hugo.json") { return .hugo }
        if fileExists(dir, "_config.yml") || fileExists(dir, "_config.yaml") { return .jekyll }
        return .vanillaHTML
    }

    // MARK: Deployment heuristics

    private static func detectDeployment(at dir: URL) -> DeploymentType {
        if fileExists(dir, "wrangler.toml") || fileExists(dir, "wrangler.jsonc") { return .cloudflarePages }
        if fileExists(dir, "vercel.json") || fileExists(dir, ".vercel") { return .vercel }
        if fileExists(dir, "netlify.toml") || fileExists(dir, "netlify") { return .netlify }
        return .githubPages
    }

    // MARK: git + fs helpers

    @discardableResult
    private static func git(_ args: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = args
        let out = Pipe()
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return nil }
            let s = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return s.isEmpty ? nil : s
        } catch {
            return nil
        }
    }

    private static func readFile(_ url: URL) -> String? {
        try? String(contentsOf: url, encoding: .utf8)
    }

    private static func fileExists(_ dir: URL, _ name: String) -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: dir.appendingPathComponent(name).path, isDirectory: &isDir)
    }
}
