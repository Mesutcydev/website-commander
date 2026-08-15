import Foundation

enum GitHubError: LocalizedError {
    case noToken
    case http(Int, String)
    case forbidden(String)   // a 403 already translated into an actionable message
    case decoding(String)

    var errorDescription: String? {
        switch self {
        case .noToken: return "No GitHub token set. Add a token in Settings."
        case .http(let code, let body): return "GitHub API error \(code): \(body)"
        case .forbidden(let message): return message
        case .decoding(let what): return "Could not read GitHub response: \(what)"
        }
    }

    /// Turn a 403 body into a plain-language, actionable message. GitHub returns
    /// the same opaque "Resource not accessible by personal access token" string
    /// whether the token lacks write permission, the org requires SSO, or a push
    /// was blocked by secret scanning — so we sniff the body to tell them apart.
    static func explain403(_ body: String) -> String {
        let lower = body.lowercased()
        if lower.contains("saml") || lower.contains("single sign-on") || lower.contains("sso") {
            return "Your GitHub token needs SSO authorization for this repository’s organization. In GitHub, open the token’s settings and click “Authorize” next to the organization, then try again."
        }
        if lower.contains("secret") && (lower.contains("push") || lower.contains("gh013")) {
            return "GitHub blocked this commit because it looks like it contains a secret (API key or token). Remove the secret from the file and try again."
        }
        if lower.contains("not accessible") || lower.contains("resource not accessible") || lower.contains("permission") {
            return "Your GitHub token can read this repository but isn’t allowed to make changes. In GitHub, edit the token → Repository permissions → set Contents to “Read and write”, save, then try again."
        }
        // Unknown 403 — keep it readable but don't dump raw JSON at the user.
        return "GitHub refused this action (403). Check that your token has Contents: Read and write for this repository, then try again."
    }

    /// Turn a 422 (often a branch-protection rejection on a ref update) into a
    /// plain-language hint instead of raw JSON.
    static func explain422(_ body: String) -> String {
        let lower = body.lowercased()
        if lower.contains("signature") || lower.contains("signed") {
            return "This branch requires signed commits, so the app can't update it directly. Make the change on a branch without that rule, or disable it for this branch."
        }
        if lower.contains("review") || lower.contains("protected") || lower.contains("required status") {
            return "This branch is protected (required reviews or status checks), so the app can't push to it directly. Target an unprotected branch, or open a pull request instead."
        }
        // Repo creation 422: the name is already taken on this account.
        if lower.contains("already exists") || lower.contains("name already exists") {
            return "A repository with that name already exists on this account. Pick a different name."
        }
        return "GitHub rejected this change (422). The branch may have protection rules that block direct updates — try an unprotected branch or a pull request."
    }
}

/// Thin wrapper over the GitHub REST contents API. These methods are exposed to
/// the agent as tools (list/read/write files, commit).
struct GitHubClient {
    var repo: RepoConfig
    private let base = SiteAgentURL.constant("https://api.github.com")

    // In-memory ETag cache for conditional GETs (keyed by full request URL).
    private static let etagLock = NSLock()
    private static var etagCache: [String: (etag: String, body: Data)] = [:]
    /// Soft LRU-ish cap: drop arbitrary oldest keys when exceeded.
    private static let etagCacheMaxEntries = 64

    private static func cachedEntry(for key: String) -> (etag: String, body: Data)? {
        etagLock.lock(); defer { etagLock.unlock() }
        return etagCache[key]
    }
    private static func setCachedEntry(_ entry: (etag: String, body: Data)?, for key: String) {
        etagLock.lock(); defer { etagLock.unlock() }
        if let entry {
            etagCache[key] = entry
            while etagCache.count > etagCacheMaxEntries, let first = etagCache.keys.first {
                etagCache.removeValue(forKey: first)
            }
        } else {
            etagCache.removeValue(forKey: key)
        }
    }

    /// Any repository mutation can advance a branch and therefore invalidate
    /// cached ref, contents, tree, commit-list, and compare responses together.
    /// Clearing the small per-repository slice is intentionally broader than
    /// removing only the mutation URL: contents reads include `?ref=…`, while
    /// writes do not, and keeping either entry produced false 409 conflicts.
    private static func invalidateCache(owner: String, name: String) {
        let marker = "/repos/\(owner)/\(name)/"
        etagLock.lock(); defer { etagLock.unlock() }
        etagCache.keys
            .filter { $0.contains(marker) }
            .forEach { etagCache.removeValue(forKey: $0) }
    }

    // Last observed rate-limit remaining, parsed off any response for future use.
    private static let rateLock = NSLock()
    private static var rateRemaining: Int?
    private static func recordRateLimit(_ http: HTTPURLResponse) {
        guard let rem = Int(http.value(forHTTPHeaderField: "x-ratelimit-remaining") ?? "") else { return }
        rateLock.lock(); rateRemaining = rem; rateLock.unlock()
    }
    private static func rateLimitResetSeconds(_ http: HTTPURLResponse) -> Int? {
        guard let raw = http.value(forHTTPHeaderField: "x-ratelimit-reset"),
              let epoch = Double(raw) else { return nil }
        return max(0, Int(epoch - Date().timeIntervalSince1970))
    }

    private func makeRequest(_ path: String, method: String = "GET", body: Data? = nil) throws -> URLRequest {
        // NOTE: do NOT use appendingPathComponent here — it treats the whole
        // string as one path segment and percent-encodes the "?" into "%3F",
        // turning "/contents?ref=main" into "/contents%3Fref=main" (→ 404).
        // Query values are appended via URLQueryItem by callers, so the path
        // here is the bare path only.
        guard let url = URL(string: base.absoluteString + path) else {
            throw GitHubError.http(-1, "bad URL path: \(path)")
        }
        return try makeRequest(url: url, method: method, body: body)
    }

