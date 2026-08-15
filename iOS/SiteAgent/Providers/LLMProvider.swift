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
    var toolCalls: [LLMToolCall]?    // assistant turn requesting tools
    var toolCallID: String?          // for role == "tool": which call this answers
    var name: String?
    var images: [LLMImage]?          // user turn carrying attached images
    var thoughtSignature: String?

    static func system(_ t: String) -> LLMMessage { .init(role: "system", content: t) }
    static func user(_ t: String, images: [LLMImage] = []) -> LLMMessage {
        .init(role: "user", content: t, images: images.isEmpty ? nil : images)
    }
    static func assistant(_ t: String?, calls: [LLMToolCall]? = nil, thoughtSignature: String? = nil) -> LLMMessage {
        .init(role: "assistant", content: t, toolCalls: calls, thoughtSignature: thoughtSignature)
    }
    static func tool(_ result: String, id: String, name: String) -> LLMMessage {
        .init(role: "tool", content: result, toolCallID: id, name: name)
    }
}

struct LLMToolCall: Identifiable, Codable {
    var id: String
    var name: String
    var argumentsJSON: String        // raw JSON string of arguments
    /// Provider-specific reasoning state attached to this exact call. Gemini 3
    /// requires it to be returned on the same functionCall part in history.
    var thoughtSignature: String? = nil
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
    var thoughtSignature: String? = nil
    var errorType: LLMResponseErrorType? = nil
}

/// Non-visible progress reported by a streaming provider. Reasoning models can
/// spend minutes emitting private reasoning or tool-call arguments before they
/// produce assistant text; these events keep the run watchdog accurate without
/// leaking private chain-of-thought into the transcript.
enum LLMStreamActivity: Equatable {
    case connected
    case reasoning
    case toolCall
}

enum LLMResponseErrorType: String, Codable {
    case toolCallIncomplete
    case outputLimitReached
    case malformedToolArguments
}

/// Transport requests must outlive the engine's first-progress watchdog. If the
/// URLSession timeout fires first, the same slow reasoning request is needlessly
/// retried and can fail even though the engine intentionally allows 180 seconds.
enum LLMTransportPolicy {
    static let requestTimeoutSeconds: TimeInterval = 240
}

enum ModelInputModality: String, Codable, Equatable, Hashable, Sendable {
    case text
    case image
    case file
    case audio
}

enum ModelOutputModality: String, Codable, Equatable, Hashable, Sendable {
    case text
    case image
    case audio
}

struct ModelCapabilities: Codable, Equatable, Sendable {
    let inputModalities: Set<ModelInputModality>
    let outputModalities: Set<ModelOutputModality>
    let supportsTools: Bool
    let supportsForcedToolChoice: Bool
    let supportsParallelToolCalls: Bool
    let supportsStreamingToolCalls: Bool
    let supportsReasoningSummary: Bool
    let maximumToolSchemaBytes: Int?

    var supportsImageInput: Bool { inputModalities.contains(.image) }

    static func textOnly(
        supportsTools: Bool,
        supportsForcedToolChoice: Bool = false,
        supportsParallelToolCalls: Bool = false,
        supportsStreamingToolCalls: Bool = true,
        supportsReasoningSummary: Bool = false,
        maximumToolSchemaBytes: Int? = nil
    ) -> ModelCapabilities {
        ModelCapabilities(
            inputModalities: [.text],
            outputModalities: [.text],
            supportsTools: supportsTools,
            supportsForcedToolChoice: supportsForcedToolChoice,
            supportsParallelToolCalls: supportsParallelToolCalls,
            supportsStreamingToolCalls: supportsStreamingToolCalls,
            supportsReasoningSummary: supportsReasoningSummary,
            maximumToolSchemaBytes: maximumToolSchemaBytes
        )
    }

