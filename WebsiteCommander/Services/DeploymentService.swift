import Foundation

/// The result of attempting to (re)deploy a workspace.
enum DeployResult: Equatable {
    case triggered          // a deploy hook fired successfully
    case autoDeployed       // git-push host rebuilds on its own (e.g. GitHub Pages)
    case manual             // no automation (e.g. SSH/SFTP) — sync by hand
    case noHook             // host supports hooks but none is configured yet
    case failed(String)

    var note: String {
        switch self {
        case .triggered:     return "Deploy hook fired — your host is rebuilding now."
        case .autoDeployed:  return "This host rebuilds automatically on push."
        case .manual:        return "No auto-deploy — sync the change to your server manually."
        case .noHook:        return "Add a deploy hook URL to trigger rebuilds from here."
        case .failed(let m): return "Deploy failed: \(m)"
        }
    }

    var isSuccess: Bool {
        if case .failed = self { return false }
        if case .noHook = self { return false }
        return true
    }
}

/// Triggers redeployments. Git-push hosts rebuild on their own; hook-capable
/// hosts (Cloudflare Pages, Vercel, Netlify) are fired via a stored deploy-hook
/// URL. Hook URLs embed a secret in the path, so they live in the Keychain and
/// are never logged verbatim.
enum DeploymentService {

    private static func hookKey(_ workspaceID: UUID) -> String { "deployhook.\(workspaceID)" }

    static func setHookURL(_ url: String, for workspaceID: UUID) {
        Keychain.set(url.trimmingCharacters(in: .whitespacesAndNewlines), for: hookKey(workspaceID))
    }

    static func hookURL(for workspaceID: UUID) -> String? {
        let raw = Keychain.get(hookKey(workspaceID))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return raw.isEmpty ? nil : raw
    }

    static var supportsHook: (DeploymentType) -> Bool = { type in
        switch type {
        case .cloudflarePages, .vercel, .netlify: return true
        case .githubPages, .sshFtp: return false
        }
    }

    /// Attempt to redeploy a workspace.
    static func trigger(for workspace: SiteWorkspace) async -> DeployResult {
        switch workspace.deployment {
        case .githubPages:
            return .autoDeployed
        case .sshFtp:
            return .manual
        case .cloudflarePages, .vercel, .netlify:
            guard let raw = hookURL(for: workspace.id), let url = URL(string: raw) else {
                return .noHook
            }
            return await post(url)
        }
    }

    private static func post(_ url: URL) async -> DeployResult {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("WebsiteCommander", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 20
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else { return .failed("no response") }
            if (200..<300).contains(http.statusCode) {
                return .triggered
            }
            return .failed("HTTP \(http.statusCode)")
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    /// Where to find the deploy hook for each host.
    static func hookHelp(for type: DeploymentType) -> String {
        switch type {
        case .cloudflarePages:
            return "Cloudflare dashboard → Workers & Pages → your project → Settings → Builds → Deploy Hooks."
        case .vercel:
            return "Vercel → Project → Settings → Git → Deploy Hooks."
        case .netlify:
            return "Netlify → Site → Site configuration → Build & deploy → Build hooks."
        case .githubPages:
            return "GitHub Pages rebuilds automatically on push — no hook needed."
        case .sshFtp:
            return "SSH/SFTP has no automation here — sync your build to the server manually."
        }
    }
}
