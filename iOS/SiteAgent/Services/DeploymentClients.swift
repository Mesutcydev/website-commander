import Foundation
import os

enum DeploymentProviderID: String, Codable {
    case cloudflare = "cloudflare"
    case cloudflareWorkers = "cloudflare-workers"
    case vercel = "vercel"
    case netlify = "netlify"
    case render = "render"
    case railway = "railway"
    case awsAmplify = "aws-amplify"
    case githubActions = "github-actions"
    case sshFtp = "ssh-ftp"
}

enum DeploymentState: String, Codable, Equatable {
    case queued
    case building
    case success
    case failure
    case canceled
    case unknown

    var isTerminal: Bool {
        switch self {
        case .success, .failure, .canceled: return true
        case .queued, .building, .unknown: return false
        }
    }

    var label: String {
        switch self {
        case .queued: return "Queued"
        case .building: return "Building"
        case .success: return "Live"
        case .failure: return "Failed"
        case .canceled: return "Canceled"
        case .unknown: return "Unknown"
        }
    }

    static func cloudflare(_ raw: String?) -> DeploymentState {
        let value = (raw ?? "").lowercased()
        if ["queued", "idle", "pending", "initializing"].contains(value) { return .queued }
        if ["active", "building", "running"].contains(value) { return .building }
        if ["success", "finished"].contains(value) { return .success }
        if ["failure", "failed", "error"].contains(value) { return .failure }
        if value == "canceled" || value == "cancelled" { return .canceled }
        return .unknown
    }

    /// Workers Builds exposes `status` (queued/initializing/running/stopped) and
    /// `build_outcome` (success/fail/skipped/cancelled/terminated) separately.
    static func cloudflareWorkersBuild(
        status: String?,
        buildOutcome: String?,
        createdAt: Date? = nil,
        finishedAt: Date? = nil
    ) -> DeploymentState {
        let statusValue = (status ?? "").lowercased()
        let outcomeValue = (buildOutcome ?? "").lowercased()

        if !outcomeValue.isEmpty {
            switch outcomeValue {
            case "success": return .success
            case "fail", "failed", "failure": return .failure
            case "cancelled", "canceled": return .canceled
            case "skipped", "terminated": return .canceled
            default: break
            }
        }

        switch statusValue {
        case "queued": return .queued
        case "initializing", "running": return .building
        case "stopped":
            if finishedAt != nil { return .success }
            return .unknown
        default:
            break
        }

        if let createdAt, finishedAt == nil, Date().timeIntervalSince(createdAt) < 900 {
            return .building
        }
        return .unknown
    }

    static func vercel(_ raw: String?) -> DeploymentState {
        let value = (raw ?? "").lowercased()
        if ["queued", "initializing"].contains(value) { return .queued }
        if value == "building" { return .building }
        if value == "ready" { return .success }
        if value == "error" { return .failure }
        if value == "canceled" || value == "cancelled" { return .canceled }
        return .unknown
    }

    static func netlify(_ raw: String?) -> DeploymentState {
        let value = (raw ?? "").lowercased()
        if ["new", "pending_review", "accepted", "enqueued", "prepared"].contains(value) { return .queued }
        if ["building", "uploading", "uploaded", "preparing", "processing", "retrying"].contains(value) { return .building }
        if ["ready", "processed"].contains(value) { return .success }
        if ["error", "rejected"].contains(value) { return .failure }
        return .unknown
    }

    static func githubActions(status: String?, conclusion: String?) -> DeploymentState {
        let statusValue = (status ?? "").lowercased()
        let conclusionValue = (conclusion ?? "").lowercased()
        if statusValue == "queued" || statusValue == "requested" || statusValue == "waiting" { return .queued }
        if statusValue == "in_progress" || statusValue == "pending" { return .building }
        if statusValue == "completed" {
            if conclusionValue == "success" { return .success }
            if ["failure", "timed_out", "startup_failure", "action_required"].contains(conclusionValue) { return .failure }
            if ["cancelled", "canceled", "skipped", "neutral"].contains(conclusionValue) { return .canceled }
        }
        return .unknown
    }

    static func render(_ raw: String?) -> DeploymentState {
        let value = (raw ?? "").lowercased()
        if ["created", "queued"].contains(value) { return .queued }
        if ["build_in_progress", "update_in_progress", "pre_deploy_in_progress"].contains(value) { return .building }
        if value == "live" { return .success }
        if ["build_failed", "update_failed", "failed"].contains(value) { return .failure }
        if value == "canceled" || value == "cancelled" || value == "deactivated" { return .canceled }
        return .unknown
    }

    static func railway(_ raw: String?) -> DeploymentState {
        let value = (raw ?? "").uppercased()
        if ["INITIALIZING", "WAITING", "QUEUED", "PENDING"].contains(value) { return .queued }
        if ["BUILDING", "DEPLOYING", "UPLOADING", "IN_PROGRESS"].contains(value) { return .building }
        if ["SUCCESS", "SUCCEEDED", "ACTIVE", "COMPLETED"].contains(value) { return .success }
        if ["FAILED", "CRASHED", "ERROR", "REMOVED"].contains(value) { return .failure }
        if ["CANCELED", "CANCELLED", "SKIPPED"].contains(value) { return .canceled }
        return .unknown
    }
}

struct DeploymentRecord: Identifiable, Equatable, Codable {
    var id: String
    var providerID: DeploymentProviderID
    var providerName: String
    var projectName: String
    var state: DeploymentState
    var branch: String?
    var commitSHA: String?
    var url: String?
    var createdAt: Date?
    var finishedAt: Date?
    var message: String?
    var logsURL: String?

    var shortSHA: String {
        guard let commitSHA, !commitSHA.isEmpty else { return "" }
        return String(commitSHA.prefix(7))
    }

    var displayURL: String {
        guard let url, !url.isEmpty else { return "" }
        if url.hasPrefix("http://") || url.hasPrefix("https://") { return url }
        return "https://\(url)"
    }
}

struct DeployLogLine: Identifiable, Equatable {
    let id = UUID()
    var timestamp: Date?
    var text: String
}

struct DeploymentDomain: Identifiable, Equatable {
    var id: String { name }
    var name: String
    var status: String
    var validationHint: String?
}

enum DeploymentClientError: LocalizedError, Equatable {
    case missingConfiguration(String)
    case unsupported(String)
    case http(Int, String)
    case decoding(String)
    case offline
    case timedOut
    case cancelled
    case invalidURL
    case invalidResponse
    case transport(code: Int, description: String)
    case unknown(String)

    /// Map transport / decoding / cancellation errors into typed cases.
    /// Real HTTP failures should use `fromHTTP(status:body:)` instead.
    static func map(_ error: Error) -> DeploymentClientError {
        if error is CancellationError { return .cancelled }
        if let typed = error as? DeploymentClientError { return typed }
        if let urlError = error as? URLError {
            switch urlError.code {
            case .notConnectedToInternet, .networkConnectionLost, .dataNotAllowed, .internationalRoamingOff:
                return .offline
            case .timedOut:
                return .timedOut
            case .cancelled:
                return .cancelled
            case .badURL, .unsupportedURL:
                return .invalidURL
            default:
                return .transport(code: urlError.errorCode, description: urlError.localizedDescription)
            }
        }
        if error is DecodingError {
            return .decoding(String(describing: error))
        }
        return .unknown(error.localizedDescription)
    }

    static func fromHTTP(status: Int, body: String) -> DeploymentClientError {
        .http(status, body)
    }

    var isCancellation: Bool {
        if case .cancelled = self { return true }
        return false
    }

    var isAuthenticationFailure: Bool {
        if case .http(let code, _) = self { return code == 401 || code == 403 }
        return false
    }

    var isNotFound: Bool {
        if case .http(let code, _) = self { return code == 404 }
        return false
    }

    var isTransient: Bool {
        switch self {
        case .offline, .timedOut, .invalidResponse:
            return true
        case .transport:
            return true
        case .http(let code, _):
            return code == 429 || (500...599).contains(code)
        case .unknown:
            return true
        default:
            return false
        }
    }

    var errorDescription: String? {
        switch self {
        case .missingConfiguration(let message):
            return message
        case .unsupported(let message):
            return message
        case .http(let code, let body):
            // Legacy sentinel (-1) must never be user-facing.
            if code < 0 {
                return body.isEmpty ? "Deployment history could not be loaded." : body
            }
            switch code {
            case 401:
                return "Cloudflare authentication has expired or is invalid."
            case 403:
                return "This account does not have permission to read deployments."
            case 404:
                return "The deployment project was not found."
            case 429:
                return "The deployment service is temporarily rate limited."
            case 500..<600:
                return "The deployment service is temporarily unavailable."
            default:
                return body.isEmpty ? "Deployment request failed (HTTP \(code))." : body
            }
        case .decoding:
            return "Deployment data could not be read."
        case .offline:
            return "You appear to be offline."
        case .timedOut:
            return "The deployment service took too long to respond."
        case .cancelled:
            return "The deployment request was cancelled."
        case .invalidURL:
            return "The deployment service URL is invalid."
        case .invalidResponse:
            return "The deployment service returned an invalid response."
        case .transport(_, let description):
            return description.isEmpty ? "Deployment history could not be loaded." : description
        case .unknown(let message):
            return message.isEmpty ? "Deployment history could not be loaded." : message
        }
    }

