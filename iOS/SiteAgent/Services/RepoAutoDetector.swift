import Foundation

struct RepoDetectionResult: Equatable {
    var techStack: TechStack
    var buildCommand: String?
    var outputDirectory: String?
    var rootDirectory: String?
    var notes: [String]
    /// Best-guess hosting target for the Connect wizard (nil = unknown).
    var suggestedDeployment: DeploymentType?
    /// Parsed `name = "..."` from wrangler.toml when present.
    var suggestedWorkerName: String?
    var suggestedLiveURL: String?
}

enum RepoAutoDetector {
    static func detect(
        entries: [RepoEntry],
        packageJSON: String?,
        wranglerTOML: String? = nil,
        homepageURL: String? = nil
    ) -> RepoDetectionResult {
        let paths = Set(entries.map { $0.path.lowercased() })
        let names = Set(entries.map { $0.name.lowercased() })
        var notes: [String] = []
        var stack: TechStack = .vanillaHTML
        var buildCommand: String?
        var outputDirectory: String?
        var suggestedDeployment: DeploymentType?
        var suggestedWorkerName: String?

        if paths.contains("astro.config.mjs") || paths.contains("astro.config.ts") {
            stack = .astro
            buildCommand = "npm run build"
            outputDirectory = "dist"
        } else if paths.contains("next.config.js") || paths.contains("next.config.mjs") || paths.contains("next.config.ts") {
            stack = .nextjs
            buildCommand = "npm run build"
            outputDirectory = ".next"
        } else if paths.contains("svelte.config.js") || paths.contains("svelte.config.ts") {
            stack = .sveltekit
            buildCommand = "npm run build"
            outputDirectory = "build"
        } else if names.contains("config.toml") && (paths.contains("hugo.toml") || paths.contains("hugo.yaml") || paths.contains("hugo.json") || paths.contains("content")) {
            stack = .hugo
            buildCommand = "hugo"
            outputDirectory = "public"
        } else if paths.contains("_config.yml") {
            stack = .jekyll
            buildCommand = "bundle exec jekyll build"
            outputDirectory = "_site"
        } else if paths.contains(".eleventy.js") || paths.contains("eleventy.config.js") || paths.contains("eleventy.config.mjs") {
            stack = .eleventy
            buildCommand = "npm run build"
            outputDirectory = "_site"
        } else if paths.contains("package.json") {
            stack = .custom
            buildCommand = "npm run build"
            outputDirectory = "dist"
        }

        if let packageJSON, let package = parsePackage(packageJSON) {
            let scripts = package["scripts"] as? [String: Any] ?? [:]
            if scripts["build"] is String {
                buildCommand = "npm run build"
            }
            if let dependencies = package["dependencies"] as? [String: Any],
               dependencies["@astrojs/react"] != nil || dependencies["astro"] != nil {
                stack = .astro
                outputDirectory = outputDirectory ?? "dist"
            }
            if let dependencies = package["dependencies"] as? [String: Any],
               dependencies["next"] != nil {
                stack = .nextjs
            }
            if let dependencies = package["dependencies"] as? [String: Any],
               dependencies["@sveltejs/kit"] != nil {
                stack = .sveltekit
            }
        }

        let hasWrangler = paths.contains("wrangler.toml")
            || paths.contains("wrangler.json")
            || paths.contains("wrangler.jsonc")
        if hasWrangler {
            notes.append("Cloudflare Workers (Wrangler) detected — connect with a deploy hook for automatic publishes.")
            suggestedDeployment = .cloudflareWorkers
            if let wranglerTOML {
                suggestedWorkerName = parseWranglerName(wranglerTOML)
            }
        }
        if paths.contains("netlify.toml") {
            notes.append("Netlify config detected.")
            if suggestedDeployment == nil { suggestedDeployment = .netlify }
        }
        if paths.contains("vercel.json") {
            notes.append("Vercel config detected.")
            if suggestedDeployment == nil { suggestedDeployment = .vercel }
        }
        if paths.contains(".github/workflows")
            || entries.contains(where: { $0.path.lowercased().hasPrefix(".github/workflows/") }) {
            notes.append("GitHub Actions workflows detected.")
        }
        // Static sites without a host config often ship on GitHub Pages.
        if suggestedDeployment == nil,
           stack == .vanillaHTML || stack == .jekyll || stack == .hugo || stack == .eleventy {
            suggestedDeployment = .githubPages
        }

        let live = homepageURL?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let suggestedLive = (live?.isEmpty == false) ? live : nil

        return RepoDetectionResult(
            techStack: stack,
            buildCommand: buildCommand,
            outputDirectory: outputDirectory,
            rootDirectory: nil,
            notes: notes,
            suggestedDeployment: suggestedDeployment,
            suggestedWorkerName: suggestedWorkerName,
            suggestedLiveURL: suggestedLive
        )
    }