    private func makeRequest(url: URL, method: String = "GET", body: Data? = nil) throws -> URLRequest {
        guard let raw = Keychain.get(Keychain.githubToken(credentialID: repo.githubCredentialID)) else {
            throw GitHubError.noToken
        }
        let token = raw.trimmingCharacters(in: .whitespacesAndNewlines)   // strip pasted newlines/spaces
        guard !token.isEmpty else { throw GitHubError.noToken }
        // The dynamic path segments are already percent-encoded by callers, so
        // concatenating onto the base and parsing keeps the query separator.
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        req.setValue("WebsiteCommander-iOS", forHTTPHeaderField: "User-Agent")
        req.httpBody = body
        if body != nil { req.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        req.timeoutInterval = 30
        return req
    }

    private func makeURL(_ path: String, query: [URLQueryItem] = []) throws -> URL {
        guard var components = URLComponents(string: base.absoluteString + path) else {
            throw GitHubError.http(-1, "bad URL path: \(path)")
        }
        if !query.isEmpty { components.queryItems = query }
        guard let url = components.url else {
            throw GitHubError.http(-1, "bad URL path: \(path)")
        }
        return url
    }

    private func sendRaw(_ req: URLRequest,
                         attempt: Int = 0,
                         useConditionalCache: Bool = true) async throws -> (Data, HTTPURLResponse) {
        // Conditional GET: only requests routed through send/sendRaw get an
        // If-None-Match (and 304 handling). Status-only probes bypass this so a
        // 304 is never misread as a non-200.
        var request = req
        if useConditionalCache,
           (request.httpMethod == "GET" || request.httpMethod == nil),
           let key = request.url?.absoluteString,
           let cached = GitHubClient.cachedEntry(for: key) {
            request.setValue(cached.etag, forHTTPHeaderField: "If-None-Match")
        }
        let (data, resp) = try await URLSession.shared.data(for: request)
        guard let http = resp as? HTTPURLResponse else {
            throw GitHubError.http(-1, "no response")
        }
        GitHubClient.recordRateLimit(http)

        // Conditional GET: a 304 means the cached body is still current.
        if useConditionalCache,
           (request.httpMethod == "GET" || request.httpMethod == nil),
           let key = request.url?.absoluteString {
            if http.statusCode == 304, let cached = GitHubClient.cachedEntry(for: key) {
                return (cached.body, http)
            } else if (200..<300).contains(http.statusCode),
                      let etag = http.value(forHTTPHeaderField: "ETag") {
                GitHubClient.setCachedEntry((etag, data), for: key)
            }
        }

        if (200..<300).contains(http.statusCode) { return (data, http) }

        // A 403 with x-ratelimit-remaining: 0 is a rate limit (not a permission error).
        let rateLimited = http.statusCode == 403
            && http.value(forHTTPHeaderField: "x-ratelimit-remaining") == "0"

        // Retry transient failures only for idempotent methods. Retrying POST/PATCH/PUT
        // after a lost 5xx can duplicate commits, blobs, PRs, or branch creates.
        let method = (request.httpMethod ?? "GET").uppercased()
        let idempotent = method == "GET" || method == "HEAD" || method == "OPTIONS"
        if idempotent, attempt < 3, http.statusCode == 429 || http.statusCode >= 500 || rateLimited {
            let backoff = Double(http.value(forHTTPHeaderField: "retry-after") ?? "") ?? pow(2.0, Double(attempt))
            try? await Task.sleep(nanoseconds: UInt64(min(backoff, 8) * 1_000_000_000))
            return try await sendRaw(req,
                                     attempt: attempt + 1,
                                     useConditionalCache: useConditionalCache)
        }

        if rateLimited {
            let wait = GitHubClient.rateLimitResetSeconds(http) ?? 60
            throw GitHubError.http(403, "GitHub rate limit reached — try again in \(wait) seconds.")
        }
        let body = String(data: data, encoding: .utf8) ?? ""
        // A non-rate-limited 403 is almost always a token-permission problem.
        // Translate it here (once) so every write path gets the actionable
        // message instead of GitHub's raw JSON.
        if http.statusCode == 403 {
            throw GitHubError.forbidden(GitHubError.explain403(body))
        }
        // A 422 is endpoint-specific. Ref updates commonly mean branch
        // protection, while Contents API writes commonly mean the file appeared
        // or changed and the supplied SHA is no longer valid. Treating every 422
        // as branch protection produced a misleading dead end during approval.
        if http.statusCode == 422 {
            let path = request.url?.path.lowercased() ?? ""
            let lower = body.lowercased()
            if path.contains("/git/refs")
                || lower.contains("signature")
                || lower.contains("protected branch")
                || lower.contains("required status") {
                throw GitHubError.forbidden(GitHubError.explain422(body))
            }
            if path.contains("/contents/")
                && (lower.contains("sha") || lower.contains("already exists")) {
                throw GitHubError.http(
                    409,
                    "The file changed on \(repo.branch) before the commit. Refresh its review and approve again."
                )
            }
            throw GitHubError.http(422, String(body.prefix(400)))
        }
        throw GitHubError.http(http.statusCode, String(body.prefix(400)))
    }

    private func send(_ req: URLRequest, attempt: Int = 0) async throws -> Data {
        try await sendRaw(req, attempt: attempt).0
    }

    /// A correctness-sensitive GET that bypasses both URLSession caching and the
    /// client's ETag cache. Approval TOCTOU checks and ref reconciliation must see
    /// the live branch, not a valid-but-now-obsolete conditional response.
    private func sendFresh(_ req: URLRequest) async throws -> Data {
        var request = req
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        request.setValue("no-cache, no-store", forHTTPHeaderField: "Cache-Control")
        request.setValue("no-cache", forHTTPHeaderField: "Pragma")
        request.setValue(nil, forHTTPHeaderField: "If-None-Match")
        return try await sendRaw(request, useConditionalCache: false).0
    }

    /// Walk the Link rel="next" header starting at `req`, returning each page's
    /// (data, response). Stops when there is no next link or `maxPages` is hit.
    /// Single-page behavior is preserved when the response has no Link header.
    private func sendPaged(_ req: URLRequest, maxPages: Int = 10) async throws -> [(Data, HTTPURLResponse)] {
        var pages: [(Data, HTTPURLResponse)] = []
        var current = req
        for _ in 0..<maxPages {
            let (data, http) = try await sendRaw(current)
            pages.append((data, http))
            guard let link = http.value(forHTTPHeaderField: "Link"),
                  let nextURL = GitHubClient.nextLink(from: link) else { break }
            current = try makeRequest(url: nextURL)
        }
        return pages
    }

    private static func nextLink(from linkHeader: String) -> URL? {
        for part in linkHeader.split(separator: ",") {
            let segment = part.trimmingCharacters(in: .whitespaces)
            guard segment.contains("rel=\"next\"") || segment.contains("rel=next") else { continue }
            guard let lt = segment.firstIndex(of: "<"),
                  let gt = segment.firstIndex(of: ">"), lt < gt else { continue }
            let urlString = segment[segment.index(after: lt)..<gt]
            if let url = URL(string: String(urlString)) { return url }
        }
        return nil
    }

    /// Verify the token works and return the authenticated login.
    func verifyToken() async throws -> String {
        let data = try await send(try makeRequest("/user"))
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let login = obj["login"] as? String else {
            throw GitHubError.decoding("user")
        }
        return login
    }

    /// Full end-to-end check: token → repo access → branch → write permission.
    /// This is what "Test connection" should use, because it exercises exactly
    /// what the agent needs (the agent reads/writes repo contents on a branch).
    struct Diagnosis {
        var ok: Bool
        var message: String
        /// If set, the caller should switch to this branch (the configured one was unreachable).
        var suggestedBranch: String?
    }

    func diagnose() async -> Diagnosis {
        // 1. Token authenticates?
        let login: String
        do { login = try await verifyToken() }
        catch GitHubError.noToken { return Diagnosis(ok: false, message: "No token set", suggestedBranch: nil) }
        catch GitHubError.http(let code, _) where code == 401 {
            return Diagnosis(ok: false, message: "✗ Token is invalid or expired (401). Generate a new token.", suggestedBranch: nil)
        }
        catch { return Diagnosis(ok: false, message: "✗ Token rejected by GitHub", suggestedBranch: nil) }

        // 2. Repo metadata (note: fine-grained tokens ALWAYS have Metadata read,
        //    so a 200 here does NOT prove Contents access — step 4 is the real test).
        let (repoStatus, info) = await getJSON("/repos/\(repo.owner)/\(repo.name)")
        if repoStatus == 404 {
            return Diagnosis(ok: false,
                             message: "✗ \(login): can't see \(repo.slug). In the token, under Repository access, select this repository.",
                             suggestedBranch: nil)
        }
        guard repoStatus == 200 else {
            return Diagnosis(ok: false, message: "✗ repo error \(repoStatus)", suggestedBranch: nil)
        }
        let defaultBranch = info?["default_branch"] as? String
        let canPush = (info?["permissions"] as? [String: Any])?["push"] as? Bool ?? false

        // 3. Resolve the branch (suggest the default if the configured one is missing).
        var branch = repo.branch
        var suggested: String?
        var branchNote = "branch \(branch) ✓"
        if !(await branchExists(branch)) {
            if let defaultBranch, defaultBranch != branch {
                suggested = defaultBranch; branch = defaultBranch
                branchNote = "branch \(repo.branch) not found → using \(defaultBranch)"
            } else {
                return Diagnosis(ok: false, message: "✗ branch \(branch) not found", suggestedBranch: nil)
            }
        }

        // 4. THE REAL TEST: read repo contents on that branch — exactly what the
        //    agent does. This is what catches a missing Contents permission.
        let contentsStatus = await statusOnly("/repos/\(repo.owner)/\(repo.name)/contents",
                                              query: [URLQueryItem(name: "ref", value: branch)])
        if contentsStatus == 403 {
            return Diagnosis(ok: false,
                             message: "✗ \(login): token can't read files (403). Edit the token → Repository permissions → Contents: Read and write.",
                             suggestedBranch: suggested)
        }
        guard contentsStatus == 200 else {
            return Diagnosis(ok: false, message: "✗ can't read contents (\(contentsStatus))", suggestedBranch: suggested)
        }

        // 5. THE WRITE TEST: actually exercise Contents:write the way a commit
        //    will, because that — not reading — is what this app exists to do.
        //    `permissions.push` is unreliable for fine-grained tokens (it mirrors
        //    the user's repo role, not the token's scope), so the only honest
        //    answer comes from a real write probe.
        switch await verifyWriteAccess() {
        case .some(true):
            return Diagnosis(ok: true,
                             message: "✓ \(login) · \(repo.slug) · \(branchNote) · read+write ✓",
                             suggestedBranch: suggested)
        case .some(false):
            return Diagnosis(ok: false,
                             message: "✗ \(login): token can read \(repo.slug) but can’t write to it, so commits will fail. Edit the token → Repository permissions → Contents: Read and write, then test again.",
                             suggestedBranch: suggested)
        case .none:
            // Probe couldn't run (transient). Fall back to the role hint, but say
            // plainly that write wasn't actually verified.
            let note = canPush ? "read ✓ · write unverified" : "⚠️ likely read-only (set Contents: Read and write)"
            return Diagnosis(ok: canPush,
                             message: "\(canPush ? "✓" : "✗") \(login) · \(repo.slug) · \(branchNote) · \(note)",
                             suggestedBranch: suggested)
        }
    }

    private func branchExists(_ branch: String) async -> Bool {
        guard !branch.isEmpty else { return false }
        return await statusOnly("/repos/\(repo.owner)/\(repo.name)/branches/\(branch)") == 200
    }

    /// GET returning (statusCode, parsed JSON object) — -1 on transport failure.
    /// Bypasses sendRaw's conditional-GET logic (a 304 must not be misread as a
    /// non-200 here) but still records rate-limit state so every response feeds
    /// the client's awareness.
    private func getJSON(_ path: String, query: [URLQueryItem] = []) async -> (Int, [String: Any]?) {
        guard let url = try? makeURL(path, query: query),
              let req = try? makeRequest(url: url),
              let (data, resp) = try? await URLSession.shared.data(for: req),
              let http = resp as? HTTPURLResponse else { return (-1, nil) }
        GitHubClient.recordRateLimit(http)
        return (http.statusCode, try? JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    /// GET returning just the HTTP status code (-1 on transport failure).
    private func statusOnly(_ path: String, query: [URLQueryItem] = []) async -> Int {
        guard let url = try? makeURL(path, query: query),
              let req = try? makeRequest(url: url),
              let (_, resp) = try? await URLSession.shared.data(for: req),
              let http = resp as? HTTPURLResponse else { return -1 }
        GitHubClient.recordRateLimit(http)
        return http.statusCode
    }

    /// Definitively test write access by creating an orphan blob, which needs the
    /// SAME Contents:write permission a commit needs. A blob that no tree or
    /// commit references makes no commit, moves no branch ref, and fires no
    /// webhook or deploy — GitHub garbage-collects it — so this is safe to run
    /// from "Test connection". This is the ONLY honest write signal: the repo's
    /// `permissions.push` flag reflects the user's repo role, not a fine-grained
    /// token's granted scope, so it can read true while every commit 403s.
    /// Returns true (can write), false (forbidden), or nil (couldn't determine).
    func verifyWriteAccess() async -> Bool? {
        let payload: [String: Any] = ["content": "Website Commander write-permission check", "encoding": "utf-8"]
        guard let body = try? JSONSerialization.data(withJSONObject: payload),
              let req = try? makeRequest("/repos/\(repo.owner)/\(repo.name)/git/blobs", method: "POST", body: body) else {
            return nil
        }
        do {
            // Route through send() so transient failures (429 / 5xx / rate-limit
            // 403s) get retried with backoff before we'd ever report a verdict —
            // otherwise a momentary blip reads as "can't write" and we fall back
            // to the unreliable role flag, defeating the whole point of the probe.
            _ = try await send(req)
            return true                 // 2xx: the blob was created → token can write
        } catch GitHubError.forbidden {
            return false                // a genuine permission 403 → token cannot write
        } catch {
            return nil                  // transient/unknown → don't guess
        }
    }

    // MARK: - Contents API

    /// Read the repository homepage configured in GitHub metadata.
    ///
    /// Older Website Commander workspaces may not have a `liveURL` in their local
    /// deployment config. The homepage is the authoritative fallback for
    /// dynamic sites (for example Next.js projects that cannot be rendered
    /// from a checked-in `index.html`).
    func repositoryHomepage() async throws -> String? {
        let data = try await sendFresh(
            try makeRequest("/repos/\(repo.owner)/\(repo.name)")
        )
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw GitHubError.decoding("repository metadata")
        }
        let raw = (object["homepage"] as? String ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return raw.isEmpty ? nil : raw
    }

    /// List a directory in the repo.
    func list(path: String = "") async throws -> [RepoEntry] {
        let encoded = path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? path
        let suffix = encoded.isEmpty ? "" : "/\(encoded)"   // no trailing slash on root
        let url = try makeURL("/repos/\(repo.owner)/\(repo.name)/contents\(suffix)",
                              query: [URLQueryItem(name: "ref", value: repo.branch)])
        let data = try await send(try makeRequest(url: url))
        guard let arr = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            throw GitHubError.decoding("directory listing")
        }
        return arr.compactMap { item in
            guard let p = item["path"] as? String, let t = item["type"] as? String else { return nil }
            return RepoEntry(path: p,
                             type: t == "dir" ? .dir : .file,
                             sha: item["sha"] as? String,
                             size: item["size"] as? Int)
        }.sorted { ($0.type == .dir ? 0 : 1, $0.name) < ($1.type == .dir ? 0 : 1, $1.name) }
    }

    /// List all files in the repository recursively using the Git Trees API.
    func listRecursive() async throws -> [RepoEntry] {
        try await listRecursiveDetailed().entries
    }

    /// Recursive tree listing plus GitHub `truncated` flag (large repos).
    func listRecursiveDetailed() async throws -> (entries: [RepoEntry], truncated: Bool) {
        let firstURL = try makeURL("/repos/\(repo.owner)/\(repo.name)/git/trees/\(repo.branch)",
                                   query: [URLQueryItem(name: "recursive", value: "1")])
        let pages = try await sendPaged(try makeRequest(url: firstURL), maxPages: 10)
        var entries: [RepoEntry] = []
        var truncated = false
        for (data, _) in pages {
            guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let tree = obj["tree"] as? [[String: Any]] else { continue }
            if obj["truncated"] as? Bool == true { truncated = true }
            entries.append(contentsOf: tree.compactMap { item in
                guard let p = item["path"] as? String, let t = item["type"] as? String else { return nil }
                return RepoEntry(path: p,
                                 type: t == "tree" ? .dir : .file,
                                 sha: item["sha"] as? String,
                                 size: item["size"] as? Int)
            })
        }
        let sorted = entries.sorted { ($0.type == .dir ? 0 : 1, $0.path) < ($1.type == .dir ? 0 : 1, $1.path) }
        return (sorted, truncated)
    }

    /// Read a UTF-8 text file. Returns (content, blobSHA). The SHA is required to update the file.
    func read(path: String, fresh: Bool = false) async throws -> (content: String, sha: String) {
        let encoded = path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? path
        let url = try makeURL("/repos/\(repo.owner)/\(repo.name)/contents/\(encoded)",
                              query: [URLQueryItem(name: "ref", value: repo.branch)])
        let request = try makeRequest(url: url)
        let data = try await (fresh ? sendFresh(request) : send(request))
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let sha = obj["sha"] as? String,
              let b64 = obj["content"] as? String else {
            throw GitHubError.decoding("file content")
        }
        // >1MB files come back with empty `content` plus a download_url. Fail
        // loudly instead of returning "" — callers would treat the file as empty
        // and stage a full overwrite against a blank baseline.
        if b64.isEmpty, (obj["size"] as? Int ?? 0) > 0 {
            throw GitHubError.decoding("file too large for the contents API (>1MB)")
        }
        let cleaned = b64.replacingOccurrences(of: "\n", with: "")
        guard let raw = Data(base64Encoded: cleaned),
              let text = String(data: raw, encoding: .utf8) else {
            throw GitHubError.decoding("file is not valid UTF-8 text")
        }
        return (text, sha)
    }

    /// Create or update a text file (a commit on `branch`). Pass the current `sha`
    /// when updating an existing file; pass nil to create a new one.
    @discardableResult
    func write(path: String, content: String, message: String, sha: String?) async throws -> String {
        try await putContents(path: path, base64: Data(content.utf8).base64EncodedString(),
                              message: message, sha: sha)
    }

    /// Upload arbitrary (incl. binary) file data — e.g. an image asset.
    @discardableResult
    func upload(path: String, data: Data, message: String, sha: String?) async throws -> String {
        try await putContents(path: path, base64: data.base64EncodedString(),
                              message: message, sha: sha)
    }

    /// Delete a file from the repository.
    func delete(path: String, message: String, sha: String) async throws {
        let encoded = path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? path
        let payload: [String: Any] = [
            "message": message,
            "sha": sha,
            "branch": repo.branch
        ]
        let body = try JSONSerialization.data(withJSONObject: payload)
        let req = try makeRequest("/repos/\(repo.owner)/\(repo.name)/contents/\(encoded)",
                                  method: "DELETE", body: body)
        _ = try await send(req)
        GitHubClient.invalidateCache(owner: repo.owner, name: repo.name)
    }

    /// Fetch recent commits on the current branch.
    func commits(limit: Int = 20) async throws -> [CommitEntry] {
        let url = try makeURL("/repos/\(repo.owner)/\(repo.name)/commits",
                              query: [URLQueryItem(name: "sha", value: repo.branch),
                                      URLQueryItem(name: "per_page", value: "\(limit)")])
        let data = try await send(try makeRequest(url: url))
        guard let arr = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            throw GitHubError.decoding("commits listing")
        }
        return arr.compactMap { item in
            guard let sha = item["sha"] as? String,
                  let commit = item["commit"] as? [String: Any],
                  let author = commit["author"] as? [String: Any],
                  let name = author["name"] as? String,
                  let date = author["date"] as? String,
                  let msg = commit["message"] as? String else { return nil }
            let avatar = (item["author"] as? [String: Any])?["avatar_url"] as? String
            return CommitEntry(sha: sha, message: msg, authorName: name, dateString: date, avatarURL: avatar)
        }
    }

    /// One check-run row from the GitHub Checks API for a commit.
    struct CheckRunEntry {
        var name: String
        var status: String
        var conclusion: String?
    }

    /// List the check-runs for a commit (GitHub Checks API, read-only). Pass a
    /// full SHA, or nil to resolve the active branch HEAD. Output is bounded to
    /// `max` rows so a noisy CI setup can't flood the agent's context.
    func checkRuns(forSHA sha: String?, max: Int = 20) async throws -> [CheckRunEntry] {
        let resolved: String
        if let sha, !sha.isEmpty {
            resolved = sha
        } else {
            let recent = try await commits(limit: 1)
            guard let head = recent.first else {
                throw GitHubError.http(-1, "no commits on \(repo.branch) to inspect")
            }
            resolved = head.sha
        }
        let encoded = resolved.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? resolved
        let url = try makeURL("/repos/\(repo.owner)/\(repo.name)/commits/\(encoded)/check-runs",
                              query: [URLQueryItem(name: "per_page", value: "\(max)")])
        let data = try await send(try makeRequest(url: url))
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let runs = obj["check_runs"] as? [[String: Any]] else {
            throw GitHubError.decoding("check-runs")
        }
        return runs.prefix(max).compactMap { item -> CheckRunEntry? in
            guard let name = item["name"] as? String,
                  let status = item["status"] as? String else { return nil }
            return CheckRunEntry(name: name, status: status, conclusion: item["conclusion"] as? String)
        }
    }

    /// Compare two refs via the GitHub compare API and return the changed files
    /// with their unified patches. Patches longer than `maxPatchChars` per file
    /// are truncated so a huge diff can't blow the agent's context window.
    struct CompareFile {
        var path: String
        var status: String
        var additions: Int
        var deletions: Int
        var patch: String?
    }

    func compare(base: String, head: String, maxFiles: Int = 30, maxPatchChars: Int = 2000) async throws -> (files: [CompareFile], aheadBy: Int, behindBy: Int) {
        let baseEnc = base.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? base
        let headEnc = head.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? head
        let url = try makeURL("/repos/\(repo.owner)/\(repo.name)/compare/\(baseEnc)...\(headEnc)")
        let data = try await send(try makeRequest(url: url))
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw GitHubError.decoding("compare")
        }
        let ahead = obj["ahead_by"] as? Int ?? 0
        let behind = obj["behind_by"] as? Int ?? 0
        guard let files = obj["files"] as? [[String: Any]] else {
            return ([], ahead, behind)
        }
        let entries = files.prefix(maxFiles).compactMap { item -> CompareFile? in
            guard let path = item["filename"] as? String else { return nil }
            let rawPatch = item["patch"] as? String
            let patch = rawPatch.map { $0.count > maxPatchChars ? String($0.prefix(maxPatchChars)) + "\n…(patch truncated)…" : $0 }
            return CompareFile(
                path: path,
                status: (item["status"] as? String) ?? "",
                additions: (item["additions"] as? Int) ?? 0,
                deletions: (item["deletions"] as? Int) ?? 0,
                patch: patch
            )
        }
        return (Array(entries), ahead, behind)
    }

