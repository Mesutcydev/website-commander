import Foundation

enum GitHubError: LocalizedError {
    case noToken
    case http(Int, String)
    case decoding(String)
    case notFound(String)
    case branchDrift(expected: String, actual: String)

    var errorDescription: String? {
        switch self {
        case .noToken:
            return "No GitHub token. Add one in Settings → GitHub."
        case .http(let code, let body):
            switch code {
            case 401:
                return "GitHub rejected the token (401). Reconnect the account in Settings → GitHub."
            case 403:
                return "GitHub denied this write (403). Check that the connected token can write to this repository."
            case 404:
                return "GitHub could not find the repository, branch, or file (404). Verify the site connection."
            case 409:
                return "GitHub could not apply this change because the repository changed. Review the file again and restage it."
            case 422:
                return "GitHub could not validate this change (422). Check the branch and file path, then try again."
            default:
                let detail = body.trimmingCharacters(in: .whitespacesAndNewlines)
                return detail.isEmpty
                    ? "GitHub returned an error (\(code)). Try again."
                    : "GitHub returned an error (\(code)): \(String(detail.prefix(220)))"
            }
        case .decoding(let what):
            return "Couldn't read GitHub response: \(what)"
        case .notFound(let what):
            return "Not found: \(what)"
        case .branchDrift:
            return "The branch changed after this import was prepared. Refresh the review before committing."
        }
    }
}

struct GitHubBatchChange {
    var path: String
    var data: Data
    var isDeletion: Bool = false
}

/// A minimal GitHub REST client covering everything the agent needs: list repos,
/// browse & read files, commit a file change, and read commit history. Uses the
/// contents API (base64 blobs) so no local git is required for the core loop.
struct GitHubClient {

    let token: String
    var apiBase: String = "https://api.github.com"
    let session: URLSession

    init(token: String, apiBase: String = "https://api.github.com",
         session: URLSession = .shared) {
        self.token = token
        self.apiBase = apiBase
        self.session = session
    }

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

    /// Read a file's raw bytes and blob SHA. This is also the safe metadata path
    /// for binary assets; callers do not need to force arbitrary bytes through
    /// UTF-8 decoding.
    func fileData(owner: String, repo: String, path: String, branch: String) async throws -> (data: Data, sha: String) {
        let encoded = path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? path
        let (data, _) = try await request("/repos/\(owner)/\(repo)/contents/\(encoded)?ref=\(branch)")
        guard let obj = try json(data) as? [String: Any] else {
            throw GitHubError.decoding("file data")
        }
        let sha = (obj["sha"] as? String) ?? ""
        let raw = (obj["content"] as? String) ?? ""
        let cleaned = raw.replacingOccurrences(of: "\n", with: "")
        guard let decoded = Data(base64Encoded: cleaned) else {
            throw GitHubError.decoding("base64 file data")
        }
        return (decoded, sha)
    }

