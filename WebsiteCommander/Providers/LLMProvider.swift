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

    static func system(_ t: String) -> LLMMessage { .init(role: "system", content: t) }
    static func user(_ t: String, images: [LLMImage] = []) -> LLMMessage {
        .init(role: "user", content: t, images: images.isEmpty ? nil : images)
    }
    static func assistant(_ t: String?, calls: [LLMToolCall]? = nil) -> LLMMessage {
        .init(role: "assistant", content: t, toolCalls: calls)
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

    static let textOnly = ModelCapabilities(supportsVision: false, supportsTools: true)
    static let vision = ModelCapabilities(supportsVision: true, supportsTools: true)
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
    /// Streaming variant. `onText` is called with the CUMULATIVE assistant text so
    /// far (the view replaces, not appends); `onActivity` reports non-visible
    /// progress. Returns the final response (text + tool calls + usage).
    /// Providers without SSE keep the default, which falls back to `complete`.
    func stream(messages: [LLMMessage], tools: [ToolSpec], model: String,
                onActivity: @escaping (LLMStreamActivity) -> Void,
                onText: @escaping (String) -> Void) async throws -> LLMResponse
}

extension LLMProvider {
    func capabilities(for model: String) -> ModelCapabilities { .vision }

    /// Default: no streaming — run the blocking call and emit the whole reply once.
    func stream(messages: [LLMMessage], tools: [ToolSpec], model: String,
                onActivity: @escaping (LLMStreamActivity) -> Void,
                onText: @escaping (String) -> Void) async throws -> LLMResponse {
        onActivity(.connected)
        let response = try await complete(messages: messages, tools: tools, model: model)
        if let content = response.content, !content.isEmpty { onText(content) }
        return response
    }
}
