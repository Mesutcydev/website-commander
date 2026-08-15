import Foundation

struct MCPServerConfiguration: Identifiable, Codable, Equatable {
    let id: UUID
    var name: String
    var endpoint: URL
    var isEnabled: Bool
    var allowsWriteTools: Bool
    var timeoutSeconds: Double
    var maximumOutputBytes: Int

    init(
        id: UUID = UUID(),
        name: String,
        endpoint: URL,
        isEnabled: Bool = true,
        allowsWriteTools: Bool = false,
        timeoutSeconds: Double = 20,
        maximumOutputBytes: Int = 200_000
    ) {
        self.id = id
        self.name = name
        self.endpoint = endpoint
        self.isEnabled = isEnabled
        self.allowsWriteTools = allowsWriteTools
        self.timeoutSeconds = timeoutSeconds
        self.maximumOutputBytes = maximumOutputBytes
    }

    var namespace: String {
        "mcp_" + id.uuidString.lowercased().replacingOccurrences(of: "-", with: "").prefix(8)
    }

    func validated() throws -> MCPServerConfiguration {
        guard endpoint.scheme?.lowercased() == "https" else {
            throw MCPError.insecureEndpoint
        }
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw MCPError.invalidConfiguration("A server name is required.")
        }
        return self
    }
}

struct MCPToolDescriptor {
    var serverID: UUID
    var originalName: String
    var namespacedName: String
    var description: String
    var parameters: [String: Any]
    var isReadOnly: Bool
}

struct MCPExecutionResult {
    var succeeded: Bool
    var payload: String
}

enum MCPError: LocalizedError {
    case insecureEndpoint
    case invalidConfiguration(String)
    case invalidResponse
    case server(Int, String)
    case unknownTool
    case writePermissionRequired
    case outputTooLarge

    var errorDescription: String? {
        switch self {
        case .insecureEndpoint:
            return "MCP endpoints must use HTTPS."
        case .invalidConfiguration(let message):
            return message
        case .invalidResponse:
            return "The MCP server returned an invalid response."
        case .server(let status, let message):
            return "MCP server error \(status): \(message)"
        case .unknownTool:
            return "This MCP tool is no longer available. Refresh the server's tools."
        case .writePermissionRequired:
            return "This MCP tool may modify external data. Enable write tools for its server before using it."
        case .outputTooLarge:
            return "The MCP result exceeded this server's output limit."
        }
    }
}