    /// Compact category for diagnostics / exportable reports (never includes secrets).
    var diagnosticCategory: String {
        switch self {
        case .offline: return "offline"
        case .timedOut: return "timeout"
        case .cancelled: return "cancellation"
        case .invalidURL: return "invalid_url"
        case .invalidResponse: return "invalid_response"
        case .decoding: return "decoding"
        case .missingConfiguration: return "configuration"
        case .unsupported: return "unsupported"
        case .transport(let code, _): return "transport:\(code)"
        case .http(let code, _): return "http:\(code)"
        case .unknown: return "unknown"
        }
    }
}

protocol DeploymentClient {
    var providerID: DeploymentProviderID { get }
    var providerName: String { get }
    var supportsRetry: Bool { get }
    var supportsRollback: Bool { get }
    var supportsPurgeBuildCache: Bool { get }
    var supportsDomains: Bool { get }

    func listDeployments(limit: Int, commitSHA: String?) async throws -> [DeploymentRecord]
    func logs(for deployment: DeploymentRecord, limit: Int) async throws -> [DeployLogLine]
    func retry(_ deployment: DeploymentRecord) async throws
    func rollback(_ deployment: DeploymentRecord) async throws
    func purgeBuildCache() async throws
    func domains() async throws -> [DeploymentDomain]
}

extension DeploymentClient {
    var supportsRetry: Bool { false }
    var supportsRollback: Bool { false }
    var supportsPurgeBuildCache: Bool { false }
    var supportsDomains: Bool { false }

    func logs(for deployment: DeploymentRecord, limit: Int) async throws -> [DeployLogLine] { [] }
    func retry(_ deployment: DeploymentRecord) async throws {
        throw DeploymentClientError.unsupported("\(providerName) retry is not available from Website Commander yet.")
    }
    func rollback(_ deployment: DeploymentRecord) async throws {
        throw DeploymentClientError.unsupported("\(providerName) rollback is not available from Website Commander yet.")
    }
    func purgeBuildCache() async throws {
        throw DeploymentClientError.unsupported("\(providerName) build-cache purge is not available from Website Commander yet.")
    }
    func domains() async throws -> [DeploymentDomain] { [] }
}

/// Per-workspace deploy-history cache (memory + App Support JSON).
/// Live fetch stays the source of truth; cache is a stale-while-revalidate layer.
enum DeploymentHistoryCache {
    struct Entry: Codable, Equatable {
        var siteID: String
        var deployments: [DeploymentRecord]
        var fetchedAt: Date
    }

    struct ServeMetadata: Equatable {
        var servedFromCache: Bool
        var fetchedAt: Date?
    }

    private static let lock = NSLock()
    private static var entries: [String: Entry] = [:]
    private static var lastServe: [String: ServeMetadata] = [:]
    /// Soft cap so long sessions don't retain deploy history for every workspace forever.
    private static let maxWorkspaces = 32
    private static let log = Logger(subsystem: "uk.mesut.SiteAgent", category: "DeploymentHistory")

    static func records(for workspaceID: String) -> [DeploymentRecord]? {
        lock.lock()
        if let memory = entries[workspaceID]?.deployments {
            lock.unlock()
            return memory
        }
        lock.unlock()
        loadFromDiskIfNeeded(workspaceID)
        lock.lock(); defer { lock.unlock() }
        return entries[workspaceID]?.deployments
    }

    static func fetchedAt(for workspaceID: String) -> Date? {
        loadFromDiskIfNeeded(workspaceID)
        lock.lock(); defer { lock.unlock() }
        return entries[workspaceID]?.fetchedAt
    }

    /// Metadata from the most recent `withFallback` call for this workspace.
    static func consumeLastServe(for workspaceID: String) -> ServeMetadata {
        lock.lock(); defer { lock.unlock() }
        let meta = lastServe[workspaceID] ?? ServeMetadata(servedFromCache: false, fetchedAt: nil)
        lastServe[workspaceID] = nil
        return meta
    }

    static func setRecords(_ records: [DeploymentRecord], for workspaceID: String, fetchedAt: Date = Date()) {
        let entry = Entry(siteID: workspaceID, deployments: records, fetchedAt: fetchedAt)
        lock.lock()
        entries[workspaceID] = entry
        trimLocked()
        lock.unlock()
        persist(entry)
    }

    static func clear(for workspaceID: String) {
        lock.lock()
        entries.removeValue(forKey: workspaceID)
        lastServe.removeValue(forKey: workspaceID)
        lock.unlock()
        try? FileManager.default.removeItem(at: fileURL(for: workspaceID))
    }

    /// Test-only: drop in-memory entries (disk files cleared per-id via `clear`).
    static func resetMemoryForTests() {
        lock.lock()
        entries.removeAll()
        lastServe.removeAll()
        lock.unlock()
    }

    /// Run a live `listDeployments`, cache on success, and on transient failure
    /// return cached records when available. Cancellation always rethrows and
    /// never clears cache. Auth/config errors (401/403/404) still throw.
    static func withFallback(
        for workspaceID: String,
        fetch: () async throws -> [DeploymentRecord]
    ) async throws -> [DeploymentRecord] {
        let requestID = String(UUID().uuidString.prefix(8))
        let started = Date()
        loadFromDiskIfNeeded(workspaceID)

        do {
            let records = try await fetch()
            let now = Date()
            setRecords(records, for: workspaceID, fetchedAt: now)
            markServe(workspaceID, servedFromCache: false, fetchedAt: now)
            let durationMs = Int(Date().timeIntervalSince(started) * 1000)
            log.info("Deployment history finished requestID=\(requestID, privacy: .public) site=\(Self.redacted(workspaceID), privacy: .public) status=ok durationMs=\(durationMs, privacy: .public) count=\(records.count, privacy: .public) cache=miss")
            return records
        } catch {
            let mapped = DeploymentClientError.map(error)
            if mapped.isCancellation {
                log.info("Deployment history finished requestID=\(requestID, privacy: .public) site=\(Self.redacted(workspaceID), privacy: .public) status=cancelled")
                throw mapped
            }

            // Auth/config/not-found must surface; never mask with stale history.
            let mustSurface: Bool = {
                switch mapped {
                case .missingConfiguration, .unsupported, .invalidURL:
                    return true
                default:
                    return mapped.isAuthenticationFailure || mapped.isNotFound
                }
            }()

            if !mustSurface, let cached = records(for: workspaceID) {
                let fetched = fetchedAt(for: workspaceID)
                markServe(workspaceID, servedFromCache: true, fetchedAt: fetched)
                let durationMs = Int(Date().timeIntervalSince(started) * 1000)
                log.info("Deployment history finished requestID=\(requestID, privacy: .public) site=\(Self.redacted(workspaceID), privacy: .public) status=cache_fallback durationMs=\(durationMs, privacy: .public) count=\(cached.count, privacy: .public) error=\(mapped.diagnosticCategory, privacy: .public)")
                return cached
            }

            let durationMs = Int(Date().timeIntervalSince(started) * 1000)
            log.info("Deployment history finished requestID=\(requestID, privacy: .public) site=\(Self.redacted(workspaceID), privacy: .public) status=error durationMs=\(durationMs, privacy: .public) error=\(mapped.diagnosticCategory, privacy: .public)")
            throw mapped
        }
    }

    /// Best-effort background warm/refresh of a workspace's cached history.
    /// No-op when the workspace has no deploy client configured.
    static func refreshInBackground(for workspace: SiteWorkspace, repo: RepoConfig) {
        Task.detached(priority: .utility) {
            guard let client = DeploymentClientFactory.client(for: workspace, repo: repo) else { return }
            _ = try? await client.listDeployments(limit: 10, commitSHA: nil)
        }
    }

    // MARK: - Internals

    private static func markServe(_ workspaceID: String, servedFromCache: Bool, fetchedAt: Date?) {
        lock.lock(); defer { lock.unlock() }
        lastServe[workspaceID] = ServeMetadata(servedFromCache: servedFromCache, fetchedAt: fetchedAt)
    }

    private static func trimLocked() {
        while entries.count > maxWorkspaces, let oldest = entries.keys.first {
            entries.removeValue(forKey: oldest)
        }
    }

    private static func redacted(_ workspaceID: String) -> String {
        let prefix = workspaceID.prefix(8)
        return "\(prefix)…"
    }

