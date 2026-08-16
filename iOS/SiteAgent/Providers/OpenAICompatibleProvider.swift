import Foundation

private enum OpenCodeGoWireAPI {
    case chatCompletions
    case responses
    case anthropicMessages
}

/// Drives any provider that speaks the OpenAI `/chat/completions` shape with
/// function calling — which covers OpenAI, DeepSeek, Groq, Together, OpenRouter,
/// local servers, and more. Adding a provider = one more instance/preset.
struct OpenAICompatibleProvider: LLMProvider {
    let id: String
    let displayName: String
    let models: [String]
    let defaultModel: String
    let baseURL: URL
    var supportsImageInput: Bool = true

    func capabilities(for model: String) -> ModelCapabilities {
        let imageInput = supportsImageInput && Self.modelSupportsImageInput(model, providerID: id)
        let isResponsesReasoningModel = id == "openai"
            || (id == "opencode" && Self.providerModelID(model).lowercased() == "gpt-5.6-luna")
        if imageInput {
            return ModelCapabilities.visionText(
                supportsTools: true,
                supportsForcedToolChoice: isResponsesReasoningModel,
                supportsParallelToolCalls: isResponsesReasoningModel,
                supportsStreamingToolCalls: true,
                supportsReasoningSummary: isResponsesReasoningModel
                    && Self.modelSupportsReasoningSummary(model)
            )
        }
        return ModelCapabilities.textOnly(
            supportsTools: true,
            supportsForcedToolChoice: isResponsesReasoningModel,
            supportsParallelToolCalls: isResponsesReasoningModel,
            supportsStreamingToolCalls: true,
            supportsReasoningSummary: isResponsesReasoningModel
                && Self.modelSupportsReasoningSummary(model)
        )
    }

    func complete(messages: [LLMMessage], tools: [ToolSpec], model: String) async throws -> LLMResponse {
        if let wireAPI = Self.openCodeGoWireAPI(providerID: id, model: model) {
            switch wireAPI {
            case .responses:
                return try await completeResponses(messages: messages, tools: tools, model: model)
            case .anthropicMessages:
                return try await completeAnthropicMessages(messages: messages, tools: tools, model: model)
            case .chatCompletions:
                break
            }
        }

        guard let auth = await ProviderCredentials.resolve(id) else {
            throw LLMError.noKey(displayName)
        }

        var payload: [String: Any] = [
            "model": model,
            "messages": messages.map(Self.encode),
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
        Self.applyChatReasoning(&payload, providerID: id, model: model)
        var lastAuthError: LLMError?
        for endpoint in requestBaseURLs {
            let req = try Self.makeRequest(
                url: endpoint.appendingPathComponent("chat/completions"),
                bearerToken: auth.token,
                payload: payload
            )
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard let http = resp as? HTTPURLResponse else { throw LLMError.http(-1, "no response") }
            guard (200..<300).contains(http.statusCode) else {
                let error = LLMError.http(
                    http.statusCode,
                    String((String(data: data, encoding: .utf8) ?? "").prefix(400))
                )
                if id == "qwen-code" && (http.statusCode == 401 || http.statusCode == 403) {
                    lastAuthError = error
                    continue
                }
                throw error
            }
            return try Self.parse(data)
        }
        throw lastAuthError ?? LLMError.http(401, "Qwen Code key was rejected by all supported Alibaba regions.")
    }

    // MARK: - Streaming (SSE)

    func stream(messages: [LLMMessage], tools: [ToolSpec], model: String,
                onActivity: @escaping (LLMStreamActivity) -> Void,
                onText: @escaping (String) -> Void) async throws -> LLMResponse {
        if let wireAPI = Self.openCodeGoWireAPI(providerID: id, model: model) {
            switch wireAPI {
            case .responses:
                return try await streamResponses(
                    messages: messages,
                    tools: tools,
                    model: model,
                    onActivity: onActivity,
                    onText: onText
                )
            case .anthropicMessages:
                return try await streamAnthropicMessages(
                    messages: messages,
                    tools: tools,
                    model: model,
                    onActivity: onActivity,
                    onText: onText
                )
            case .chatCompletions:
                break
            }
        }

        guard let auth = await ProviderCredentials.resolve(id) else {
            throw LLMError.noKey(displayName)
        }

        var payload: [String: Any] = [
            "model": model,
            "messages": messages.map(Self.encode),
            "stream": true,
        ]
        // Only OpenAI/DeepSeek reliably support usage-in-stream; custom endpoints
        // may reject the option, so don't send it to them.
        if id == "openai" || id == "deepseek" {
            payload["stream_options"] = ["include_usage": true]
        }
        if !tools.isEmpty {
            payload["tools"] = tools.map { spec in
                ["type": "function",
                 "function": ["name": spec.name, "description": spec.description, "parameters": spec.parameters]]
            }
            payload["tool_choice"] = "auto"
        }
        Self.applyChatReasoning(&payload, providerID: id, model: model)
        var lastAuthError: LLMError?
        for endpoint in requestBaseURLs {
            let req = try Self.makeRequest(
                url: endpoint.appendingPathComponent("chat/completions"),
                bearerToken: auth.token,
                payload: payload
            )
            do {
                return try await Self.parseSSE(req, onActivity: onActivity, onText: onText)
            } catch let error as LLMError {
                if id == "qwen-code", case .http(let status, _) = error,
                   status == 401 || status == 403 {
                    lastAuthError = error
                    continue
                }
                throw error
            }
        }
        throw lastAuthError ?? LLMError.http(401, "Qwen Code key was rejected by all supported Alibaba regions.")
    }

    // MARK: - OpenCode Go's mixed wire formats

    /// OpenCode Go is one provider in the UI, but its catalog is backed by
    /// several AI SDK adapters. Dispatching by model keeps the provider picker
    /// simple while still sending each model the request shape its endpoint
    /// expects. This is especially important for GPT 5.6 Luna (`/responses`)
    /// and Qwen/Minimax (`/messages`).
    private static func openCodeGoWireAPI(providerID: String, model: String) -> OpenCodeGoWireAPI? {
        guard providerID == "opencode" else { return nil }
        let modelID = providerModelID(model).lowercased()
        if modelID.hasPrefix("gpt-") {
            return .responses
        }
        if modelID.hasPrefix("qwen") || modelID.hasPrefix("minimax-") {
            return .anthropicMessages
        }
        return .chatCompletions
    }

    private static func providerModelID(_ model: String) -> String {
        let trimmed = model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let slash = trimmed.lastIndex(of: "/") else { return trimmed }
        return String(trimmed[trimmed.index(after: slash)...])
    }

    private func completeResponses(messages: [LLMMessage], tools: [ToolSpec], model: String) async throws -> LLMResponse {
        guard let auth = await ProviderCredentials.resolve(id) else {
            throw LLMError.noKey(displayName)
        }
        let payload = Self.responsesPayload(
            messages: messages,
            tools: tools,
            model: Self.providerModelID(model),
            stream: false
        )
        let request = try Self.makeRequest(
            url: baseURL.appendingPathComponent("responses"),
            bearerToken: auth.token,
            payload: payload
        )
        let data = try await Self.data(for: request)
        return try Self.parseResponses(data)
    }

    private func streamResponses(messages: [LLMMessage], tools: [ToolSpec], model: String,
                                 onActivity: @escaping (LLMStreamActivity) -> Void,
                                 onText: @escaping (String) -> Void) async throws -> LLMResponse {
        guard let auth = await ProviderCredentials.resolve(id) else {
            throw LLMError.noKey(displayName)
        }
        let payload = Self.responsesPayload(
            messages: messages,
            tools: tools,
            model: Self.providerModelID(model),
            stream: true
        )
        let request = try Self.makeRequest(
            url: baseURL.appendingPathComponent("responses"),
            bearerToken: auth.token,
            payload: payload
        )
        return try await Self.parseResponsesSSE(request, onActivity: onActivity, onText: onText)
    }

    private func completeAnthropicMessages(messages: [LLMMessage], tools: [ToolSpec], model: String) async throws -> LLMResponse {
        guard let auth = await ProviderCredentials.resolve(id) else {
            throw LLMError.noKey(displayName)
        }
        let payload = Self.anthropicMessagesPayload(
            messages: messages,
            tools: tools,
            model: Self.providerModelID(model),
            stream: false
        )
        let request = try Self.makeRequest(
            url: baseURL.appendingPathComponent("messages"),
            bearerToken: auth.token,
            payload: payload
        )
        let data = try await Self.data(for: request)
        return try Self.parseAnthropicMessages(data)
    }

    private func streamAnthropicMessages(messages: [LLMMessage], tools: [ToolSpec], model: String,
                                         onActivity: @escaping (LLMStreamActivity) -> Void,
                                         onText: @escaping (String) -> Void) async throws -> LLMResponse {
        guard let auth = await ProviderCredentials.resolve(id) else {
            throw LLMError.noKey(displayName)
        }
        let payload = Self.anthropicMessagesPayload(
            messages: messages,
            tools: tools,
            model: Self.providerModelID(model),
            stream: true
        )
        let request = try Self.makeRequest(
            url: baseURL.appendingPathComponent("messages"),
            bearerToken: auth.token,
            payload: payload
        )
        return try await Self.parseAnthropicMessagesSSE(request, onActivity: onActivity, onText: onText)
    }

    private static func data(for request: URLRequest) async throws -> Data {
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw LLMError.http(-1, "no response")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw LLMError.http(
                http.statusCode,
                String((String(data: data, encoding: .utf8) ?? "").prefix(400))
            )
        }
        return data
    }

