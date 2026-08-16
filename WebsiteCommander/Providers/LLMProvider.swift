import Foundation

// MARK: - Wire-neutral message & tool types

/// A base64-encoded image attached to a user turn (for vision-capable models).
struct LLMImage: Codable {
    var mimeType: String
    var base64: String
}

/// A message in the model's context window (distinct from the UI's ChatMessage).
struct LLMMessage: Codable {
    var role: String                 // "system" | "user" | "assistant" | "tool"
    var content: String?
    var toolCalls: [LLMToolCall]?
    var toolCallID: String?
    var name: String?
    var images: [LLMImage]?
    /// Provider reasoning / extended-thinking text for this assistant turn.
    /// Only set when the provider actually returned it — never synthesized.
    var reasoning: String?
    /// Opaque Anthropic thinking-block signature required when replaying
    /// thinking + tool_use turns. Other providers leave this nil.
    var reasoningSignature: String?
    /// Anthropic `redacted_thinking.data` payload, when the API redacted the
    /// thinking block. Must be replayed unmodified with tool rounds.
    var reasoningRedactedData: String?

    static func system(_ t: String) -> LLMMessage { .init(role: "system", content: t) }
    static func user(_ t: String, images: [LLMImage] = []) -> LLMMessage {
        .init(role: "user", content: t, images: images.isEmpty ? nil : images)
    }
    static func assistant(_ t: String?, calls: [LLMToolCall]? = nil,
                          reasoning: String? = nil, reasoningSignature: String? = nil,
                          reasoningRedactedData: String? = nil) -> LLMMessage {
        .init(role: "assistant", content: t, toolCalls: calls,
              reasoning: reasoning, reasoningSignature: reasoningSignature,
              reasoningRedactedData: reasoningRedactedData)
    }
    static func tool(_ result: String, id: String, name: String) -> LLMMessage {
        .init(role: "tool", content: result, toolCallID: id, name: name)
    }
}

struct LLMToolCall: Identifiable, Codable {
    var id: String
    var name: String
    var argumentsJSON: String
}

/// A function the model may call. `parameters` is a JSON Schema object.
struct ToolSpec {
    var name: String
    var description: String
    var parameters: [String: Any]
}

struct TokenUsage: Codable, Equatable {
    var promptTokens: Int
    var completionTokens: Int
}

struct LLMResponse {
    var content: String?
    var toolCalls: [LLMToolCall]
    var usage: TokenUsage?
    /// Real reasoning / thinking text from the provider, if any.
    var reasoning: String? = nil
    /// Anthropic thinking-block signature (required when replaying tool turns).
    var reasoningSignature: String? = nil
    /// Anthropic redacted thinking payload (replayed with tool turns).
    var reasoningRedactedData: String? = nil
}

/// Non-visible progress from a streaming provider, used to keep the UI honest
/// while a reasoning model thinks or streams tool-call arguments.
enum LLMStreamActivity: Equatable {
    case connected
    case reasoning
    case toolCall
}

enum LLMError: LocalizedError {
    case noKey(String)
    case http(Int, String)
    case decoding(String)

    var errorDescription: String? {
        switch self {
        case .noKey(let p):  return "No API key set for \(p). Add one in Settings."
        case .http(let c, let b): return "Provider error \(c): \(b)"
        case .decoding(let w): return "Could not read provider response: \(w)"
        }
    }
}

/// Model capability metadata used for routing and attachment warnings.
struct ModelCapabilities: Equatable {
    var supportsVision: Bool
    var supportsTools: Bool
    /// Whether we should request / expect provider reasoning for this model.
    var supportsReasoning: Bool

    static let textOnly = ModelCapabilities(supportsVision: false, supportsTools: true, supportsReasoning: false)
    static let vision = ModelCapabilities(supportsVision: true, supportsTools: true, supportsReasoning: false)

    static func vision(reasoning: Bool) -> ModelCapabilities {
        ModelCapabilities(supportsVision: true, supportsTools: true, supportsReasoning: reasoning)
    }
}

/// Heuristics for models known to return (or accept requests for) reasoning /
/// extended-thinking content. Used only to enable provider-side request flags;
/// the UI still shows reasoning only when real text arrives.
enum ModelReasoningSupport {
    static func anthropic(_ model: String) -> Bool {
        let m = model.lowercased()
        return m.contains("sonnet-4")
            || m.contains("opus-4")
            || m.contains("3-7-sonnet")
            || m.contains("claude-opus")
            || m.contains("claude-sonnet-4")
    }

    static func gemini(_ model: String) -> Bool {
        let m = model.lowercased()
        return m.contains("gemini-2.5") || m.contains("gemini-3")
    }