    private static func cacheDirectory() throws -> URL {
        let root = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let dir = root.appendingPathComponent("DeploymentHistory", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private static func fileURL(for workspaceID: String) -> URL {
        let safe = workspaceID.replacingOccurrences(of: "/", with: "_")
        // Best-effort path; callers tolerate failure.
        let dir = (try? cacheDirectory()) ?? FileManager.default.temporaryDirectory
        return dir.appendingPathComponent("\(safe).json")
    }

    private static func persist(_ entry: Entry) {
        do {
            let data = try JSONEncoder().encode(entry)
            try data.write(to: fileURL(for: entry.siteID), options: .atomic)
        } catch {
            log.error("Failed to persist deployment cache for \(Self.redacted(entry.siteID), privacy: .public)")
        }
    }

    private static func loadFromDiskIfNeeded(_ workspaceID: String) {
        lock.lock()
        if entries[workspaceID] != nil {
            lock.unlock()
            return
        }
        lock.unlock()

        let url = fileURL(for: workspaceID)
        guard let data = try? Data(contentsOf: url),
              let entry = try? JSONDecoder().decode(Entry.self, from: data) else { return }
        lock.lock()
        if entries[workspaceID] == nil {
            entries[workspaceID] = entry
            trimLocked()
        }
        lock.unlock()
    }
}

enum DeploymentClientFactory {
    static func client(for workspace: SiteWorkspace, repo: RepoConfig) -> DeploymentClient? {
        switch workspace.deployment {
        case .cloudflarePages:
            guard let token = token(.cloudflare, workspace: workspace),
                  let accountID = workspace.deploymentConfig.trimmed("cloudflareAccountID"),
                  let projectName = workspace.deploymentConfig.trimmed("cloudflareProjectName") else { return nil }
            return CloudflarePagesClient(workspace: workspace, token: token, accountID: accountID, projectName: projectName)
        case .cloudflareWorkers:
            guard let token = token(.cloudflareWorkers, workspace: workspace),
                  let accountID = workspace.deploymentConfig.trimmed("cloudflareAccountID"),
                  let workerName = workspace.deploymentConfig.trimmed("cloudflareWorkerName") else { return nil }
            return CloudflareWorkersClient(workspace: workspace, token: token, accountID: accountID, workerName: workerName)
        case .vercel:
            guard let token = token(.vercel, workspace: workspace),
                  let project = workspace.deploymentConfig.trimmed("vercelProjectID")
                    ?? workspace.deploymentConfig.trimmed("vercelProjectName") else { return nil }
            return VercelDeployClient(workspace: workspace, token: token, projectIDOrName: project)
        case .netlify:
            guard let token = token(.netlify, workspace: workspace),
                  let siteID = workspace.deploymentConfig.trimmed("netlifySiteID") else { return nil }
            return NetlifyDeployClient(workspace: workspace, token: token, siteID: siteID)
        case .render:
            guard let token = token(.render, workspace: workspace),
                  let serviceID = workspace.deploymentConfig.trimmed("renderServiceID")
                    ?? workspace.deploymentConfig.trimmed("renderServiceId") else { return nil }
            return RenderDeployClient(workspace: workspace, token: token, serviceID: serviceID)
        case .railway:
            guard let token = token(.railway, workspace: workspace),
                  let projectID = workspace.deploymentConfig.trimmed("railwayProjectID")
                    ?? workspace.deploymentConfig.trimmed("railwayProjectId"),
                  let serviceID = workspace.deploymentConfig.trimmed("railwayServiceID")
                    ?? workspace.deploymentConfig.trimmed("railwayServiceId"),
                  let environmentID = workspace.deploymentConfig.trimmed("railwayEnvironmentID")
                    ?? workspace.deploymentConfig.trimmed("railwayEnvironmentId") else { return nil }
            let useProjectToken = workspace.deploymentConfig.trimmed("railwayTokenType") == "project"
            return RailwayDeployClient(
                workspace: workspace,
                token: token,
                projectID: projectID,
                serviceID: serviceID,
                environmentID: environmentID,
                useProjectToken: useProjectToken
            )
        case .awsAmplify:
            return nil
        case .githubPages:
            guard Keychain.hasGitHubToken(credentialID: repo.githubCredentialID) else { return nil }
            return GitHubActionsDeployClient(workspace: workspace, repo: repo)
        case .sshFtp:
            return SSHFTPUnavailableClient()
        }
    }

    static func token(_ provider: DeploymentProviderID, workspace: SiteWorkspace) -> String? {
        let value = Keychain.get(Keychain.deploymentToken(provider.rawValue, workspaceID: workspace.id))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return value?.isEmpty == false ? value : nil
    }

    static func deployHookURL(for workspace: SiteWorkspace) -> URL? {
        guard let raw = Keychain.get(Keychain.deployHookURL(workspaceID: workspace.id))?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty else { return nil }
        // Keychain values can outlive a provider change or be pasted with a
        // malformed scheme. Treat them as missing configuration instead of
        // handing an invalid URL to URLRequest later in the action flow.
        return normalizedDeployHookURL(raw)
    }

    static func normalizedDeployHookURL(_ raw: String) -> URL? {
        SiteWorkspace.normalizedLiveURL(raw)
    }

    static func triggerDeployHook(for workspace: SiteWorkspace) async throws {
        guard let url = deployHookURL(for: workspace) else {
            throw DeploymentClientError.missingConfiguration("Add a deploy hook URL for this workspace first.")
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("WebsiteCommander-iOS", forHTTPHeaderField: "User-Agent")
        req.timeoutInterval = 20
        do {
            // Route through DeployJSON.send for 429/5xx backoff parity. The hook
            // URL embeds its secret in the path, so never let a transport error
            // (URLError.failedURL) or a raw response body surface verbatim.
            _ = try await DeployJSON.send(req)
        } catch let err as DeploymentClientError {
            switch err {
            case .http(let code, _):
                throw DeploymentClientError.http(code, "deploy hook request failed")
            case .cancelled:
                throw err
            default:
                throw err
            }
        } catch {
            throw DeploymentClientError.map(error)
        }
    }
}

private extension Dictionary where Key == String, Value == String {
    func trimmed(_ key: String) -> String? {
        let value = self[key]?.trimmingCharacters(in: .whitespacesAndNewlines)
        return value?.isEmpty == false ? value : nil
    }
}

enum DeployJSON {
    static let isoFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    static let isoFormatterNoFraction: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    static func date(_ any: Any?) -> Date? {
        if let string = any as? String {
            return isoFormatter.date(from: string) ?? isoFormatterNoFraction.date(from: string)
        }
        if let millis = any as? Double {
            return Date(timeIntervalSince1970: millis > 10_000_000_000 ? millis / 1000.0 : millis)
        }
        if let millis = any as? Int {
            let raw = Double(millis)
            return Date(timeIntervalSince1970: raw > 10_000_000_000 ? raw / 1000.0 : raw)
        }
        return nil
    }

    static func string(_ obj: [String: Any], _ keys: String...) -> String? {
        for key in keys {
            if let value = obj[key] as? String, !value.isEmpty { return value }
        }
        return nil
    }

    static func object(_ obj: [String: Any], _ key: String) -> [String: Any] {
        obj[key] as? [String: Any] ?? [:]
    }

    static func send(_ req: URLRequest, attempt: Int = 0) async throws -> Data {
        var request = req
        // URLRequest's system default is 60s. Only rewrite that default to 30s —
        // preserve shorter (deploy hook = 20s) and any explicitly longer timeouts.
        if abs(request.timeoutInterval - 60) < 0.001 {
            request.timeoutInterval = 30
        }

        let data: Data
        let resp: URLResponse
        do {
            (data, resp) = try await URLSession.shared.data(for: request)
        } catch {
            throw DeploymentClientError.map(error)
        }

        guard let http = resp as? HTTPURLResponse else {
            throw DeploymentClientError.invalidResponse
        }
        if (200..<300).contains(http.statusCode) { return data }

        // Retry only idempotent methods. POSTing deploy/retry/rollback/hook again
        // on a lost 5xx response can duplicate side effects.
        let method = (request.httpMethod ?? "GET").uppercased()
        let idempotent = method == "GET" || method == "HEAD" || method == "OPTIONS"
        if idempotent, attempt < 2, http.statusCode == 429 || http.statusCode >= 500 {
            let retryAfterHeader = Double(http.value(forHTTPHeaderField: "retry-after") ?? "")
            let base = retryAfterHeader ?? pow(2.0, Double(attempt))
            let jitter = Double.random(in: 0...0.35)
            let delay = min(base + jitter, 6)
            // Honour task cancellation during backoff (do not swallow with try?).
            try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            return try await send(request, attempt: attempt + 1)
        }
        throw DeploymentClientError.fromHTTP(
            status: http.statusCode,
            body: sanitizeErrorBody(data, status: http.statusCode)
        )
    }

    /// Test seam for `sanitizeErrorBody` (private enum otherwise).
    static func sanitizeErrorBodyForTests(_ data: Data, status: Int) -> String {
        sanitizeErrorBody(data, status: status)
    }

    /// Strip tokens / long opaque blobs from provider error bodies before they
    /// reach UI, logs, or LLM tool history.
    static func sanitizeErrorBody(_ data: Data, status: Int) -> String {
        let raw = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if raw.isEmpty { return "HTTP \(status)" }
        var text = raw
        // Collapse obvious bearer/token fragments.
        if let re = try? NSRegularExpression(pattern: #"(?i)(bearer\s+)[A-Za-z0-9._\-+/=]{8,}"#) {
            text = re.stringByReplacingMatches(in: text, options: [], range: NSRange(text.startIndex..., in: text), withTemplate: "$1[redacted]")
        }
        // Keep the original closing quote (template adds none) so redacted JSON
        // stays parseable and the message-extraction below still works.
        if let re = try? NSRegularExpression(pattern: #"(?i)("?(?:access_)?token"?\s*:\s*")[^"]{8,}"#) {
            text = re.stringByReplacingMatches(in: text, options: [], range: NSRange(text.startIndex..., in: text), withTemplate: "$1[redacted]")
        }
        // Prefer short JSON message fields when present.
        if let obj = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] {
            let message = (obj["message"] as? String)
                ?? (obj["error"] as? String)
                ?? ((obj["error"] as? [String: Any])?["message"] as? String)
                ?? ((obj["errors"] as? [[String: Any]])?.first?["message"] as? String)
            if let message, !message.isEmpty {
                return String(message.prefix(240))
            }
        }
        return String(text.prefix(240))
    }
}

enum CloudflarePages {
    /// List the Pages project slugs in an account. Used to turn a 404
    /// "project not found" into a pick-the-right-name flow.
    static func listProjectNames(accountID: String, token: String) async throws -> [String] {
        guard let url = URL(string: "https://api.cloudflare.com/client/v4/accounts/\(accountID)/pages/projects") else {
            throw DeploymentClientError.invalidURL
        }
        var req = URLRequest(url: url)
        req.setValue("Bearer \(token.trimmingCharacters(in: .whitespacesAndNewlines))", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue("WebsiteCommander-iOS", forHTTPHeaderField: "User-Agent")
        let data = try await DeployJSON.send(req)
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let result = obj["result"] as? [[String: Any]] else {
            throw DeploymentClientError.decoding("Cloudflare projects")
        }
        return result.compactMap { $0["name"] as? String }
    }
}

struct CloudflarePagesClient: DeploymentClient {
    let providerID: DeploymentProviderID = .cloudflare
    let providerName = "Cloudflare Pages"
    let workspace: SiteWorkspace
    let token: String
    let accountID: String
    let projectName: String

    var supportsRetry: Bool { true }
    var supportsRollback: Bool { true }
    var supportsPurgeBuildCache: Bool { true }
    var supportsDomains: Bool { true }

    private var base: URL { SiteAgentURL.constant("https://api.cloudflare.com/client/v4") }

    func listDeployments(limit: Int, commitSHA: String?) async throws -> [DeploymentRecord] {
        try await DeploymentHistoryCache.withFallback(for: workspace.id.uuidString) {
            guard var components = URLComponents(url: base.appendingPathComponent("accounts/\(accountID)/pages/projects/\(projectName)/deployments"), resolvingAgainstBaseURL: false) else {
                throw DeploymentClientError.invalidURL
            }
            components.queryItems = [URLQueryItem(name: "per_page", value: "\(limit)")]
            guard let url = components.url else { throw DeploymentClientError.invalidURL }
            let data = try await DeployJSON.send(try request(url))
            guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw DeploymentClientError.decoding("Cloudflare deployments")
            }
            let result = obj["result"] as? [[String: Any]] ?? []
            let records = result.map(parseDeployment)
            guard let commitSHA, !commitSHA.isEmpty else { return records }
            return records.filter { $0.commitSHA?.hasPrefix(commitSHA) == true || commitSHA.hasPrefix($0.commitSHA ?? " ") }
        }
    }

    func logs(for deployment: DeploymentRecord, limit: Int) async throws -> [DeployLogLine] {
        let url = base.appendingPathComponent("accounts/\(accountID)/pages/projects/\(projectName)/deployments/\(deployment.id)/history/logs")
        let data = try await DeployJSON.send(try request(url))
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw DeploymentClientError.decoding("Cloudflare logs")
        }
        let result = obj["result"] as? [String: Any] ?? obj
        let rows = result["data"] as? [[String: Any]] ?? []
        return rows.suffix(limit).map {
            DeployLogLine(timestamp: DeployJSON.date($0["ts"]), text: ($0["line"] as? String) ?? "")
        }
    }

    func retry(_ deployment: DeploymentRecord) async throws {
        let url = base.appendingPathComponent("accounts/\(accountID)/pages/projects/\(projectName)/deployments/\(deployment.id)/retry")
        _ = try await DeployJSON.send(try request(url, method: "POST"))
    }

    func rollback(_ deployment: DeploymentRecord) async throws {
        let url = base.appendingPathComponent("accounts/\(accountID)/pages/projects/\(projectName)/deployments/\(deployment.id)/rollback")
        _ = try await DeployJSON.send(try request(url, method: "POST"))
    }

    func purgeBuildCache() async throws {
        let url = base.appendingPathComponent("accounts/\(accountID)/pages/projects/\(projectName)/purge_build_cache")
        _ = try await DeployJSON.send(try request(url, method: "POST"))
    }

    func domains() async throws -> [DeploymentDomain] {
        let url = base.appendingPathComponent("accounts/\(accountID)/pages/projects/\(projectName)/domains")
        let data = try await DeployJSON.send(try request(url))
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw DeploymentClientError.decoding("Cloudflare domains")
        }
        let result = obj["result"] as? [[String: Any]] ?? []
        return result.compactMap { item in
            guard let name = item["name"] as? String else { return nil }
            let validation = item["validation_data"] as? [String: Any] ?? [:]
            let txtName = validation["txt_name"] as? String
            let txtValue = validation["txt_value"] as? String
            let hint = [txtName, txtValue].compactMap { $0 }.joined(separator: " = ")
            return DeploymentDomain(name: name, status: (item["status"] as? String) ?? "unknown", validationHint: hint.isEmpty ? nil : hint)
        }
    }

