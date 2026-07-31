import Foundation

/// A provider that speaks the OpenAI `/chat/completions` protocol. This one type
/// powers OpenAI, DeepSeek, Grok, Mistral, GitHub Copilot, and any custom
/// OpenAI-compatible endpoint — only the base URL, key, and model list differ.
struct OpenAICompatibleProvider: LLMProvider {

    struct Config {
        var id: String
        var displayName: String
        var baseURL: String          // e.g. https://api.openai.com/v1
        var apiKey: String
        var models: [String]
        var defaultModel: String
        var visionModels: Set<String> = []
        var extraHeaders: [String: String] = [:]
    }

    let config: Config

    var id: String { config.id }
    var displayName: String { config.displayName }
    var models: [String] { config.models }
    var defaultModel: String { config.defaultModel }

    func capabilities(for model: String) -> ModelCapabilities {
        ModelCapabilities(
            supportsVision: config.visionModels.contains(model),
            supportsTools: true,
            supportsReasoning: ModelReasoningSupport.openAICompatible(model)
        )
    }

    func complete(messages: [LLMMessage], tools: [ToolSpec], model: String) async throws -> LLMResponse {
        var body: [String: Any] = [
            "model": model,
            "messages": messages.map { Self.messageJSON($0) }
        ]
        Self.applyThinkingIfSupported(&body, model: model)
        if !tools.isEmpty {
            body["tools"] = tools.map { tool -> [String: Any] in
                ["type": "function",
                 "function": [
                    "name": tool.name,
                    "description": tool.description,
                    "parameters": tool.parameters
                 ] as [String: Any]]
            }
        }

        var headers: [String: String] = [
            "Authorization": "Bearer \(config.apiKey)",
            "Content-Type": "application/json"
        ]
        for (k, v) in config.extraHeaders { headers[k] = v }

        let data = try await Self.post(url: config.baseURL + "/chat/completions",
                                       headers: headers, body: body)
        return try Self.parse(data)
    }

