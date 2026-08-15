import Foundation

enum IntelligenceAvailability: Equatable, Sendable {
    case available
    case disabledByBuild
    case unsupportedOS
    case unsupportedDevice
    case appleIntelligenceUnavailable
    case networkUnavailable
    case approachingQuotaLimit
    case quotaLimitReached
    case temporarilyUnavailable
    
    var isAvailable: Bool {
        self == .available || self == .approachingQuotaLimit
    }
    
    var description: String {
        switch self {
        case .available:
            return "Available"
        case .disabledByBuild:
            return "Disabled in this build configuration."
        case .unsupportedOS:
            return "Requires iOS 27 or later."
        case .unsupportedDevice:
            return "This device does not support Apple Intelligence."
        case .appleIntelligenceUnavailable:
            return "Apple Intelligence is not enabled. Please enable it in Settings."
        case .networkUnavailable:
            return "Internet connection is required."
        case .approachingQuotaLimit:
            return "Approaching daily usage limit."
        case .quotaLimitReached:
            return "Daily Private Cloud Compute usage limit reached."
        case .temporarilyUnavailable:
            return "Temporarily unavailable."
        }
    }
}

struct IntelligenceRequest: Sendable {
    var messages: [LLMMessage]
    var tools: [ToolSpec]
    var model: String
}

typealias IntelligenceResponse = LLMResponse

protocol IntelligenceProvider: Sendable {
    var identifier: String { get }
    var displayName: String { get }

    func availability() async -> IntelligenceAvailability
    func respond(to request: IntelligenceRequest) async throws -> IntelligenceResponse
}

// Adapt LLMProvider to conform to IntelligenceProvider
extension LLMProvider {
    var identifier: String { id }
    
    func availability() async -> IntelligenceAvailability {
        return .available
    }
    
    func respond(to request: IntelligenceRequest) async throws -> IntelligenceResponse {
        try await complete(messages: request.messages, tools: request.tools, model: request.model)
    }
}