    private func request(_ url: URL, method: String = "GET") throws -> URLRequest {
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue("WebsiteCommander-iOS", forHTTPHeaderField: "User-Agent")
        return req
    }

    private func parseDeployment(_ item: [String: Any]) -> DeploymentRecord {
        let latestStage = DeployJSON.object(item, "latest_stage")
        let trigger = DeployJSON.object(item, "deployment_trigger")
        let metadata = DeployJSON.object(trigger, "metadata")
        let source = DeployJSON.object(item, "source")
        let config = DeployJSON.object(source, "config")
        let id = DeployJSON.string(item, "id", "short_id") ?? UUID().uuidString
        let commit = DeployJSON.string(metadata, "commit_hash", "commit_sha", "commit_ref")
        let status = DeployJSON.string(latestStage, "status") ?? DeployJSON.string(item, "status")
        let url = DeployJSON.string(item, "url") ?? (item["aliases"] as? [String])?.first
        return DeploymentRecord(
            id: id,
            providerID: .cloudflare,
            providerName: providerName,
            projectName: DeployJSON.string(item, "project_name") ?? projectName,
            state: DeploymentState.cloudflare(status),
            branch: DeployJSON.string(config, "branch") ?? DeployJSON.string(metadata, "branch"),
            commitSHA: commit,
            url: url,
            createdAt: DeployJSON.date(item["created_on"]),
            finishedAt: DeployJSON.date(item["modified_on"]),
            message: DeployJSON.string(metadata, "commit_message") ?? DeployJSON.string(latestStage, "name"),
            logsURL: nil
        )
    }
}

enum CloudflareWorkers {
    private static let tagCacheLock = NSLock()
    private static var tagCache: [String: String] = [:]
    private static let tagCacheMaxEntries = 64

    /// List Worker script names in an account (the script `id` is its name).
    /// Needs a token with Workers Scripts:Read.
    static func listScriptNames(accountID: String, token: String) async throws -> [String] {
        guard let url = URL(string: "https://api.cloudflare.com/client/v4/accounts/\(accountID)/workers/scripts") else {
            throw DeploymentClientError.invalidURL
        }
        var req = URLRequest(url: url)
        req.setValue("Bearer \(token.trimmingCharacters(in: .whitespacesAndNewlines))", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue("WebsiteCommander-iOS", forHTTPHeaderField: "User-Agent")
        let data = try await DeployJSON.send(req)
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let result = obj["result"] as? [[String: Any]] else {
            throw DeploymentClientError.decoding("Cloudflare Workers scripts")
        }
        return result.compactMap { $0["id"] as? String }
    }

    /// Resolve a Worker's immutable tag (`external_script_id`) from its name.
    static func resolveWorkerTag(accountID: String, token: String, workerName: String) async throws -> String {
        let cacheKey = "\(accountID):\(workerName)"
        if let cached = cachedTag(for: cacheKey) { return cached }

        guard let url = URL(string: "https://api.cloudflare.com/client/v4/accounts/\(accountID)/workers/scripts") else {
            throw DeploymentClientError.invalidURL
        }
        var req = URLRequest(url: url)
        req.setValue("Bearer \(token.trimmingCharacters(in: .whitespacesAndNewlines))", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue("WebsiteCommander-iOS", forHTTPHeaderField: "User-Agent")
        let data = try await DeployJSON.send(req)
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let result = obj["result"] as? [[String: Any]] else {
            throw DeploymentClientError.decoding("Cloudflare Workers scripts")
        }
        guard let tag = result.first(where: { ($0["id"] as? String) == workerName })?["tag"] as? String,
              !tag.isEmpty else {
            throw DeploymentClientError.missingConfiguration("Worker \"\(workerName)\" not found in this Cloudflare account.")
        }
        storeTag(tag, for: cacheKey)
        return tag
    }

    private static func cachedTag(for key: String) -> String? {
        tagCacheLock.lock(); defer { tagCacheLock.unlock() }
        return tagCache[key]
    }

    private static func storeTag(_ tag: String, for key: String) {
        tagCacheLock.lock(); defer { tagCacheLock.unlock() }
        tagCache[key] = tag
        while tagCache.count > tagCacheMaxEntries, let first = tagCache.keys.first {
            tagCache.removeValue(forKey: first)
        }
    }
}

/// Status for Git-connected Cloudflare Workers (Workers Builds). Triggering is
/// done with a deploy hook (see DeploymentClientFactory.triggerDeployHook), which
/// is the supported path for Workers Builds and needs no API token.
struct CloudflareWorkersClient: DeploymentClient {
    let providerID: DeploymentProviderID = .cloudflareWorkers
    let providerName = "Cloudflare Workers"
    let workspace: SiteWorkspace
    let token: String
    let accountID: String
    let workerName: String

    private var base: URL { SiteAgentURL.constant("https://api.cloudflare.com/client/v4") }

    private var buildsDashboardURL: String {
        "https://dash.cloudflare.com/\(accountID)/workers/services/view/\(workerName)/production/builds"
    }

    func listDeployments(limit: Int, commitSHA: String?) async throws -> [DeploymentRecord] {
        try await DeploymentHistoryCache.withFallback(for: workspace.id.uuidString) {
            do {
                let records = try await listBuildDeployments(limit: limit, commitSHA: commitSHA)
                if !records.isEmpty { return records }
            } catch let err as DeploymentClientError {
                // Auth / missing project: try the legacy script deployments path.
                if err.isAuthenticationFailure || err.isNotFound {
                    // fall through
                } else {
                    throw err
                }
            }
            return try await listScriptDeployments(limit: limit, commitSHA: commitSHA)
        }
    }

    func logs(for deployment: DeploymentRecord, limit: Int) async throws -> [DeployLogLine] {
        let url = base.appendingPathComponent("accounts/\(accountID)/builds/builds/\(deployment.id)/logs")
        do {
            let data = try await DeployJSON.send(try request(url))
            guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw DeploymentClientError.decoding("Cloudflare Workers build logs")
            }
            let result = obj["result"] as? [String: Any] ?? obj
            let rows = result["lines"] as? [[Any]] ?? []
            let parsed = rows.compactMap { row -> DeployLogLine? in
                guard row.count >= 2 else { return nil }
                let text = (row[1] as? String) ?? String(describing: row[1])
                guard !text.isEmpty else { return nil }
                return DeployLogLine(timestamp: DeployJSON.date(row[0]), text: text)
            }
            if !parsed.isEmpty { return Array(parsed.suffix(limit)) }
        } catch let err as DeploymentClientError {
            if case .http(let code, _) = err, code != 404 && code != 501 { throw err }
        }
        let dashboard = deployment.logsURL ?? buildsDashboardURL
        var lines = [DeployLogLine(timestamp: deployment.createdAt,
                                   text: "Build log lines aren't available via API for this deployment.")]
        if let message = deployment.message, !message.isEmpty {
            lines.insert(DeployLogLine(timestamp: deployment.createdAt, text: message), at: 0)
        }
        lines.append(DeployLogLine(timestamp: deployment.createdAt,
                                   text: "Open build logs in the Cloudflare dashboard: \(dashboard)"))
        return Array(lines.suffix(limit))
    }

    func rollback(_ deployment: DeploymentRecord) async throws {
        throw DeploymentClientError.unsupported("Cloudflare Workers Builds has no rollback API. Re-trigger the deploy hook on a pinned commit to redeploy that version.")
    }

    private func listBuildDeployments(limit: Int, commitSHA: String?) async throws -> [DeploymentRecord] {
        let workerTag = try await CloudflareWorkers.resolveWorkerTag(
            accountID: accountID, token: token, workerName: workerName
        )
        let url = base.appendingPathComponent("accounts/\(accountID)/builds/workers/\(workerTag)/builds")
        let data = try await DeployJSON.send(try request(url))
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw DeploymentClientError.decoding("Cloudflare Workers builds")
        }
        let rows: [[String: Any]]
        if let array = obj["result"] as? [[String: Any]] {
            rows = array
        } else if let result = obj["result"] as? [String: Any],
                  let builds = result["builds"] as? [[String: Any]] {
            rows = builds
        } else {
            rows = []
        }
        let records = Array(rows.prefix(limit).map(parseBuild))
        return filterRecords(records, commitSHA: commitSHA)
    }

