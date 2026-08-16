import Foundation

/// Anthropic (Claude) via the Messages API. Translates the uniform OpenAI-style
/// `LLMMessage` wire format into Anthropic's content-block structure (text,
/// image, tool_use, tool_result, thinking).
struct AnthropicProvider: LLMProvider {

    let apiKey: String
    /// Thinking-budget level. The API only exposes a token budget, so effort
    /// levels map onto (budget, max_tokens) pairs that always keep the budget
    /// strictly below max_tokens.
    let effort: ReasoningEffort

    init(apiKey: String, effort: ReasoningEffort = .default) {
        self.apiKey = apiKey
        self.effort = effort
    }

    var id: String { "anthropic" }
    var displayName: String { "Claude" }
    var models: [String] {
        ["claude-sonnet-4-5", "claude-opus-4-1", "claude-3-7-sonnet-latest", "claude-3-5-haiku-latest"]
    }
    var defaultModel: String { "claude-sonnet-4-5" }

    func capabilities(for model: String) -> ModelCapabilities {
        .vision(reasoning: ModelReasoningSupport.anthropic(model))
    }

    func requestBody(messages: [LLMMessage], tools: [ToolSpec], model: String) throws -> [String: Any] {
        guard !apiKey.isEmpty else { throw LLMError.noKey(displayName) }

        var system = ""
        var anthropicMessages: [[String: Any]] = []
        var pendingToolResults: [[String: Any]] = []

        func flushToolResults() {
            guard !pendingToolResults.isEmpty else { return }
            anthropicMessages.append(["role": "user", "content": pendingToolResults])
            pendingToolResults = []
        }

        for message in messages {
            switch message.role {
            case "system":
                system += (system.isEmpty ? "" : "\n\n") + (message.content ?? "")

            case "user":
                flushToolResults()
                var blocks: [[String: Any]] = [["type": "text", "text": message.content ?? ""]]
                for image in message.images ?? [] {
                    blocks.append([
                        "type": "image",
                        "source": ["type": "base64",
                                   "media_type": image.mimeType,
                                   "data": image.base64]
                    ])
                }
                anthropicMessages.append(["role": "user", "content": blocks])

            case "assistant":
                flushToolResults()
                var blocks: [[String: Any]] = []
                // Anthropic requires thinking (+ signature) — or redacted_thinking —
                // before tool_use when replaying an extended-thinking tool turn.
                if let redacted = message.reasoningRedactedData, !redacted.isEmpty {
                    blocks.append(["type": "redacted_thinking", "data": redacted])
                } else if let reasoning = message.reasoning, !reasoning.isEmpty {
                    var thinking: [String: Any] = [
                        "type": "thinking",
                        "thinking": reasoning
                    ]
                    if let signature = message.reasoningSignature, !signature.isEmpty {
                        thinking["signature"] = signature
                    }
                    blocks.append(thinking)
                }
                if let text = message.content, !text.isEmpty {
                    blocks.append(["type": "text", "text": text])
                }
                for call in message.toolCalls ?? [] {
                    let input = (try? JSONSerialization.jsonObject(
                        with: Data(call.argumentsJSON.utf8))) ?? [String: Any]()
                    blocks.append([
                        "type": "tool_use",
                        "id": call.id,
                        "name": call.name,
                        "input": input
                    ])
                }
                if blocks.isEmpty { blocks.append(["type": "text", "text": ""]) }
                anthropicMessages.append(["role": "assistant", "content": blocks])

            case "tool":
                pendingToolResults.append([
                    "type": "tool_result",
                    "tool_use_id": message.toolCallID ?? "",
                    "content": message.content ?? ""
                ])

            default:
                continue
            }
        }
        flushToolResults()

        let thinkingEnabled = ModelReasoningSupport.anthropic(model)
        // Thinking budget must be less than max_tokens; each effort level pairs
        // its budget with headroom for the visible answer above it.
        let budgetTokens: Int
        let maxTokens: Int
        switch effort {
        case .default, .medium: budgetTokens = 8_000;  maxTokens = 16_000
        case .low:              budgetTokens = 2_048;  maxTokens = 8_192
        case .high:             budgetTokens = 16_000; maxTokens = 24_000
        }
        var body: [String: Any] = [
            "model": model,
            "max_tokens": thinkingEnabled ? maxTokens : 8192,
            "messages": anthropicMessages
        ]
        if thinkingEnabled {
            body["thinking"] = ["type": "enabled", "budget_tokens": budgetTokens]
        }
        if !system.isEmpty { body["system"] = system }
        if !tools.isEmpty {
            body["tools"] = tools.map { tool -> [String: Any] in
                ["name": tool.name,
                 "description": tool.description,
                 "input_schema": tool.parameters]
            }
        }
        return body
    }

    func complete(messages: [LLMMessage], tools: [ToolSpec], model: String) async throws -> LLMResponse {
        let body = try requestBody(messages: messages, tools: tools, model: model)
        let headers = [
            "x-api-key": apiKey,
            "anthropic-version": "2023-06-01",
            "content-type": "application/json"
        ]
        let data = try await OpenAICompatibleProvider.post(
            url: "https://api.anthropic.com/v1/messages", headers: headers, body: body)
        return try parse(data)
    }