    static func responsesPayload(messages: [LLMMessage], tools: [ToolSpec], model: String,
                                 stream: Bool,
                                 effort: ReasoningPreference = .stored) -> [String: Any] {
        var payload: [String: Any] = [
            "model": model,
            "input": encodeResponses(messages),
            "stream": stream,
            // Luna is a reasoning model. These are the same stateless
            // Responses settings used by OpenCode's OpenAI adapter and are
            // required to round-trip encrypted reasoning across tool turns.
            "store": false,
            "include": ["reasoning.encrypted_content"],
            "max_output_tokens": 16_384,
            "reasoning": [
                "effort": ReasoningEffortCatalog.resolved(effort, providerID: "openai", modelID: model).openaiEffort,
                "summary": "auto"
            ],
            "text": ["verbosity": "low"],
            "parallel_tool_calls": true
        ]
        if !tools.isEmpty {
            payload["tools"] = tools.map { spec in
                [
                    "type": "function",
                    "name": spec.name,
                    "description": spec.description,
                    "parameters": spec.parameters
                ]
            }
            payload["tool_choice"] = "auto"
        }
        return payload
    }

    static func encodeResponses(_ messages: [LLMMessage]) -> [[String: Any]] {
        var output: [[String: Any]] = []
        for message in messages {
            switch message.role {
            case "tool":
                output.append([
                    "type": "function_call_output",
                    "call_id": message.toolCallID ?? "",
                    "output": message.content ?? ""
                ])

            case "assistant" where !(message.toolCalls ?? []).isEmpty:
                if let encryptedReasoning = message.thoughtSignature,
                   !encryptedReasoning.isEmpty {
                    output.append([
                        "type": "reasoning",
                        "encrypted_content": encryptedReasoning,
                        "summary": []
                    ])
                }
                if let content = message.content, !content.isEmpty {
                    output.append([
                        "role": "assistant",
                        "content": [["type": "output_text", "text": content]]
                    ])
                }
                for call in message.toolCalls ?? [] {
                    output.append([
                        "type": "function_call",
                        "call_id": call.id,
                        "name": call.name,
                        "arguments": call.argumentsJSON
                    ])
                }

            case "system", "user", "assistant", "developer":
                if message.role == "assistant",
                   let encryptedReasoning = message.thoughtSignature,
                   !encryptedReasoning.isEmpty {
                    output.append([
                        "type": "reasoning",
                        "encrypted_content": encryptedReasoning,
                        "summary": []
                    ])
                }
                let role = message.role == "system" ? "developer" : message.role
                var item: [String: Any] = [
                    "role": role,
                    "content": responseContent(for: message)
                ]
                if let name = message.name, !name.isEmpty { item["name"] = name }
                output.append(item)

            default:
                break
            }
        }
        return output
    }

