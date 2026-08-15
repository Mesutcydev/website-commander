import Foundation

/// URL constants are part of the app's protocol configuration, but keeping a
/// force-unwrap at an API boundary turns a harmless typo or bad merge into a
/// process-wide crash. Invalid constants become a non-networking file URL so
/// the caller's existing request/error handling can show a fallback instead.
enum SiteAgentURL {
    static func constant(_ raw: String) -> URL {
        URL(string: raw) ?? URL(fileURLWithPath: "/")
    }
}

enum TechStack: String, Codable, CaseIterable, Identifiable {
    case vanillaHTML = "Vanilla HTML/JS"
    case hugo = "Hugo"
    case jekyll = "Jekyll"
    case nextjs = "Next.js"
    case astro = "Astro"
    case sveltekit = "SvelteKit"
    case eleventy = "Eleventy"
    case custom = "Custom"

    var id: String { rawValue }
}

enum DeploymentType: String, Codable, CaseIterable, Identifiable {
    case cloudflarePages = "Cloudflare Pages"
    case cloudflareWorkers = "Cloudflare Workers"
    case vercel = "Vercel"
    case netlify = "Netlify"
    case render = "Render"
    case railway = "Railway"
    case awsAmplify = "AWS Amplify"
    case githubPages = "GitHub Pages"
    case sshFtp = "SSH/SFTP"

    var id: String { rawValue }

    var displayName: String { rawValue }

    var icon: String {
        switch self {
        case .cloudflarePages: return "cloud.fill"
        case .cloudflareWorkers: return "bolt.horizontal.fill"
        case .vercel: return "triangle.fill"
        case .netlify: return "network"
        case .render: return "server.rack"
        case .railway: return "train.side.front.car"
        case .awsAmplify: return "bolt.horizontal.circle.fill"
        case .githubPages: return "book.pages"
        case .sshFtp: return "terminal"
        }
    }

    /// The line shown after a successful commit. Git-push-triggered hosts
    /// auto-redeploy; SSH/SFTP does not, so it must not promise a deploy that
    /// won't happen. (Replaces the previous hardcoded "Cloudflare" message.)
    var redeployNote: String {
        switch self {
        case .cloudflarePages: return "Cloudflare Pages will redeploy shortly."
        case .cloudflareWorkers: return "Cloudflare Workers will rebuild shortly (via the deploy hook)."
        case .vercel:          return "Vercel will redeploy shortly."
        case .netlify:         return "Netlify will redeploy shortly."
        case .render:          return "Render will redeploy shortly."
        case .railway:         return "Railway will redeploy shortly."
        case .awsAmplify:      return "AWS Amplify will rebuild shortly (via the deploy hook or git push)."
        case .githubPages:     return "GitHub Pages will rebuild shortly."
        case .sshFtp:          return "SSH/SFTP isn't auto-deployed — sync the change to your server."
        }
    }
}

/// Workspace-scoped facts the agent should treat as approved context (brand
/// voice, standards, and protection boundaries). Optional and additive — nil
/// for every workspace created before this existed.
struct SiteProfile: Codable, Equatable {
    var brandVoice: String = ""
    var audience: String = ""
    var approvedTerminology: String = ""
    var designTokens: String = ""
    var accessibilityRequirements: String = ""
    var deploymentConventions: String = ""
    var protectedRules: String = ""
    var lastConfirmedAt: Date?