    func stream(messages: [LLMMessage], tools: [ToolSpec], model: String,
                onActivity: @escaping (LLMStreamActivity) -> Void,
                onText: @escaping (String) -> Void,
                onReasoning: @escaping (String) -> Void) async throws -> LLMResponse {
        var body = try requestBody(messages: messages, tools: tools, model: model)
        body["stream"] = true
        let headers = [
            "x-api-key": apiKey,
            "anthropic-version": "2023-06-01",
            "content-type": "application/json",
            "accept": "text/event-stream"
        ]
        guard let endpoint = URL(string: "https://api.anthropic.com/v1/messages") else {
            throw LLMError.decoding("bad URL")
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
        var reasoningSignature = ""
        var reasoningRedactedData = ""
        var toolAcc: [Int: (id: String, name: String, args: String)] = [:]
        var usage = TokenUsage(promptTokens: 0, completionTokens: 0)
        var eventType = ""

        for try await rawLine in bytes.lines {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("event:") {
                eventType = line.dropFirst(6).trimmingCharacters(in: .whitespaces)
                continue
            }
            guard line.hasPrefix("data:") else { continue }
            let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
            guard let data = payload.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
            let index = (obj["index"] as? Int) ?? -1
            switch eventType {
            case "message_start":
                if let m = obj["message"] as? [String: Any], let u = m["usage"] as? [String: Any] {
                    usage.promptTokens = (u["input_tokens"] as? Int) ?? 0
                }
            case "content_block_start":
                if let cb = obj["content_block"] as? [String: Any] {
                    let type = cb["type"] as? String
                    if type == "tool_use" {
                        toolAcc[index] = (id: (cb["id"] as? String) ?? UUID().uuidString,
                                          name: (cb["name"] as? String) ?? "", args: "")
                        onActivity(.toolCall)
                    } else if type == "thinking" {
                        onActivity(.reasoning)
                        if let t = cb["thinking"] as? String, !t.isEmpty {
                            reasoning += t
                            onReasoning(reasoning)
                        }
                    } else if type == "redacted_thinking" {
                        onActivity(.reasoning)
                        if let d = cb["data"] as? String { reasoningRedactedData += d }
                    }
                }
            case "content_block_delta":
                if let delta = obj["delta"] as? [String: Any] {
                    let dtype = delta["type"] as? String
                    if dtype == "text_delta", let t = delta["text"] as? String {
                        content += t
                        onText(content)
                    } else if dtype == "thinking_delta", let t = delta["thinking"] as? String {
                        if reasoning.isEmpty { onActivity(.reasoning) }
                        reasoning += t
                        onReasoning(reasoning)
                    } else if dtype == "signature_delta", let s = delta["signature"] as? String {
                        reasoningSignature += s
                    } else if dtype == "input_json_delta",
                              let pj = delta["partial_json"] as? String, index >= 0 {
                        toolAcc[index]?.args.append(pj)
                    }
                }
            case "message_delta":
                if let u = obj["usage"] as? [String: Any] {
                    usage.completionTokens = (u["output_tokens"] as? Int) ?? usage.completionTokens
                }
            case "error":
                let message = (obj["error"] as? [String: Any])?["message"] as? String
                    ?? "Anthropic stream error"
                throw LLMError.decoding("Anthropic stream error: \(message)")
            default:
                break
            }
        }

        let toolCalls = toolAcc.keys.sorted().map { i -> LLMToolCall in
            let e = toolAcc[i]!
            return LLMToolCall(id: e.id, name: e.name,
                               argumentsJSON: e.args.isEmpty ? "{}" : e.args)
        }
        let usedUsage: TokenUsage? =
            (usage.promptTokens == 0 && usage.completionTokens == 0) ? nil : usage
        return LLMResponse(content: content.isEmpty ? nil : content,
                           toolCalls: toolCalls, usage: usedUsage,
                           reasoning: reasoning.isEmpty ? nil : reasoning,
                           reasoningSignature: reasoningSignature.isEmpty ? nil : reasoningSignature,
                           reasoningRedactedData: reasoningRedactedData.isEmpty ? nil : reasoningRedactedData)
    }

    private func parse(_ data: Data) throws -> LLMResponse {
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let blocks = obj["content"] as? [[String: Any]] else {
            throw LLMError.decoding("no content blocks")
        }
        var text = ""
        var reasoning = ""
        var reasoningSignature: String?
        var reasoningRedactedData: String?
        var toolCalls: [LLMToolCall] = []
        for block in blocks {
            switch block["type"] as? String {
            case "text":
                text += (block["text"] as? String) ?? ""
            case "thinking":
                reasoning += (block["thinking"] as? String) ?? ""
                if let sig = block["signature"] as? String, !sig.isEmpty {
                    reasoningSignature = sig
                }
            case "redacted_thinking":
                if let d = block["data"] as? String, !d.isEmpty {
                    reasoningRedactedData = (reasoningRedactedData ?? "") + d
                }
            case "tool_use":
                let input = block["input"] ?? [String: Any]()
                let argsData = (try? JSONSerialization.data(withJSONObject: input)) ?? Data("{}".utf8)
                toolCalls.append(LLMToolCall(
                    id: (block["id"] as? String) ?? UUID().uuidString,
                    name: (block["name"] as? String) ?? "",
                    argumentsJSON: String(data: argsData, encoding: .utf8) ?? "{}"))
            default:
                continue
            }
        }
        var usage: TokenUsage?
        if let u = obj["usage"] as? [String: Any] {
            usage = TokenUsage(
                promptTokens: (u["input_tokens"] as? Int) ?? 0,
                completionTokens: (u["output_tokens"] as? Int) ?? 0)
        }
        return LLMResponse(content: text.isEmpty ? nil : text, toolCalls: toolCalls, usage: usage,
                           reasoning: reasoning.isEmpty ? nil : reasoning,
                           reasoningSignature: reasoningSignature,
                           reasoningRedactedData: reasoningRedactedData)
    }
}
