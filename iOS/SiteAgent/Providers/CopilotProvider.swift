import Foundation

/// GitHub Copilot as an LLM provider. The chat endpoint is OpenAI-compatible, so
/// we reuse OpenAICompatibleProvider's message codec; the differences are auth (a
/// short-lived bearer from `CopilotAuth`) and the editor-identity headers Copilot
/// requires. Models are served from the user's Copilot subscription.
struct CopilotProvider: LLMProvider {
    let id = "copilot"
    let displayName = "GitHub Copilot"
    // Copilot serves OpenAI + Claude models under its own slugs; availability is
    // plan/version dependent. Ideally fetched from GitHub's models-catalog API
    // rather than hardcoded — tracked as the ModelCatalog work.
    let models = ["gpt-5", "gpt-5-mini", "claude-sonnet-4.5", "claude-haiku-4.5", "o4-mini"]
    let defaultModel = "claude-sonnet-4.5"

    func capabilities(for model: String) -> ModelCapabilities {
        let imageInput = Self.modelSupportsImageInput(model)
        let reasoningSummary = model.lowercased().hasPrefix("gpt-5") || model.lowercased().hasPrefix("o")
        if imageInput {
            return ModelCapabilities.visionText(
                supportsTools: true,
                supportsStreamingToolCalls: true,
                supportsReasoningSummary: reasoningSummary
            )
        }
        return ModelCapabilities.textOnly(
            supportsTools: true,
            supportsStreamingToolCalls: true,
            supportsReasoningSummary: reasoningSummary
        )
    }

    private let endpoint = SiteAgentURL.constant("https://api.githubcopilot.com/chat/completions")

    func complete(messages: [LLMMessage], tools: [ToolSpec], model: String) async throws -> LLMResponse {
        let token = try await CopilotAuth.shared.bearerToken()

        var payload: [String: Any] = [
            "model": model,
            "messages": messages.map(OpenAICompatibleProvider.encode),
        ]
        if !tools.isEmpty {
            payload["tools"] = tools.map { spec in
                ["type": "function",
                 "function": ["name": spec.name,
                              "description": spec.description,
                              "parameters": spec.parameters]]
            }
            payload["tool_choice"] = "auto"
        }
        let req = try OpenAICompatibleProvider.makeRequest(url: endpoint,
                                                           bearerToken: token,
                                                           payload: payload,
                                                           extraHeaders: Self.editorHeaders(for: messages))

        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse else { throw LLMError.http(-1, "no response") }
        guard (200..<300).contains(http.statusCode) else {
            throw LLMError.http(http.statusCode, String((String(data: data, encoding: .utf8) ?? "").prefix(400)))
        }
        return try OpenAICompatibleProvider.parse(data)
    }

    func stream(messages: [LLMMessage], tools: [ToolSpec], model: String,
                onActivity: @escaping (LLMStreamActivity) -> Void,
                onText: @escaping (String) -> Void) async throws -> LLMResponse {
        let token = try await CopilotAuth.shared.bearerToken()

        var payload: [String: Any] = [
            "model": model,
            "messages": messages.map(OpenAICompatibleProvider.encode),
            "stream": true,
        ]
        if !tools.isEmpty {
            payload["tools"] = tools.map { spec in
                ["type": "function",
                 "function": ["name": spec.name,
                              "description": spec.description,
                              "parameters": spec.parameters]]
            }
            payload["tool_choice"] = "auto"
        }
        let req = try OpenAICompatibleProvider.makeRequest(url: endpoint,
                                                           bearerToken: token,
                                                           payload: payload,
                                                           extraHeaders: Self.editorHeaders(for: messages))
        return try await OpenAICompatibleProvider.parseSSE(req, onActivity: onActivity, onText: onText)
    }

    /// Copilot-specific editor-identity headers (plus the vision opt-in when the
    /// request carries images). The shared auth/content-type/body assembly lives
    /// on `OpenAICompatibleProvider.makeRequest`; this is everything that's unique
    /// to Copilot on top of the OpenAI request shape.
    private static func editorHeaders(for messages: [LLMMessage]) -> [String: String] {
        var headers: [String: String] = [
            "Editor-Version": CopilotAuth.editorVersion,
            "Editor-Plugin-Version": CopilotAuth.pluginVersion,
            "Copilot-Integration-Id": "vscode-chat",
            "User-Agent": "WebsiteCommander",
        ]
        if messages.contains(where: { $0.images?.isEmpty == false }) {
            headers["Copilot-Vision-Request"] = "true"
        }
        return headers
    }

    private static func modelSupportsImageInput(_ model: String) -> Bool {
        let lower = model.lowercased()
        let visionMarkers = ["gpt-4o", "gpt-4.1", "gpt-5", "o3", "o4", "claude", "gemini", "vision"]
        return visionMarkers.contains { lower.contains($0) }
    }
}
