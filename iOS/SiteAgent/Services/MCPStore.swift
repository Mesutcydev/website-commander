import Foundation

@MainActor
final class MCPStore: ObservableObject {
    static let shared = MCPStore()

    @Published private(set) var servers: [MCPServerConfiguration] = []
    @Published private(set) var tools: [MCPToolDescriptor] = []
    @Published private(set) var activity: [String] = []

    private let defaults: UserDefaults
    private let serversKey = "mcpServersV1"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        load()
    }

    func save(_ server: MCPServerConfiguration, token: String?) throws {
        let validated = try server.validated()
        if let index = servers.firstIndex(where: { $0.id == server.id }) {
            servers[index] = validated
        } else {
            servers.append(validated)
        }
        servers.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        persist()
        if let token {
            Keychain.set(
                token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : token,
                for: Keychain.mcpToken(serverID: server.id)
            )
        }
    }

    func delete(_ server: MCPServerConfiguration) {
        servers.removeAll { $0.id == server.id }
        tools.removeAll { $0.serverID == server.id }
        Keychain.set(nil, for: Keychain.mcpToken(serverID: server.id))
        persist()
    }

    func refreshTools(for server: MCPServerConfiguration) async throws {
        let discovered = try await MCPClient(server: server).listTools()
        tools.removeAll { $0.serverID == server.id }
        tools.append(contentsOf: discovered)
        activity.insert("Discovered \(discovered.count) tools from \(server.name).", at: 0)
        trimActivity()
    }

    func refreshEnabledServers() async {
        for server in servers where server.isEnabled {
            do {
                try await refreshTools(for: server)
            } catch {
                activity.insert("\(server.name): \(error.localizedDescription)", at: 0)
                trimActivity()
            }
        }
    }

    func toolSpecs() -> [ToolSpec] {
        tools.compactMap { descriptor in
            guard let server = servers.first(where: {
                $0.id == descriptor.serverID && $0.isEnabled
            }) else { return nil }
            return ToolSpec(
                name: descriptor.namespacedName,
                description: "\(server.name): \(descriptor.description)",
                parameters: descriptor.parameters
            )
        }
    }

    func execute(namespacedName: String, argumentsJSON: String) async -> MCPExecutionResult {
        guard let tool = tools.first(where: { $0.namespacedName == namespacedName }),
              let server = servers.first(where: { $0.id == tool.serverID && $0.isEnabled }) else {
            return MCPExecutionResult(succeeded: false, payload: MCPError.unknownTool.localizedDescription)
        }
        guard tool.isReadOnly || server.allowsWriteTools else {
            return MCPExecutionResult(
                succeeded: false,
                payload: MCPError.writePermissionRequired.localizedDescription
            )
        }
        do {
            let result = try await MCPClient(server: server).callTool(
                name: tool.originalName,
                argumentsJSON: argumentsJSON
            )
            activity.insert("Ran \(tool.originalName) on \(server.name).", at: 0)
            trimActivity()
            return MCPExecutionResult(succeeded: true, payload: result)
        } catch {
            activity.insert("\(tool.originalName) failed: \(error.localizedDescription)", at: 0)
            trimActivity()
            return MCPExecutionResult(succeeded: false, payload: error.localizedDescription)
        }
    }

    private func load() {
        guard let data = defaults.data(forKey: serversKey),
              let decoded = try? JSONDecoder().decode([MCPServerConfiguration].self, from: data) else {
            return
        }
        servers = decoded
    }

    private func persist() {
        defaults.set(try? JSONEncoder().encode(servers), forKey: serversKey)
    }

    private func trimActivity() {
        if activity.count > 50 {
            activity.removeLast(activity.count - 50)
        }
    }
}

private struct MCPClient {
    let server: MCPServerConfiguration

    func listTools() async throws -> [MCPToolDescriptor] {
        _ = try? await request(
            method: "initialize",
            params: [
                "protocolVersion": "2025-03-26",
                "capabilities": [:],
                "clientInfo": ["name": "SiteAgent", "version": "1.16"]
            ],
            id: 1
        )
        let result = try await request(method: "tools/list", params: [:], id: 2)
        guard let object = result as? [String: Any],
              let tools = object["tools"] as? [[String: Any]] else {
            throw MCPError.invalidResponse
        }
        return tools.compactMap { item in
            guard let name = item["name"] as? String else { return nil }
            let annotations = item["annotations"] as? [String: Any]
            let readOnly = annotations?["readOnlyHint"] as? Bool
                ?? Self.inferReadOnly(name: name)
            return MCPToolDescriptor(
                serverID: server.id,
                originalName: name,
                namespacedName: "\(server.namespace)_\(Self.sanitize(name))",
                description: item["description"] as? String ?? name,
                parameters: item["inputSchema"] as? [String: Any]
                    ?? ["type": "object", "properties": [:]],
                isReadOnly: readOnly
            )
        }
    }

    func callTool(name: String, argumentsJSON: String) async throws -> String {
        let arguments = (try? JSONSerialization.jsonObject(with: Data(argumentsJSON.utf8)))
            as? [String: Any] ?? [:]
        let result = try await request(
            method: "tools/call",
            params: ["name": name, "arguments": arguments],
            id: 3
        )
        let data = try JSONSerialization.data(
            withJSONObject: result ?? NSNull(),
            options: [.sortedKeys]
        )
        guard data.count <= server.maximumOutputBytes else { throw MCPError.outputTooLarge }
        return String(decoding: data, as: UTF8.self)
    }

    private func request(method: String, params: [String: Any], id: Int) async throws -> Any? {
        var request = URLRequest(url: server.endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = server.timeoutSeconds
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        if let token = Keychain.get(Keychain.mcpToken(serverID: server.id)), !token.isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "jsonrpc": "2.0",
            "id": id,
            "method": method,
            "params": params
        ])
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw MCPError.invalidResponse }
        guard (200...299).contains(http.statusCode) else {
            throw MCPError.server(
                http.statusCode,
                String(decoding: data.prefix(1_000), as: UTF8.self)
            )
        }
        guard data.count <= server.maximumOutputBytes else { throw MCPError.outputTooLarge }
        let json = try JSONSerialization.jsonObject(with: data)
        guard let object = json as? [String: Any] else { throw MCPError.invalidResponse }
        if let error = object["error"] as? [String: Any] {
            throw MCPError.invalidConfiguration(error["message"] as? String ?? "Unknown MCP error.")
        }
        return object["result"]
    }

    private static func sanitize(_ name: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_"))
        return name.unicodeScalars.map { allowed.contains($0) ? Character(String($0)) : "_" }
            .map(String.init)
            .joined()
    }

    private static func inferReadOnly(name: String) -> Bool {
        let lower = name.lowercased()
        return ["get", "list", "read", "search", "find", "fetch", "inspect", "query"]
            .contains { lower.hasPrefix($0) }
    }
}
