import Foundation

/// Integrates natively with the Google Gemini REST API.
/// This provider correctly supports thought signatures required by newer Gemini models.
struct GeminiProvider: LLMProvider {
    let id: String = "gemini"
    let displayName: String = "Gemini (Google)"
    let models: [String] = [
        "gemini-3.5-flash",
        "gemini-3.1-pro-preview",
        "gemini-2.5-pro",
        "gemini-2.5-flash"
    ]
    let defaultModel: String = "gemini-3.5-flash"

    func capabilities(for model: String) -> ModelCapabilities {
        ModelCapabilities.visionText(
            supportsTools: true,
            supportsStreamingToolCalls: false
        )
    }

    func complete(messages: [LLMMessage], tools: [ToolSpec], model: String) async throws -> LLMResponse {
        guard let auth = await ProviderCredentials.resolve(id) else {
            throw LLMError.noKey(displayName)
        }
        
        let urlString = "https://generativelanguage.googleapis.com/v1beta/models/\(model):generateContent"
        guard let url = URL(string: urlString) else {
            throw LLMError.decoding("Invalid URL")
        }
        
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = LLMTransportPolicy.requestTimeoutSeconds
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(auth.token, forHTTPHeaderField: "x-goog-api-key")
        
        let (systemInst, contents) = mapMessages(messages)
        var payload: [String: Any] = ["contents": contents]
        if let systemInst = systemInst {
            payload["systemInstruction"] = systemInst
        }
        if !tools.isEmpty {
            payload["tools"] = [
                ["functionDeclarations": tools.map { convertToolSpec($0) }]
            ]
        }
        
        req.httpBody = try JSONSerialization.data(withJSONObject: payload)
        
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse else { throw LLMError.http(-1, "no response") }
        guard (200..<300).contains(http.statusCode) else {
            throw LLMError.http(http.statusCode, String((String(data: data, encoding: .utf8) ?? "").prefix(400)))
        }
        
        return try parseResponse(data)
    }

