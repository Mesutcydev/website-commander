import Foundation

/// On-device provider. Runs a local MLX model and adapts it to Website Commander's
/// `LLMProvider` contract. Two impedance mismatches are handled here:
///
///  • Website Commander uses *structured* tool calls; local models don't, so we inject
///    a tool-format spec into the system prompt and parse fenced ```tool```
///    blocks back out of the output (the approach proven in the reference app).
///  • Website Commander's protocol is non-streaming; the engine accumulates the full
///    generation and we return it as one `LLMResponse`, exactly like the
///    remote providers do per tool round.
struct OnDeviceProvider: LLMProvider {
    let id = "ondevice"
    let displayName = "On-Device (Private)"
    var models: [String] { OnDeviceModelCatalog.all.map(\.id) }
    let defaultModel = OnDeviceModelCatalog.defaultModelID

    func capabilities(for model: String) -> ModelCapabilities {
        ModelCapabilities.textOnly(
            supportsTools: true,
            supportsStreamingToolCalls: false
        )
    }

    func complete(messages: [LLMMessage], tools: [ToolSpec], model: String) async throws -> LLMResponse {
        guard OnDeviceCapability.isCapable else { throw OnDeviceError.notCapable }

        // Gate + resolve the model on the main actor (touches @MainActor state).
        let resolved: OnDeviceModel = try await MainActor.run {
            guard IAPManager.shared.canUseOnDevice else { throw OnDeviceError.locked }
            let requested = OnDeviceModelCatalog.model(id: model) ?? OnDeviceModelCatalog.defaultModel
            guard OnDeviceModelManager.shared.isDownloaded(requested) else {
                throw OnDeviceError.notDownloaded(requested.displayName)
            }
            return requested
        }

        let runtimePolicy = await MainActor.run {
            OnDeviceRuntimeMonitor.shared.currentPolicy(
                requestedMaxTokens: OnDeviceRuntimePolicy.standardMaxCompletionTokens
            )
        }
        guard runtimePolicy.allowsGeneration else { throw OnDeviceError.thermalCritical }

        // Load from disk if needed (no network — the picker handles downloads),
        // then generate a full completion.
        let generationModel: OnDeviceModel
        do {
            try await MLXTextEngine.ensureLoaded(resolved)
            generationModel = resolved
        } catch {
            let stable = OnDeviceModelCatalog.stableFallbackModel
            let isFallbackDownloaded = await MainActor.run {
                OnDeviceModelManager.shared.isDownloaded(stable)
            }
            let canFallback = stable.id != resolved.id && isFallbackDownloaded
            guard canFallback else { throw error }
            try await MLXTextEngine.ensureLoaded(stable)
            generationModel = stable
        }
        // The model is loaded and about to run — this is the genuine "first use"
        // that should start the 3-day trial clock (no-op once already started).
        await MainActor.run { IAPManager.shared.beginOnDeviceTrialIfNeeded() }
        let thinkingEnabled = UserDefaults.standard.object(forKey: "onDeviceThinkingEnabled") as? Bool ?? true
        let turns = Self.coalesce(Self.buildTurns(
            messages: messages,
            tools: tools,
            enableThinking: thinkingEnabled && generationModel.supportsThinking
        ))
        // A full write_file (HTML/JS) easily exceeds the old 2048-token default and
        // truncated mid tool-call; give on-device room to finish one when thermals
        // allow. The runtime policy trims this during heat or memory pressure.
        // Truncation past this still recovers via makeResponse's errorType flagging.
        let raw = try await MLXTextEngine.generate(
            turns: turns,
            maxTokens: runtimePolicy.maxCompletionTokens,
            tokenDelayNanoseconds: runtimePolicy.decodeDelayNanoseconds,
            sampling: generationModel.sampling
        )
        return Self.makeResponse(from: raw, allowedTools: tools)
    }

    // MARK: - Message → prompt