    /// Extract `name = "worker-name"` (or JSON `"name": "..."`) from wrangler config text.
    static func parseWranglerName(_ text: String) -> String? {
        let patterns = [
            #"^\s*name\s*=\s*\"([^\"]+)\""#,
            #"^\s*name\s*=\s*'([^']+)'"#,
            #""name"\s*:\s*\"([^\"]+)\""#
        ]
        for pattern in patterns {
            guard let re = try? NSRegularExpression(pattern: pattern, options: [.anchorsMatchLines]) else { continue }
            let range = NSRange(text.startIndex..., in: text)
            if let match = re.firstMatch(in: text, options: [], range: range),
               match.numberOfRanges >= 2,
               let nameRange = Range(match.range(at: 1), in: text) {
                let name = String(text[nameRange]).trimmingCharacters(in: .whitespacesAndNewlines)
                if !name.isEmpty { return name }
            }
        }
        return nil
    }

    private static func parsePackage(_ text: String) -> [String: Any]? {
        guard let data = text.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }
}

struct SiteAuditIssue: Identifiable, Equatable {
    let id = UUID()
    var title: String
    var detail: String
    var severity: Severity

    enum Severity: String {
        case info = "Info"
        case warning = "Warning"
        case critical = "Critical"
    }
}

enum LightweightSiteAuditor {
    static func audit(html: String, metrics: PerformanceMetrics, requests: [NetworkRequest], logs: [ConsoleLog]) -> [SiteAuditIssue] {
        var issues: [SiteAuditIssue] = []
        let lower = html.lowercased()

        if !lower.contains("<title") {
            issues.append(.init(title: "Missing title", detail: "The page has no title tag.", severity: .critical))
        }
        if !lower.contains("name=\"description\"") && !lower.contains("name='description'") {
            issues.append(.init(title: "Missing meta description", detail: "Search previews may use weak fallback copy.", severity: .warning))
        }
        if lower.contains("<img") && missingAltCount(in: lower) > 0 {
            issues.append(.init(title: "Images missing alt text", detail: "\(missingAltCount(in: lower)) image tag(s) do not include alt text.", severity: .warning))
        }
        if metrics.loadTime > 3_000 {
            issues.append(.init(title: "Slow load", detail: "Load time is above 3 seconds in the preview.", severity: .warning))
        }
        let failedRequests = requests.filter { $0.status >= 400 }
        if !failedRequests.isEmpty {
            issues.append(.init(title: "Failed network requests", detail: "\(failedRequests.count) request(s) returned 4xx/5xx responses.", severity: .critical))
        }
        let consoleErrors = logs.filter { $0.level == "error" }
        if !consoleErrors.isEmpty {
            issues.append(.init(title: "Console errors", detail: "\(consoleErrors.count) JavaScript/runtime error(s) were captured.", severity: .critical))
        }
        if issues.isEmpty {
            issues.append(.init(title: "No major issues", detail: "Preview checks did not find obvious SEO, accessibility, performance, or runtime problems.", severity: .info))
        }
        return issues
    }

    private static func missingAltCount(in lowerHTML: String) -> Int {
        let pattern = "<img\\b(?![^>]*\\balt\\s*=)[^>]*>"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return 0 }
        return regex.numberOfMatches(in: lowerHTML, range: NSRange(lowerHTML.startIndex..., in: lowerHTML))
    }
}