    func stream(messages: [LLMMessage], tools: [ToolSpec], model: String,
                onActivity: @escaping (LLMStreamActivity) -> Void,
                onText: @escaping (String) -> Void) async throws -> LLMResponse {
        guard let auth = await ProviderCredentials.resolve(id) else {
            throw LLMError.noKey(displayName)
        }
        
        let urlString = "https://generativelanguage.googleapis.com/v1beta/models/\(model):streamGenerateContent?alt=sse"
        guard let url = URL(string: urlString) else {
            throw LLMError.decoding("Invalid URL")
        }
        
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = LLMTransportPolicy.requestTimeoutSeconds
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(auth.token, forHTTPHeaderField: "x-goog-api-key")
        
        let (systemInst, contents) = mapMessages(messages)
        var payload: [String: Any] = ["contents": contents]
        if let systemInst = systemInst {
            payload["systemInstruction"] = systemInst
        }
        if !tools.isEmpty {
            payload["tools"] = [
                ["functionDeclarations": tools.map { convertToolSpec($0) }]
            ]
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
        
        var textContent = ""
        var toolCalls: [LLMToolCall] = []
        var detectedThoughtSignature: String? = nil
        var usage: TokenUsage? = nil
        
        for try await line in bytes.lines {
            // Cap accumulated streaming buffer size (10 MB) — parity with OpenAI/Anthropic.
            let toolBytes = toolCalls.reduce(0) { $0 + $1.argumentsJSON.utf8.count }
            if textContent.utf8.count + toolBytes > 10 * 1024 * 1024 {
                throw LLMError.decoding("Streaming buffer limit exceeded (10 MB)")
            }

            guard line.hasPrefix("data:") else { continue }
            let payloadStr = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
            if payloadStr == "[DONE]" { break }
            guard let data = payloadStr.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
            
            if let candidates = obj["candidates"] as? [[String: Any]],
               let firstCandidate = candidates.first {
                let contentObj = firstCandidate["content"] as? [String: Any]
                let parts = contentObj?["parts"] as? [[String: Any]] ?? []
                
                for part in parts {
                    let isThought = part["thought"] as? Bool == true
                    if isThought, let thought = part["text"] as? String, !thought.isEmpty {
                        onActivity(.reasoning)
                    }
                    if !isThought, let text = part["text"] as? String {
                        textContent += text
                        onText(textContent)
                    }
                    let signature = Self.thoughtSignature(in: part)
                    
                    if let fnCall = part["functionCall"] as? [String: Any],
                       let name = fnCall["name"] as? String {
                        onActivity(.toolCall)
                        let args = fnCall["args"] as? [String: Any] ?? [:]
                        let argsJSON: String
                        if let argsData = try? JSONSerialization.data(withJSONObject: args),
                           let str = String(data: argsData, encoding: .utf8) {
                            argsJSON = str
                        } else {
                            argsJSON = "{}"
                        }
                        toolCalls.append(LLMToolCall(
                            id: fnCall["id"] as? String ?? UUID().uuidString,
                            name: name,
                            argumentsJSON: argsJSON,
                            thoughtSignature: signature
                        ))
                    } else if !isThought, signature != nil {
                        detectedThoughtSignature = signature
                    }
                }
            }
            
            if let rawUsage = obj["usageMetadata"] as? [String: Any],
               let prompt = rawUsage["promptTokenCount"] as? Int,
               let completion = rawUsage["candidatesTokenCount"] as? Int {
                usage = TokenUsage(promptTokens: prompt, completionTokens: completion)
            }
        }
        
        return LLMResponse(
            content: textContent.isEmpty ? nil : textContent,
            toolCalls: toolCalls,
            usage: usage,
            thoughtSignature: detectedThoughtSignature
        )
    }

    func fetchAvailableModels() async throws -> [String]? {
        guard let auth = await ProviderCredentials.resolve(id) else { return nil }
        
        let urlString = "https://generativelanguage.googleapis.com/v1beta/models"
        guard let url = URL(string: urlString) else { return nil }
        
        var req = URLRequest(url: url)
        req.setValue(auth.token, forHTTPHeaderField: "x-goog-api-key")
        
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rows = obj["models"] as? [[String: Any]] else { return nil }
              
        let ids = rows
            .filter { row in
                let methods = row["supportedGenerationMethods"] as? [String] ?? []
                return methods.contains("generateContent")
            }
            .compactMap { $0["name"] as? String }
            .map { $0.hasPrefix("models/") ? String($0.dropFirst("models/".count)) : $0 }
            .filter { looksLikeChatModel($0) }
            
        let unique = Array(Set(ids)).sorted(by: >)
        return unique.isEmpty ? nil : unique
    }

    // MARK: - Private Mappers

    private func looksLikeChatModel(_ id: String) -> Bool {
        let lower = id.lowercased()
        let drop = ["embedding", "embed", "imagen", "image", "tts", "audio",
                    "veo", "aqa", "rerank", "moderation", "whisper", "dall-e",
                    "transcribe", "speech", "live", "robotics", "computer-use",
                    "deep-research"]
        return lower.contains("gemini") && !drop.contains { lower.contains($0) }
    }

    func mapMessages(_ messages: [LLMMessage]) -> (systemInstruction: [String: Any]?, contents: [[String: Any]]) {
        var systemText = ""
        var contents: [[String: Any]] = []

        for msg in messages {
            if msg.role == "system" {
                if let content = msg.content, !content.isEmpty {
                    if !systemText.isEmpty { systemText += "\n" }
                    systemText += content
                }
                continue
            }

            var parts: [[String: Any]] = []

            if msg.role == "user" {
                if let content = msg.content, !content.isEmpty {
                    parts.append(["text": content])
                }
                if let images = msg.images {
                    for img in images {
                        parts.append([
                            "inlineData": [
                                "mimeType": img.mimeType,
                                "data": img.base64
                            ]
                        ])
                    }
                }
                contents.append([
                    "role": "user",
                    "parts": parts
                ])
            } else if msg.role == "assistant" {
                if let content = msg.content, !content.isEmpty {
                    var part: [String: Any] = ["text": content]
                    if let sig = msg.thoughtSignature, !sig.isEmpty {
                        part["thoughtSignature"] = sig
                    }
                    parts.append(part)
                }
                if let toolCalls = msg.toolCalls {
                    for call in toolCalls {
                        var fnCall: [String: Any] = [
                            "name": call.name,
                            "args": (try? JSONSerialization.jsonObject(with: Data(call.argumentsJSON.utf8))) as? [String: Any] ?? [:]
                        ]
                        if !call.id.isEmpty {
                            fnCall["id"] = call.id
                        }
                        var part: [String: Any] = ["functionCall": fnCall]
                        if let sig = call.thoughtSignature, !sig.isEmpty {
                            part["thoughtSignature"] = sig
                        }
                        parts.append(part)
                    }
                }
                contents.append([
                    "role": "model",
                    "parts": parts
                ])
            } else if msg.role == "tool" {
                let responseDict = (try? JSONSerialization.jsonObject(with: Data((msg.content ?? "").utf8))) as? [String: Any]
                let wrappedResponse = responseDict ?? ["result": msg.content ?? ""]
                
                var functionResponse: [String: Any] = [
                    "name": msg.name ?? "",
                    "response": wrappedResponse
                ]
                if let callID = msg.toolCallID, !callID.isEmpty {
                    functionResponse["id"] = callID
                }
                parts.append(["functionResponse": functionResponse])

                // Gemini accepts only user/model roles. Parallel tool results also
                // belong in one user content block, not consecutive pseudo-roles.
                if let last = contents.indices.last,
                   contents[last]["role"] as? String == "user",
                   var existing = contents[last]["parts"] as? [[String: Any]],
                   existing.allSatisfy({ $0["functionResponse"] != nil }) {
                    existing.append(contentsOf: parts)
                    contents[last]["parts"] = existing
                } else {
                    contents.append(["role": "user", "parts": parts])
                }
            }
        }

        var systemInstruction: [String: Any]? = nil
        if !systemText.isEmpty {
            systemInstruction = [
                "parts": [
                    ["text": systemText]
                ]
            ]
        }

        return (systemInstruction, contents)
    }

    private func convertToolSpec(_ spec: ToolSpec) -> [String: Any] {
        var dict: [String: Any] = [
            "name": spec.name,
            "description": spec.description
        ]
        // Gemini's REST API accepts standard lowercase JSON Schema types, which
        // is already the format used by ToolSpec and the official REST examples.
        dict["parameters"] = spec.parameters
        return dict
    }

    private func parseResponse(_ data: Data) throws -> LLMResponse {
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw LLMError.decoding("Could not parse JSON response")
        }
        return try parseCandidate(obj)
    }