    /// Read a file's UTF-8 content and its blob SHA.
    func fileContent(owner: String, repo: String, path: String, branch: String) async throws -> (content: String, sha: String) {
        let raw = try await fileData(owner: owner, repo: repo, path: path, branch: branch)
        return (String(data: raw.data, encoding: .utf8) ?? "", raw.sha)
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

    // MARK: Atomic batch commits

    /// Return the current commit SHA at a branch head.
    func branchHeadSHA(owner: String, repo: String, branch: String) async throws -> String {
        let encodedBranch = branch.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? branch
        let (data, _) = try await request("/repos/\(owner)/\(repo)/git/ref/heads/\(encodedBranch)")
        guard let obj = try json(data) as? [String: Any],
              let object = obj["object"] as? [String: Any],
              let sha = object["sha"] as? String, !sha.isEmpty else {
            throw GitHubError.decoding("branch head")
        }
        return sha
    }

    /// Commit multiple text/binary files as one non-force update. The branch
    /// head is checked immediately before the Git Data API sequence so a blog
    /// import cannot silently overwrite unrelated remote work.
    @discardableResult
    func commitBatch(owner: String, repo: String, branch: String,
                     expectedParentSHA: String, message: String,
                     changes: [GitHubBatchChange]) async throws -> String {
        guard !changes.isEmpty else { throw GitHubError.decoding("empty batch") }
        let currentHead = try await branchHeadSHA(owner: owner, repo: repo, branch: branch)
        guard currentHead == expectedParentSHA else {
            throw GitHubError.branchDrift(expected: expectedParentSHA, actual: currentHead)
        }

        let encodedParent = expectedParentSHA.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed)
            ?? expectedParentSHA
        let (commitData, _) = try await request(
            "/repos/\(owner)/\(repo)/git/commits/\(encodedParent)"
        )
        guard let commit = try json(commitData) as? [String: Any],
              let tree = commit["tree"] as? [String: Any],
              let baseTreeSHA = tree["sha"] as? String else {
            throw GitHubError.decoding("parent tree")
        }

        var treeEntries: [[String: Any]] = []
        for change in changes {
            let blobBody: [String: Any] = [
                "content": change.data.base64EncodedString(),
                "encoding": "base64"
            ]
            let (blobData, _) = try await request(
                "/repos/\(owner)/\(repo)/git/blobs", method: "POST", body: blobBody
            )
            guard let blob = try json(blobData) as? [String: Any],
                  let blobSHA = blob["sha"] as? String else {
                throw GitHubError.decoding("created blob")
            }
            treeEntries.append([
                "path": change.path,
                "mode": "100644",
                "type": "blob",
                "sha": blobSHA
            ])
        }

        let treeBody: [String: Any] = [
            "base_tree": baseTreeSHA,
            "tree": treeEntries
        ]
        let (treeData, _) = try await request(
            "/repos/\(owner)/\(repo)/git/trees", method: "POST", body: treeBody
        )
        guard let createdTree = try json(treeData) as? [String: Any],
              let createdTreeSHA = createdTree["sha"] as? String else {
            throw GitHubError.decoding("created tree")
        }

        let commitBody: [String: Any] = [
            "message": message,
            "tree": createdTreeSHA,
            "parents": [expectedParentSHA]
        ]
        let (newCommitData, _) = try await request(
            "/repos/\(owner)/\(repo)/git/commits", method: "POST", body: commitBody
        )
        guard let newCommit = try json(newCommitData) as? [String: Any],
              let newCommitSHA = newCommit["sha"] as? String else {
            throw GitHubError.decoding("created commit")
        }

        let encodedBranch = branch.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? branch
        let refBody: [String: Any] = ["sha": newCommitSHA, "force": false]
        _ = try await request(
            "/repos/\(owner)/\(repo)/git/refs/heads/\(encodedBranch)",
            method: "PATCH", body: refBody
        )
        return newCommitSHA
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

    /// Fetch the changed-file summary for one commit. The list endpoint is
    /// intentionally lightweight; details are loaded only when the user opens
    /// the inspector so History stays fast.
    func commitDetail(owner: String, repo: String, sha: String) async throws -> CommitDetail {
        let encodedSHA = sha.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? sha
        let (data, _) = try await request("/repos/\(owner)/\(repo)/commits/\(encodedSHA)")
        guard let obj = try json(data) as? [String: Any] else {
            throw GitHubError.decoding("commit details")
        }
        let files = (obj["files"] as? [[String: Any]] ?? []).compactMap { file -> CommitFileChange? in
            guard let path = file["filename"] as? String else { return nil }
            return CommitFileChange(
                path: path,
                status: (file["status"] as? String) ?? "modified",
                additions: (file["additions"] as? Int) ?? 0,
                deletions: (file["deletions"] as? Int) ?? 0,
                changes: (file["changes"] as? Int) ?? 0
            )
        }
        return CommitDetail(sha: (obj["sha"] as? String) ?? sha,
                            htmlURL: obj["html_url"] as? String,
                            files: files)
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
