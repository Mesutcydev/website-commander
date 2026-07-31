import Foundation

#if canImport(FoundationModels)
import FoundationModels

/// On-device inference via Apple's FoundationModels framework (macOS 26+).
/// Runs entirely on the Mac — no network, no API key, no external dependency.
///
/// FoundationModels owns a static tool system, so to keep the agent's dynamic
/// tools we inject the tool specs into the prompt and ask the model to emit
/// calls as a JSON code block, which we parse back into `LLMToolCall`s.
@available(macOS 26.0, *)
struct OnDeviceProvider: LLMProvider {

    var id: String { "ondevice" }
    var displayName: String { "On-Device" }
    var models: [String] { ["System Model"] }
    var defaultModel: String { "System Model" }

    func capabilities(for model: String) -> ModelCapabilities {
        ModelCapabilities(supportsVision: false, supportsTools: true, supportsReasoning: false)
    }

    /// Whether Apple Intelligence is available on this machine.
    static var isAvailable: Bool {
        SystemLanguageModel.default.isAvailable
    }

    func complete(messages: [LLMMessage], tools: [ToolSpec], model: String) async throws -> LLMResponse {
        guard OnDeviceProvider.isAvailable else {
            throw LLMError.noKey("On-Device AI (Apple Intelligence isn't available on this Mac)")
        }
        let session = LanguageModelSession(instructions: Self.instructions)
        let prompt = Self.buildPrompt(messages: messages, tools: tools)
        let response = try await session.respond(to: prompt)
        return Self.parse(response.content)
    }

    private static let instructions = """
    You are Website Commander, an autonomous web-development agent running fully
    on this Mac. You edit websites stored in GitHub. Propose file edits with the
    write_file tool; they are staged for the user to approve before committing.
    Be concise and precise.
    """

    // MARK: Prompt building

    private static func buildPrompt(messages: [LLMMessage], tools: [ToolSpec]) -> String {
        var parts: [String] = []
        for message in messages where message.role != "system" {
            switch message.role {
            case "user":
                parts.append("User: \(message.content ?? "")")
            case "assistant":
                if let text = message.content, !text.isEmpty { parts.append("Assistant: \(text)") }
                for call in message.toolCalls ?? [] {
                    parts.append("Assistant tool call: \(call.name) \(call.argumentsJSON)")
                }
            case "tool":
                parts.append("Tool result (\(message.name ?? "tool")): \(message.content ?? "")")
            default:
                continue
            }
        }

        if !tools.isEmpty {
            var toolLines: [String] = []
            for tool in tools {
                let params = (try? JSONSerialization.data(withJSONObject: tool.parameters))
                    .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
                toolLines.append("- \(tool.name): \(tool.description) Parameters: \(params)")
            }
            parts.append("""
            Available tools:
            \(toolLines.joined(separator: "\n"))

            To use a tool, reply with ONLY a JSON code block like:
            ```json
            {"name": "tool_name", "arguments": { ... }}
            ```
            To call several tools, use a JSON array of such objects.
            If no tool is needed, reply with plain text (no code block).
            """)
        }
        return parts.joined(separator: "\n\n")
    }

    // MARK: Response parsing

    private static func parse(_ text: String) -> LLMResponse {
        let calls = extractToolCalls(from: text)
        if !calls.isEmpty {
            return LLMResponse(content: nil, toolCalls: calls, usage: nil)
        }
        return LLMResponse(content: text, toolCalls: [], usage: nil)
    }

    /// Pull tool calls out of any ```json fenced block(s) in the reply.
    private static func extractToolCalls(from text: String) -> [LLMToolCall] {
        var calls: [LLMToolCall] = []
        let blocks = jsonBlocks(in: text)
        for block in blocks {
            guard let data = block.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) else { continue }
            if let dict = obj as? [String: Any], dict["name"] != nil {
                if let call = toolCall(from: dict) { calls.append(call) }
            } else if let arr = obj as? [[String: Any]] {
                for dict in arr { if let call = toolCall(from: dict) { calls.append(call) } }
            }
        }
        return calls
    }

    private static func toolCall(from dict: [String: Any]) -> LLMToolCall? {
        guard let name = dict["name"] as? String else { return nil }
        let args = dict["arguments"] ?? [String: Any]()
        let argsData = (try? JSONSerialization.data(withJSONObject: args)) ?? Data("{}".utf8)
        return LLMToolCall(id: UUID().uuidString, name: name,
                           argumentsJSON: String(data: argsData, encoding: .utf8) ?? "{}")
    }

    private static func jsonBlocks(in text: String) -> [String] {
        var results: [String] = []
        var search = text
        while let openRange = search.range(of: "```json") {
            let afterOpen = search[openRange.upperBound...]
            guard let closeRange = afterOpen.range(of: "```") else { break }
            results.append(String(afterOpen[..<closeRange.lowerBound])
                .trimmingCharacters(in: .whitespacesAndNewlines))
            search = String(afterOpen[closeRange.upperBound...])
        }
        // Fallback: a bare fenced block without the json tag.
        if results.isEmpty {
            var search2 = text
            while let openRange = search2.range(of: "```") {
                let afterOpen = search2[openRange.upperBound...]
                guard let closeRange = afterOpen.range(of: "```") else { break }
                let candidate = String(afterOpen[..<closeRange.lowerBound])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if candidate.hasPrefix("{") || candidate.hasPrefix("[") { results.append(candidate) }
                search2 = String(afterOpen[closeRange.upperBound...])
            }
        }
        return results
    }
}
#endif