    /// OpenAI-compatible endpoints that stream `reasoning_content` / `reasoning`
    /// (DeepSeek reasoner / V4 thinking, o-series when exposed, MiniMax, etc.).
    static func openAICompatible(_ model: String) -> Bool {
        let m = model.lowercased()
        if m.contains("deepseek") {
            // V4 Flash/Pro both support thinking mode; also legacy reasoner IDs.
            if m.contains("v4") || m.contains("reasoner") || m.contains("r1")
                || m.contains("v3.2") || m.contains("thinking") {
                return true
            }
        }
        if m.hasPrefix("o1") || m.hasPrefix("o3") || m.hasPrefix("o4") { return true }
        if m.contains("reasoner") || m.contains("thinking") { return true }
        if m.contains("qwq") || (m.contains("qwen") && m.contains("think")) { return true }
        // MiniMax M2/M3 and Kimi thinking variants often expose reasoning_content.
        if m.contains("minimax") && (m.contains("m2") || m.contains("m3") || m.contains("thinking")) {
            return true
        }
        if m.contains("kimi") && (m.contains("thinking") || m.contains("k2")) { return true }
        return false
    }
}

/// User-facing reasoning effort for models that expose one. `.default` sends
/// no effort parameter and keeps each provider's current request shape.
enum ReasoningEffort: String, Codable, CaseIterable, Identifiable {
    case `default`
    case low
    case medium
    case high

    var id: String { rawValue }

    var label: String {
        switch self {
        case .default: return String(localized: "Default")
        case .low:     return String(localized: "Low")
        case .medium:  return String(localized: "Medium")
        case .high:    return String(localized: "High")
        }
    }

    var summary: String {
        switch self {
        case .default: return String(localized: "Provider default")
        case .low:     return String(localized: "Fastest, least thinking")
        case .medium:  return String(localized: "Balanced")
        case .high:    return String(localized: "Deepest thinking")
        }
    }
}

/// Pure heuristics for which provider+model combinations honor an effort
/// choice, mirroring what the providers can actually change on the wire.
/// Kept free of Keychain access so popover layout can call it safely.
enum ReasoningEffortSupport {
    static func supports(providerID: String, model: String) -> Bool {
        switch providerID {
        case "ondevice":
            return false
        case "anthropic":
            return ModelReasoningSupport.anthropic(model)
        case "gemini":
            return ModelReasoningSupport.gemini(model)
        default:
            // OpenAI, DeepSeek, Copilot, custom endpoints, and OpenAI-compatible
            // gateways all speak the same model-ID space.
            return openAICompatible(model)
        }
    }

    /// Models that accept `reasoning_effort` (OpenAI o-series / GPT-5 family)
    /// or a thinking on/off toggle (DeepSeek V4 family).
    static func openAICompatible(_ model: String) -> Bool {
        let m = model.lowercased()
        if m.hasPrefix("o1") || m.hasPrefix("o3") || m.hasPrefix("o4") { return true }
        if m.hasPrefix("gpt-5") { return true }
        if m.contains("deepseek") {
            return m.contains("v4") || m.contains("reasoner") || m.contains("r1")
                || m.contains("v3.2") || m.contains("thinking")
        }
        return false
    }
}

// MARK: - The pluggable protocol

/// Conform a new type to this to add any provider. Switch the active one in Settings.
protocol LLMProvider {
    var id: String { get }
    var displayName: String { get }
    var models: [String] { get }
    var defaultModel: String { get }
    func capabilities(for model: String) -> ModelCapabilities
    func complete(messages: [LLMMessage], tools: [ToolSpec], model: String) async throws -> LLMResponse
    /// Streaming variant. `onText` / `onReasoning` receive CUMULATIVE text so
    /// far (the view replaces, not appends); `onActivity` reports non-visible
    /// progress. Returns the final response (text + reasoning + tool calls + usage).
    /// Providers without SSE keep the default, which falls back to `complete`.
    func stream(messages: [LLMMessage], tools: [ToolSpec], model: String,
                onActivity: @escaping (LLMStreamActivity) -> Void,
                onText: @escaping (String) -> Void,
                onReasoning: @escaping (String) -> Void) async throws -> LLMResponse
}

extension LLMProvider {
    func capabilities(for model: String) -> ModelCapabilities { .vision }

    /// Default: no streaming — run the blocking call and emit the whole reply once.
    func stream(messages: [LLMMessage], tools: [ToolSpec], model: String,
                onActivity: @escaping (LLMStreamActivity) -> Void,
                onText: @escaping (String) -> Void,
                onReasoning: @escaping (String) -> Void) async throws -> LLMResponse {
        onActivity(.connected)
        let response = try await complete(messages: messages, tools: tools, model: model)
        if let reasoning = response.reasoning, !reasoning.isEmpty {
            onActivity(.reasoning)
            onReasoning(reasoning)
        }
        if let content = response.content, !content.isEmpty { onText(content) }
        return response
    }
}