    func parseCandidate(_ obj: [String: Any]) throws -> LLMResponse {
        guard let candidates = obj["candidates"] as? [[String: Any]],
              let firstCandidate = candidates.first else {
            throw LLMError.decoding("missing candidates")
        }
        
        let contentObj = firstCandidate["content"] as? [String: Any]
        let parts = contentObj?["parts"] as? [[String: Any]] ?? []
        
        var textContent = ""
        var toolCalls: [LLMToolCall] = []
        var detectedThoughtSignature: String? = nil
        
        for part in parts {
            let isThought = part["thought"] as? Bool == true
            if !isThought, let text = part["text"] as? String {
                textContent += text
            }
            let signature = Self.thoughtSignature(in: part)
            
            if let fnCall = part["functionCall"] as? [String: Any],
               let name = fnCall["name"] as? String {
                let args = fnCall["args"] as? [String: Any] ?? [:]
                let argsJSON: String
                if let argsData = try? JSONSerialization.data(withJSONObject: args),
                   let str = String(data: argsData, encoding: .utf8) {
                    argsJSON = str
                } else {
                    argsJSON = "{}"
                }
                toolCalls.append(LLMToolCall(
                    id: fnCall["id"] as? String ?? UUID().uuidString,
                    name: name,
                    argumentsJSON: argsJSON,
                    thoughtSignature: signature
                ))
            } else if !isThought, signature != nil {
                detectedThoughtSignature = signature
            }
        }
        
        var usage: TokenUsage? = nil
        if let rawUsage = obj["usageMetadata"] as? [String: Any],
           let prompt = rawUsage["promptTokenCount"] as? Int,
           let completion = rawUsage["candidatesTokenCount"] as? Int {
            usage = TokenUsage(promptTokens: prompt, completionTokens: completion)
        }

        var errorType: LLMResponseErrorType? = nil
        if (firstCandidate["finishReason"] as? String) == "MAX_TOKENS" {
            errorType = .outputLimitReached
        }

        return LLMResponse(
            content: textContent.isEmpty ? nil : textContent,
            toolCalls: toolCalls,
            usage: usage,
            thoughtSignature: detectedThoughtSignature,
            errorType: errorType
        )
    }

    private static func thoughtSignature(in part: [String: Any]) -> String? {
        (part["thoughtSignature"] as? String) ?? (part["thought_signature"] as? String)
    }
}
