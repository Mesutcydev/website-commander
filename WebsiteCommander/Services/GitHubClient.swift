import Foundation

enum GitHubError: LocalizedError {
    case noToken
    case http(Int, String)
    case decoding(String)
    case notFound(String)

    var errorDescription: String? {
        switch self {
        case .noToken:
            return "No GitHub token. Add one in Settings → GitHub."
        case .http(let code, let body):
            return "GitHub error \(code): \(body)"
        case .decoding(let what):
            return "Couldn't read GitHub response: \(what)"
        case .notFound(let what):
            return "Not found: \(what)"
        }
    }
}

/// A minimal GitHub REST client covering everything the agent needs: list repos,
/// browse & read files, commit a file change, and read commit history. Uses the
/// contents API (base64 blobs) so no local git is required for the core loop.
struct GitHubClient {

    let token: String
    var apiBase: String = "https://api.github.com"

    private var session: URLSession { .shared }

    private func request(_ path: String, method: String = "GET",
                         body: [String: Any]? = nil) async throws -> (Data, HTTPURLResponse) {
        guard !token.isEmpty else { throw GitHubError.noToken }
        var req = URLRequest(url: URL(string: apiBase + path)!)
        req.httpMethod = method
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        if let body {
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse else {
            throw GitHubError.decoding("no HTTP response")
        }
        guard (200..<300).contains(http.statusCode) else {
            let msg = String(data: data, encoding: .utf8) ?? ""
            throw GitHubError.http(http.statusCode, String(msg.prefix(300)))
        }
        return (data, http)
    }

    private func json(_ data: Data) throws -> Any {
        try JSONSerialization.jsonObject(with: data)
    }

    // MARK: Repos

    /// Repos the token can see, most recently updated first.
    func listRepos() async throws -> [GitHubRepoSummary] {
        let (data, _) = try await request("/user/repos?per_page=100&sort=updated&affiliation=owner,collaborator,organization_member")
        guard let arr = try json(data) as? [[String: Any]] else {
            throw GitHubError.decoding("repos list")
        }
        return arr.compactMap { obj in
            guard let id = obj["id"] as? Int,
                  let name = obj["name"] as? String,
                  let fullName = obj["full_name"] as? String,
                  let ownerObj = obj["owner"] as? [String: Any],
                  let owner = ownerObj["login"] as? String else { return nil }
            let home = (obj["homepage"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            return GitHubRepoSummary(
                id: id,
                owner: owner,
                name: name,
                fullName: fullName,
                defaultBranch: (obj["default_branch"] as? String) ?? "main",
                homepage: (home?.isEmpty == false) ? home : nil,
                isPrivate: (obj["private"] as? Bool) ?? false
            )
        }
    }

    // MARK: Contents

    /// List entries at `path` ("" = repo root).
    func contents(owner: String, repo: String, path: String, branch: String) async throws -> [RepoEntry] {
        let encoded = path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? path
        let (data, _) = try await request("/repos/\(owner)/\(repo)/contents/\(encoded)?ref=\(branch)")
        guard let arr = try json(data) as? [[String: Any]] else {
            throw GitHubError.decoding("contents")
        }
        return arr.map { obj in
            RepoEntry(
                path: (obj["path"] as? String) ?? "",
                type: (obj["type"] as? String) == "dir" ? .dir : .file,
                sha: obj["sha"] as? String,
                size: obj["size"] as? Int
            )
        }
        .sorted { ($0.type == $1.type) ? ($0.name < $1.name) : ($0.type == .dir) }
    }

    /// Read a file's UTF-8 content and its blob SHA.
    func fileContent(owner: String, repo: String, path: String, branch: String) async throws -> (content: String, sha: String) {
        let encoded = path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? path
        let (data, _) = try await request("/repos/\(owner)/\(repo)/contents/\(encoded)?ref=\(branch)")
        guard let obj = try json(data) as? [String: Any] else {
            throw GitHubError.decoding("file content")
        }
        let sha = (obj["sha"] as? String) ?? ""
        let raw = (obj["content"] as? String) ?? ""
        let cleaned = raw.replacingOccurrences(of: "\n", with: "")
        let decoded = Data(base64Encoded: cleaned).flatMap { String(data: $0, encoding: .utf8) } ?? ""
        return (decoded, sha)
    }

    /// Create or update a file and commit it in one call. Pass `sha` to update an
    /// existing file (GitHub requires it; also guards against clobbering edits).
    @discardableResult
    func commitFile(owner: String, repo: String, path: String, content: String,
                    message: String, branch: String, sha: String? = nil) async throws -> String {
        let encoded = path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? path
        var body: [String: Any] = [
            "message": message,
            "content": Data(content.utf8).base64EncodedString(),
            "branch": branch
        ]
        if let sha { body["sha"] = sha }
        let (data, _) = try await request("/repos/\(owner)/\(repo)/contents/\(encoded)",
                                          method: "PUT", body: body)
        guard let obj = try json(data) as? [String: Any],
              let commit = obj["commit"] as? [String: Any],
              let newSHA = commit["sha"] as? String else {
            throw GitHubError.decoding("commit result")
        }
        return newSHA
    }

    /// Delete a file (requires its blob SHA).
    func deleteFile(owner: String, repo: String, path: String, message: String,
                    branch: String, sha: String) async throws {
        let encoded = path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? path
        let body: [String: Any] = ["message": message, "sha": sha, "branch": branch]
        _ = try await request("/repos/\(owner)/\(repo)/contents/\(encoded)", method: "DELETE", body: body)
    }

    // MARK: History

    func commits(owner: String, repo: String, branch: String, limit: Int = 30) async throws -> [CommitEntry] {
        let (data, _) = try await request("/repos/\(owner)/\(repo)/commits?sha=\(branch)&per_page=\(limit)")
        guard let arr = try json(data) as? [[String: Any]] else {
            throw GitHubError.decoding("commits")
        }
        let df = ISO8601DateFormatter()
        return arr.compactMap { obj in
            guard let sha = obj["sha"] as? String,
                  let commit = obj["commit"] as? [String: Any],
                  let message = commit["message"] as? String else { return nil }
            let author = ((commit["author"] as? [String: Any])?["name"] as? String) ?? "unknown"
            let dateStr = ((commit["author"] as? [String: Any])?["date"] as? String) ?? ""
            let date = df.date(from: dateStr) ?? Date()
            return CommitEntry(sha: sha, message: message, author: author, date: date)
        }
    }

    // MARK: Connection test

    /// The login plus the granted OAuth scopes for this token (via GET /user).
    /// `scopes` is empty for fine-grained PATs (github_pat_…), whose permissions
    /// aren't exposed in this header — callers should treat that as "unknown,
    /// verify per-repo" rather than "no access".
    func accountInfo() async throws -> (login: String, scopes: [String]) {
        let (data, http) = try await request("/user")
        let login = ((try? json(data)) as? [String: Any])?["login"] as? String ?? "unknown"
        let header = (http.allHeaderFields["X-OAuth-Scopes"] as? String)
            ?? (http.allHeaderFields["x-oauth-scopes"] as? String) ?? ""
        let scopes = header.split(separator: ",").map {
            $0.trimmingCharacters(in: .whitespaces)
        }.filter { !$0.isEmpty }
        return (login, scopes)
    }

    /// The login (username) for this token, via GET /user.
    func currentLogin() async throws -> String {
        try await accountInfo().login
    }

    /// Verifies the token can read AND write (write = the `repo` scope is present).
    func testConnection(owner: String, repo: String) async throws -> (read: Bool, write: Bool, login: String) {
        let (userData, _) = try await request("/user")
        let login = ((try? json(userData)) as? [String: Any])?["login"] as? String ?? "unknown"
        // Read check
        _ = try await request("/repos/\(owner)/\(repo)")
        // Write check via the permissions field on the repo object.
        let (repoData, _) = try await request("/repos/\(owner)/\(repo)")
        var write = false
        if let obj = try? json(repoData) as? [String: Any],
           let perms = obj["permissions"] as? [String: Any] {
            write = (perms["push"] as? Bool) ?? false
        }
        return (true, write, login)
    }
}