    /// Fetch a file's blob SHA without decoding its content (works for binary).
    /// Returns nil if the file doesn't exist yet.
    /// Throwing SHA read for approval safety. `nil` means a confirmed 404 (new
    /// file); transport/auth/decoding failures remain errors so they cannot be
    /// mistaken for permission to create/overwrite blindly.
    func currentFileSHA(path: String, fresh: Bool = false) async throws -> String? {
        let encoded = path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? path
        let url = try makeURL("/repos/\(repo.owner)/\(repo.name)/contents/\(encoded)",
                              query: [URLQueryItem(name: "ref", value: repo.branch)])
        let request = try makeRequest(url: url)
        do {
            let data = try await (fresh ? sendFresh(request) : send(request))
            guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let sha = obj["sha"] as? String else {
                throw GitHubError.decoding("file SHA")
            }
            return sha
        } catch let GitHubError.http(code, _) where code == 404 {
            return nil
        }
    }

    /// Best-effort convenience for non-safety-critical call sites.
    func fileSHA(path: String, fresh: Bool = false) async -> String? {
        try? await currentFileSHA(path: path, fresh: fresh)
    }

    // MARK: - Batched commit (Git Data API)

    /// One file mutation inside a batched commit.
    struct FileChange {
        enum Kind {
            case write(content: String)   // create or overwrite a text file
            case upload(data: Data)        // create or overwrite a binary file
            case delete                    // remove the file
        }
        var path: String
        var kind: Kind
    }

