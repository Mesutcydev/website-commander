import Foundation

enum LocalWorkspaceError: LocalizedError {
    case gitMissing
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .gitMissing:
            return "git wasn't found on this machine. Install Xcode command line tools."
        case .failed(let msg):
            return "git error: \(msg)"
        }
    }
}

/// Manages a local git clone per workspace so the site can be opened and edited
/// in VSCode. The core agent loop talks to GitHub's API directly and does not
/// require a clone; this store powers the "Open in VSCode" workflow and lets the
/// agent read the user's local edits.
struct LocalWorkspaceStore {

    /// Root folder holding one subfolder per workspace (`owner/repo`).
    static var rootDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("WebsiteCommander/Workspaces", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    /// The local folder for a workspace (created on demand by `ensureClone`).
    static func localPath(for workspace: SiteWorkspace) -> URL {
        rootDirectory
            .appendingPathComponent(workspace.gitOwner, isDirectory: true)
            .appendingPathComponent(workspace.gitRepo, isDirectory: true)
    }

    static func isCloned(_ workspace: SiteWorkspace) -> Bool {
        var isDir: ObjCBool = false
        let path = localPath(for: workspace).appendingPathComponent(".git")
        return FileManager.default.fileExists(atPath: path.path, isDirectory: &isDir)
    }

    /// Clone the repo if missing; otherwise fast-forward to the remote branch.
    /// A fast-forward-only merge preserves uncommitted local edits (the
    /// "Open in VSCode and edit" workflow) instead of `reset --hard` wiping
    /// them; a divergent or conflicting clone surfaces a git error instead of
    /// silently destroying work. Auth is passed transiently via an HTTP header
    /// so the token is NEVER written to `.git/config`.
    static func ensureClone(_ workspace: SiteWorkspace, token: String) async throws -> URL {
        let dest = localPath(for: workspace)
        let cleanURL = remoteURL(for: workspace)
        if isCloned(workspace) {
            try await runGit(["-C", dest.path] + authArgs(token) + ["fetch", "origin", workspace.gitBranch])
            try await runGit(["-C", dest.path, "merge", "--ff-only", "origin/\(workspace.gitBranch)"])
        } else {
            try? FileManager.default.createDirectory(
                at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
            try await runGit(authArgs(token) +
                             ["clone", "--branch", workspace.gitBranch,
                              "--single-branch", cleanURL, dest.path])
        }
        return dest
    }

    /// Pull latest changes from the remote branch into the local clone.
    static func pull(_ workspace: SiteWorkspace, token: String) async throws {
        guard isCloned(workspace) else {
            _ = try await ensureClone(workspace, token: token)
            return
        }
        let dest = localPath(for: workspace)
        try await runGit(["-C", dest.path] + authArgs(token) + ["fetch", "origin", workspace.gitBranch])
        try await runGit(["-C", dest.path, "reset", "--hard", "origin/\(workspace.gitBranch)"])
    }

    /// A clean (token-free) clone URL. Credentials are supplied per-command via
    /// `authArgs`, never embedded here, so nothing sensitive is persisted.
    private static func remoteURL(for workspace: SiteWorkspace) -> String {
        "https://github.com/\(workspace.gitOwner)/\(workspace.gitRepo).git"
    }

    /// Git `-c` args that attach an Authorization header for this one command only.
    private static func authArgs(_ token: String) -> [String] {
        let basic = Data("x-access-token:\(token)".utf8).base64EncodedString()
        return ["-c", "http.extraheader=Authorization: Basic \(basic)"]
    }

    /// Run a git command off the main actor and surface stderr on failure.
    private static func runGit(_ arguments: [String]) async throws {
        let gitPath = "/usr/bin/git"
        guard FileManager.default.isExecutableFile(atPath: gitPath) else {
            throw LocalWorkspaceError.gitMissing
        }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: gitPath)
                process.arguments = arguments
                let errPipe = Pipe()
                process.standardError = errPipe
                do {
                    try process.run()
                    process.waitUntilExit()
                    let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
                    let errText = String(data: errData, encoding: .utf8)?
                        .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    if process.terminationStatus == 0 {
                        continuation.resume()
                    } else {
                        // Don't leak the embedded token into error text.
                        let safe = errText.replacingOccurrences(
                            of: "x-access-token:[^@]+@", with: "x-access-token:***@",
                            options: .regularExpression)
                        continuation.resume(throwing: LocalWorkspaceError.failed(safe))
                    }
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
}