    /// Convert the wire-neutral history into Sendable turns, injecting the tool
    /// spec into the system message and reconstructing prior tool calls/results
    /// as fenced blocks so the model sees its own actions in context.
    static func buildTurns(
        messages: [LLMMessage],
        tools: [ToolSpec],
        enableThinking: Bool = false
    ) -> [OnDeviceTurn] {
        var turns: [OnDeviceTurn] = []
        var injectedTools = false

        for m in messages {
            switch m.role {
            case "system":
                var content = m.content ?? ""
                if !tools.isEmpty {
                    content += "\n\n" + toolInstructions(tools)
                    injectedTools = true
                }
                turns.append(.init(role: "system", content: content))

            case "user":
                var text = m.content ?? ""
                if let imgs = m.images, !imgs.isEmpty {
                    text += (text.isEmpty ? "" : "\n")
                        + "[\(imgs.count) image(s) attached — not visible to the on-device model]"
                }
                turns.append(.init(role: "user", content: text))

            case "assistant":
                var text = m.content ?? ""
                for call in m.toolCalls ?? [] {
                    // Escape the name the same way tool results are (jsonString) so a
                    // name with a quote/backslash can't break the fenced JSON block.
                    let block = "```tool\n{\"name\": \(jsonString(call.name)), \"args\": \(normalizedArguments(call.argumentsJSON))}\n```"
                    text += (text.isEmpty ? "" : "\n") + block
                }
                turns.append(.init(role: "assistant", content: text))

            case "tool":
                // Tool results re-enter as a user turn carrying a result block.
                let name = m.name ?? "tool"
                let block = "```tool_result\n{\"name\": \(jsonString(name)), \"result\": \(jsonString(m.content ?? ""))}\n```\n"
                    + "Use this result to continue. Call another tool if needed, or give the user your final answer in plain text."
                turns.append(.init(role: "user", content: block))

            default:
                break
            }
        }

        if !tools.isEmpty && !injectedTools {
            turns.insert(.init(role: "system", content: toolInstructions(tools)), at: 0)
        }
        if enableThinking,
           let lastUser = turns.lastIndex(where: { $0.role == "user" }) {
            turns[lastUser] = .init(
                role: turns[lastUser].role,
                content: turns[lastUser].content + "\n\n/think"
            )
        }
        return turns
    }

    /// Chat templates reject two turns of the same role in a row (which can
    /// happen when the agent appends several tool results). Merge adjacents.
    static func coalesce(_ turns: [OnDeviceTurn]) -> [OnDeviceTurn] {
        var out: [OnDeviceTurn] = []
        for t in turns {
            if let last = out.last, last.role == t.role {
                out[out.count - 1] = .init(role: last.role, content: last.content + "\n\n" + t.content)
            } else {
                out.append(t)
            }
        }
        return out
    }