    private func listScriptDeployments(limit: Int, commitSHA: String?) async throws -> [DeploymentRecord] {
        let url = base.appendingPathComponent("accounts/\(accountID)/workers/scripts/\(workerName)/deployments")
        let data = try await DeployJSON.send(try request(url))
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw DeploymentClientError.decoding("Cloudflare Workers deployments")
        }
        let result = obj["result"] as? [String: Any]
        let rows = (result?["deployments"] as? [[String: Any]]) ?? (obj["result"] as? [[String: Any]]) ?? []
        let records = Array(rows.prefix(limit).map(parseScriptDeployment))
        return filterRecords(records, commitSHA: commitSHA)
    }

    private func filterRecords(_ records: [DeploymentRecord], commitSHA: String?) -> [DeploymentRecord] {
        guard let commitSHA, !commitSHA.isEmpty else { return records }
        let matches = records.filter {
            $0.commitSHA?.hasPrefix(commitSHA) == true || commitSHA.hasPrefix($0.commitSHA ?? " ")
        }
        return matches.isEmpty ? records : matches
    }

    private func request(_ url: URL, method: String = "GET") throws -> URLRequest {
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue("WebsiteCommander-iOS", forHTTPHeaderField: "User-Agent")
        return req
    }

    private func parseBuild(_ item: [String: Any]) -> DeploymentRecord {
        let triggerMeta = DeployJSON.object(item, "build_trigger_metadata")
        let id = DeployJSON.string(item, "build_uuid", "id") ?? UUID().uuidString
        let status = DeployJSON.string(item, "status")
        let outcome = DeployJSON.string(item, "build_outcome")
        let createdAt = DeployJSON.date(item["created_on"])
        let finishedAt = DeployJSON.date(item["stopped_on"] ?? item["modified_on"])
        let commit = DeployJSON.string(triggerMeta, "commit_hash", "commit_sha", "sha")
        let branch = DeployJSON.string(triggerMeta, "branch") ?? workspace.gitBranch.nilIfEmpty
        let message = DeployJSON.string(triggerMeta, "commit_message")
            ?? DeployJSON.string(triggerMeta, "author")
            ?? "Worker build"
        let liveURL = workspace.deploymentConfig.trimmed("liveURL")
        return DeploymentRecord(
            id: id,
            providerID: .cloudflareWorkers,
            providerName: providerName,
            projectName: workerName,
            state: DeploymentState.cloudflareWorkersBuild(
                status: status,
                buildOutcome: outcome,
                createdAt: createdAt,
                finishedAt: finishedAt
            ),
            branch: branch,
            commitSHA: commit,
            url: liveURL,
            createdAt: createdAt,
            finishedAt: finishedAt,
            message: message,
            logsURL: "\(buildsDashboardURL)/\(id)"
        )
    }

    /// Script deployment rollouts from the legacy deployments endpoint are
    /// completed publishes — they don't expose build status fields.
    private func parseScriptDeployment(_ item: [String: Any]) -> DeploymentRecord {
        let annotations = DeployJSON.object(item, "annotations")
        let createdAt = DeployJSON.date(item["created_on"])
        let id = DeployJSON.string(item, "id") ?? UUID().uuidString
        let message = DeployJSON.string(annotations, "workers/message")
            ?? DeployJSON.string(item, "author_email")
            ?? "Worker deployment"
        let liveURL = workspace.deploymentConfig.trimmed("liveURL")
        return DeploymentRecord(
            id: id,
            providerID: .cloudflareWorkers,
            providerName: providerName,
            projectName: workerName,
            state: .success,
            branch: workspace.gitBranch.nilIfEmpty,
            commitSHA: nil,
            url: liveURL,
            createdAt: createdAt,
            finishedAt: createdAt,
            message: message,
            logsURL: buildsDashboardURL
        )
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

struct VercelDeployClient: DeploymentClient {
    let providerID: DeploymentProviderID = .vercel
    let providerName = "Vercel"
    let workspace: SiteWorkspace
    let token: String
    let projectIDOrName: String

    var supportsRollback: Bool { true }

    private var base: URL { SiteAgentURL.constant("https://api.vercel.com") }

    func listDeployments(limit: Int, commitSHA: String?) async throws -> [DeploymentRecord] {
        try await DeploymentHistoryCache.withFallback(for: workspace.id.uuidString) {
            guard var components = URLComponents(url: base.appendingPathComponent("v6/deployments"), resolvingAgainstBaseURL: false) else {
                throw DeploymentClientError.invalidURL
            }
            var query = [
                URLQueryItem(name: "limit", value: "\(limit)"),
                URLQueryItem(name: "projectId", value: projectIDOrName),
                URLQueryItem(name: "target", value: "production")
            ]
            if let branch = workspace.deploymentConfig.trimmed("vercelBranch") ?? workspace.deploymentConfig.trimmed("branch") ?? Optional(workspace.gitBranch) {
                query.append(URLQueryItem(name: "branch", value: branch))
            }
            if let commitSHA { query.append(URLQueryItem(name: "sha", value: commitSHA)) }
            if let teamID = workspace.deploymentConfig.trimmed("vercelTeamID") {
                query.append(URLQueryItem(name: "teamId", value: teamID))
            }
            components.queryItems = query
            guard let url = components.url else { throw DeploymentClientError.invalidURL }
            let data = try await DeployJSON.send(try request(url))
            guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw DeploymentClientError.decoding("Vercel deployments")
            }
            let result = obj["deployments"] as? [[String: Any]] ?? []
            return result.map(parseDeployment)
        }
    }

    func logs(for deployment: DeploymentRecord, limit: Int) async throws -> [DeployLogLine] {
        guard var components = URLComponents(url: base.appendingPathComponent("v3/deployments/\(deployment.id)/events"), resolvingAgainstBaseURL: false) else {
            throw DeploymentClientError.invalidURL
        }
        var query = [
            URLQueryItem(name: "limit", value: "\(limit)"),
            URLQueryItem(name: "direction", value: "backward"),
            URLQueryItem(name: "builds", value: "1")
        ]
        if let teamID = workspace.deploymentConfig.trimmed("vercelTeamID") {
            query.append(URLQueryItem(name: "teamId", value: teamID))
        }
        components.queryItems = query
        guard let url = components.url else { throw DeploymentClientError.invalidURL }
        let data = try await DeployJSON.send(try request(url))
        guard let rows = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            throw DeploymentClientError.decoding("Vercel deployment events")
        }
        return Array(rows.compactMap { row in
            let payload = DeployJSON.object(row, "payload")
            let text = payload["text"] as? String
            return text.map { DeployLogLine(timestamp: DeployJSON.date(row["created"] ?? payload["created"]), text: $0) }
        }.suffix(limit))
    }

    func rollback(_ deployment: DeploymentRecord) async throws {
        guard var components = URLComponents(url: base.appendingPathComponent("v13/deployments/\(deployment.id)/promote"), resolvingAgainstBaseURL: false) else {
            throw DeploymentClientError.invalidURL
        }
        var query: [URLQueryItem] = []
        if let teamID = workspace.deploymentConfig.trimmed("vercelTeamID") {
            query.append(URLQueryItem(name: "teamId", value: teamID))
        }
        components.queryItems = query
        let body = try JSONSerialization.data(withJSONObject: ["target": "production"])
        guard let url = components.url else { throw DeploymentClientError.invalidURL }
        _ = try await DeployJSON.send(try request(url, method: "POST", body: body))
    }

    private func request(_ url: URL, method: String = "GET", body: Data? = nil) throws -> URLRequest {
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue("WebsiteCommander-iOS", forHTTPHeaderField: "User-Agent")
        if let body {
            req.httpBody = body
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        return req
    }

    private func parseDeployment(_ item: [String: Any]) -> DeploymentRecord {
        let id = DeployJSON.string(item, "uid", "id") ?? UUID().uuidString
        let gitSource = DeployJSON.object(item, "gitSource")
        let meta = DeployJSON.object(item, "meta")
        let state = DeployJSON.string(item, "readyState", "state", "status")
        return DeploymentRecord(
            id: id,
            providerID: .vercel,
            providerName: providerName,
            projectName: DeployJSON.string(item, "name") ?? projectIDOrName,
            state: DeploymentState.vercel(state),
            branch: DeployJSON.string(gitSource, "ref") ?? DeployJSON.string(meta, "githubCommitRef"),
            commitSHA: DeployJSON.string(gitSource, "sha") ?? DeployJSON.string(meta, "githubCommitSha"),
            url: DeployJSON.string(item, "url"),
            createdAt: DeployJSON.date(item["createdAt"] ?? item["created"]),
            finishedAt: DeployJSON.date(item["ready"] ?? item["aliasAssignedAt"]),
            message: DeployJSON.string(item, "errorMessage", "readyStateReason"),
            logsURL: DeployJSON.string(item, "inspectorUrl")
        )
    }
}

