import Foundation

/// Google Gemini via the `generateContent` API. Maps the uniform wire format onto
/// Gemini's `contents`/`parts` structure (text, inlineData, functionCall,
/// functionResponse, thought).
struct GeminiProvider: LLMProvider {

    let apiKey: String
    var id: String { "gemini" }
    var displayName: String { "Gemini" }
    var models: [String] {
        ["gemini-2.5-pro", "gemini-2.5-flash", "gemini-2.0-flash"]
    }
    var defaultModel: String { "gemini-2.5-pro" }

    func capabilities(for model: String) -> ModelCapabilities {
        .vision(reasoning: ModelReasoningSupport.gemini(model))
    }

    func complete(messages: [LLMMessage], tools: [ToolSpec], model: String) async throws -> LLMResponse {
        guard !apiKey.isEmpty else { throw LLMError.noKey(displayName) }
        let body = try requestBodyDict(messages: messages, tools: tools, model: model)
        let url = "https://generativelanguage.googleapis.com/v1beta/models/\(model):generateContent?key=\(apiKey)"
        let data = try await OpenAICompatibleProvider.post(
            url: url, headers: ["Content-Type": "application/json"], body: body)
        return try parse(data)
    }

    func stream(messages: [LLMMessage], tools: [ToolSpec], model: String,
                onActivity: @escaping (LLMStreamActivity) -> Void,
                onText: @escaping (String) -> Void,
                onReasoning: @escaping (String) -> Void) async throws -> LLMResponse {
        guard !apiKey.isEmpty else { throw LLMError.noKey(displayName) }
        let body = try requestBodyDict(messages: messages, tools: tools, model: model)
        let url = "https://generativelanguage.googleapis.com/v1beta/models/\(model):streamGenerateContent?alt=sse&key=\(apiKey)"
        guard let endpoint = URL(string: url) else { throw LLMError.decoding("bad URL") }
        var req = URLRequest(url: endpoint)
        req.httpMethod = "POST"
        req.timeoutInterval = 240
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (bytes, response) = try await URLSession.shared.bytes(for: req)
        guard let http = response as? HTTPURLResponse else { throw LLMError.decoding("no response") }
        if !(200..<300).contains(http.statusCode) {
            var err = Data()
            for try await byte in bytes { err.append(byte) }
            // Fall back to non-streaming generateContent if stream is unavailable.
            if http.statusCode == 404 || http.statusCode == 400 {
                return try await streamFallbackComplete(
                    messages: messages, tools: tools, model: model,
                    onActivity: onActivity, onText: onText, onReasoning: onReasoning)
            }
            throw LLMError.http(http.statusCode, String(data: err, encoding: .utf8) ?? "")
        }
        onActivity(.connected)

        var text = ""
        var reasoning = ""
        var toolCalls: [LLMToolCall] = []
        var usage: TokenUsage?

        for try await rawLine in bytes.lines {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix("data:") else { continue }
            let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
            guard !payload.isEmpty, payload != "[DONE]",
                  let data = payload.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }

            if let u = obj["usageMetadata"] as? [String: Any] {
                usage = TokenUsage(
                    promptTokens: (u["promptTokenCount"] as? Int) ?? 0,
                    completionTokens: (u["candidatesTokenCount"] as? Int) ?? 0)
            }
            guard let candidates = obj["candidates"] as? [[String: Any]],
                  let content = candidates.first?["content"] as? [String: Any],
                  let parts = content["parts"] as? [[String: Any]] else { continue }

            for part in parts {
                if let call = part["functionCall"] as? [String: Any] {
                    onActivity(.toolCall)
                    let args = call["args"] ?? [String: Any]()
                    let argsData = (try? JSONSerialization.data(withJSONObject: args)) ?? Data("{}".utf8)
                    toolCalls.append(LLMToolCall(
                        id: UUID().uuidString,
                        name: (call["name"] as? String) ?? "",
                        argumentsJSON: String(data: argsData, encoding: .utf8) ?? "{}"))
                    continue
                }
                guard let t = part["text"] as? String, !t.isEmpty else { continue }
                if part["thought"] as? Bool == true {
                    if reasoning.isEmpty { onActivity(.reasoning) }
                    reasoning += t
                    onReasoning(reasoning)
                } else {
                    text += t
                    onText(text)
                }
            }
        }

        return LLMResponse(
            content: text.isEmpty ? nil : text,
            toolCalls: toolCalls,
            usage: usage,
            reasoning: reasoning.isEmpty ? nil : reasoning
        )
    }

    private func streamFallbackComplete(
        messages: [LLMMessage], tools: [ToolSpec], model: String,
        onActivity: @escaping (LLMStreamActivity) -> Void,
        onText: @escaping (String) -> Void,
        onReasoning: @escaping (String) -> Void
    ) async throws -> LLMResponse {
        onActivity(.connected)
        let response = try await complete(messages: messages, tools: tools, model: model)
        if let reasoning = response.reasoning, !reasoning.isEmpty {
            onActivity(.reasoning)
            onReasoning(reasoning)
        }
        if let content = response.content, !content.isEmpty { onText(content) }
        return response
    }

    /// Shared request body builder for complete + streamGenerateContent.
    private func requestBodyDict(messages: [LLMMessage], tools: [ToolSpec], model: String) throws -> [String: Any] {
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
                if let reasoning = message.reasoning, !reasoning.isEmpty {
                    parts.append(["text": reasoning, "thought": true])
                }
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
        if ModelReasoningSupport.gemini(model) {
            body["generationConfig"] = [
                "thinkingConfig": ["includeThoughts": true]
            ]
        }
        if !tools.isEmpty {
            body["tools"] = [[
                "functionDeclarations": tools.map { tool -> [String: Any] in
                    ["name": tool.name, "description": tool.description, "parameters": tool.parameters]
                }
            ]]
        }
        return body
    }

    private func parse(_ data: Data) throws -> LLMResponse {
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let candidates = obj["candidates"] as? [[String: Any]],
              let content = candidates.first?["content"] as? [String: Any],
              let parts = content["parts"] as? [[String: Any]] else {
            throw LLMError.decoding("no candidates")
        }
        var text = ""
        var reasoning = ""
        var toolCalls: [LLMToolCall] = []
        for part in parts {
            if let call = part["functionCall"] as? [String: Any] {
                let args = call["args"] ?? [String: Any]()
                let argsData = (try? JSONSerialization.data(withJSONObject: args)) ?? Data("{}".utf8)
                toolCalls.append(LLMToolCall(
                    id: UUID().uuidString,
                    name: (call["name"] as? String) ?? "",
                    argumentsJSON: String(data: argsData, encoding: .utf8) ?? "{}"))
                continue
            }
            guard let t = part["text"] as? String else { continue }
            if part["thought"] as? Bool == true {
                reasoning += t
            } else {
                text += t
            }
        }
        var usage: TokenUsage?
        if let u = obj["usageMetadata"] as? [String: Any] {
            usage = TokenUsage(
                promptTokens: (u["promptTokenCount"] as? Int) ?? 0,
                completionTokens: (u["candidatesTokenCount"] as? Int) ?? 0)
        }
        return LLMResponse(content: text.isEmpty ? nil : text, toolCalls: toolCalls, usage: usage,
                           reasoning: reasoning.isEmpty ? nil : reasoning)
    }
}