    var isEmpty: Bool {
        [
            brandVoice,
            audience,
            approvedTerminology,
            designTokens,
            accessibilityRequirements,
            deploymentConventions,
            protectedRules
        ].allSatisfy { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    var promptContext: String {
        [
            ("Brand voice", brandVoice),
            ("Audience", audience),
            ("Approved terminology", approvedTerminology),
            ("Design tokens", designTokens),
            ("Accessibility requirements", accessibilityRequirements),
            ("Deployment conventions", deploymentConventions),
            ("Never change without explicit approval", protectedRules)
        ]
        .filter { !$0.1.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        .map { "- \($0.0): \($0.1)" }
        .joined(separator: "\n")
    }
}

struct SiteWorkspace: Identifiable, Codable, Equatable {
    var id: UUID = UUID()
    var name: String
    var gitOwner: String
    var gitRepo: String
    var gitBranch: String
    /// Credential used for this website. `nil` keeps compatibility with the
    /// original, single-account GitHub connection.
    var githubCredentialID: UUID? = nil
    var techStack: TechStack
    var deployment: DeploymentType
    var defaultModel: String
    var customRules: String = ""
    /// Optional workspace-scoped facts (brand, standards, approval boundaries).
    /// `nil` for every workspace saved before this existed.
    var siteProfile: SiteProfile? = nil
    var deploymentConfig: [String: String] = [:]
    
    var slug: String { "\(gitOwner)/\(gitRepo)" }

    /// Best-effort live site string from deployment config (`liveURL` preferred).
    /// Older workspaces and the deployment wizard have used a few equivalent
    /// keys, so preview should not lose the live-site fallback just because the
    /// value was saved under an older name.
    var configuredLiveURL: String {
        ["liveURL", "url", "siteURL", "domain"]
            .compactMap { deploymentConfig[$0] }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty } ?? ""
    }

    /// Accepts bare domains (e.g. `mesut.uk`) and adds `https://` when needed.
    static func normalizedLiveURL(_ raw: String) -> URL? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let normalized: String
        if let schemeSeparator = trimmed.range(of: "://") {
            let scheme = String(trimmed[..<schemeSeparator.lowerBound]).lowercased()
            guard ["http", "https"].contains(scheme) else { return nil }
            normalized = trimmed
        } else {
            normalized = "https://\(trimmed)"
        }
        guard let url = URL(string: normalized),
              let scheme = url.scheme?.lowercased(),
              ["http", "https"].contains(scheme),
              url.host != nil else { return nil }
        return url
    }

    /// Best-effort URL to use when a workspace predates the saved liveURL
    /// field. Connected sites are commonly named after their public domain,
    /// while Workers projects can expose their conventional workers.dev URL
    /// through deployment metadata.
    var previewURLCandidate: URL? {
        if let configured = Self.normalizedLiveURL(configuredLiveURL) {
            return configured
        }

        // Provider-derived URLs are more authoritative than a domain guessed
        // from the workspace name. A renamed custom domain (for example a
        // workspace still named after its old repository) must not route the
        // preview to the stale guess.
        if deployment == .cloudflareWorkers {
            let worker = deploymentConfig["cloudflareWorkerName"]?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let subdomain = deploymentConfig["cloudflareAccountSubdomain"]?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !worker.isEmpty, !subdomain.isEmpty,
               let derived = Self.normalizedLiveURL("\(worker).\(subdomain).workers.dev") {
                return derived
            }
        }

        if let inferred = Self.domainURL(from: name) {
            return inferred
        }

        return nil
    }

    /// Extract a production URL declared by a repository's deployment config.
    /// This is deliberately limited to explicit site/homepage keys and
    /// Cloudflare route patterns; arbitrary URLs in source files are not
    /// treated as the live site.
    static func repositoryConfiguredLiveURL(source: String) -> URL? {
        let patterns = [
            #"(?im)\b(?:NEXT_PUBLIC_SITE_URL|PUBLIC_SITE_URL|SITE_URL|HOMEPAGE)\s*[:=]\s*["']([^"']+)["']"#,
            #"(?im)\bpattern\s*=\s*["']((?:https?://)?(?:www\.)?[A-Za-z0-9.-]+\.[A-Za-z]{2,})["']"#
        ]

        let sourceRange = NSRange(source.startIndex..<source.endIndex, in: source)
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            for match in regex.matches(in: source, range: sourceRange) {
                guard let valueRange = Range(match.range(at: 1), in: source) else { continue }
                if let url = normalizedLiveURL(String(source[valueRange])) {
                    return url
                }
            }
        }
        return nil
    }

    private static func domainURL(from raw: String) -> URL? {
        let candidate = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard candidate.contains("."),
              !candidate.contains(where: { $0.isWhitespace }),
              !candidate.contains("/"),
              !candidate.contains(":") else { return nil }
        return normalizedLiveURL(candidate)
    }
}