    private static func responseContent(for message: LLMMessage) -> Any {
        guard let images = message.images, !images.isEmpty else {
            return message.content ?? ""
        }
        var parts: [[String: Any]] = []
        if let text = message.content, !text.isEmpty {
            parts.append(["type": "input_text", "text": text])
        }
        for image in images {
            parts.append([
                "type": "input_image",
                "image_url": "data:\(image.mimeType);base64,\(image.base64)"
            ])
        }
        return parts
    }

    private static func anthropicMessagesPayload(messages: [LLMMessage], tools: [ToolSpec], model: String,
                                                  stream: Bool) -> [String: Any] {
        var systemParts: [String] = []
        var mappedMessages: [[String: Any]] = []

        for message in messages {
            switch message.role {
            case "system", "developer":
                if let content = message.content, !content.isEmpty { systemParts.append(content) }

            case "tool":
                mappedMessages.append([
                    "role": "user",
                    "content": [[
                        "type": "tool_result",
                        "tool_use_id": message.toolCallID ?? "",
                        "content": message.content ?? ""
                    ]]
                ])

            case "assistant":
                var blocks: [[String: Any]] = []
                if let content = message.content, !content.isEmpty {
                    blocks.append(["type": "text", "text": content])
                }
                for call in message.toolCalls ?? [] {
                    blocks.append([
                        "type": "tool_use",
                        "id": call.id,
                        "name": call.name,
                        "input": jsonObject(from: call.argumentsJSON)
                    ])
                }
                if !blocks.isEmpty {
                    mappedMessages.append(["role": "assistant", "content": blocks])
                }

            case "user":
                mappedMessages.append([
                    "role": "user",
                    "content": anthropicContent(for: message)
                ])

            default:
                break
            }
        }

        var payload: [String: Any] = [
            "model": model,
            // OpenCode Go's Anthropic adapter requires max_tokens even though
            // the chat-completions adapter does not expose the same field.
            "max_tokens": 16_384,
            "messages": mappedMessages,
            "stream": stream
        ]
        if !systemParts.isEmpty { payload["system"] = systemParts.joined(separator: "\n\n") }
        if !tools.isEmpty {
            payload["tools"] = tools.map { spec in
                [
                    "name": spec.name,
                    "description": spec.description,
                    "input_schema": spec.parameters
                ]
            }
            payload["tool_choice"] = ["type": "auto"]
        }
        return payload
    }

    private static func anthropicContent(for message: LLMMessage) -> Any {
        guard let images = message.images, !images.isEmpty else {
            return message.content ?? ""
        }
        var blocks: [[String: Any]] = []
        if let text = message.content, !text.isEmpty {
            blocks.append(["type": "text", "text": text])
        }
        for image in images {
            blocks.append([
                "type": "image",
                "source": [
                    "type": "base64",
                    "media_type": image.mimeType,
                    "data": image.base64
                ]
            ])
        }
        return blocks
    }

