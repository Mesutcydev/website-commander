import Foundation
import Network
import Security

/// A loopback-only TCP server that lets other agents on the same Mac drive
/// Website Commander (the same surface the `wc` CLI exposes): list sites, run the
/// agent on a site, and build a debug brief.
///
/// Security posture (this is intentionally conservative):
/// * Binds to `127.0.0.1` only — never the LAN.
/// * **Off by default.** Nothing listens until the user enables it in Settings.
/// * On start, a random 32-byte token is written to `bridge.token` (mode 0600)
///   and the chosen port to `bridge.port`. Every connection must present the
///   token on its first line or it is dropped.
/// * The token file lives under Application Support, readable only by the user.
///
/// Wire protocol (one request per connection, newline-delimited):
///   -> `AUTH <token>\n`
///   <- `OK\n`            (or `ERR unauthorized\n` then close)
///   -> `<json request>\n`
///   <- `<json response>\n`
@MainActor
final class LocalBridge: ObservableObject {

    static let tokenFileName = "bridge.token"
    static let portFileName = "bridge.port"

    private var listener: NWListener?
    private var connections: [NWConnection] = []
    @Published private(set) var port: UInt16?
    @Published private(set) var token: String?
    @Published private(set) var isRunning = false
    @Published private(set) var lastError: String?

    weak var settings: SettingsStore?
    weak var engine: AgentEngine?
    weak var browser: BrowserController?