    static func visionText(
        supportsTools: Bool,
        supportsForcedToolChoice: Bool = false,
        supportsParallelToolCalls: Bool = false,
        supportsStreamingToolCalls: Bool = true,
        supportsReasoningSummary: Bool = false,
        maximumToolSchemaBytes: Int? = nil
    ) -> ModelCapabilities {
        ModelCapabilities(
            inputModalities: [.text, .image],
            outputModalities: [.text],
            supportsTools: supportsTools,
            supportsForcedToolChoice: supportsForcedToolChoice,
            supportsParallelToolCalls: supportsParallelToolCalls,
            supportsStreamingToolCalls: supportsStreamingToolCalls,
            supportsReasoningSummary: supportsReasoningSummary,
            maximumToolSchemaBytes: maximumToolSchemaBytes
        )
    }
}

// MARK: - The pluggable protocol ("ext all")

/// Conform a new type to this to add any provider. Switch the active one in Settings.
protocol LLMProvider: IntelligenceProvider {
    var id: String { get }              // stable key (also the Keychain key suffix)
    var displayName: String { get }
    var models: [String] { get }
    var defaultModel: String { get }
    /// Model-specific capability metadata. Mixed catalogs (OpenRouter, Copilot,
    /// custom providers) can expose text-only and vision models side by side.
    func capabilities(for model: String) -> ModelCapabilities
    func complete(messages: [LLMMessage], tools: [ToolSpec], model: String) async throws -> LLMResponse
    /// Streaming variant: calls `onActivity` for meaningful non-visible progress,
    /// calls `onText` with cumulative assistant text, and returns the final
    /// response (text + tool calls + usage).
    func stream(messages: [LLMMessage], tools: [ToolSpec], model: String,
                onActivity: @escaping (LLMStreamActivity) -> Void,
                onText: @escaping (String) -> Void) async throws -> LLMResponse
    /// Live model list from the provider's API, so the picker shows newly-released
    /// models without a code change. Returns nil when the provider has no listing
    /// endpoint (the static `models` is used as-is).
    func fetchAvailableModels() async throws -> [String]?
}

extension LLMProvider {
    func capabilities(for model: String) -> ModelCapabilities {
        // MLX on-device bridges tools via prompt-injection (OnDeviceProvider injects
        // a tool spec and parses ```tool``` blocks back out), so it *does* support
        // tools. Only the Apple Foundation Models providers genuinely can't — their
        // framework owns its own tool loop and can't drive our runtime-defined tools
        // (see AppleFoundationProvider) — so they alone report supportsTools: false.
        let noTools = id.hasPrefix("apple")
        return ModelCapabilities.visionText(
            supportsTools: !noTools,
            supportsForcedToolChoice: (id == "openai" || id == "anthropic"),
            supportsParallelToolCalls: (id == "openai" || id == "anthropic"),
            supportsStreamingToolCalls: (id != "gemini"),
            supportsReasoningSummary: id == "openai",
            maximumToolSchemaBytes: nil
        )
    }

    /// Default: no token streaming — run the non-streaming call and emit the
    /// whole reply once. Providers that support SSE override this.
    func stream(messages: [LLMMessage], tools: [ToolSpec], model: String,
                onActivity: @escaping (LLMStreamActivity) -> Void,
                onText: @escaping (String) -> Void) async throws -> LLMResponse {
        onActivity(.connected)
        let response = try await complete(messages: messages, tools: tools, model: model)
        if let content = response.content, !content.isEmpty { onText(content) }
        return response
    }

    /// Default: no listing endpoint — callers fall back to the static `models`.
    func fetchAvailableModels() async throws -> [String]? { nil }
}

enum LLMError: LocalizedError {
    case noKey(String)
    case http(Int, String)
    case decoding(String)

    var errorDescription: String? {
        switch self {
        case .noKey(let p): return "No API key set for \(p). Add one in Settings."
        case .http(let c, let b): return "Provider error \(c): \(b)"
        case .decoding(let w): return "Could not read provider response: \(w)"
        }
    }
}
