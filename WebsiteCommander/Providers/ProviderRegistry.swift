import Foundation

/// Static metadata about each provider, used to build the Settings UI and to
/// instantiate the concrete `LLMProvider`.
struct ProviderInfo: Identifiable {
    let id: String
    let displayName: String
    let icon: String
    let keyLabel: String          // what the key field is called in the UI
    let keySourceURL: String      // where to get a key
    let models: [String]
    let defaultModel: String
    let supportsVision: Bool

    func modelLabel(_ model: String) -> String {
        guard id == "deepseek" else { return model }
        switch model {
        case "deepseek-v4-pro": return "V4 Pro"
        case "deepseek-v4-flash": return "V4 Flash"
        default: return model
        }
    }
}

/// Knows every provider and how to build the active one from settings.
@MainActor
enum ProviderRegistry {

    static let catalog: [ProviderInfo] = [
        ProviderInfo(id: "openai", displayName: "OpenAI", icon: "circle.hexagongrid.fill",
                     keyLabel: "OpenAI API Key", keySourceURL: "https://platform.openai.com/api-keys",
                     models: ["gpt-4o", "gpt-4o-mini", "o3-mini"], defaultModel: "gpt-4o",
                     supportsVision: true),
        ProviderInfo(id: "anthropic", displayName: "Claude", icon: "sparkle",
                     keyLabel: "Anthropic API Key", keySourceURL: "https://console.anthropic.com/settings/keys",
                     models: ["claude-sonnet-4-5", "claude-opus-4-1", "claude-3-7-sonnet-latest"],
                     defaultModel: "claude-sonnet-4-5", supportsVision: true),
        ProviderInfo(id: "gemini", displayName: "Gemini", icon: "star.fill",
                     keyLabel: "Gemini API Key", keySourceURL: "https://aistudio.google.com/app/apikey",
                     models: ["gemini-2.5-pro", "gemini-2.5-flash", "gemini-2.0-flash"],
                     defaultModel: "gemini-2.5-pro", supportsVision: true),
        ProviderInfo(id: "deepseek", displayName: "DeepSeek", icon: "fish.fill",
                     keyLabel: "DeepSeek API Key", keySourceURL: "https://platform.deepseek.com/api_keys",
                     models: ["deepseek-v4-pro", "deepseek-v4-flash"], defaultModel: "deepseek-v4-flash",
                     supportsVision: false),
        ProviderInfo(id: "alibaba-token", displayName: "Alibaba Token Plan", icon: "cloud.fill",
                     keyLabel: "Token Plan API Key (sk-sp-…)",
                     keySourceURL: "https://bailian.console.aliyun.com/",
                     models: ["qwen3.8-max-preview", "qwen3.7-max", "qwen3.7-plus",
                              "qwen3.6-flash", "glm-5.2", "deepseek-v4-pro"],
                     defaultModel: "qwen3.7-plus", supportsVision: true),
        ProviderInfo(id: "opencode-go", displayName: "OpenCode Go", icon: "paperplane.fill",
                     keyLabel: "OpenCode Go API Key", keySourceURL: "https://opencode.ai/auth",
                     models: ["minimax-m3", "minimax-m2.7", "minimax-m2.5",
                              "kimi-k3", "kimi-k2.7-code", "kimi-k2.6", "kimi-k2.5",
                              "glm-5.2", "glm-5.1", "glm-5",
                              "deepseek-v4-pro", "deepseek-v4-flash",
                              "qwen3.7-max", "qwen3.7-plus", "qwen3.6-plus", "qwen3.5-plus",
                              "mimo-v2-pro", "mimo-v2-omni", "mimo-v2.5-pro", "mimo-v2.5",
                              "hy3", "hy3-preview", "grok-4.5"],
                     defaultModel: "kimi-k2.7-code", supportsVision: false),
        ProviderInfo(id: "opencode-zen", displayName: "OpenCode Zen", icon: "sparkles",
                     keyLabel: "OpenCode Zen API Key", keySourceURL: "https://opencode.ai/auth",
                     models: ["kimi-k2.7-code", "kimi-k2.6", "kimi-k2.5",
                              "deepseek-v4-pro", "deepseek-v4-flash",
                              "minimax-m3", "minimax-m2.7", "minimax-m2.5",
                              "glm-5.2", "glm-5.1", "glm-5", "grok-4.5",
                              "grok-build-0.1", "big-pickle", "mimo-v2.5-free",
                              "north-mini-code-free", "nemotron-3-ultra-free",
                              "deepseek-v4-flash-free"],
                     defaultModel: "kimi-k2.7-code", supportsVision: false),
        ProviderInfo(id: "grok", displayName: "Grok", icon: "bolt.fill",
                     keyLabel: "xAI API Key", keySourceURL: "https://console.x.ai",
                     models: ["grok-3", "grok-2-latest"], defaultModel: "grok-3",
                     supportsVision: true),
        ProviderInfo(id: "mistral", displayName: "Mistral", icon: "wind",
                     keyLabel: "Mistral API Key", keySourceURL: "https://console.mistral.ai/api-keys",
                     models: ["mistral-large-latest", "mistral-small-latest"],
                     defaultModel: "mistral-large-latest", supportsVision: true),
        ProviderInfo(id: "copilot", displayName: "GitHub Copilot", icon: "github",
                     keyLabel: "Copilot Token", keySourceURL: "https://github.com/settings/tokens",
                     models: ["gpt-4o", "claude-sonnet-4", "o3-mini"], defaultModel: "gpt-4o",
                     supportsVision: true),
        ProviderInfo(id: "ondevice", displayName: "On-Device", icon: "cpu",
                     keyLabel: "", keySourceURL: "",
                     models: ["System Model"], defaultModel: "System Model",
                     supportsVision: false),
        ProviderInfo(id: "custom", displayName: "Custom (OpenAI-compatible)", icon: "terminal.fill",
                     keyLabel: "API Key", keySourceURL: "",
                     models: [], defaultModel: "", supportsVision: true)
    ]