    /// Result of reconciling a requested ref move with a freshly observed tip.
    /// Kept pure so the orphan-commit recovery policy has regression coverage.
    enum RefUpdateResolution: Equatable {
        case applied
        case unchanged
        case diverged
    }

    static func resolveRefUpdate(baseSHA: String,
                                 newCommitSHA: String,
                                 observedTip: String) -> RefUpdateResolution {
        if observedTip == newCommitSHA { return .applied }
        if observedTip == baseSHA { return .unchanged }
        return .diverged
    }

    private func freshBranchTip(owner: String, name: String, branch: String) async throws -> String {
        let data = try await sendFresh(
            try makeRequest("/repos/\(owner)/\(name)/git/ref/heads/\(branch)")
        )
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let target = object["object"] as? [String: Any],
              let sha = target["sha"] as? String else {
            throw GitHubError.decoding("fresh branch ref")
        }
        return sha
    }

    func branchTip(fresh: Bool = false) async throws -> String {
        if fresh {
            return try await freshBranchTip(owner: repo.owner, name: repo.name, branch: repo.branch)
        }
        let data = try await send(
            try makeRequest("/repos/\(repo.owner)/\(repo.name)/git/ref/heads/\(repo.branch)")
        )
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let target = object["object"] as? [String: Any],
              let sha = target["sha"] as? String else {
            throw GitHubError.decoding("branch ref")
        }
        return sha
    }

