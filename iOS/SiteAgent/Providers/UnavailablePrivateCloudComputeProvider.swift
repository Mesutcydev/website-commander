import Foundation

struct UnavailablePrivateCloudComputeProvider: LLMProvider {
    let id = "apple-pcc"
    let displayName = "Apple Private Cloud — Beta"
    let models = ["Automatic", "Light", "Moderate", "Deep"]
    let defaultModel = "Automatic"
    func capabilities(for model: String) -> ModelCapabilities {
        ModelCapabilities.textOnly(supportsTools: false)
    }
    
    let reason: IntelligenceAvailability
    
    func availability() async -> IntelligenceAvailability {
        return reason
    }
    
    func complete(messages: [LLMMessage], tools: [ToolSpec], model: String) async throws -> LLMResponse {
        throw AppleModelError.unavailable(reason.description)
    }
    
    func fetchAvailableModels() async throws -> [String]? { nil }
}

enum AppleModelError: LocalizedError {
    case unavailable(String)
    var errorDescription: String? { if case .unavailable(let m) = self { return m } ; return nil }
}
