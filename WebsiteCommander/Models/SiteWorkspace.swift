import Foundation

/// The static-site / framework family a workspace uses. Drives the agent's
/// conventions and the icon shown across the UI.
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

    var icon: String {
        switch self {
        case .vanillaHTML: return "globe"
        case .hugo:        return "doc.text.fill"
        case .jekyll:      return "book.closed.fill"
        case .nextjs:      return "app.window.reference"
        case .astro:       return "sparkles"
        case .sveltekit:   return "s.square.fill"
        case .eleventy:    return "11.square.fill"
        case .custom:      return "terminal.fill"
        }
    }
}

/// Where the site is hosted. Determines the post-commit redeploy note.
enum DeploymentType: String, Codable, CaseIterable, Identifiable {
    case cloudflarePages = "Cloudflare Pages"
    case vercel = "Vercel"
    case netlify = "Netlify"
    case githubPages = "GitHub Pages"
    case sshFtp = "SSH/SFTP"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .cloudflarePages: return "cloud.fill"
        case .vercel:          return "triangle.fill"
        case .netlify:         return "network"
        case .githubPages:     return "book.pages"
        case .sshFtp:          return "terminal"
        }
    }

    /// Shown after a successful commit. Git-push hosts auto-redeploy; SSH/SFTP
    /// does not, so it must not promise a deploy that won't happen.
    var redeployNote: String {
        switch self {
        case .cloudflarePages: return "Cloudflare Pages will redeploy shortly."
        case .vercel:          return "Vercel will redeploy shortly."
        case .netlify:         return "Netlify will redeploy shortly."
        case .githubPages:     return "GitHub Pages will rebuild shortly."
        case .sshFtp:          return "SSH/SFTP isn't auto-deployed — sync the change to your server."
        }
    }
}

/// Workspace-scoped facts the agent treats as approved context (brand voice,
/// standards, protection boundaries). Optional and additive.
struct SiteProfile: Codable, Equatable {
    var brandVoice: String = ""
    var audience: String = ""
    var approvedTerminology: String = ""
    var designTokens: String = ""
    var accessibilityRequirements: String = ""
    var protectedRules: String = ""

    var isEmpty: Bool {
        [brandVoice, audience, approvedTerminology, designTokens,
         accessibilityRequirements, protectedRules]
            .allSatisfy { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    var promptContext: String {
        [
            ("Brand voice", brandVoice),
            ("Audience", audience),
            ("Approved terminology", approvedTerminology),
            ("Design tokens", designTokens),
            ("Accessibility requirements", accessibilityRequirements),
            ("Never change without explicit approval", protectedRules)
        ]
        .filter { !$0.1.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        .map { "- \($0.0): \($0.1)" }
        .joined(separator: "\n")
    }
}

/// A connected website: a GitHub repo plus the metadata the agent needs.
struct SiteWorkspace: Identifiable, Codable, Equatable {
    var id: UUID = UUID()
    var name: String
    var gitOwner: String
    var gitRepo: String
    var gitBranch: String
    /// The GitHub account used for this site. `nil` = the default/legacy account.
    var githubCredentialID: UUID? = nil
    var techStack: TechStack
    var deployment: DeploymentType
    var defaultModel: String
    var customRules: String = ""
    var siteProfile: SiteProfile? = nil
    var deploymentConfig: [String: String] = [:]
    /// Optional per-site accent (hex like "#33B8C7"). `nil` = derive from name.
    var accentHex: String? = nil
    /// Free-text per-site memory the agent prepends to its context every run
    /// (e.g. "the contact form posts to /api/lead; never touch /legacy").
    var memory: String = ""

    var slug: String { "\(gitOwner)/\(gitRepo)" }

    /// Best-effort live site URL from deployment config.
    var configuredLiveURL: String {
        (deploymentConfig["liveURL"] ?? deploymentConfig["url"] ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Accepts bare domains (e.g. `example.com`) and adds `https://` when needed.
    static func normalizedLiveURL(_ raw: String) -> URL? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              !trimmed.contains(where: { $0.isWhitespace }) else { return nil }
        // Preserve an explicitly supplied scheme so unsafe values such as
        // `file:` or `javascript:` cannot be mistaken for bare domains.
        if let suppliedScheme = URLComponents(string: trimmed)?.scheme,
           !["http", "https"].contains(suppliedScheme.lowercased()) {
            return nil
        }
        let normalized = URLComponents(string: trimmed)?.scheme != nil
            ? trimmed : "https://\(trimmed)"
        guard let components = URLComponents(string: normalized),
              let scheme = components.scheme?.lowercased(),
              ["http", "https"].contains(scheme),
              let host = components.host,
              !host.isEmpty,
              !host.contains(" ") else { return nil }
        return components.url
    }

    // MARK: - Tolerant decoding

    /// Explicit memberwise initializer (defining `init(from:)` below suppresses the
    /// synthesized one, so we restate it to keep every `SiteWorkspace(...)` call
    /// site compiling).
    init(id: UUID = UUID(), name: String, gitOwner: String, gitRepo: String, gitBranch: String,
         githubCredentialID: UUID? = nil, techStack: TechStack, deployment: DeploymentType,
         defaultModel: String, customRules: String = "", siteProfile: SiteProfile? = nil,
         deploymentConfig: [String: String] = [:], accentHex: String? = nil, memory: String = "") {
        self.id = id
        self.name = name
        self.gitOwner = gitOwner
        self.gitRepo = gitRepo
        self.gitBranch = gitBranch
        self.githubCredentialID = githubCredentialID
        self.techStack = techStack
        self.deployment = deployment
        self.defaultModel = defaultModel
        self.customRules = customRules
        self.siteProfile = siteProfile
        self.deploymentConfig = deploymentConfig
        self.accentHex = accentHex
        self.memory = memory
    }

    /// Forward/backward tolerant: any missing key falls back to a sensible default
    /// instead of failing the whole load (which would wipe the user's sites when a
    /// future field is added). `encode(to:)` stays synthesized.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? c.decode(UUID.self, forKey: .id)) ?? UUID()
        name = (try? c.decode(String.self, forKey: .name)) ?? ""
        gitOwner = (try? c.decode(String.self, forKey: .gitOwner)) ?? ""
        gitRepo = (try? c.decode(String.self, forKey: .gitRepo)) ?? ""
        gitBranch = (try? c.decode(String.self, forKey: .gitBranch)) ?? "main"
        githubCredentialID = try? c.decode(UUID?.self, forKey: .githubCredentialID) ?? nil
        techStack = (try? c.decode(TechStack.self, forKey: .techStack)) ?? .vanillaHTML
        deployment = (try? c.decode(DeploymentType.self, forKey: .deployment)) ?? .githubPages
        defaultModel = (try? c.decode(String.self, forKey: .defaultModel)) ?? ""
        customRules = (try? c.decode(String.self, forKey: .customRules)) ?? ""
        siteProfile = try? c.decode(SiteProfile?.self, forKey: .siteProfile) ?? nil
        deploymentConfig = (try? c.decode([String: String].self, forKey: .deploymentConfig)) ?? [:]
        accentHex = try? c.decode(String?.self, forKey: .accentHex) ?? nil
        memory = (try? c.decode(String.self, forKey: .memory)) ?? ""
    }
}