    /// Move a branch to an already-created commit. Retrying this PATCH with the
    /// same target SHA is state-idempotent, unlike recreating the whole commit.
    /// If a response is lost, a fresh ref read distinguishes success, unchanged
    /// state, and a real concurrent update before one safe retry.
    private func moveBranchRef(owner: String,
                               name: String,
                               branch: String,
                               from baseSHA: String,
                               to newCommitSHA: String) async throws {
        let path = "/repos/\(owner)/\(name)/git/refs/heads/\(branch)"
        let body = try JSONSerialization.data(withJSONObject: [
            "sha": newCommitSHA,
            "force": false,
        ])
        var lastFailure = "GitHub did not confirm the branch update."

        for attempt in 0..<2 {
            do {
                let data = try await send(try makeRequest(path, method: "PATCH", body: body))
                GitHubClient.invalidateCache(owner: owner, name: name)

                // GitHub's successful Update Reference response is authoritative
                // and includes the ref's new target. Avoid an immediate GET that
                // may hit a lagging edge/cache and manufacture a false conflict.
                if let response = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let object = response["object"] as? [String: Any],
                   let responseSHA = object["sha"] as? String,
                   responseSHA == newCommitSHA {
                    return
                }
                lastFailure = "GitHub returned an incomplete branch-update response."
            } catch let GitHubError.forbidden(message) {
                throw GitHubError.forbidden(
                    "\(message) Nothing was published to \(branch), and your staged changes are still available."
                )
            } catch {
                lastFailure = error.localizedDescription
            }

            let tip: String
            do {
                tip = try await freshBranchTip(owner: owner, name: name, branch: branch)
            } catch {
                if attempt == 1 {
                    throw GitHubError.http(
                        -1,
                        "The commit was prepared, but its branch update could not be confirmed. Your staged changes are still available. Underlying: \(lastFailure)"
                    )
                }
                continue
            }

            switch Self.resolveRefUpdate(baseSHA: baseSHA,
                                         newCommitSHA: newCommitSHA,
                                         observedTip: tip) {
            case .applied:
                GitHubClient.invalidateCache(owner: owner, name: name)
                return
            case .unchanged where attempt == 0:
                // The first PATCH definitely did not land. Retry only the
                // same desired ref move, never the tree/commit creation.
                continue
            case .unchanged:
                throw GitHubError.http(
                    -1,
                    "The commit was prepared, but \(branch) was not updated. Your staged changes are still available. Try Apply again. Underlying: \(lastFailure)"
                )
            case .diverged:
                throw GitHubError.http(
                    409,
                    "\(branch) changed while the commit was being published. The staged changes are still available; refresh the review before applying again."
                )
            }
        }
    }

