import Foundation

/// Google Gemini via the `generateContent` API. Maps the uniform wire format onto
/// Gemini's `contents`/`parts` structure (text, inlineData, functionCall,
/// functionResponse).
struct GeminiProvider: LLMProvider {

    let apiKey: String
    var id: String { "gemini" }
    var displayName: String { "Gemini" }
    var models: [String] {
        ["gemini-2.5-pro", "gemini-2.5-flash", "gemini-2.0-flash"]
    }
    var defaultModel: String { "gemini-2.5-pro" }

    func capabilities(for model: String) -> ModelCapabilities { .vision }

    func complete(messages: [LLMMessage], tools: [ToolSpec], model: String) async throws -> LLMResponse {
        guard !apiKey.isEmpty else { throw LLMError.noKey(displayName) }

        var system = ""
        var contents: [[String: Any]] = []
        var pendingResponses: [[String: Any]] = []

        func flushResponses() {
            guard !pendingResponses.isEmpty else { return }
            contents.append(["role": "user", "parts": pendingResponses])
            pendingResponses = []
        }

        for message in messages {
            switch message.role {
            case "system":
                system += (system.isEmpty ? "" : "\n\n") + (message.content ?? "")

            case "user":
                flushResponses()
                var parts: [[String: Any]] = [["text": message.content ?? ""]]
                for image in message.images ?? [] {
                    parts.append(["inlineData": ["mimeType": image.mimeType, "data": image.base64]])
                }
                contents.append(["role": "user", "parts": parts])

            case "assistant":
                flushResponses()
                var parts: [[String: Any]] = []
                if let text = message.content, !text.isEmpty { parts.append(["text": text]) }
                for call in message.toolCalls ?? [] {
                    let args = (try? JSONSerialization.jsonObject(
                        with: Data(call.argumentsJSON.utf8))) ?? [String: Any]()
                    parts.append(["functionCall": ["name": call.name, "args": args]])
                }
                if parts.isEmpty { parts.append(["text": ""]) }
                contents.append(["role": "model", "parts": parts])

            case "tool":
                let responseObj = (try? JSONSerialization.jsonObject(
                    with: Data((message.content ?? "").utf8))) ?? (message.content ?? "")
                pendingResponses.append([
                    "functionResponse": [
                        "name": message.name ?? "",
                        "response": ["result": responseObj]
                    ]
                ])

            default:
                continue
            }
        }
        flushResponses()

        var body: [String: Any] = ["contents": contents]
        if !system.isEmpty {
            body["systemInstruction"] = ["parts": [["text": system]]]
        }
        if !tools.isEmpty {
            body["tools"] = [[
                "functionDeclarations": tools.map { tool -> [String: Any] in
                    ["name": tool.name, "description": tool.description, "parameters": tool.parameters]
                }
            ]]
        }

        let url = "https://generativelanguage.googleapis.com/v1beta/models/\(model):generateContent?key=\(apiKey)"
        let data = try await OpenAICompatibleProvider.post(
            url: url, headers: ["Content-Type": "application/json"], body: body)
        return try parse(data)
    }

    private func parse(_ data: Data) throws -> LLMResponse {
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let candidates = obj["candidates"] as? [[String: Any]],
              let content = candidates.first?["content"] as? [String: Any],
              let parts = content["parts"] as? [[String: Any]] else {
            throw LLMError.decoding("no candidates")
        }
        var text = ""
        var toolCalls: [LLMToolCall] = []
        for part in parts {
            if let t = part["text"] as? String {
                text += t
            } else if let call = part["functionCall"] as? [String: Any] {
                let args = call["args"] ?? [String: Any]()
                let argsData = (try? JSONSerialization.data(withJSONObject: args)) ?? Data("{}".utf8)
                toolCalls.append(LLMToolCall(
                    id: UUID().uuidString,
                    name: (call["name"] as? String) ?? "",
                    argumentsJSON: String(data: argsData, encoding: .utf8) ?? "{}"))
            }
        }
        var usage: TokenUsage?
        if let u = obj["usageMetadata"] as? [String: Any] {
            usage = TokenUsage(
                promptTokens: (u["promptTokenCount"] as? Int) ?? 0,
                completionTokens: (u["candidatesTokenCount"] as? Int) ?? 0)
        }
        return LLMResponse(content: text.isEmpty ? nil : text, toolCalls: toolCalls, usage: usage)
    }
}
