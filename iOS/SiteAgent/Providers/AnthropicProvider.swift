import Foundation

/// Claude provider (Anthropic Messages API). Authenticates with a logged-in
/// OAuth token when available, otherwise an API key. Translates the app's
/// wire-neutral messages/tools to Anthropic's format and back.
struct AnthropicProvider: LLMProvider {
    let id = "anthropic"
    let displayName = "Claude"
    // Current Claude lineup (the 3.5/3-opus IDs were retired in 2025–26 and now 404).
    let models = ["claude-opus-4-8", "claude-sonnet-4-6", "claude-haiku-4-5"]
    let defaultModel = "claude-sonnet-4-6"

    private let endpoint = SiteAgentURL.constant("https://api.anthropic.com/v1/messages")

    func capabilities(for model: String) -> ModelCapabilities {
        ModelCapabilities.visionText(
            supportsTools: true,
            supportsForcedToolChoice: true,
            supportsParallelToolCalls: true,
            supportsStreamingToolCalls: true
        )
    }

    func complete(messages: [LLMMessage], tools: [ToolSpec], model: String) async throws -> LLMResponse {
        guard let auth = await ProviderCredentials.resolve(id) else {
            throw LLMError.noKey(displayName)
        }

        var req = URLRequest(url: endpoint)
        req.httpMethod = "POST"
        req.timeoutInterval = LLMTransportPolicy.requestTimeoutSeconds
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        if auth.isOAuth {
            req.setValue("Bearer \(auth.token)", forHTTPHeaderField: "Authorization")
            req.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        } else {
            req.setValue(auth.token, forHTTPHeaderField: "x-api-key")
        }

        let (system, msgs) = Self.convert(messages)
        var payload: [String: Any] = [
            "model": model,
            "max_tokens": 16384,   // 4096 truncated larger file writes; raise for whole-file edits
            "messages": msgs,
        ]
        if !system.isEmpty { payload["system"] = system }
        if !tools.isEmpty {
            payload["tools"] = tools.map { ["name": $0.name, "description": $0.description, "input_schema": $0.parameters] }
        }
        if let effort = ReasoningEffortCatalog.resolved(.stored, providerID: "anthropic", modelID: model).anthropicEffort {
            payload["effort"] = effort
        }
        req.httpBody = try JSONSerialization.data(withJSONObject: payload)

        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse else { throw LLMError.http(-1, "no response") }
        guard (200..<300).contains(http.statusCode) else {
            throw LLMError.http(http.statusCode, String((String(data: data, encoding: .utf8) ?? "").prefix(400)))
        }
        return try Self.parse(data)
    }

    // MARK: - Streaming (Anthropic SSE)

    func stream(messages: [LLMMessage], tools: [ToolSpec], model: String,
                onActivity: @escaping (LLMStreamActivity) -> Void,
                onText: @escaping (String) -> Void) async throws -> LLMResponse {
        guard let auth = await ProviderCredentials.resolve(id) else {
            throw LLMError.noKey(displayName)
        }
        var req = URLRequest(url: endpoint)
        req.httpMethod = "POST"
        req.timeoutInterval = LLMTransportPolicy.requestTimeoutSeconds
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        if auth.isOAuth {
            req.setValue("Bearer \(auth.token)", forHTTPHeaderField: "Authorization")
            req.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        } else {
            req.setValue(auth.token, forHTTPHeaderField: "x-api-key")
        }

        let (system, msgs) = Self.convert(messages)
        var payload: [String: Any] = [
            "model": model,
            "max_tokens": 16384,
            "messages": msgs,
            "stream": true,
        ]
        if !system.isEmpty { payload["system"] = system }
        if !tools.isEmpty {
            payload["tools"] = tools.map { ["name": $0.name, "description": $0.description, "input_schema": $0.parameters] }
        }
        if let effort = ReasoningEffortCatalog.resolved(.stored, providerID: "anthropic", modelID: model).anthropicEffort {
            payload["effort"] = effort
        }
        req.httpBody = try JSONSerialization.data(withJSONObject: payload)

        let (bytes, resp) = try await URLSession.shared.bytes(for: req)
        guard let http = resp as? HTTPURLResponse else { throw LLMError.http(-1, "no response") }
        guard (200..<300).contains(http.statusCode) else {
            var body = ""
            for try await line in bytes.lines { body += line; if body.count > 800 { break } }
            throw LLMError.http(http.statusCode, String(body.prefix(400)))
        }
        onActivity(.connected)

        var text = ""
        var inputTokens = 0, outputTokens = 0
        var toolBlocks: [Int: (id: String, name: String, json: String)] = [:]
        var isLimitReached = false

        for try await line in bytes.lines {
            // Cap accumulated streaming buffer size (10 MB)
            let currentBytes = text.utf8.count + toolBlocks.values.reduce(0, { $0 + $1.json.utf8.count })
            if currentBytes > 10 * 1024 * 1024 {
                throw LLMError.decoding("Streaming buffer limit exceeded (10 MB)")
            }

            guard line.hasPrefix("data:") else { continue }
            let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
            guard let data = payload.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let type = obj["type"] as? String else { continue }

            switch type {
            case "message_start":
                if let m = obj["message"] as? [String: Any],
                   let u = m["usage"] as? [String: Any],
                   let i = u["input_tokens"] as? Int { inputTokens = i }
            case "content_block_start":
                if let idx = obj["index"] as? Int,
                   let block = obj["content_block"] as? [String: Any],
                   (block["type"] as? String) == "tool_use" {
                    onActivity(.toolCall)
                    toolBlocks[idx] = (id: block["id"] as? String ?? UUID().uuidString,
                                       name: block["name"] as? String ?? "", json: "")
                }
            case "content_block_delta":
                guard let idx = obj["index"] as? Int, let delta = obj["delta"] as? [String: Any] else { break }
                if let t = delta["text"] as? String { text += t; onText(text) }
                if let thinking = delta["thinking"] as? String, !thinking.isEmpty {
                    onActivity(.reasoning)
                }
                if let partial = delta["partial_json"] as? String, toolBlocks[idx] != nil {
                    if !partial.isEmpty { onActivity(.toolCall) }
                    toolBlocks[idx]?.json += partial
                }
            case "message_delta":
                if let u = obj["usage"] as? [String: Any], let o = u["output_tokens"] as? Int { outputTokens = o }
                if let delta = obj["delta"] as? [String: Any], let sr = delta["stop_reason"] as? String, sr == "max_tokens" {
                    isLimitReached = true
                }
            default:
                break
            }
        }

        var errorType: LLMResponseErrorType? = nil
        if isLimitReached {
            errorType = .outputLimitReached
        }

        let calls = toolBlocks.sorted { $0.key < $1.key }.map { _, v in
            LLMToolCall(id: v.id, name: v.name, argumentsJSON: v.json.isEmpty ? "{}" : v.json)
        }
        
        // Do not execute partial JSON tool arguments
        for call in calls {
            if call.argumentsJSON.utf8.count > 1 * 1024 * 1024 { // 1 MB individual arg cap
                errorType = .toolCallIncomplete
            }
            let data = Data(call.argumentsJSON.utf8)
            if (try? JSONSerialization.jsonObject(with: data)) == nil {
                errorType = errorType ?? .malformedToolArguments
            }
        }

        let usage: TokenUsage? = (inputTokens > 0 || outputTokens > 0)
            ? TokenUsage(promptTokens: inputTokens, completionTokens: outputTokens) : nil
        return LLMResponse(content: text.isEmpty ? nil : text, toolCalls: calls, usage: usage, errorType: errorType)
    }