    func stream(messages: [LLMMessage], tools: [ToolSpec], model: String,
                onActivity: @escaping (LLMStreamActivity) -> Void,
                onText: @escaping (String) -> Void,
                onReasoning: @escaping (String) -> Void) async throws -> LLMResponse {
        var body: [String: Any] = [
            "model": model,
            "stream": true,
            "stream_options": ["include_usage": true],
            "messages": messages.map { Self.messageJSON($0) }
        ]
        Self.applyThinkingIfSupported(&body, model: model)
        if !tools.isEmpty {
            body["tools"] = tools.map { tool -> [String: Any] in
                ["type": "function",
                 "function": [
                    "name": tool.name,
                    "description": tool.description,
                    "parameters": tool.parameters
                 ] as [String: Any]]
            }
        }
        var headers: [String: String] = [
            "Authorization": "Bearer \(config.apiKey)",
            "Content-Type": "application/json",
            "Accept": "text/event-stream"
        ]
        for (k, v) in config.extraHeaders { headers[k] = v }
        guard let endpoint = URL(string: config.baseURL + "/chat/completions") else {
            throw LLMError.decoding("bad URL \(config.baseURL)")
        }
        var req = URLRequest(url: endpoint)
        req.httpMethod = "POST"
        req.timeoutInterval = 240
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (bytes, response) = try await URLSession.shared.bytes(for: req)
        guard let http = response as? HTTPURLResponse else { throw LLMError.decoding("no response") }
        if !(200..<300).contains(http.statusCode) {
            var err = Data()
            for try await byte in bytes { err.append(byte) }
            throw LLMError.http(http.statusCode, String(data: err, encoding: .utf8) ?? "")
        }
        onActivity(.connected)

        var content = ""
        var reasoning = ""
        var toolAcc: [Int: (id: String, name: String, args: String)] = [:]
        var usage: TokenUsage?

        for try await rawLine in bytes.lines {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix("data:") else { continue }
            let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
            if payload == "[DONE]" { break }
            guard let data = payload.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
            if let u = obj["usage"] as? [String: Any] {
                usage = TokenUsage(promptTokens: (u["prompt_tokens"] as? Int) ?? 0,
                                   completionTokens: (u["completion_tokens"] as? Int) ?? 0)
            }
            guard let choices = obj["choices"] as? [[String: Any]],
                  let choice = choices.first,
                  let delta = (choice["delta"] as? [String: Any])
                    ?? (choice["message"] as? [String: Any]) else { continue }
            if let chunk = Self.reasoningChunk(from: delta), !chunk.isEmpty {
                if reasoning.isEmpty { onActivity(.reasoning) }
                reasoning += chunk
                onReasoning(reasoning)
            }
            if let c = delta["content"] as? String, !c.isEmpty {
                content += c
                onText(content)
            }
            if let tcs = delta["tool_calls"] as? [[String: Any]] {
                onActivity(.toolCall)
                for tc in tcs {
                    let idx = (tc["index"] as? Int) ?? 0
                    var entry = toolAcc[idx] ?? (id: "", name: "", args: "")
                    if let id = tc["id"] as? String, !id.isEmpty { entry.id = id }
                    if let fn = tc["function"] as? [String: Any] {
                        if let n = fn["name"] as? String, !n.isEmpty {
                            if entry.name.isEmpty { entry.name = n }
                            else if n != entry.name {
                                entry.name = n.hasPrefix(entry.name) ? n : entry.name + n
                            }
                        }
                        if let a = fn["arguments"] as? String {
                            entry.args += a
                        } else if let a = fn["arguments"],
                                  let data = try? JSONSerialization.data(withJSONObject: a),
                                  let json = String(data: data, encoding: .utf8) {
                            entry.args = json
                        }
                    }
                    toolAcc[idx] = entry
                }
            } else if let fn = delta["function_call"] as? [String: Any] {
                onActivity(.toolCall)
                var entry = toolAcc[0] ?? (id: UUID().uuidString, name: "", args: "")
                if let name = fn["name"] as? String, !name.isEmpty { entry.name = name }
                if let args = fn["arguments"] as? String { entry.args += args }
                toolAcc[0] = entry
            }
        }

        let toolCalls = toolAcc.keys.sorted().compactMap { i -> LLMToolCall? in
            let e = toolAcc[i]!
            guard !e.name.isEmpty else { return nil }
            return LLMToolCall(id: e.id.isEmpty ? UUID().uuidString : e.id,
                               name: e.name,
                               argumentsJSON: e.args.isEmpty ? "{}" : e.args)
        }
        return LLMResponse(content: content.isEmpty ? nil : content,
                           toolCalls: toolCalls, usage: usage,
                           reasoning: reasoning.isEmpty ? nil : reasoning)
    }

    /// Extract a reasoning delta from OpenAI-compatible payloads.
    /// DeepSeek uses `reasoning_content`; some gateways use `reasoning`.
    static func reasoningChunk(from delta: [String: Any]) -> String? {
        if let s = delta["reasoning_content"] as? String, !s.isEmpty { return s }
        if let s = delta["reasoning"] as? String, !s.isEmpty { return s }
        return nil
    }

    /// Request thinking / reasoning traces when the model is known to support them.
    /// DeepSeek V4 accepts `thinking: {type: enabled}`; unknown gateways ignore it.
    static func applyThinkingIfSupported(_ body: inout [String: Any], model: String) {
        guard ModelReasoningSupport.openAICompatible(model) else { return }
        let m = model.lowercased()
        // o-series uses reasoning_effort rather than DeepSeek's thinking toggle.
        if m.hasPrefix("o1") || m.hasPrefix("o3") || m.hasPrefix("o4") {
            if body["reasoning_effort"] == nil {
                body["reasoning_effort"] = "medium"
            }
            return
        }
        // DeepSeek V4 thinking mode. Other gateways often reject unknown keys,
        // so only send this for DeepSeek model IDs.
        if m.contains("deepseek"), body["thinking"] == nil {
            body["thinking"] = ["type": "enabled"]
        }
    }