struct NetlifyDeployClient: DeploymentClient {
    let providerID: DeploymentProviderID = .netlify
    let providerName = "Netlify"
    let workspace: SiteWorkspace
    let token: String
    let siteID: String

    var supportsRollback: Bool { true }

    private var base: URL { SiteAgentURL.constant("https://api.netlify.com/api/v1") }

    func listDeployments(limit: Int, commitSHA: String?) async throws -> [DeploymentRecord] {
        try await DeploymentHistoryCache.withFallback(for: workspace.id.uuidString) {
            guard var components = URLComponents(url: base.appendingPathComponent("sites/\(siteID)/deploys"), resolvingAgainstBaseURL: false) else {
                throw DeploymentClientError.invalidURL
            }
            var query = [
                URLQueryItem(name: "per_page", value: "\(limit)"),
                URLQueryItem(name: "production", value: "true")
            ]
            if !workspace.gitBranch.isEmpty {
                query.append(URLQueryItem(name: "branch", value: workspace.gitBranch))
            }
            components.queryItems = query
            guard let url = components.url else { throw DeploymentClientError.invalidURL }
            let data = try await DeployJSON.send(try request(url))
            guard let rows = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
                throw DeploymentClientError.decoding("Netlify deploys")
            }
            let records = rows.map(parseDeployment)
            guard let commitSHA, !commitSHA.isEmpty else { return records }
            return records.filter { $0.commitSHA?.hasPrefix(commitSHA) == true || commitSHA.hasPrefix($0.commitSHA ?? " ") }
        }
    }

    func logs(for deployment: DeploymentRecord, limit: Int) async throws -> [DeployLogLine] {
        let url = base.appendingPathComponent("sites/\(siteID)/deploys/\(deployment.id)")
        let data = try await DeployJSON.send(try request(url))
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw DeploymentClientError.decoding("Netlify deploy")
        }
        var lines: [DeployLogLine] = []
        if let title = obj["title"] as? String, !title.isEmpty {
            lines.append(DeployLogLine(timestamp: DeployJSON.date(obj["created_at"]), text: title))
        }
        if let error = obj["error_message"] as? String, !error.isEmpty {
            lines.append(DeployLogLine(timestamp: DeployJSON.date(obj["updated_at"]), text: error))
        }
        if let buildID = obj["build_id"] as? String, !buildID.isEmpty {
            let build = try await buildInfo(buildID)
            if let error = build["error"] as? String, !error.isEmpty {
                lines.append(DeployLogLine(timestamp: DeployJSON.date(build["created_at"]), text: error))
            }
        }
        return Array(lines.suffix(limit))
    }

    func rollback(_ deployment: DeploymentRecord) async throws {
        let url = base.appendingPathComponent("sites/\(siteID)/deploys/\(deployment.id)/restore")
        _ = try await DeployJSON.send(try request(url, method: "POST"))
    }

    private func buildInfo(_ buildID: String) async throws -> [String: Any] {
        let data = try await DeployJSON.send(try request(base.appendingPathComponent("builds/\(buildID)")))
        return (try JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }

    private func request(_ url: URL, method: String = "GET") throws -> URLRequest {
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue("WebsiteCommander-iOS", forHTTPHeaderField: "User-Agent")
        return req
    }

    private func parseDeployment(_ item: [String: Any]) -> DeploymentRecord {
        DeploymentRecord(
            id: DeployJSON.string(item, "id") ?? UUID().uuidString,
            providerID: .netlify,
            providerName: providerName,
            projectName: DeployJSON.string(item, "name") ?? siteID,
            state: DeploymentState.netlify(DeployJSON.string(item, "state")),
            branch: DeployJSON.string(item, "branch"),
            commitSHA: DeployJSON.string(item, "commit_ref"),
            url: DeployJSON.string(item, "ssl_url", "url", "deploy_ssl_url", "deploy_url"),
            createdAt: DeployJSON.date(item["created_at"]),
            finishedAt: DeployJSON.date(item["published_at"] ?? item["updated_at"]),
            message: DeployJSON.string(item, "error_message", "title"),
            logsURL: DeployJSON.string(item, "admin_url")
        )
    }
}

struct RenderDeployClient: DeploymentClient {
    let providerID: DeploymentProviderID = .render
    let providerName = "Render"
    let workspace: SiteWorkspace
    let token: String
    let serviceID: String

    private var base: URL { SiteAgentURL.constant("https://api.render.com/v1") }

    func listDeployments(limit: Int, commitSHA: String?) async throws -> [DeploymentRecord] {
        try await DeploymentHistoryCache.withFallback(for: workspace.id.uuidString) {
            guard var components = URLComponents(url: base.appendingPathComponent("services/\(serviceID)/deploys"), resolvingAgainstBaseURL: false) else {
                throw DeploymentClientError.invalidURL
            }
            components.queryItems = [URLQueryItem(name: "limit", value: "\(limit)")]
            guard let url = components.url else { throw DeploymentClientError.invalidURL }
            let data = try await DeployJSON.send(try request(url))
            guard let rows = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
                throw DeploymentClientError.decoding("Render deploys")
            }
            let records = rows.map { row in
                let deploy = (row["deploy"] as? [String: Any]) ?? row
                return parseDeployment(deploy)
            }
            guard let commitSHA, !commitSHA.isEmpty else { return records }
            return records.filter { $0.commitSHA?.hasPrefix(commitSHA) == true || commitSHA.hasPrefix($0.commitSHA ?? " ") }
        }
    }

    func logs(for deployment: DeploymentRecord, limit: Int) async throws -> [DeployLogLine] {
        let url = base.appendingPathComponent("services/\(serviceID)/deploys/\(deployment.id)/logs")
        do {
            let data = try await DeployJSON.send(try request(url))
            if let text = String(data: data, encoding: .utf8), !text.isEmpty {
                let lines = text.split(separator: "\n", omittingEmptySubsequences: false).suffix(limit)
                return lines.map { DeployLogLine(timestamp: nil, text: String($0)) }
            }
        } catch let err as DeploymentClientError {
            if case .http(let code, _) = err, code == 404 || code == 501 {
                // Render may not expose raw logs for all service types.
            } else {
                throw err
            }
        }
        let dashboard = "https://dashboard.render.com/web/\(serviceID)/deploys/\(deployment.id)"
        return [DeployLogLine(timestamp: deployment.createdAt,
                              text: "Open deploy logs in the Render dashboard: \(dashboard)")]
    }

    private func request(_ url: URL, method: String = "GET") throws -> URLRequest {
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue("WebsiteCommander-iOS", forHTTPHeaderField: "User-Agent")
        return req
    }

    private func parseDeployment(_ item: [String: Any]) -> DeploymentRecord {
        let commit = DeployJSON.object(item, "commit")
        let id = DeployJSON.string(item, "id") ?? UUID().uuidString
        let status = DeployJSON.string(item, "status")
        let dashboardURL = "https://dashboard.render.com/web/\(serviceID)/deploys/\(id)"
        return DeploymentRecord(
            id: id,
            providerID: .render,
            providerName: providerName,
            projectName: DeployJSON.string(item, "serviceId") ?? serviceID,
            state: DeploymentState.render(status),
            branch: nil,
            commitSHA: DeployJSON.string(commit, "id", "commitSha", "sha"),
            url: DeployJSON.string(item, "url"),
            createdAt: DeployJSON.date(item["createdAt"] ?? item["created_at"]),
            finishedAt: DeployJSON.date(item["finishedAt"] ?? item["updatedAt"]),
            message: DeployJSON.string(commit, "message") ?? DeployJSON.string(item, "trigger", "reason") ?? status,
            logsURL: dashboardURL
        )
    }
}