    /// Commit several file changes as a SINGLE commit using the Git Data API
    /// (ref → base tree → new tree → commit → move ref). This replaces the old
    /// behaviour of one Contents-API PUT per file, which produced one commit per
    /// file and re-triggered the deploy pipeline for every change.
    @discardableResult
    func commitBatch(_ changes: [FileChange],
                     message: String,
                     expectingHead expectedHeadSHA: String? = nil) async throws -> String {
        guard !changes.isEmpty else { throw GitHubError.http(-1, "no changes to commit") }
        let owner = repo.owner, name = repo.name, branch = repo.branch

        // 1. Latest commit on the branch.
        let refData = try await sendFresh(try makeRequest("/repos/\(owner)/\(name)/git/ref/heads/\(branch)"))
        guard let refObj = try JSONSerialization.jsonObject(with: refData) as? [String: Any],
              let object = refObj["object"] as? [String: Any],
              let latestCommitSHA = object["sha"] as? String else {
            throw GitHubError.decoding("branch ref")
        }
        if let expectedHeadSHA, latestCommitSHA != expectedHeadSHA {
            throw GitHubError.http(
                409,
                "\(branch) changed while you were reviewing this batch. Refresh the staged diffs before applying again."
            )
        }

        // 2. Base tree SHA from that commit.
        let commitData = try await send(try makeRequest("/repos/\(owner)/\(name)/git/commits/\(latestCommitSHA)"))
        guard let commitObj = try JSONSerialization.jsonObject(with: commitData) as? [String: Any],
              let treeObj = commitObj["tree"] as? [String: Any],
              let baseTreeSHA = treeObj["sha"] as? String else {
            throw GitHubError.decoding("base commit tree")
        }

        // 3. Build tree entries. Text writes inline their content; binary uploads
        //    are uploaded as blobs first; deletions set the entry's sha to null.
        var treeEntries: [[String: Any]] = []
        for change in changes {
            switch change.kind {
            case .write(let content):
                treeEntries.append(["path": change.path, "mode": "100644", "type": "blob", "content": content])
            case .upload(let data):
                let blobSHA = try await createBlob(base64: data.base64EncodedString())
                treeEntries.append(["path": change.path, "mode": "100644", "type": "blob", "sha": blobSHA])
            case .delete:
                treeEntries.append(["path": change.path, "mode": "100644", "type": "blob", "sha": NSNull()])
            }
        }

        // 4. Create the new tree on top of the base tree.
        let treeBody = try JSONSerialization.data(withJSONObject: ["base_tree": baseTreeSHA, "tree": treeEntries])
        let newTreeData = try await send(try makeRequest("/repos/\(owner)/\(name)/git/trees", method: "POST", body: treeBody))
        guard let newTreeObj = try JSONSerialization.jsonObject(with: newTreeData) as? [String: Any],
              let newTreeSHA = newTreeObj["sha"] as? String else {
            throw GitHubError.decoding("new tree")
        }

        // 5. Create the commit pointing at the new tree.
        let commitBody = try JSONSerialization.data(withJSONObject: [
            "message": message,
            "tree": newTreeSHA,
            "parents": [latestCommitSHA],
        ])
        let newCommitData = try await send(try makeRequest("/repos/\(owner)/\(name)/git/commits", method: "POST", body: commitBody))
        guard let newCommitObj = try JSONSerialization.jsonObject(with: newCommitData) as? [String: Any],
              let newCommitSHA = newCommitObj["sha"] as? String else {
            throw GitHubError.decoding("new commit")
        }

        // 6. Fast-forward the branch ref to the new commit. The helper reconciles
        // lost responses and retries only this idempotent ref move—not the batch.
        try await moveBranchRef(owner: owner,
                                name: name,
                                branch: branch,
                                from: latestCommitSHA,
                                to: newCommitSHA)

        return newCommitSHA
    }