    // MARK: JSON mapping

    private static func messageJSON(_ message: LLMMessage) -> [String: Any] {
        var obj: [String: Any] = ["role": message.role]

        // User turn with images → content as an array of typed parts.
        if message.role == "user", let images = message.images, !images.isEmpty {
            var parts: [[String: Any]] = [["type": "text", "text": message.content ?? ""]]
            for image in images {
                parts.append([
                    "type": "image_url",
                    "image_url": ["url": "data:\(image.mimeType);base64,\(image.base64)"]
                ])
            }
            obj["content"] = parts
        } else {
            obj["content"] = message.content ?? ""
        }

        if let calls = message.toolCalls, !calls.isEmpty {
            obj["tool_calls"] = calls.map { call -> [String: Any] in
                ["id": call.id,
                 "type": "function",
                 "function": ["name": call.name, "arguments": call.argumentsJSON]]
            }
        }
        if let toolCallID = message.toolCallID {
            obj["tool_call_id"] = toolCallID
        }
        if let name = message.name { obj["name"] = name }
        // DeepSeek V4 (and similar) require reasoning_content to be replayed on
        // assistant turns that produced tool calls — omitting it yields HTTP 400.
        if let reasoning = message.reasoning?.trimmingCharacters(in: .whitespacesAndNewlines),
           !reasoning.isEmpty {
            obj["reasoning_content"] = reasoning
        }
        return obj
    }

    static func parse(_ data: Data) throws -> LLMResponse {
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = obj["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any] else {
            throw LLMError.decoding("no choices")
        }
        let content = message["content"] as? String
        let reasoning = (message["reasoning_content"] as? String)
            ?? (message["reasoning"] as? String)
        var toolCalls: [LLMToolCall] = []
        if let rawCalls = message["tool_calls"] as? [[String: Any]] {
            for raw in rawCalls {
                let fn = raw["function"] as? [String: Any]
                let arguments: String
                if let value = fn?["arguments"] as? String {
                    arguments = value
                } else if let value = fn?["arguments"],
                          let data = try? JSONSerialization.data(withJSONObject: value),
                          let json = String(data: data, encoding: .utf8) {
                    arguments = json
                } else {
                    arguments = "{}"
                }
                toolCalls.append(LLMToolCall(
                    id: (raw["id"] as? String) ?? UUID().uuidString,
                    name: (fn?["name"] as? String) ?? "",
                    argumentsJSON: arguments
                ))
            }
        }
        var usage: TokenUsage?
        if let u = obj["usage"] as? [String: Any] {
            usage = TokenUsage(
                promptTokens: (u["prompt_tokens"] as? Int) ?? 0,
                completionTokens: (u["completion_tokens"] as? Int) ?? 0)
        }
        let cleanedReasoning = reasoning?.trimmingCharacters(in: .whitespacesAndNewlines)
        return LLMResponse(
            content: content,
            toolCalls: toolCalls,
            usage: usage,
            reasoning: (cleanedReasoning?.isEmpty == false) ? cleanedReasoning : nil
        )
    }

    // MARK: Transport

    static func post(url: String, headers: [String: String], body: [String: Any]) async throws -> Data {
        guard let endpoint = URL(string: url) else { throw LLMError.decoding("bad URL \(url)") }
        var req = URLRequest(url: endpoint)
        req.httpMethod = "POST"
        req.timeoutInterval = 240
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse else { throw LLMError.decoding("no response") }
        guard (200..<300).contains(http.statusCode) else {
            throw LLMError.http(http.statusCode, String(data: data, encoding: .utf8) ?? "")
        }
        return data
    }
}