    private static func jsonObject(from raw: String) -> Any {
        guard let data = raw.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) else {
            return [:]
        }
        return object
    }

    /// Tool arguments are usually a JSON string, but OpenCode's adapters may
    /// return an already-decoded object. Preserve malformed strings for the
    /// existing recovery path instead of silently turning them into `{}`.
    private static func jsonString(from value: Any?) -> String {
        guard let value else { return "{}" }
        if let string = value as? String {
            return string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "{}" : string
        }
        guard JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]),
              let string = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return string
    }

    private static func appendJSONFragment(_ value: Any?, to target: inout String) {
        guard let value else { return }
        if let string = value as? String {
            target += string
        } else {
            target = jsonString(from: value)
        }
    }

    private static func tokenUsage(from raw: [String: Any]?) -> TokenUsage? {
        guard let raw else { return nil }
        let prompt = (raw["prompt_tokens"] as? Int)
            ?? (raw["input_tokens"] as? Int)
            ?? (raw["inputTokens"] as? Int)
        let completion = (raw["completion_tokens"] as? Int)
            ?? (raw["output_tokens"] as? Int)
            ?? (raw["outputTokens"] as? Int)
        guard let prompt, let completion else { return nil }
        return TokenUsage(promptTokens: prompt, completionTokens: completion)
    }

    private static func initialJSONArgument(from value: Any?) -> String {
        guard value != nil else { return "" }
        let normalized = jsonString(from: value)
        return normalized == "{}" ? "" : normalized
    }

    private static func validatedResponse(content: String?, toolCalls: [LLMToolCall], usage: TokenUsage?,
                                          thoughtSignature: String? = nil,
                                          errorType: LLMResponseErrorType? = nil) -> LLMResponse {
        var finalError = errorType
        for call in toolCalls {
            if call.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                finalError = finalError ?? .malformedToolArguments
            }
            if call.argumentsJSON.utf8.count > 1 * 1024 * 1024 {
                finalError = .toolCallIncomplete
                continue
            }
            if (try? JSONSerialization.jsonObject(with: Data(call.argumentsJSON.utf8))) == nil {
                finalError = finalError ?? .malformedToolArguments
            }
        }
        return LLMResponse(
            content: content,
            toolCalls: toolCalls,
            usage: usage,
            thoughtSignature: thoughtSignature,
            errorType: finalError
        )
    }

    // MARK: - Responses API parsing

    static func parseResponses(_ data: Data) throws -> LLMResponse {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw LLMError.decoding("invalid Responses JSON")
        }
        return parseResponsesObject(object)
    }

    private static func parseResponsesObject(_ object: [String: Any]) -> LLMResponse {
        var text = ""
        let fallbackText = object["output_text"] as? String
        var calls: [LLMToolCall] = []
        var encryptedReasoning: String?
        if let output = object["output"] as? [[String: Any]] {
            for item in output {
                let type = item["type"] as? String ?? ""
                if type == "reasoning" {
                    encryptedReasoning = item["encrypted_content"] as? String
                } else if type == "message", let parts = item["content"] as? [[String: Any]] {
                    for part in parts where (part["type"] as? String) == "output_text" {
                        if let value = part["text"] as? String { text += value }
                    }
                } else if type == "function_call" {
                    let id = (item["call_id"] as? String)
                        ?? (item["id"] as? String)
                        ?? UUID().uuidString
                    let name = item["name"] as? String ?? ""
                    calls.append(LLMToolCall(
                        id: id,
                        name: name,
                        argumentsJSON: jsonString(from: item["arguments"])
                    ))
                }
            }
        }
        if text.isEmpty, let fallbackText { text = fallbackText }

        var errorType: LLMResponseErrorType?
        if let details = object["incomplete_details"] as? [String: Any], !details.isEmpty {
            errorType = .outputLimitReached
        } else if (object["status"] as? String) == "incomplete" {
            errorType = .outputLimitReached
        }
        return validatedResponse(
            content: text.isEmpty ? nil : text,
            toolCalls: calls,
            usage: tokenUsage(from: object["usage"] as? [String: Any]),
            thoughtSignature: encryptedReasoning,
            errorType: errorType
        )
    }

    private static func parseResponsesSSE(_ request: URLRequest,
                                          onActivity: @escaping (LLMStreamActivity) -> Void,
                                          onText: @escaping (String) -> Void) async throws -> LLMResponse {
        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        guard let http = response as? HTTPURLResponse else { throw LLMError.http(-1, "no response") }
        guard (200..<300).contains(http.statusCode) else {
            var body = ""
            for try await line in bytes.lines { body += line; if body.count > 800 { break } }
            throw LLMError.http(http.statusCode, String(body.prefix(400)))
        }

        onActivity(.connected)
        var text = ""
        var toolAcc: [Int: (id: String, name: String, args: String)] = [:]
        var usage: TokenUsage?
        var encryptedReasoning: String?
        var errorType: LLMResponseErrorType?

        for try await line in bytes.lines {
            let currentBytes = text.utf8.count + toolAcc.values.reduce(0) { $0 + $1.args.utf8.count }
            if currentBytes > 10 * 1024 * 1024 {
                throw LLMError.decoding("Streaming buffer limit exceeded (10 MB)")
            }
            guard line.hasPrefix("data:") else { continue }
            let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
            if payload == "[DONE]" { break }
            guard let data = payload.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }

            if let rawUsage = object["usage"] as? [String: Any] {
                usage = tokenUsage(from: rawUsage) ?? usage
            }
            if let responseObject = object["response"] as? [String: Any],
               let rawUsage = responseObject["usage"] as? [String: Any] {
                usage = tokenUsage(from: rawUsage) ?? usage
            }

            let type = object["type"] as? String ?? ""
            if type == "error" {
                let error = object["error"] as? [String: Any]
                let message = (error?["message"] as? String) ?? (object["message"] as? String) ?? "Responses stream failed"
                throw LLMError.decoding(message)
            }

            switch type {
            case "response.output_text.delta":
                if let delta = object["delta"] as? String, !delta.isEmpty {
                    text += delta
                    onText(text)
                }

            case "response.reasoning_summary_text.delta",
                 "response.reasoning_summary_part.added",
                 "response.reasoning_text.delta":
                onActivity(.reasoning)

            case "response.output_item.added", "response.output_item.done":
                guard let item = object["item"] as? [String: Any] else { continue }
                let itemType = item["type"] as? String ?? ""
                if itemType == "reasoning" {
                    if let encrypted = item["encrypted_content"] as? String, !encrypted.isEmpty {
                        encryptedReasoning = encrypted
                    }
                } else if itemType == "function_call" {
                    let index = (object["output_index"] as? Int) ?? (item["output_index"] as? Int) ?? toolAcc.count
                    var call = toolAcc[index] ?? (id: "", name: "", args: "")
                    if let id = item["call_id"] as? String, !id.isEmpty { call.id = id }
                    if call.id.isEmpty, let id = item["id"] as? String, !id.isEmpty { call.id = id }
                    if let name = item["name"] as? String, !name.isEmpty { call.name = name }
                    if type == "response.output_item.done", item["arguments"] != nil {
                        call.args = jsonString(from: item["arguments"])
                    }
                    toolAcc[index] = call
                    onActivity(.toolCall)
                } else if itemType == "message", text.isEmpty,
                          let parts = item["content"] as? [[String: Any]] {
                    for part in parts where (part["type"] as? String) == "output_text" {
                        if let value = part["text"] as? String, !value.isEmpty {
                            text += value
                            onText(text)
                        }
                    }
                }

            case "response.function_call_arguments.delta":
                let index = (object["output_index"] as? Int) ?? toolAcc.count
                var call = toolAcc[index] ?? (id: "", name: "", args: "")
                if let id = object["call_id"] as? String, !id.isEmpty { call.id = id }
                if call.id.isEmpty, let id = object["item_id"] as? String, !id.isEmpty { call.id = id }
                if let delta = object["delta"] { appendJSONFragment(delta, to: &call.args) }
                toolAcc[index] = call
                onActivity(.toolCall)

            case "response.function_call_arguments.done":
                let index = (object["output_index"] as? Int) ?? toolAcc.count
                var call = toolAcc[index] ?? (id: "", name: "", args: "")
                if let id = object["call_id"] as? String, !id.isEmpty { call.id = id }
                if call.id.isEmpty, let id = object["item_id"] as? String, !id.isEmpty { call.id = id }
                if let name = object["name"] as? String, !name.isEmpty { call.name = name }
                if object["arguments"] != nil { call.args = jsonString(from: object["arguments"]) }
                toolAcc[index] = call
                onActivity(.toolCall)

            case "response.completed", "response.done":
                let completed = (object["response"] as? [String: Any]) ?? object
                if let rawUsage = completed["usage"] as? [String: Any] {
                    usage = tokenUsage(from: rawUsage) ?? usage
                }
                if let details = completed["incomplete_details"] as? [String: Any], !details.isEmpty {
                    errorType = .outputLimitReached
                }
                if text.isEmpty, let output = completed["output"] as? [[String: Any]] {
                    for item in output where (item["type"] as? String) == "message" {
                        for part in (item["content"] as? [[String: Any]]) ?? []
                        where (part["type"] as? String) == "output_text" {
                            if let value = part["text"] as? String { text += value }
                        }
                    }
                    if !text.isEmpty { onText(text) }
                }
                if let output = completed["output"] as? [[String: Any]] {
                    // Some gateways expose encrypted reasoning only on the
                    // completed response, after function-call events streamed.
                    // Always inspect it so the next tool turn can round-trip
                    // Luna's reasoning state.
                    for item in output where (item["type"] as? String) == "reasoning" {
                        if let encrypted = item["encrypted_content"] as? String,
                           !encrypted.isEmpty {
                            encryptedReasoning = encrypted
                        }
                    }
                    if toolAcc.isEmpty {
                        for (index, item) in output.enumerated()
                        where (item["type"] as? String) == "function_call" {
                            toolAcc[index] = (
                                id: (item["call_id"] as? String) ?? (item["id"] as? String) ?? "",
                                name: item["name"] as? String ?? "",
                                args: jsonString(from: item["arguments"])
                            )
                        }
                    }
                }

            default:
                break
            }
        }

        let calls = toolAcc.sorted { $0.key < $1.key }.map { _, value in
            LLMToolCall(
                id: value.id.isEmpty ? UUID().uuidString : value.id,
                name: value.name,
                argumentsJSON: value.args.isEmpty ? "{}" : value.args
            )
        }
        return validatedResponse(
            content: text.isEmpty ? nil : text,
            toolCalls: calls,
            usage: usage,
            thoughtSignature: encryptedReasoning,
            errorType: errorType
        )
    }

    // MARK: - Anthropic Messages parsing

    static func parseAnthropicMessages(_ data: Data) throws -> LLMResponse {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw LLMError.decoding("invalid Messages JSON")
        }
        var text = ""
        var calls: [LLMToolCall] = []
        for block in (object["content"] as? [[String: Any]]) ?? [] {
            switch block["type"] as? String {
            case "text":
                if let value = block["text"] as? String { text += value }
            case "tool_use":
                calls.append(LLMToolCall(
                    id: (block["id"] as? String) ?? UUID().uuidString,
                    name: block["name"] as? String ?? "",
                    argumentsJSON: jsonString(from: block["input"])
                ))
            default:
                break
            }
        }
        let errorType: LLMResponseErrorType? = (object["stop_reason"] as? String) == "max_tokens"
            ? .outputLimitReached : nil
        return validatedResponse(
            content: text.isEmpty ? nil : text,
            toolCalls: calls,
            usage: tokenUsage(from: object["usage"] as? [String: Any]),
            errorType: errorType
        )
    }

    private static func parseAnthropicMessagesSSE(_ request: URLRequest,
                                                  onActivity: @escaping (LLMStreamActivity) -> Void,
                                                  onText: @escaping (String) -> Void) async throws -> LLMResponse {
        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        guard let http = response as? HTTPURLResponse else { throw LLMError.http(-1, "no response") }
        guard (200..<300).contains(http.statusCode) else {
            var body = ""
            for try await line in bytes.lines { body += line; if body.count > 800 { break } }
            throw LLMError.http(http.statusCode, String(body.prefix(400)))
        }

        onActivity(.connected)
        var eventName: String?
        var text = ""
        var toolAcc: [Int: (id: String, name: String, args: String)] = [:]
        var usage: TokenUsage?
        var errorType: LLMResponseErrorType?

        for try await line in bytes.lines {
            let currentBytes = text.utf8.count + toolAcc.values.reduce(0) { $0 + $1.args.utf8.count }
            if currentBytes > 10 * 1024 * 1024 {
                throw LLMError.decoding("Streaming buffer limit exceeded (10 MB)")
            }
            if line.hasPrefix("event:") {
                eventName = line.dropFirst(6).trimmingCharacters(in: .whitespaces)
                continue
            }
            guard line.hasPrefix("data:") else { continue }
            let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
            if payload == "[DONE]" { break }
            guard let data = payload.data(using: .utf8),
                  var object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
            if object["type"] == nil, let eventName { object["type"] = eventName }
            eventName = nil

            if (object["type"] as? String) == "error" {
                let error = object["error"] as? [String: Any]
                throw LLMError.decoding((error?["message"] as? String) ?? "Messages stream failed")
            }

            switch object["type"] as? String {
            case "message_start":
                if let message = object["message"] as? [String: Any],
                   let rawUsage = message["usage"] as? [String: Any] {
                    usage = tokenUsage(from: rawUsage) ?? usage
                }

            case "content_block_start":
                let index = object["index"] as? Int ?? toolAcc.count
                guard let block = object["content_block"] as? [String: Any] else { continue }
                switch block["type"] as? String {
                case "tool_use":
                    toolAcc[index] = (
                        id: block["id"] as? String ?? "",
                        name: block["name"] as? String ?? "",
                        args: initialJSONArgument(from: block["input"])
                    )
                    onActivity(.toolCall)
                case "thinking", "redacted_thinking":
                    onActivity(.reasoning)
                default:
                    break
                }

            case "content_block_delta":
                let delta = object["delta"] as? [String: Any] ?? [:]
                switch delta["type"] as? String {
                case "text_delta":
                    if let value = delta["text"] as? String, !value.isEmpty {
                        text += value
                        onText(text)
                    }
                case "input_json_delta":
                    let index = object["index"] as? Int ?? toolAcc.count
                    var call = toolAcc[index] ?? (id: "", name: "", args: "")
                    appendJSONFragment(delta["partial_json"], to: &call.args)
                    toolAcc[index] = call
                    onActivity(.toolCall)
                case "thinking_delta", "signature_delta":
                    onActivity(.reasoning)
                default:
                    break
                }

            case "message_delta":
                if let rawUsage = object["usage"] as? [String: Any] {
                    usage = tokenUsage(from: rawUsage) ?? usage
                }
                if let delta = object["delta"] as? [String: Any],
                   (delta["stop_reason"] as? String) == "max_tokens" {
                    errorType = .outputLimitReached
                }

            default:
                break
            }
        }

        let calls = toolAcc.sorted { $0.key < $1.key }.map { _, value in
            LLMToolCall(
                id: value.id.isEmpty ? UUID().uuidString : value.id,
                name: value.name,
                argumentsJSON: value.args.isEmpty ? "{}" : value.args
            )
        }
        return validatedResponse(content: text.isEmpty ? nil : text, toolCalls: calls, usage: usage, errorType: errorType)
    }

    /// Builds a POST `URLRequest` for an OpenAI-shaped `/chat/completions` call.
    /// Shared by every OpenAI-compatible preset and by CopilotProvider (which
    /// passes Copilot's endpoint, bearer, and editor-identity headers) so the
    /// auth/content-type/body assembly can't drift between them.
    static func makeRequest(url: URL, bearerToken: String, payload: [String: Any],
                            extraHeaders: [String: String] = [:]) throws -> URLRequest {
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = LLMTransportPolicy.requestTimeoutSeconds
        req.setValue("Bearer \(bearerToken)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        for (field, value) in extraHeaders {
            req.setValue(value, forHTTPHeaderField: field)
        }
        req.httpBody = try JSONSerialization.data(withJSONObject: payload)
        return req
    }

    /// Parses an OpenAI-style `chat/completions` SSE stream. Shared by the
    /// OpenAI/DeepSeek/custom providers and (via its own request) Copilot.
    static func parseSSE(_ request: URLRequest,
                         onActivity: @escaping (LLMStreamActivity) -> Void,
                         onText: @escaping (String) -> Void) async throws -> LLMResponse {
        let (bytes, resp) = try await URLSession.shared.bytes(for: request)
        guard let http = resp as? HTTPURLResponse else { throw LLMError.http(-1, "no response") }
        guard (200..<300).contains(http.statusCode) else {
            var body = ""
            for try await line in bytes.lines { body += line; if body.count > 800 { break } }
            throw LLMError.http(http.statusCode, String(body.prefix(400)))
        }
        onActivity(.connected)

        var text = ""
        var toolAcc: [Int: (id: String, name: String, args: String)] = [:]
        var usage: TokenUsage?
        var isLimitReached = false

        for try await line in bytes.lines {
            // Cap accumulated streaming buffer size (10 MB)
            let currentBytes = text.utf8.count + toolAcc.values.reduce(0, { $0 + $1.args.utf8.count })
            if currentBytes > 10 * 1024 * 1024 {
                throw LLMError.decoding("Streaming buffer limit exceeded (10 MB)")
            }

            guard line.hasPrefix("data:") else { continue }
            let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
            if payload == "[DONE]" { break }
            guard let data = payload.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }

            if let u = obj["usage"] as? [String: Any] {
                usage = Self.tokenUsage(from: u) ?? usage
            }
            guard let choice = (obj["choices"] as? [[String: Any]])?.first else { continue }
            
            if let fr = choice["finish_reason"] as? String, fr == "length" {
                isLimitReached = true
            }
            
            guard let delta = choice["delta"] as? [String: Any] else { continue }

            if Self.containsReasoningProgress(delta) {
                onActivity(.reasoning)
            }

            if let chunk = delta["content"] as? String, !chunk.isEmpty {
                text += chunk
                onText(text)
            }
            if let calls = delta["tool_calls"] as? [[String: Any]] {
                if !calls.isEmpty { onActivity(.toolCall) }
                for call in calls {
                    let idx = call["index"] as? Int ?? 0
                    var acc = toolAcc[idx] ?? (id: "", name: "", args: "")
                    if let cid = call["id"] as? String, !cid.isEmpty { acc.id = cid }
                    if let fn = call["function"] as? [String: Any] {
                        if let n = fn["name"] as? String, !n.isEmpty { acc.name = n }
                        Self.appendJSONFragment(fn["arguments"], to: &acc.args)
                    }
                    toolAcc[idx] = acc
                }
            }
            if let functionCall = delta["function_call"] as? [String: Any] {
                var acc = toolAcc[0] ?? (id: "", name: "", args: "")
                if let n = functionCall["name"] as? String, !n.isEmpty { acc.name = n }
                Self.appendJSONFragment(functionCall["arguments"], to: &acc.args)
                toolAcc[0] = acc
                onActivity(.toolCall)
            }
        }

        var errorType: LLMResponseErrorType? = nil
        if isLimitReached {
            errorType = .outputLimitReached
        }

        let toolCalls = toolAcc.sorted { $0.key < $1.key }.map { _, v in
            LLMToolCall(id: v.id.isEmpty ? UUID().uuidString : v.id,
                        name: v.name,
                        argumentsJSON: v.args.isEmpty ? "{}" : v.args)
        }
        
        for call in toolCalls {
            if call.argumentsJSON.utf8.count > 1 * 1024 * 1024 { errorType = .toolCallIncomplete }
        }

        return Self.validatedResponse(
            content: text.isEmpty ? nil : text,
            toolCalls: toolCalls,
            usage: usage,
            errorType: errorType
        )
    }

    /// OpenAI-compatible gateways use several keys for hidden reasoning. Treat
    /// all known shapes as progress, but never append their contents to chat.
    static func containsReasoningProgress(_ delta: [String: Any]) -> Bool {
        for key in ["reasoning_content", "reasoning", "thinking"] {
            if let value = delta[key] as? String, !value.isEmpty { return true }
        }
        if let details = delta["reasoning_details"] as? [Any], !details.isEmpty { return true }
        return false
    }

    // MARK: - Encoding (shared with CopilotProvider, which is also OpenAI-shaped)

    static func encode(_ m: LLMMessage) -> [String: Any] {
        var dict: [String: Any] = ["role": m.role]
        if let images = m.images, !images.isEmpty {
            // Multimodal content: an array of text + image_url parts.
            var parts: [[String: Any]] = []
            if let t = m.content, !t.isEmpty { parts.append(["type": "text", "text": t]) }
            for img in images {
                parts.append(["type": "image_url",
                              "image_url": ["url": "data:\(img.mimeType);base64,\(img.base64)"]])
            }
            dict["content"] = parts
        } else {
            dict["content"] = m.content ?? NSNull()
        }
        if let name = m.name { dict["name"] = name }
        if let id = m.toolCallID { dict["tool_call_id"] = id }
        if let calls = m.toolCalls {
            dict["tool_calls"] = calls.map { c in
                ["id": c.id, "type": "function",
                 "function": ["name": c.name, "arguments": c.argumentsJSON]]
            }
        }
        return dict
    }

    // MARK: - Model listing

    /// Fetches the live model catalog from the OpenAI-compatible `/models` endpoint
    /// (OpenAI, DeepSeek, Grok, Mistral, Gemini, and most custom servers support it).
    /// Returns nil on any failure so the caller falls back to the static list.
    func fetchAvailableModels() async throws -> [String]? {
        guard let auth = await ProviderCredentials.resolve(id) else { return nil }
        for endpoint in requestBaseURLs {
            let modelsURL = id == "longcat"
                ? SiteAgentURL.constant("https://api.longcat.chat/v1/models")
                : endpoint.appendingPathComponent("models")
            var req = URLRequest(url: modelsURL)
            req.setValue("Bearer \(auth.token)", forHTTPHeaderField: "Authorization")

            let (data, resp) = try await URLSession.shared.data(for: req)
            guard let http = resp as? HTTPURLResponse else { continue }
            if id == "qwen-code" && (http.statusCode == 401 || http.statusCode == 403) {
                continue
            }
            guard (200..<300).contains(http.statusCode),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let rows = obj["data"] as? [[String: Any]] else { return nil }

            let ids = rows.compactMap { $0["id"] as? String }
                .map { $0.hasPrefix("models/") ? String($0.dropFirst("models/".count)) : $0 }
                .filter(Self.looksLikeChatModel)
            let unique = Array(Set(ids)).sorted(by: >)
            return unique.isEmpty ? nil : unique
        }
        return nil
    }

    /// Alibaba keys are region- and plan-bound. Try the Southeast Asia Token
    /// Plan endpoint first, then Coding Plan and standard ModelStudio routes.
    private var requestBaseURLs: [URL] {
        guard id == "qwen-code" else { return [baseURL] }
        return [
            SiteAgentURL.constant("https://token-plan.ap-southeast-1.maas.aliyuncs.com/compatible-mode/v1"),
            baseURL,
            SiteAgentURL.constant("https://coding.dashscope.aliyuncs.com/v1"),
            SiteAgentURL.constant("https://dashscope-intl.aliyuncs.com/compatible-mode/v1"),
            SiteAgentURL.constant("https://dashscope.aliyuncs.com/compatible-mode/v1")
        ]
    }

    /// Chat Completions reasoning controls. Responses API uses `reasoning.effort`
    /// instead; this covers OpenAI GPT-5, o-series, Grok, and DeepSeek V4.
    static func applyChatReasoning(_ payload: inout [String: Any], providerID: String, model: String) {
        let effort = ReasoningEffortCatalog.resolved(.stored, providerID: providerID, modelID: model)
        let lower = model.lowercased()
        if ReasoningEffortCatalog.isOpenAIFullScale(provider: providerID, model: model)
            || lower.hasPrefix("o1") || lower.hasPrefix("o3") || lower.hasPrefix("o4") {
            payload["reasoning_effort"] = effort.openaiEffort
            return
        }
        if lower.contains("grok") {
            payload["reasoning_effort"] = effort.canonical == .high || effort.canonical == .xhigh || effort.canonical == .max
                ? "high" : "low"
            return
        }
        if lower.contains("deepseek"), lower.contains("v4") || lower.contains("reasoner") {
            if effort.canonical != .automatic, effort.canonical != .none {
                payload["thinking"] = ["type": "enabled"]
            }
        }
    }

    /// Keeps text/vision chat models, drops the non-conversational entries every
    /// provider mixes into `/models` (embeddings, image/audio/video, moderation).
    static func looksLikeChatModel(_ id: String) -> Bool {
        let lower = id.lowercased()
        let drop = ["embedding", "embed", "imagen", "image", "tts", "audio",
                    "veo", "aqa", "rerank", "moderation", "whisper", "dall-e",
                    "transcribe", "speech"]
        return !drop.contains { lower.contains($0) }
    }

    static func modelSupportsImageInput(_ model: String, providerID: String) -> Bool {
        let lower = model.lowercased()
        if providerID == "openai" || providerID == "grok" {
            return true
        }
        if providerID == "openrouter" || providerID == "openrouter-free" {
            let visionMarkers = [
                "gpt-4o", "gpt-4.1", "gpt-5", "o3", "o4",
                "claude", "gemini", "grok-4", "vision", "llava", "pixtral"
            ]
            return visionMarkers.contains { lower.contains($0) }
        }
        if providerID == "custom" {
            let textOnlyMarkers = ["embedding", "embed", "rerank", "whisper", "tts", "audio"]
            return !textOnlyMarkers.contains { lower.contains($0) }
        }
        return true
    }

    static func modelSupportsReasoningSummary(_ model: String) -> Bool {
        let lower = model.lowercased()
        return lower.hasPrefix("gpt-5") || lower.hasPrefix("o")
    }

    // MARK: - Parsing

    static func parse(_ data: Data) throws -> LLMResponse {
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = obj["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any] else {
            throw LLMError.decoding("missing choices/message")
        }
        let content = message["content"] as? String
        var calls: [LLMToolCall] = []
        if let rawCalls = message["tool_calls"] as? [[String: Any]] {
            for rc in rawCalls {
                guard let fn = rc["function"] as? [String: Any],
                      let name = fn["name"] as? String else { continue }
                let id = (rc["id"] as? String) ?? UUID().uuidString
                let args = jsonString(from: fn["arguments"])
                calls.append(LLMToolCall(id: id, name: name, argumentsJSON: args))
            }
        }

        let usage = tokenUsage(from: obj["usage"] as? [String: Any])

        var errorType: LLMResponseErrorType? = nil
        if (choices.first?["finish_reason"] as? String) == "length" {
            errorType = .outputLimitReached
        }

        return validatedResponse(content: content, toolCalls: calls, usage: usage, errorType: errorType)
    }
}