    /// Create a blob from base64-encoded data and return its SHA.
    private func createBlob(base64: String) async throws -> String {
        let body = try JSONSerialization.data(withJSONObject: ["content": base64, "encoding": "base64"])
        let data = try await send(try makeRequest("/repos/\(repo.owner)/\(repo.name)/git/blobs", method: "POST", body: body))
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let sha = obj["sha"] as? String else {
            throw GitHubError.decoding("blob")
        }
        return sha
    }

    /// Download the raw bytes of a file (text or binary). Handles GitHub's >1MB
    /// case, where the contents API returns empty `content` plus a `download_url`.
    func downloadData(path: String) async throws -> Data {
        let encoded = path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? path
        let url = try makeURL("/repos/\(repo.owner)/\(repo.name)/contents/\(encoded)",
                              query: [URLQueryItem(name: "ref", value: repo.branch)])
        let data = try await send(try makeRequest(url: url))
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw GitHubError.decoding("file content")
        }
        if let b64 = (obj["content"] as? String)?.replacingOccurrences(of: "\n", with: ""),
           !b64.isEmpty, let raw = Data(base64Encoded: b64) {
            return raw
        }
        // Large file: content omitted, follow the raw download URL.
        if let urlString = obj["download_url"] as? String, let url = URL(string: urlString) {
            let (raw, _) = try await URLSession.shared.data(from: url)
            return raw
        }
        throw GitHubError.decoding("could not decode file data for \(path)")
    }

    /// Read the small set of deployment manifests that commonly declare the
    /// production URL. This covers dynamic sites whose GitHub homepage is
    /// empty, including Workers/OpenNext repos with NEXT_PUBLIC_SITE_URL or
    /// custom-domain route entries.
    func repositoryConfiguredLiveURL(rootDirectory: String = "") async -> URL? {
        let root = rootDirectory
            .trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let prefix = root.isEmpty ? "" : "\(root)/"
        let candidates = [
            "\(prefix)wrangler.toml",
            "\(prefix)wrangler.jsonc",
            "\(prefix)wrangler.json",
            "\(prefix)package.json"
        ]

        for path in candidates {
            guard let data = try? await downloadData(path: path),
                  let source = String(data: data, encoding: .utf8),
                  let url = SiteWorkspace.repositoryConfiguredLiveURL(source: source) else {
                continue
            }
            return url
        }
        return nil
    }

    /// Shared PUT to the contents API.
    private func putContents(path: String, base64: String, message: String, sha: String?) async throws -> String {
        let encoded = path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? path
        var payload: [String: Any] = [
            "message": message,
            "content": base64,
            "branch": repo.branch,
        ]
        if let sha { payload["sha"] = sha }
        let body = try JSONSerialization.data(withJSONObject: payload)
        let req = try makeRequest("/repos/\(repo.owner)/\(repo.name)/contents/\(encoded)",
                                  method: "PUT", body: body)
        let data = try await send(req)
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let commit = obj["commit"] as? [String: Any],
              let newSHA = commit["sha"] as? String else {
            throw GitHubError.decoding("commit response")
        }
        GitHubClient.invalidateCache(owner: repo.owner, name: repo.name)
        return newSHA
    }

    // MARK: - Search, branches, pull requests (agent tools)

    /// Code search within this repo — returns matching file paths.
    func searchCode(query: String) async throws -> [String] {
        let scoped = "\(query) repo:\(repo.owner)/\(repo.name)"
        guard let encoded = scoped.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) else {
            throw GitHubError.http(-1, "bad query")
        }
        let data = try await send(try makeRequest("/search/code?q=\(encoded)&per_page=50"))
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let items = obj["items"] as? [[String: Any]] else { return [] }
        return items.compactMap { $0["path"] as? String }
    }

    /// Create a new branch pointing at the head of `from`.
    func createBranch(_ name: String, from: String) async throws {
        let refData = try await send(try makeRequest("/repos/\(repo.owner)/\(repo.name)/git/ref/heads/\(from)"))
        guard let refObj = try JSONSerialization.jsonObject(with: refData) as? [String: Any],
              let object = refObj["object"] as? [String: Any],
              let sha = object["sha"] as? String else {
            throw GitHubError.decoding("source branch ref")
        }
        let body = try JSONSerialization.data(withJSONObject: ["ref": "refs/heads/\(name)", "sha": sha])
        _ = try await send(try makeRequest("/repos/\(repo.owner)/\(repo.name)/git/refs", method: "POST", body: body))
        GitHubClient.invalidateCache(owner: repo.owner, name: repo.name)
    }

    /// Open a pull request and return its html_url.
    func openPullRequest(title: String, head: String, base: String, body: String) async throws -> String {
        let payload: [String: Any] = ["title": title, "head": head, "base": base, "body": body]
        let data = try await send(try makeRequest("/repos/\(repo.owner)/\(repo.name)/pulls",
                                                  method: "POST",
                                                  body: try JSONSerialization.data(withJSONObject: payload)))
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let url = obj["html_url"] as? String else {
            throw GitHubError.decoding("pull request")
        }
        return url
    }

    // MARK: - Undo

    /// Undo the latest commit by creating a new commit whose tree is the latest
    /// commit's parent tree (a forward revert: no force-push, no lost history,
    /// still fires a redeploy). Throws 409 if HEAD moved since `expectedSHA` was
    /// captured, so it can't clobber a commit made in the meantime.
    @discardableResult
    func revertHead(expecting expectedSHA: String) async throws -> String {
        let owner = repo.owner, name = repo.name, branch = repo.branch

        // 1. Current HEAD — and confirm it's still what the caller saw.
        let refData = try await sendFresh(try makeRequest("/repos/\(owner)/\(name)/git/ref/heads/\(branch)"))
        guard let refObj = try JSONSerialization.jsonObject(with: refData) as? [String: Any],
              let object = refObj["object"] as? [String: Any],
              let headSHA = object["sha"] as? String else {
            throw GitHubError.decoding("branch ref")
        }
        guard headSHA == expectedSHA else {
            throw GitHubError.http(409, "The branch moved since you loaded this commit — refresh and try again.")
        }

        // 2. HEAD commit → its parent + message.
        let headData = try await send(try makeRequest("/repos/\(owner)/\(name)/git/commits/\(headSHA)"))
        guard let headObj = try JSONSerialization.jsonObject(with: headData) as? [String: Any],
              let parents = headObj["parents"] as? [[String: Any]],
              let parentSHA = parents.first?["sha"] as? String else {
            throw GitHubError.http(-1, "Nothing to undo — this is the first commit on the branch.")
        }
        // A merge commit has 2+ parents; restoring just the first parent's tree
        // would silently drop the merged-in changes. Refuse rather than mislead.
        guard parents.count == 1 else {
            throw GitHubError.http(-1, "The last commit is a merge — undo it on GitHub instead, so nothing is silently dropped.")
        }
        let originalMessage = (headObj["message"] as? String) ?? ""

        // 3. Parent's tree — the state we want to restore.
        let parentData = try await send(try makeRequest("/repos/\(owner)/\(name)/git/commits/\(parentSHA)"))
        guard let parentObj = try JSONSerialization.jsonObject(with: parentData) as? [String: Any],
              let parentTree = parentObj["tree"] as? [String: Any],
              let parentTreeSHA = parentTree["sha"] as? String else {
            throw GitHubError.decoding("parent commit tree")
        }

        // 4. New commit on top of HEAD pointing at the parent's tree.
        let summary = originalMessage.split(separator: "\n").first.map(String.init) ?? originalMessage
        let commitBody = try JSONSerialization.data(withJSONObject: [
            "message": "Revert \"\(summary.prefix(60))\"",
            "tree": parentTreeSHA,
            "parents": [headSHA],
        ])
        let newCommitData = try await send(try makeRequest("/repos/\(owner)/\(name)/git/commits", method: "POST", body: commitBody))
        guard let newCommitObj = try JSONSerialization.jsonObject(with: newCommitData) as? [String: Any],
              let newCommitSHA = newCommitObj["sha"] as? String else {
            throw GitHubError.decoding("revert commit")
        }

        // 5. Fast-forward the branch ref to the revert commit with the same
        // lost-response reconciliation used by batched approvals.
        try await moveBranchRef(owner: owner,
                                name: name,
                                branch: branch,
                                from: headSHA,
                                to: newCommitSHA)
        return newCommitSHA
    }

    // MARK: - Create a brand-new site (repo + Pages)

    /// Repositories the signed-in user can access (for the Connect Website wizard).
    func listAccessibleRepos(perPage: Int = 50, maxPages: Int = 2) async throws -> [GitHubRepoSummary] {
        var components = URLComponents(url: base.appendingPathComponent("user/repos"), resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "per_page", value: "\(max(1, min(perPage, 100)))"),
            URLQueryItem(name: "sort", value: "updated"),
            URLQueryItem(name: "affiliation", value: "owner,collaborator,organization_member")
        ]
        guard let firstURL = components.url else { throw GitHubError.http(-1, "bad query") }
        let req = try makeRequest(url: firstURL)
        let pages = try await sendPaged(req, maxPages: maxPages)
        var results: [GitHubRepoSummary] = []
        for (data, _) in pages {
            guard let rows = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
                throw GitHubError.decoding("user repos")
            }
            for row in rows {
                guard let summary = GitHubRepoSummary(json: row) else { continue }
                results.append(summary)
            }
        }
        return results
    }

    /// Create a brand-new repository under the authenticated user — or under an org
    /// when `owner` isn't the signed-in login. `auto_init: true` is REQUIRED for
    /// Website Commander: it creates the default branch + an initial commit, so commitBatch/
    /// read/write (which all assume an existing branch ref) work immediately after.
    /// Returns the created repo's default branch and html_url.
    @discardableResult
    func createRepo(owner: String, name: String, isPrivate: Bool,
                    description: String = "Created with Website Commander") async throws -> (defaultBranch: String, htmlURL: String) {
        let login = try await verifyToken()
        let underUser = login.caseInsensitiveCompare(owner) == .orderedSame
        let path = underUser ? "/user/repos" : "/orgs/\(owner)/repos"
        let payload: [String: Any] = [
            "name": name,
            "private": isPrivate,
            "auto_init": true,
            "description": description,
        ]
        let body = try JSONSerialization.data(withJSONObject: payload)
        do {
            let data = try await send(try makeRequest(path, method: "POST", body: body))
            guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw GitHubError.decoding("repo creation")
            }
            let defaultBranch = (obj["default_branch"] as? String) ?? "main"
            let html = (obj["html_url"] as? String) ?? "https://github.com/\(owner)/\(name)"
            return (defaultBranch, html)
        } catch GitHubError.forbidden {
            // A 403 here is NOT a file-permission problem — creating a repo needs a
            // broader scope than the Contents:write that editing files uses, so the
            // generic "set Contents to Read and write" message would be misleading.
            throw GitHubError.forbidden(underUser
                ? "Creating a repository needs broader access than editing files. Use “Sign in with GitHub” below (it grants the right scope), or a classic token with the repo scope."
                : "Your token can't create repositories in “\(owner)”. You need repo-creation permission for that organization, or create the site under your own account instead.")
        } catch let GitHubError.http(code, body) where code == 422 {
            // Repository creation has its own 422 semantics (most commonly an
            // invalid or already-used name), unrelated to branch protection.
            throw GitHubError.http(422, GitHubError.explain422(body))
        }
    }

    /// Enable GitHub Pages, serving `branch` at `path`. Returns the site URL.
    /// GitHub runs a first build after this call, so the URL 404s for ~30–90s —
    /// callers should show "Publishing…" rather than verify the URL immediately.
    /// A 409 means Pages was already enabled, which we treat as success.
    @discardableResult
    func enablePages(owner: String, name: String, branch: String, path: String = "/") async throws -> String {
        let payload: [String: Any] = ["source": ["branch": branch, "path": path]]
        let body = try JSONSerialization.data(withJSONObject: payload)
        do {
            _ = try await send(try makeRequest("/repos/\(owner)/\(name)/pages", method: "POST", body: body))
        } catch GitHubError.http(let code, _) where code == 409 {
            // Already enabled — nothing to do, fall through to return the URL.
        } catch GitHubError.forbidden {
            // 403 (admin scope) or 422 (private repo on a free plan) both surface
            // here via send()'s translation. Both point to the same fixes.
            throw GitHubError.forbidden("Enabling GitHub Pages needs admin access to this repo. Use “Sign in with GitHub” (grants it) or set Administration: write on the token. Note: GitHub Pages needs a public repo on free plans.")
        }
        // Pages hostnames are always lowercased.
        return "https://\(owner.lowercased()).github.io/\(name)/"
    }
}