struct RailwayDeployClient: DeploymentClient {
    let providerID: DeploymentProviderID = .railway
    let providerName = "Railway"
    let workspace: SiteWorkspace
    let token: String
    let projectID: String
    let serviceID: String
    let environmentID: String
    let useProjectToken: Bool

    private var graphURL: URL { SiteAgentURL.constant("https://backboard.railway.app/graphql/v2") }

    func listDeployments(limit: Int, commitSHA: String?) async throws -> [DeploymentRecord] {
        try await DeploymentHistoryCache.withFallback(for: workspace.id.uuidString) {
            let query = """
            query($projectId: String!, $serviceId: String!, $environmentId: String!, $first: Int!) {
              deployments(input: { projectId: $projectId, serviceId: $serviceId, environmentId: $environmentId }, first: $first) {
                edges {
                  node {
                    id
                    status
                    createdAt
                    url
                    meta
                  }
                }
              }
            }
            """
            let variables: [String: Any] = [
                "projectId": projectID,
                "serviceId": serviceID,
                "environmentId": environmentID,
                "first": limit
            ]
            let data = try await DeployJSON.send(try graphRequest(query: query, variables: variables))
            guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw DeploymentClientError.decoding("Railway deployments")
            }
            if let errors = obj["errors"] as? [[String: Any]],
               let message = errors.first?["message"] as? String {
                throw DeploymentClientError.http(400, message)
            }
            guard let dataObj = obj["data"] as? [String: Any],
                  let deployments = dataObj["deployments"] as? [String: Any],
                  let edges = deployments["edges"] as? [[String: Any]] else {
                throw DeploymentClientError.decoding("Railway deployments")
            }
            let records = edges.compactMap { edge -> DeploymentRecord? in
                guard let node = edge["node"] as? [String: Any] else { return nil }
                return parseDeployment(node)
            }
            guard let commitSHA, !commitSHA.isEmpty else { return records }
            return records.filter { $0.commitSHA?.hasPrefix(commitSHA) == true || commitSHA.hasPrefix($0.commitSHA ?? " ") }
        }
    }

    func logs(for deployment: DeploymentRecord, limit: Int) async throws -> [DeployLogLine] {
        let query = """
        query($deploymentId: String!, $limit: Int) {
          deploymentLogs(deploymentId: $deploymentId, limit: $limit) {
            message
            timestamp
          }
        }
        """
        do {
            let data = try await DeployJSON.send(try graphRequest(
                query: query,
                variables: ["deploymentId": deployment.id, "limit": limit]
            ))
            if let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
               let dataObj = obj["data"] as? [String: Any],
               let rows = dataObj["deploymentLogs"] as? [[String: Any]], !rows.isEmpty {
                return Array(rows.suffix(limit).map {
                    DeployLogLine(timestamp: DeployJSON.date($0["timestamp"]), text: ($0["message"] as? String) ?? "")
                })
            }
        } catch {
            // Fall through to dashboard link when log query isn't available.
            #if DEBUG
            print("Railway deploy logs unavailable: \(error.localizedDescription)")
            #endif
        }
        let dashboard = "https://railway.app/project/\(projectID)"
        return [DeployLogLine(timestamp: deployment.createdAt,
                              text: "Open deployment logs in the Railway dashboard: \(dashboard)")]
    }

    private func graphRequest(query: String, variables: [String: Any]) throws -> URLRequest {
        var req = URLRequest(url: graphURL)
        req.httpMethod = "POST"
        if useProjectToken {
            req.setValue(token, forHTTPHeaderField: "Project-Access-Token")
        } else {
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("WebsiteCommander-iOS", forHTTPHeaderField: "User-Agent")
        let body: [String: Any] = ["query": query, "variables": variables]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        return req
    }

    private func parseDeployment(_ item: [String: Any]) -> DeploymentRecord {
        let meta = item["meta"] as? [String: Any] ?? [:]
        let id = DeployJSON.string(item, "id") ?? UUID().uuidString
        let status = DeployJSON.string(item, "status")
        return DeploymentRecord(
            id: id,
            providerID: .railway,
            providerName: providerName,
            projectName: serviceID,
            state: DeploymentState.railway(status),
            branch: DeployJSON.string(meta, "branch"),
            commitSHA: DeployJSON.string(meta, "commitHash", "commitSha", "sha"),
            url: DeployJSON.string(item, "url"),
            createdAt: DeployJSON.date(item["createdAt"]),
            finishedAt: nil,
            message: DeployJSON.string(meta, "commitMessage") ?? status,
            logsURL: "https://railway.app/project/\(projectID)"
        )
    }
}

struct GitHubActionsDeployClient: DeploymentClient {
    let providerID: DeploymentProviderID = .githubActions
    let providerName = "GitHub Actions"
    let workspace: SiteWorkspace
    let repo: RepoConfig

    var supportsRetry: Bool { true }

    private var base: URL { SiteAgentURL.constant("https://api.github.com") }

    func listDeployments(limit: Int, commitSHA: String?) async throws -> [DeploymentRecord] {
        try await DeploymentHistoryCache.withFallback(for: workspace.id.uuidString) {
            guard var components = URLComponents(url: base.appendingPathComponent("repos/\(repo.owner)/\(repo.name)/actions/runs"), resolvingAgainstBaseURL: false) else {
                throw DeploymentClientError.invalidURL
            }
            var query = [
                URLQueryItem(name: "branch", value: repo.branch),
                URLQueryItem(name: "per_page", value: "\(limit)")
            ]
            if let commitSHA { query.append(URLQueryItem(name: "head_sha", value: commitSHA)) }
            components.queryItems = query
            guard let url = components.url else { throw DeploymentClientError.invalidURL }
            let data = try await DeployJSON.send(try request(url))
            guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let rows = obj["workflow_runs"] as? [[String: Any]] else {
                throw DeploymentClientError.decoding("GitHub Actions runs")
            }
            return rows.map(parseRun)
        }
    }

    func logs(for deployment: DeploymentRecord, limit: Int) async throws -> [DeployLogLine] {
        let runID = deployment.id
        if let cached = Self.cachedLogs(for: runID) {
            return Array(cached.suffix(limit))
        }
        var lines: [DeployLogLine] = []
        do {
            let jobs = try await jobs(for: runID)
            if jobs.isEmpty {
                lines.append(DeployLogLine(timestamp: deployment.createdAt,
                                           text: "No jobs have been reported for this run yet."))
            }
            for job in jobs {
                let jobConcl = job.conclusion.map { " [\($0.uppercased())]" } ?? ""
                lines.append(DeployLogLine(timestamp: deployment.createdAt,
                                           text: "Job: \(job.name)\(jobConcl)"))
                for step in job.steps {
                    let mark = (step.conclusion ?? step.status).uppercased()
                    lines.append(DeployLogLine(timestamp: deployment.createdAt,
                                               text: "  \(mark) — \(step.name)"))
                }
                if job.conclusion == "failure" || job.conclusion == "timed_out" {
                    if let jobLogs = try? await logs(forJob: job.id) {
                        lines.append(contentsOf: jobLogs)
                    }
                }
            }
        } catch {
            lines = [DeployLogLine(timestamp: deployment.createdAt,
                                   text: "Couldn't fetch Actions logs: \(error.localizedDescription)")]
            if let url = deployment.logsURL {
                lines.append(DeployLogLine(timestamp: deployment.createdAt,
                                           text: "Open the run on GitHub: \(url)"))
            }
            Self.cacheLogs(lines, for: runID)
            return Array(lines.suffix(limit))
        }
        if lines.isEmpty {
            let text = deployment.logsURL.map { "Open GitHub Actions logs: \($0)" }
                ?? "Open this workflow run on GitHub to inspect logs."
            lines.append(DeployLogLine(timestamp: deployment.createdAt, text: text))
        }
        Self.cacheLogs(lines, for: runID)
        return Array(lines.suffix(limit))
    }

    /// List jobs for a workflow run (`GET /repos/{o}/{r}/actions/runs/{id}/jobs`).
    func jobs(for runID: String) async throws -> [GitHubJob] {
        let url = base.appendingPathComponent("repos/\(repo.owner)/\(repo.name)/actions/runs/\(runID)/jobs")
        let data = try await DeployJSON.send(try request(url))
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rows = obj["jobs"] as? [[String: Any]] else {
            throw DeploymentClientError.decoding("GitHub Actions jobs")
        }
        return rows.map(parseJob)
    }

    /// Fetch a job's log text (`GET /repos/{o}/{r}/actions/jobs/{id}/logs`). The
    /// endpoint 302-redirects to a blob URL; URLSession follows the redirect.
    /// The blob is normally a zip archive (which we can't extract dependency-free),
    /// so plain-text bodies are returned as lines and zips surface a clear note.
    func logs(forJob jobID: Int) async throws -> [DeployLogLine] {
        let url = base.appendingPathComponent("repos/\(repo.owner)/\(repo.name)/actions/jobs/\(jobID)/logs")
        let data = try await DeployJSON.send(try request(url))
        let isZip = data.count >= 2 && data[data.startIndex] == 0x50 && data[data.startIndex + 1] == 0x4B
        if !isZip, let text = String(data: data, encoding: .utf8), !text.isEmpty {
            return text.split(separator: "\n").map {
                DeployLogLine(timestamp: nil, text: String($0))
            }
        }
        return [DeployLogLine(timestamp: nil,
                              text: "Raw step logs are packaged as a zip archive — open the job on GitHub to view the full output.")]
    }

    private static let logCacheLock = NSLock()
    private static var logCache: [String: [DeployLogLine]] = [:]
    private static let logCacheMaxEntries = 32