// MARK: - Built-in presets

extension OpenAICompatibleProvider {
    static let deepseek = OpenAICompatibleProvider(
        id: "deepseek",
        displayName: "DeepSeek",
        // `deepseek-chat`/`deepseek-reasoner` are deprecated (hard-removed
        // 2026-07-24) and were aliases for V4-Flash's non-thinking/thinking modes.
        models: ["deepseek-v4-flash", "deepseek-v4-pro"],
        defaultModel: "deepseek-v4-flash",
        baseURL: SiteAgentURL.constant("https://api.deepseek.com/v1"),
        supportsImageInput: false)   // DeepSeek chat models are text-only

    static let openAI = OpenAICompatibleProvider(
        id: "openai",
        displayName: "OpenAI",
        // gpt-4o / o1-mini / o3-mini are superseded by the GPT-5 line.
        models: ["gpt-5.5", "gpt-5.4", "o4-mini", "gpt-4.1-nano"],
        defaultModel: "gpt-5.4",
        baseURL: SiteAgentURL.constant("https://api.openai.com/v1"),
        supportsImageInput: true)

    static let grok = OpenAICompatibleProvider(
        id: "grok",
        displayName: "Grok (xAI)",
        models: ["grok-4.5", "grok-4.5-latest", "grok-4", "grok-3-mini"],
        defaultModel: "grok-4.5",
        baseURL: SiteAgentURL.constant("https://api.x.ai/v1"),
        supportsImageInput: true)