    private static var supportDir: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("WebsiteCommander", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static var tokenFileURL: URL { supportDir.appendingPathComponent(tokenFileName) }
    static var portFileURL: URL { supportDir.appendingPathComponent(portFileName) }

    /// Read the token another process would use (nil if the bridge isn't running).
    static func readPublishedToken() -> String? {
        try? String(contentsOf: tokenFileURL, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
    static func readPublishedPort() -> Int? {
        Int((try? String(contentsOf: portFileURL, encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? "")
    }

    // MARK: Lifecycle

    func start(preferredPort: Int) {
        stop()
        lastError = nil
        let newToken = Self.randomToken()
        // Bind to a concrete loopback port (ephemeral `.any` on a pinned host is
        // unreliable). Try the preferred port, else a few random high ports.
        var candidates: [UInt16] = []
        if preferredPort > 0 { candidates.append(UInt16(preferredPort)) }
        for _ in 0..<8 { candidates.append(UInt16.random(in: 49152...65000)) }

        for port in candidates {
            guard let ep = NWEndpoint.Port(rawValue: port) else { continue }
            let params = NWParameters.tcp
            params.requiredLocalEndpoint = NWEndpoint.hostPort(host: .ipv4(.loopback), port: ep)
            do {
                let listener = try NWListener(using: params)
                self.listener = listener
                listener.stateUpdateHandler = { [weak self] state in
                    Task { @MainActor in
                        guard let self else { return }
                        switch state {
                        case .ready:
                            self.isRunning = true
                            if let p = listener.port?.rawValue {
                                self.port = p
                                self.token = newToken
                                Self.write(newToken, to: Self.tokenFileURL, secret: true)
                                Self.write("\(p)", to: Self.portFileURL, secret: false)
                            }
                        case .failed(let err):
                            self.lastError = "Listener failed: \(err). Another process may hold the port, or this build needs the network-server entitlement."
                            FileHandle.standardError.write(Data("bridge listener failed: \(err)\n".utf8))
                            self.isRunning = false
                        case .cancelled:
                            self.isRunning = false
                        default: break
                        }
                    }
                }
                listener.newConnectionHandler = { [weak self] conn in
                    Task { @MainActor in self?.handle(conn, token: newToken) }
                }
                listener.start(queue: .global(qos: .userInitiated))
                return   // bound; state handler reports readiness
            } catch {
                continue   // port in use — try next
            }
        }
        isRunning = false
        lastError = "Could not bind a loopback port."
        FileHandle.standardError.write(Data("bridge: no loopback port available\n".utf8))
    }

    func stop() {
        listener?.cancel()
        listener = nil
        connections.forEach { $0.cancel() }
        connections.removeAll()
        isRunning = false
        port = nil
        token = nil
        try? FileManager.default.removeItem(at: Self.tokenFileURL)
        try? FileManager.default.removeItem(at: Self.portFileURL)
    }

    // MARK: Connection handling

    private func handle(_ connection: NWConnection, token: String) {
        connections.append(connection)
        connection.start(queue: .global(qos: .userInitiated))
        Task.detached { [weak self] in
            guard let self else { return }
            let authLine = await self.readLine(connection)
            guard let authLine, authLine.hasPrefix("AUTH "),
                  authLine.dropFirst(5).trimmingCharacters(in: .whitespaces) == token else {
                await self.writeLine(connection, "ERR unauthorized")
                connection.cancel(); return
            }
            await self.writeLine(connection, "OK")
            guard let reqLine = await self.readLine(connection),
                  let data = reqLine.data(using: .utf8),
                  let req = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let op = req["op"] as? String else {
                await self.writeJSON(connection, ["ok": false, "error": "bad request"])
                connection.cancel(); return
            }
            let response = await self.dispatch(op: op, req: req)
            await self.writeJSON(connection, response)
            connection.cancel()
        }
    }

    func dispatch(op: String, req: [String: Any]) async -> [String: Any] {
        guard let settings, let engine else { return ["ok": false, "error": "app not ready"] }
        switch op {
        case "ping":
            return ["ok": true]
        case "sites":
            let active = settings.activeWorkspace?.id
            let rows = settings.workspaces.map { ws -> [String: Any] in
                ["name": ws.name, "slug": ws.slug, "branch": ws.gitBranch,
                 "techStack": ws.techStack.rawValue, "deployment": ws.deployment.rawValue,
                 "active": ws.id == active]
            }
            return ["ok": true, "sites": rows]
        case "use":
            guard let site = req["site"] as? String, let prompt = req["prompt"] as? String else {
                return ["ok": false, "error": "use requires site and prompt"]
            }
            let lowered = site.lowercased()
            guard let ws = settings.workspaces.first(where: {
                $0.name.lowercased() == lowered || $0.slug.lowercased() == lowered
            }) else {
                return ["ok": false, "error": "no site named \(site)"]
            }
            settings.setActive(ws)
            if let model = req["model"] as? String { settings.model = model }
            let approve = (req["approve"] as? Bool) ?? false
            let result = await engine.runHeadless(prompt, autoApprove: approve)
            var dict: [String: Any] = ["ok": result.ok, "reply": result.reply,
                                       "committed": result.committed, "staged": result.staged]
            if let e = result.error { dict["error"] = e }
            return dict
        case "preview":
            if let error = activateRequestedWorkspace(req, settings: settings) {
                return ["ok": false, "error": error]
            }
            NotificationCenter.default.post(name: .requestPreviewFromBridge, object: nil)
            return ["ok": true]
        case "inspect":
            if let error = activateRequestedWorkspace(req, settings: settings) {
                return ["ok": false, "error": error]
            }
            NotificationCenter.default.post(name: .requestPreviewInspectFromBridge, object: nil)
            return ["ok": true]
        case "audit":
            if let error = activateRequestedWorkspace(req, settings: settings) {
                return ["ok": false, "error": error]
            }
            let brief = await makeDebugBrief(settings: settings, engine: engine)
            return [
                "ok": true,
                "healthScore": brief.healthScore,
                "liveURL": brief.context.liveURL,
                "audit": brief.audit.map {
                    ["severity": $0.severity, "title": $0.title, "detail": $0.detail]
                },
                "consoleErrors": brief.consoleErrors,
                "failedRequests": brief.failedRequests.map {
                    ["method": $0.method, "url": $0.url, "status": $0.status]
                }
            ]
        case "debug":
            if let error = activateRequestedWorkspace(req, settings: settings) {
                return ["ok": false, "error": error]
            }
            let brief = await makeDebugBrief(settings: settings, engine: engine)
            let file = EditorBridge.writeBrief(brief, repoPath: brief.context.repoPath)
            let target = AgentTarget(rawValue: (req["for"] as? String) ?? "") ?? .codex
            return ["ok": true, "briefPath": file.path,
                    "prompt": brief.prompt(for: target, briefPath: file.path),
                    "markdown": brief.markdown(briefPath: file.path)]
        default:
            return ["ok": false, "error": "unknown op \(op)"]
        }
    }

    /// Preview/debug commands can target a site without requiring the caller to
    /// mutate app state through a separate command. The extension uses this for
    /// its site picker, while existing callers that omit `site` keep the active
    /// workspace behavior.
    private func activateRequestedWorkspace(_ req: [String: Any], settings: SettingsStore) -> String? {
        guard let rawSite = req["site"] as? String, !rawSite.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        let site = rawSite.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard let workspace = settings.workspaces.first(where: {
            $0.name.lowercased() == site || $0.slug.lowercased() == site
        }) else {
            return "no site named (rawSite)"
        }
        settings.setActive(workspace)
        return nil
    }

    private func makeDebugBrief(settings: SettingsStore, engine: AgentEngine) async -> DebugBrief {
        let ws = settings.activeWorkspace
        let repoPath = ws.flatMap {
            LocalWorkspaceStore.isCloned($0) ? LocalWorkspaceStore.localPath(for: $0).path : nil
        }
        let hasLiveURL = ws.flatMap { SiteWorkspace.normalizedLiveURL($0.configuredLiveURL) } != nil
        let previewReady = hasLiveURL ? await browser?.ensureAvailable() ?? false : false
        let html = previewReady ? await browser?.snapshotHTML() ?? "" : ""
        // A failed navigation must not report console/network breadcrumbs left
        // over from a different workspace that was previewed earlier.
        let inspector = previewReady ? browser?.inspector : nil
        let audit: [SiteAuditIssue]
        if previewReady, let inspector {
            audit = SiteAuditor.audit(html: html, inspector: inspector)
        } else {
            audit = [SiteAuditIssue(
                title: "Preview unavailable",
                detail: hasLiveURL
                    ? (browser?.navigationError ?? "The live preview could not finish loading.")
                    : "No valid live URL is configured for this site.",
                severity: .critical
            )]
        }
        return DebugBrief(
            generatedAt: Date(), appVersion: "bridge",
            context: .init(siteName: ws?.name ?? "—", slug: ws?.slug ?? "—",
                           branch: ws?.gitBranch ?? "—", liveURL: ws?.configuredLiveURL ?? "",
                           repoPath: repoPath, techStack: ws?.techStack.rawValue ?? "—",
                           deployment: ws?.deployment.rawValue ?? "—"),
            consoleErrors: inspector?.consoleLogs.filter { $0.level == .error }.map { $0.text } ?? [],
            consoleWarnings: inspector?.consoleLogs.filter { $0.level == .warn }.map { $0.text } ?? [],
            failedRequests: inspector?.networkRequests.compactMap { request in
                guard let status = request.status, status == 0 || status >= 400 else { return nil }
                return DebugBrief.Request(method: request.method, url: request.url, status: status)
            } ?? [],
            loadMs: inspector?.performance.loadTimeMs,
            domReadyMs: inspector?.performance.domReadyMs,
            transferKB: inspector?.performance.transferKB,
            audit: audit.map { DebugBrief.Finding(severity: $0.severity.rawValue,
                                                  title: $0.title, detail: $0.detail) },
            injection: PromptGuard.injectionFindings(in: html),
            lastAgentError: engine.lastError,
            stagedChanges: engine.pendingChanges.count)
    }

    // MARK: Low-level I/O

    private func readLine(_ connection: NWConnection) async -> String? {
        await withCheckedContinuation { cont in
            var buffer = Data()
            func receiveMore() {
                connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { data, _, isComplete, error in
                    if let data, !data.isEmpty {
                        buffer.append(data)
                        if let nl = buffer.firstIndex(of: 0x0A) {
                            let line = String(data: buffer[..<nl], encoding: .utf8)?
                                .trimmingCharacters(in: .carriageReturns)
                            cont.resume(returning: line); return
                        }
                        if buffer.count > 65536 { cont.resume(returning: nil); return }
                        receiveMore()
                    } else if isComplete || error != nil {
                        let line = buffer.isEmpty ? nil : String(data: buffer, encoding: .utf8)?
                            .trimmingCharacters(in: .whitespacesAndNewlines)
                        cont.resume(returning: line)
                    } else {
                        cont.resume(returning: nil)
                    }
                }
            }
            receiveMore()
        }
    }

    private func writeLine(_ connection: NWConnection, _ s: String) async {
        let data = Data((s + "\n").utf8)
        await withCheckedContinuation { cont in
            connection.send(content: data, completion: .contentProcessed { _ in cont.resume() })
        }
    }

    private func writeJSON(_ connection: NWConnection, _ obj: [String: Any]) async {
        let data = (try? JSONSerialization.data(withJSONObject: obj)) ?? Data("{}".utf8)
        var line = String(data: data, encoding: .utf8) ?? "{}"
        line = line.replacingOccurrences(of: "\n", with: " ")
        await writeLine(connection, line)
    }

    // MARK: Helpers

    private static func randomToken() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    private static func write(_ s: String, to url: URL, secret: Bool) {
        try? s.write(to: url, atomically: true, encoding: .utf8)
        if secret {
            // 0600 — owner read/write only.
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        }
    }
}

private extension CharacterSet {
    static let carriageReturns = CharacterSet(charactersIn: "\r")
}