    // MARK: - Convert app messages → Anthropic format

    /// Returns (systemPrompt, messages). Anthropic puts system text at top level,
    /// and tool results go inside a `user` turn as `tool_result` blocks.
    static func convert(_ messages: [LLMMessage]) -> (String, [[String: Any]]) {
        var system = ""
        var out: [[String: Any]] = []

        for m in messages {
            switch m.role {
            case "system":
                system += (system.isEmpty ? "" : "\n\n") + (m.content ?? "")

            case "user":
                if let images = m.images, !images.isEmpty {
                    var blocks: [[String: Any]] = []
                    if let t = m.content, !t.isEmpty { blocks.append(["type": "text", "text": t]) }
                    for img in images {
                        blocks.append(["type": "image",
                                       "source": ["type": "base64",
                                                  "media_type": img.mimeType,
                                                  "data": img.base64]])
                    }
                    out.append(["role": "user", "content": blocks])
                } else {
                    out.append(["role": "user", "content": m.content ?? ""])
                }

            case "assistant":
                var blocks: [[String: Any]] = []
                if let text = m.content, !text.isEmpty {
                    blocks.append(["type": "text", "text": text])
                }
                for call in m.toolCalls ?? [] {
                    let input = (try? JSONSerialization.jsonObject(with: Data(call.argumentsJSON.utf8))) as? [String: Any] ?? [:]
                    blocks.append(["type": "tool_use", "id": call.id, "name": call.name, "input": input])
                }
                if blocks.isEmpty { blocks = [["type": "text", "text": ""]] }
                out.append(["role": "assistant", "content": blocks])

            case "tool":
                // Merge into the previous user turn if it's already tool_results,
                // otherwise start a new user turn.
                let block: [String: Any] = [
                    "type": "tool_result",
                    "tool_use_id": m.toolCallID ?? "",
                    "content": m.content ?? "",
                ]
                if var last = out.last, last["role"] as? String == "user",
                   var content = last["content"] as? [[String: Any]] {
                    content.append(block)
                    last["content"] = content
                    out[out.count - 1] = last
                } else {
                    out.append(["role": "user", "content": [block]])
                }

            default:
                break
            }
        }
        return (system, out)
    }

    // MARK: - Parse Anthropic response → wire-neutral

    private static func parse(_ data: Data) throws -> LLMResponse {
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let content = obj["content"] as? [[String: Any]] else {
            throw LLMError.decoding("missing content")
        }
        var text = ""
        var calls: [LLMToolCall] = []
        for block in content {
            switch block["type"] as? String {
            case "text":
                text += (block["text"] as? String) ?? ""
            case "tool_use":
                let name = (block["name"] as? String) ?? ""
                let id = (block["id"] as? String) ?? UUID().uuidString
                let input = block["input"] ?? [:]
                let argsData = (try? JSONSerialization.data(withJSONObject: input)) ?? Data("{}".utf8)
                calls.append(LLMToolCall(id: id, name: name, argumentsJSON: String(data: argsData, encoding: .utf8) ?? "{}"))
            default:
                break
            }
        }
        
        var usage: TokenUsage?
        if let rawUsage = obj["usage"] as? [String: Any],
           let prompt = rawUsage["input_tokens"] as? Int,
           let completion = rawUsage["output_tokens"] as? Int {
            usage = TokenUsage(promptTokens: prompt, completionTokens: completion)
        }

        var errorType: LLMResponseErrorType? = nil
        if (obj["stop_reason"] as? String) == "max_tokens" {
            errorType = .outputLimitReached
        }

        return LLMResponse(content: text.isEmpty ? nil : text, toolCalls: calls, usage: usage, errorType: errorType)
    }
}