    static let mistral = OpenAICompatibleProvider(
        id: "mistral",
        displayName: "Mistral",
        models: ["mistral-large-latest", "mistral-small-latest"],
        defaultModel: "mistral-large-latest",
        baseURL: SiteAgentURL.constant("https://api.mistral.ai/v1"),
        supportsImageInput: false)

    static let opencode = OpenAICompatibleProvider(
        id: "opencode",
        displayName: "OpenCode Go",
        models: [
            "minimax-m3", "minimax-m2.7", "minimax-m2.5",
            "kimi-k3", "kimi-k2.7-code", "kimi-k2.6", "kimi-k2.5",
            "glm-5.2", "glm-5.1", "glm-5",
            "deepseek-v4-pro", "deepseek-v4-flash",
            "qwen3.8-max", "qwen3.7-max", "qwen3.7-plus", "qwen3.6-plus", "qwen3.5-plus",
            "mimo-v2-pro", "mimo-v2-omni", "mimo-v2.5-pro", "mimo-v2.5",
            "hy3", "hy3-preview", "gpt-5.6-luna", "grok-4.5"
        ],
        defaultModel: "gpt-5.6-luna",
        baseURL: SiteAgentURL.constant("https://opencode.ai/zen/go/v1"),
        supportsImageInput: false)