    /// The tool-calling contract appended to the system prompt, built from the
    /// same `ToolSpec`s the remote providers receive.
    static func toolInstructions(_ tools: [ToolSpec]) -> String {
        var lines = ["""
        # Tools
        Use tools when the request requires inspecting or changing the website. Inspect before editing. Use exact tool names and required argument keys; never invent a tool or key. Prefer a targeted edit tool over rewriting a whole file.

        To call one tool, output exactly one fenced block and NOTHING after it:

        ```tool
        {"name": "TOOL_NAME", "args": { ... }}
        ```

        Then stop. The app runs it and returns a ```tool_result``` block. Read that result before deciding whether to call another tool. Call ONE tool at a time. When no tool is needed, reply in plain text without JSON.

        Available tools:
        """]
        for t in tools {
            let schema = (try? JSONSerialization.data(withJSONObject: compactSchema(t.parameters), options: [.sortedKeys]))
                .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
            let description = t.description
                .split(whereSeparator: \.isWhitespace)
                .joined(separator: " ")
            lines.append("- `\(t.name)` — \(description.prefix(220))\n  args: \(schema)")
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - Output → response

    /// Parse the raw generation: pull out the first ```tool``` block as a
    /// structured `LLMToolCall`, and return the surrounding prose as content.
    static func makeResponse(from raw: String, allowedTools: [ToolSpec]? = nil) -> LLMResponse {
        if let (call, range) = extractToolCall(from: raw) {
            var content = raw
            content.removeSubrange(range)
            // The first fence became the structured call; discard any remaining
            // ```tool``` blocks (complete or trailing-unclosed) so a second call
            // the model emitted can't leak into the bubble as raw JSON prose.
            content = stripThinking(from: stripToolFences(from: content))
            let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
            if let allowedTools, !isValid(call, for: allowedTools) {
                return LLMResponse(
                    content: trimmed.isEmpty ? nil : trimmed,
                    toolCalls: [],
                    usage: nil,
                    errorType: .malformedToolArguments
                )
            }
            return LLMResponse(content: trimmed.isEmpty ? nil : trimmed, toolCalls: [call], usage: nil)
        }
        let trimmed = stripThinking(from: raw).trimmingCharacters(in: .whitespacesAndNewlines)
        // A ```tool opener with no extractable call means the model started a tool
        // call we couldn't parse — almost always because a big write_file blew the
        // token cap and got cut off mid-block (small on-device models, no closing
        // fence), or it emitted malformed JSON. Flag it like the cloud providers do
        // so the engine's recovery re-prompts for a surgical replace_text edit,
        // instead of silently finishing with the half-written tool JSON as prose.
        if let opener = openingToolFence(in: raw) ?? openingXMLToolTag(in: raw) {
            let tail = raw[opener.upperBound...]
            let closed = tail.contains("```") || tail.range(of: "</tool_call>", options: [.caseInsensitive]) != nil
            let errType: LLMResponseErrorType = closed ? .malformedToolArguments : .toolCallIncomplete
            return LLMResponse(content: trimmed.isEmpty ? nil : trimmed, toolCalls: [], usage: nil, errorType: errType)
        }
        return LLMResponse(content: trimmed.isEmpty ? nil : trimmed, toolCalls: [], usage: nil)
    }

    /// Locate the first ```tool``` opening fence (not ```tool_result```), so an
    /// unparseable/truncated tool block can be distinguished from plain prose.
    static func openingToolFence(in text: String) -> Range<String.Index>? {
        guard let regex = try? NSRegularExpression(
            pattern: #"```(?:tool|tool_call)(?!_)"#,
            options: [.caseInsensitive]
        ) else { return nil }
        let ns = NSRange(text.startIndex..., in: text)
        guard let m = regex.firstMatch(in: text, range: ns), let r = Range(m.range, in: text) else { return nil }
        return r
    }

    /// The portion of a (possibly partial) generation that's safe to show live:
    /// everything before a ```tool``` fence, so the raw tool JSON never flashes
    /// in the chat bubble while streaming.
    static func visibleContent(_ text: String) -> String {
        let withoutThinking = stripThinking(from: text)
        let markers = [openingToolFence(in: withoutThinking), openingXMLToolTag(in: withoutThinking)].compactMap { $0 }
        if let r = markers.min(by: { $0.lowerBound < $1.lowerBound }) {
            return String(withoutThinking[..<r.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return withoutThinking.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Reasoning is private scratch work. Remove complete blocks and suppress a
    /// currently-streaming unclosed block; tool calls after `</think>` remain.
    static func stripThinking(from text: String) -> String {
        var result = text
        if let regex = try? NSRegularExpression(
            pattern: #"<think>[\s\S]*?</think>"#,
            options: [.caseInsensitive]
        ) {
            let ns = NSRange(result.startIndex..., in: result)
            for match in regex.matches(in: result, range: ns).compactMap({ Range($0.range, in: result) }).reversed() {
                result.removeSubrange(match)
            }
        }
        if let opener = result.range(of: "<think>", options: [.caseInsensitive]) {
            result.removeSubrange(opener.lowerBound..<result.endIndex)
        }
        return result
    }

    /// Remove every ```tool``` fenced block (but not ```tool_result```) from
    /// `text`, including a trailing unclosed ```tool opener (a generation cut
    /// off mid-block). Used to clean prose after the first block has been
    /// extracted as the structured call.
    static func stripToolFences(from text: String) -> String {
        var stripped = text
        for pattern in [#"```(?:tool|tool_call)(?!_)\s*[\s\S]*?```"#, #"<tool_call>\s*[\s\S]*?</tool_call>"#] {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { continue }
            let ns = NSRange(stripped.startIndex..., in: stripped)
            let matches = regex.matches(in: stripped, range: ns).compactMap { Range($0.range, in: stripped) }
            for r in matches.reversed() { stripped.removeSubrange(r) }
        }
        if let opener = openingToolFence(in: stripped) {
            stripped.removeSubrange(opener.lowerBound..<stripped.endIndex)
        }
        if let opener = openingXMLToolTag(in: stripped) {
            stripped.removeSubrange(opener.lowerBound..<stripped.endIndex)
        }
        return stripped
    }

    /// Matches a ```tool``` fence (but not ```tool_result```, via `(?!_)`) and
    /// decodes its JSON `{name, args}` payload.
    static func extractToolCall(from text: String) -> (call: LLMToolCall, range: Range<String.Index>)? {
        let patterns = [
            #"```(?:tool|tool_call)(?!_)\s*([\s\S]*?)```"#,
            #"<tool_call>\s*([\s\S]*?)</tool_call>"#
        ]
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { continue }
            let ns = NSRange(text.startIndex..., in: text)
            guard let match = regex.firstMatch(in: text, range: ns),
                  match.numberOfRanges >= 2,
                  let bodyRange = Range(match.range(at: 1), in: text),
                  let fullRange = Range(match.range(at: 0), in: text) else { continue }
            let body = String(text[bodyRange])
            guard let call = decodeToolCall(body) ?? decodeXMLFunctionToolCall(body) else { continue }
            return (call, fullRange)
        }

        // Some local models finish the JSON object but omit the closing fence.
        // Recover that call instead of wasting a retry, while still rejecting a
        // genuinely truncated/unbalanced object.
        if let opener = openingToolFence(in: text),
           let jsonRange = firstJSONObjectRange(in: text, after: opener.upperBound),
           let call = decodeToolCall(String(text[jsonRange])) {
            return (call, opener.lowerBound..<jsonRange.upperBound)
        }

        // Qwen-derived checkpoints occasionally return the function object by
        // itself despite the fenced instruction. Accept it only when the entire
        // response is a valid tool object, so ordinary JSON prose is untouched.
        let whitespace = CharacterSet.whitespacesAndNewlines
        let trimmed = text.trimmingCharacters(in: whitespace)
        if trimmed.first == "{", trimmed.last == "}", let call = decodeToolCall(trimmed),
           let start = text.rangeOfCharacter(from: whitespace.inverted)?.lowerBound,
           let endScalar = text.rangeOfCharacter(from: whitespace.inverted, options: .backwards)?.upperBound {
            return (call, start..<endScalar)
        }
        return nil
    }

    private static func decodeToolCall(_ candidate: String) -> LLMToolCall? {
        let json = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let data = json.data(using: .utf8),
              var object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        if let function = object["function"] as? [String: Any] { object = function }
        guard let name = (object["name"] ?? object["tool"]) as? String, !name.isEmpty else { return nil }

        let rawArguments = object["args"] ?? object["arguments"] ?? object["input"] ?? [String: Any]()
        let arguments: [String: Any]
        if let dictionary = rawArguments as? [String: Any] {
            arguments = dictionary
        } else if let string = rawArguments as? String,
                  let argumentData = string.data(using: .utf8),
                  let dictionary = try? JSONSerialization.jsonObject(with: argumentData) as? [String: Any] {
            arguments = dictionary
        } else {
            return nil
        }
        guard let argsData = try? JSONSerialization.data(withJSONObject: arguments, options: [.sortedKeys]),
              let argsJSON = String(data: argsData, encoding: .utf8) else { return nil }
        return LLMToolCall(id: UUID().uuidString, name: name, argumentsJSON: argsJSON)
    }

    /// Qwen3.5-derived models, including Ternary Bonsai, may follow their native
    /// XML-function grammar even when asked for JSON:
    /// `<function=read_file><parameter=path>index.html</parameter></function>`.
    /// Convert it to Website Commander's shared structured call so local approval tools
    /// enter the exact same Accept/Refuse UI path as API-provider calls.
    private static func decodeXMLFunctionToolCall(_ candidate: String) -> LLMToolCall? {
        guard let functionRegex = try? NSRegularExpression(
            pattern: #"<function\s*=\s*([^>\s]+)\s*>([\s\S]*?)</function>"#,
            options: [.caseInsensitive]
        ) else { return nil }
        let ns = NSRange(candidate.startIndex..., in: candidate)
        guard let match = functionRegex.firstMatch(in: candidate, range: ns),
              let nameRange = Range(match.range(at: 1), in: candidate),
              let bodyRange = Range(match.range(at: 2), in: candidate) else { return nil }

        let name = String(candidate[nameRange]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return nil }
        let body = String(candidate[bodyRange])
        var arguments: [String: Any] = [:]
        if let parameterRegex = try? NSRegularExpression(
            pattern: #"<parameter\s*=\s*([^>\s]+)\s*>([\s\S]*?)</parameter>"#,
            options: [.caseInsensitive]
        ) {
            let bodyNS = NSRange(body.startIndex..., in: body)
            for parameter in parameterRegex.matches(in: body, range: bodyNS) {
                guard let keyRange = Range(parameter.range(at: 1), in: body),
                      let valueRange = Range(parameter.range(at: 2), in: body) else { continue }
                let key = String(body[keyRange]).trimmingCharacters(in: .whitespacesAndNewlines)
                let value = String(body[valueRange]).trimmingCharacters(in: .whitespacesAndNewlines)
                if !key.isEmpty {
                    // Preserve structured array/object parameters such as
                    // request_user_approval.proposedActions instead of turning
                    // their JSON into a plain string.
                    if let valueData = value.data(using: .utf8),
                       let structured = try? JSONSerialization.jsonObject(with: valueData),
                       value.first == "[" || value.first == "{" {
                        arguments[key] = structured
                    } else {
                        arguments[key] = value
                    }
                }
            }
        }
        guard let data = try? JSONSerialization.data(withJSONObject: arguments, options: [.sortedKeys]),
              let json = String(data: data, encoding: .utf8) else { return nil }
        return LLMToolCall(id: UUID().uuidString, name: name, argumentsJSON: json)
    }

    private static func isValid(_ call: LLMToolCall, for tools: [ToolSpec]) -> Bool {
        guard let spec = tools.first(where: { $0.name == call.name }),
              let data = call.argumentsJSON.data(using: .utf8),
              let arguments = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
        let required = spec.parameters["required"] as? [String] ?? []
        return required.allSatisfy { arguments[$0] != nil && !(arguments[$0] is NSNull) }
    }

    private static func firstJSONObjectRange(
        in text: String,
        after lowerBound: String.Index
    ) -> Range<String.Index>? {
        guard let start = text[lowerBound...].firstIndex(of: "{") else { return nil }
        var depth = 0
        var inString = false
        var escaping = false
        var index = start
        while index < text.endIndex {
            let character = text[index]
            if inString {
                if escaping { escaping = false }
                else if character == "\\" { escaping = true }
                else if character == "\"" { inString = false }
            } else if character == "\"" {
                inString = true
            } else if character == "{" {
                depth += 1
            } else if character == "}" {
                depth -= 1
                if depth == 0 { return start..<text.index(after: index) }
            }
            index = text.index(after: index)
        }
        return nil
    }

    private static func openingXMLToolTag(in text: String) -> Range<String.Index>? {
        text.range(of: "<tool_call>", options: [.caseInsensitive])
    }

    private static func normalizedArguments(_ raw: String) -> String {
        guard let data = raw.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let normalized = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else {
            return "{}"
        }
        return String(data: normalized, encoding: .utf8) ?? "{}"
    }

    private static func compactSchema(_ schema: [String: Any]) -> [String: Any] {
        var result: [String: Any] = [:]
        let structuralKeys = ["type", "required", "enum", "const", "additionalProperties", "$ref"]
        for key in structuralKeys where schema[key] != nil { result[key] = schema[key] }
        if let description = schema["description"] as? String {
            result["description"] = String(description.prefix(160))
        }
        if let properties = schema["properties"] as? [String: Any] {
            result["properties"] = properties.mapValues {
                ($0 as? [String: Any]).map(compactSchema) ?? $0
            }
        }
        if let items = schema["items"] as? [String: Any] { result["items"] = compactSchema(items) }
        for key in ["oneOf", "anyOf", "allOf"] {
            if let variants = schema[key] as? [[String: Any]] { result[key] = variants.map(compactSchema) }
        }
        if let definitions = schema["$defs"] as? [String: Any] {
            result["$defs"] = definitions.mapValues { ($0 as? [String: Any]).map(compactSchema) ?? $0 }
        }
        return result
    }

    /// Encode an arbitrary string as a JSON string literal (handles quotes /
    /// newlines so an embedded tool result can't break the fenced block).
    static func jsonString(_ s: String) -> String {
        (try? String(data: JSONEncoder().encode(s), encoding: .utf8)) ?? "\"\""
    }
}