    static func info(for id: String) -> ProviderInfo? {
        catalog.first { $0.id == id }
    }

    /// Build a concrete provider for `id`, reading its key from settings.
    /// Returns nil when a required key is missing.
    static func makeProvider(id: String, settings: SettingsStore) -> LLMProvider? {
        let key = (settings.apiKey(for: id) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        switch id {
        case "anthropic":
            return AnthropicProvider(apiKey: key)
        case "gemini":
            return GeminiProvider(apiKey: key)
        case "custom":
            guard !settings.customBaseURL.isEmpty else { return nil }
            let model = settings.customModel.isEmpty ? "gpt-4o" : settings.customModel
            return OpenAICompatibleProvider(config: .init(
                id: "custom", displayName: "Custom", baseURL: settings.customBaseURL,
                apiKey: key, models: [model], defaultModel: model, visionModels: [model]))
        case "copilot":
            return OpenAICompatibleProvider(config: .init(
                id: "copilot", displayName: "GitHub Copilot",
                baseURL: "https://api.githubcopilot.com", apiKey: key,
                models: ["gpt-4o", "claude-sonnet-4", "o3-mini"], defaultModel: "gpt-4o",
                visionModels: ["gpt-4o"],
                extraHeaders: ["Copilot-Integration-Id": "vscode-chat"]))
        case "ondevice":
            #if canImport(FoundationModels)
            if #available(macOS 26.0, *), OnDeviceProvider.isAvailable {
                return OnDeviceProvider()
            }
            #endif
            return nil
        default:
            guard let info = info(for: id) else { return nil }
            let baseURL: String
            switch id {
            case "openai":   baseURL = "https://api.openai.com/v1"
            case "deepseek": baseURL = "https://api.deepseek.com/v1"
            case "alibaba-token":
                baseURL = "https://token-plan.ap-southeast-1.maas.aliyuncs.com/compatible-mode/v1"
            case "opencode-go":
                baseURL = "https://opencode.ai/zen/go/v1"
            case "opencode-zen":
                baseURL = "https://opencode.ai/zen/v1"
            case "grok":     baseURL = "https://api.x.ai/v1"
            case "mistral":  baseURL = "https://api.mistral.ai/v1"
            default:         baseURL = ""
            }
            let visionModels: Set<String>
            if id == "alibaba-token" {
                visionModels = ["qwen3.8-max-preview", "qwen3.7-plus", "qwen3.6-flash"]
            } else {
                visionModels = info.supportsVision ? Set(info.models) : []
            }
            return OpenAICompatibleProvider(config: .init(
                id: id, displayName: info.displayName, baseURL: baseURL, apiKey: key,
                models: info.models, defaultModel: info.defaultModel,
                visionModels: visionModels))
        }
    }

    /// The provider currently selected in settings.
    static func activeProvider(_ settings: SettingsStore) -> LLMProvider? {
        makeProvider(id: settings.providerID, settings: settings)
    }

    /// Smart routing: pick the best available provider id for the strategy,
    /// preferring ones that already have a key configured.
    static func routedProviderID(_ settings: SettingsStore) -> String {
        let order: [String]
        switch settings.routingStrategy {
        case .budget:
            order = ["opencode-go", "deepseek", "gemini", "openai", "copilot", "mistral"]
        case .quality:
            order = ["anthropic", "openai", "opencode-zen", "alibaba-token",
                     "copilot", "gemini", "grok"]
        case .code:
            order = ["opencode-zen", "opencode-go", "alibaba-token",
                     "copilot", "anthropic", "openai", "gemini", "deepseek"]
        }
        let available = order.filter { !(settings.apiKey(for: $0) ?? "").isEmpty }
        return available.first ?? settings.providerID
    }
}