    static let openRouter = OpenAICompatibleProvider(
        id: "openrouter",
        displayName: "OpenRouter",
        models: ["openai/gpt-4o-mini", "openai/gpt-4o", "anthropic/claude-sonnet-4", "google/gemini-2.5-flash"],
        defaultModel: "openai/gpt-4o-mini",
        baseURL: SiteAgentURL.constant("https://openrouter.ai/api/v1"),
        supportsImageInput: true)

    /// OpenRouter's no-cost router. Kept separate from the paid OpenRouter
    /// catalog so SiteAgent's free tier cannot select billable models.
    static let openRouterFree = OpenAICompatibleProvider(
        id: "openrouter-free",
        displayName: "OpenRouter Free",
        models: ["openrouter/free"],
        defaultModel: "openrouter/free",
        baseURL: SiteAgentURL.constant("https://openrouter.ai/api/v1"),
        supportsImageInput: true)

    static let groq = OpenAICompatibleProvider(
        id: "groq",
        displayName: "Groq",
        models: ["llama-3.3-70b-versatile", "llama-3.1-8b-instant", "mixtral-8x7b-32768"],
        defaultModel: "llama-3.3-70b-versatile",
        baseURL: SiteAgentURL.constant("https://api.groq.com/openai/v1"),
        supportsImageInput: false)