    private static func cachedLogs(for runID: String) -> [DeployLogLine]? {
        logCacheLock.lock(); defer { logCacheLock.unlock() }
        return logCache[runID]
    }

    private static func cacheLogs(_ lines: [DeployLogLine], for runID: String) {
        logCacheLock.lock(); defer { logCacheLock.unlock() }
        logCache[runID] = lines
        while logCache.count > logCacheMaxEntries, let first = logCache.keys.first {
            logCache.removeValue(forKey: first)
        }
    }

    struct GitHubStep {
        let number: Int
        let name: String
        let conclusion: String?
        let status: String
    }

    struct GitHubJob {
        let id: Int
        let name: String
        let conclusion: String?
        let status: String
        let steps: [GitHubStep]
    }

    private func parseJob(_ item: [String: Any]) -> GitHubJob {
        let steps = (item["steps"] as? [[String: Any]] ?? []).map { step in
            GitHubStep(
                number: (step["number"] as? Int) ?? 0,
                name: (step["name"] as? String) ?? "",
                conclusion: step["conclusion"] as? String,
                status: (step["status"] as? String) ?? ""
            )
        }
        return GitHubJob(
            id: (item["id"] as? Int) ?? 0,
            name: (item["name"] as? String) ?? "job",
            conclusion: item["conclusion"] as? String,
            status: (item["status"] as? String) ?? "",
            steps: steps
        )
    }

    func retry(_ deployment: DeploymentRecord) async throws {
        let url = base.appendingPathComponent("repos/\(repo.owner)/\(repo.name)/actions/runs/\(deployment.id)/rerun")
        _ = try await DeployJSON.send(try request(url, method: "POST"))
    }

    private func request(_ url: URL, method: String = "GET") throws -> URLRequest {
        guard let token = Keychain.get(Keychain.githubToken(credentialID: repo.githubCredentialID))?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !token.isEmpty else { throw GitHubError.noToken }
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        req.setValue("WebsiteCommander-iOS", forHTTPHeaderField: "User-Agent")
        return req
    }

    private func parseRun(_ item: [String: Any]) -> DeploymentRecord {
        let id = String((item["id"] as? Int) ?? 0)
        let status = item["status"] as? String
        let conclusion = item["conclusion"] as? String
        return DeploymentRecord(
            id: id == "0" ? UUID().uuidString : id,
            providerID: .githubActions,
            providerName: providerName,
            projectName: DeployJSON.string(item, "name", "display_title") ?? repo.slug,
            state: DeploymentState.githubActions(status: status, conclusion: conclusion),
            branch: DeployJSON.string(item, "head_branch"),
            commitSHA: DeployJSON.string(item, "head_sha"),
            url: DeployJSON.string(item, "html_url"),
            createdAt: DeployJSON.date(item["created_at"]),
            finishedAt: DeployJSON.date(item["updated_at"]),
            message: DeployJSON.string(item, "display_title") ?? conclusion,
            logsURL: DeployJSON.string(item, "html_url")
        )
    }
}

enum DeploymentLogDiagnosis {
    static func summarize(_ deployment: DeploymentRecord, logs: [DeployLogLine]) -> String {
        let text = logs.map(\.text).joined(separator: "\n").lowercased()
        guard deployment.state == .failure || !text.isEmpty else { return "" }
        if text.contains("module not found") || text.contains("cannot find module") {
            return "Likely missing dependency or import path. Check package.json, lockfile, and the file path casing used in imports."
        }
        if text.contains("command not found") || text.contains("not recognized") {
            return "Build command likely references a missing CLI. Add the package as a dependency or update the build command."
        }
        if text.contains("environment variable") || text.contains("env var") || text.contains("missing env") {
            return "A required environment variable appears to be missing from the hosting provider."
        }
        if text.contains("out of memory") || text.contains("oom") {
            return "The build likely exceeded memory. Reduce build work, upgrade the build environment, or split heavy generation steps."
        }
        if text.contains("failed to compile") || text.contains("syntaxerror") || text.contains("type error") {
            return "The deployment failed during compilation. Ask the agent to inspect the referenced file and stage a focused fix."
        }
        if deployment.state == .failure {
            return "The deployment failed. Pull the latest logs into chat and ask the agent to diagnose the exact failing step."
        }
        return ""
    }
}

enum DeploymentTracker {
    static func confirm(client: DeploymentClient, commitSHA: String?, pushedAt: Date? = nil, rounds: Int = 18) async -> (message: String, deployment: DeploymentRecord?, logs: [DeployLogLine]) {
        var lastRecord: DeploymentRecord?
        let hasSHA = (commitSHA?.isEmpty == false)
        // Without a SHA we can't attribute a deploy to this push. Fall back to a
        // timestamp window when available; if neither is available, refuse to
        // claim live rather than reporting records.first as this push's deploy.
        if !hasSHA && pushedAt == nil {
            return ("⏳ Couldn't confirm which \(client.providerName) deployment this push produced — check the deployment dashboard.", nil, [])
        }
        for round in 0..<rounds {
            if Task.isCancelled { return ("", nil, []) }
            do {
                let records = try await client.listDeployments(limit: 8, commitSHA: commitSHA)
                let candidate = matchDeployment(records: records, commitSHA: commitSHA, pushedAt: pushedAt)
                if let record = candidate {
                    lastRecord = record
                    if record.state.isTerminal {
                        let logs = (try? await client.logs(for: record, limit: 20)) ?? []
                        let detail = DeploymentLogDiagnosis.summarize(record, logs: logs)
                        let shaSuffix = record.shortSHA.isEmpty ? "" : " for \(record.shortSHA)"
                        switch record.state {
                        case .success:
                            return ("✅ \(client.providerName) deployment is live\(shaSuffix).", record, logs)
                        case .failure:
                            let suffix = detail.isEmpty ? "" : "\n\(detail)"
                            return ("❌ \(client.providerName) deployment failed\(shaSuffix).\(suffix)", record, logs)
                        case .canceled:
                            return ("⚠️ \(client.providerName) deployment was canceled.", record, logs)
                        default:
                            break
                        }
                    }
                }
            } catch {
                let clientErr = DeploymentClientError.map(error)
                if clientErr.isCancellation {
                    return ("", lastRecord, [])
                }
                switch clientErr {
                case .missingConfiguration(let msg):
                    return ("⚠️ \(client.providerName) configuration missing: \(msg)", lastRecord, [])
                case .unsupported(let msg):
                    return ("⚠️ \(client.providerName) unsupported action: \(msg)", lastRecord, [])
                case .decoding(let msg):
                    return ("⚠️ \(client.providerName) response decoding error: \(msg)", lastRecord, [])
                case .http(let code, _) where code == 400 || code == 401 || code == 403 || code == 404:
                    return ("⚠️ \(client.providerName) deployment check failed: \(clientErr.localizedDescription)", lastRecord, [])
                case .invalidURL:
                    return ("⚠️ \(client.providerName) deployment check failed: invalid URL.", lastRecord, [])
                default:
                    break
                }
                if round == rounds - 1 {
                    return ("⚠️ Could not check \(client.providerName) deployment status: \(clientErr.localizedDescription)", lastRecord, [])
                }
            }
            if round < rounds - 1 {
                do { try await Task.sleep(nanoseconds: 5_000_000_000) } catch { return ("", lastRecord, []) }
            }
        }
        if let lastRecord {
            return ("⏳ \(client.providerName) deployment is still \(lastRecord.state.label.lowercased()). Check the deployment dashboard for details.", lastRecord, [])
        }
        return ("⏳ Commit pushed, but \(client.providerName) has not reported a matching deployment yet.", nil, [])
    }

    private static func matchDeployment(
        records: [DeploymentRecord],
        commitSHA: String?,
        pushedAt: Date?
    ) -> DeploymentRecord? {
        guard !records.isEmpty else { return nil }
        let hasSHA = (commitSHA?.isEmpty == false)

        if hasSHA, let commitSHA {
            if let shaMatch = records.first(where: { record in
                guard let sha = record.commitSHA, !sha.isEmpty else { return false }
                return sha.hasPrefix(commitSHA) || commitSHA.hasPrefix(sha)
            }) {
                return shaMatch
            }
        }

        if let pushedAt {
            let windowStart = pushedAt.addingTimeInterval(-90)
            if let recent = records.first(where: { ($0.createdAt ?? .distantPast) >= windowStart }) {
                return recent
            }
        }

        // When a commit SHA was provided but no record matched, do NOT fall back
        // to `records.first` — that can attribute the wrong deployment.
        return nil
    }
}

/// Placeholder client for workspaces whose deployment type is `.sshFtp`.
/// SSH/SFTP needs a third-party library (NMSSH/SwiftSH) that SiteAgent doesn't
/// ship, so rather than advertise a working integration, every call surfaces a
/// clear "not supported" message. Returning this from the factory (instead of
/// nil) lets persisted `.sshFtp` workspaces load without crashing and tells the
/// user exactly why no deploys happen.
struct SSHFTPUnavailableClient: DeploymentClient {
    let providerID: DeploymentProviderID = .sshFtp
    let providerName = "SSH/SFTP"

    private static var unavailableMessage: String {
        "SSH/SFTP deploys aren't supported from Website Commander. Sync changes to your server directly, or switch this workspace to a supported deployment provider."
    }

    func listDeployments(limit: Int, commitSHA: String?) async throws -> [DeploymentRecord] {
        throw DeploymentClientError.unsupported(Self.unavailableMessage)
    }

    func logs(for deployment: DeploymentRecord, limit: Int) async throws -> [DeployLogLine] {
        [DeployLogLine(timestamp: nil, text: Self.unavailableMessage)]
    }
}