    /// Alibaba Cloud Coding Plan (international). Coding Plan keys use this
    /// dedicated endpoint and are not interchangeable with standard DashScope keys.
    static let qwenCode = OpenAICompatibleProvider(
        id: "qwen-code",
        displayName: "Qwen Code",
        models: [
            "qwen3.8-max-preview",
            "qwen3-coder-plus",
            "qwen3-coder-next",
            "qwen3.7-plus",
            "qwen3.6-plus",
            "qwen3.5-plus"
        ],
        defaultModel: "qwen3-coder-plus",
        baseURL: SiteAgentURL.constant("https://coding-intl.dashscope.aliyuncs.com/v1"),
        supportsImageInput: false)

    /// Kimi Code membership API. These keys are issued by the Kimi Code Console,
    /// not the separate pay-as-you-go Kimi Platform console.
    static let kimiCode = OpenAICompatibleProvider(
        id: "kimi-code",
        displayName: "Kimi Code",
        models: ["k3", "kimi-for-coding", "kimi-for-coding-highspeed"],
        defaultModel: "kimi-for-coding",
        baseURL: SiteAgentURL.constant("https://api.kimi.com/coding/v1"),
        supportsImageInput: false)

    /// LongCat's OpenAI-compatible API. The current LongCat-2.0 endpoint is
    /// text-only and supports streaming responses.
    static let longCat = OpenAICompatibleProvider(
        id: "longcat",
        displayName: "LongCat",
        models: ["LongCat-2.0"],
        defaultModel: "LongCat-2.0",
        baseURL: SiteAgentURL.constant("https://api.longcat.chat/openai/v1"),
        supportsImageInput: false)

    /// User-defined provider — base URL & model entered in Settings ("ext all").
    static func custom(baseURL: URL, model: String) -> OpenAICompatibleProvider {
        OpenAICompatibleProvider(
            id: "custom",
            displayName: "Custom",
            models: [model],
            defaultModel: model,
            baseURL: baseURL)
    }
}
