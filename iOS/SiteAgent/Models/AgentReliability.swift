import Foundation

enum ReasoningPreference: String, Codable, Identifiable {
    case automatic = "Automatic"
    case none = "none"
    case minimal = "minimal"
    case low = "low"
    case medium = "medium"
    case high = "high"
    case max = "max"
    case xhigh = "xhigh"
    /// Legacy Settings labels. Still decoded from older installs / archives.
    case fast = "Fast"
    case balanced = "Balanced"
    case deep = "Deep"

    var id: String { rawValue }

    /// Official API / picker identity after collapsing legacy aliases.
    var canonical: ReasoningPreference {
        switch self {
        case .fast: return .low
        case .balanced: return .medium
        case .deep: return .high
        default: return self
        }
    }

    var officialID: String {
        switch canonical {
        case .automatic: return "automatic"
        default: return canonical.rawValue
        }
    }

    var displayLabel: String {
        switch canonical {
        case .automatic: return "Automatic"
        case .none: return "None"
        case .minimal: return "Minimal"
        case .low: return "Low"
        case .medium: return "Medium"
        case .high: return "High"
        case .max: return "Max"
        case .xhigh: return "Extra high"
        default: return rawValue
        }
    }

    var instruction: String? {
        switch canonical {
        case .automatic, .none:
            return nil
        case .minimal, .low:
            return "Use a fast, direct approach. Avoid unnecessary exploration and prefer the smallest safe change."
        case .medium:
            return "Balance speed with careful verification. Inspect the relevant code, then make the smallest well-supported change."
        case .high, .max, .xhigh:
            return "Reason carefully before acting. Check assumptions, inspect dependencies, and verify edge cases before staging changes."
        default:
            return nil
        }
    }

    /// OpenAI / OpenCode Responses `reasoning.effort` and chat `reasoning_effort`.
    var openaiEffort: String {
        switch canonical {
        case .none: return "none"
        case .minimal: return "minimal"
        case .low: return "low"
        case .automatic, .medium: return "medium"
        case .high, .max: return "high"
        case .xhigh: return "xhigh"
        default: return "medium"
        }
    }

    /// Anthropic `effort` when the model publishes that parameter.
    var anthropicEffort: String? {
        switch canonical {
        case .automatic, .none: return nil
        case .minimal, .low: return "low"
        case .medium: return "medium"
        case .high: return "high"
        case .max, .xhigh: return "max"
        default: return nil
        }
    }

    /// Anthropic extended-thinking budget. Automatic leaves thinking off.
    var anthropicBudgetTokens: Int? {
        switch canonical {
        case .automatic, .none: return nil
        case .minimal, .low: return 1_024
        case .medium: return 5_000
        case .high: return 10_000
        case .max, .xhigh: return 16_000
        default: return nil
        }
    }

    var geminiThinkingLevel: String? {
        switch canonical {
        case .automatic, .none: return nil
        case .minimal: return "MINIMAL"
        case .low: return "LOW"
        case .medium: return "MEDIUM"
        case .high, .max, .xhigh: return "HIGH"
        default: return nil
        }
    }

    static var stored: ReasoningPreference {
        ReasoningPreference(rawValue: UserDefaults.standard.string(forKey: "reasoningPreference") ?? "")
            ?? .automatic
    }
}

enum ReasoningEffortCatalog {
    static func levels(providerID: String, modelID: String) -> [ReasoningPreference] {
        let provider = providerID.lowercased()
        let model = modelID.lowercased()

        if isOpenAIFullScale(provider: provider, model: model) {
            return [.none, .minimal, .low, .medium, .high, .xhigh]
        }
        if isOpenAIClassicScale(model: model) {
            return [.low, .medium, .high]
        }
        if model.contains("claude") {
            return [.automatic, .low, .medium, .high, .max]
        }
        if model.contains("gemini") {
            return [.automatic, .minimal, .low, .medium, .high]
        }
        if model.contains("grok") {
            return [.low, .high]
        }
        if model.contains("deepseek") && (model.contains("v4") || model.contains("reasoner")) {
            return [.automatic, .low, .high]
        }
        if provider == "ondevice" || provider.hasPrefix("apple") {
            return [.automatic, .low, .medium, .high]
        }
        return [.automatic, .low, .medium, .high]
    }

    static func resolved(
        _ stored: ReasoningPreference,
        providerID: String,
        modelID: String
    ) -> ReasoningPreference {
        let options = levels(providerID: providerID, modelID: modelID)
        let canonical = stored.canonical
        if options.contains(canonical) { return canonical }
        switch canonical {
        case .none, .minimal:
            if options.contains(.low) { return .low }
        case .high, .max, .xhigh:
            if options.contains(.max) { return .max }
            if options.contains(.high) { return .high }
        default:
            break
        }
        if options.contains(.medium) { return .medium }
        if options.contains(.automatic) { return .automatic }
        return options.first ?? .automatic
    }

    static func isOpenAIFullScale(provider: String, model: String) -> Bool {
        let id = bareModelID(model)
        if id == "gpt-5.6-luna" || id.hasPrefix("gpt-5.6") { return true }
        if id.hasPrefix("gpt-5.5") || id.hasPrefix("gpt-5.4") || id.hasPrefix("gpt-5.2") { return true }
        if id.hasPrefix("gpt-5.1") || id.hasPrefix("gpt-5") { return true }
        if provider == "opencode" && id.hasPrefix("gpt-") { return true }
        return false
    }

    private static func isOpenAIClassicScale(model: String) -> Bool {
        let id = bareModelID(model)
        return id.hasPrefix("o1") || id.hasPrefix("o3") || id.hasPrefix("o4")
    }

    private static func bareModelID(_ model: String) -> String {
        let trimmed = model.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard let slash = trimmed.lastIndex(of: "/") else { return trimmed }
        return String(trimmed[trimmed.index(after: slash)...])
    }
}

enum ChatModelCatalog {
    /// Empty query returns the full list. A provider-name hit also returns the
    /// full list so search can surface every model for that vendor.
    static func matching(models: [String], providerName: String, query: String) -> [String] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return models }
        if providerName.localizedStandardContains(trimmed) { return models }
        return models.filter { $0.localizedStandardContains(trimmed) }
    }
}

enum LaunchPreference: String, Codable, CaseIterable, Identifiable {
    case commandCenter = "Command Center"
    case lastConversation = "Last Conversation"
    case newChat = "New Chat"

    var id: String { rawValue }
}

enum ModelFallbackStrategy: String, Codable, CaseIterable, Identifiable {
    case off = "Off"
    case transient = "Connection errors"
    case anyError = "Any provider error"

    var id: String { rawValue }
}

enum PrivacyRedactor {
    /// Masks common secret-bearing assignments and JSON fields before tool output
    /// is added to model-visible history. The original local file is untouched.
    static func redact(_ text: String) -> String {
        var result = text
        let patterns = [
            #"(?im)\b([A-Z][A-Z0-9_]*(?:TOKEN|SECRET|PASSWORD|API_KEY|PRIVATE_KEY)[A-Z0-9_]*)\s*=\s*([^\s"'`]+|"[^"]*"|'[^']*')"#,
            #"(?i)("(?:token|secret|password|api[_-]?key|private[_-]?key)"\s*:\s*)"[^"]*""#,
            #"(?i)\b(Bearer)\s+[A-Za-z0-9._~+/=-]{8,}"#,
            #"\b(?:sk|ghp|github_pat)_[A-Za-z0-9_]{12,}\b"#,
        ]
        let replacements = [
            "$1=[REDACTED]",
            "$1\"[REDACTED]\"",
            "$1 [REDACTED]",
            "[REDACTED]",
        ]
        for (pattern, replacement) in zip(patterns, replacements) {
            result = result.replacingOccurrences(
                of: pattern,
                with: replacement,
                options: .regularExpression
            )
        }
        return result
    }
}

struct ModelCapability: Equatable {
    var contextTokens: Int
    var outputReserveTokens: Int
    var supportsVision: Bool
    var supportsReasoningPreference: Bool

    var safeInputTokens: Int {
        max(4_096, Int(Double(contextTokens) * 0.82) - outputReserveTokens)
    }
}

enum ModelCapabilityRegistry {
    /// Conservative local metadata. Provider catalogs expose model identifiers but
    /// not a consistent cross-provider capability schema, so unknown models use a
    /// deliberately modest budget and are compacted earlier rather than later.
    static func capability(providerID: String, modelID: String) -> ModelCapability {
        let model = modelID.lowercased()

        if providerID == "ondevice",
           let local = OnDeviceModelCatalog.model(id: modelID) {
            return ModelCapability(
                contextTokens: local.contextTokens,
                outputReserveTokens: 1_024,
                supportsVision: false,
                supportsReasoningPreference: true
            )
        }

        if model.contains("claude") {
            return ModelCapability(
                contextTokens: 200_000,
                outputReserveTokens: 16_384,
                supportsVision: true,
                supportsReasoningPreference: true
            )
        }

        if model.contains("gemini") {
            return ModelCapability(
                contextTokens: 1_000_000,
                outputReserveTokens: 16_384,
                supportsVision: true,
                supportsReasoningPreference: true
            )
        }

        if model.contains("deepseek") {
            return ModelCapability(
                contextTokens: 128_000,
                outputReserveTokens: 8_192,
                supportsVision: false,
                supportsReasoningPreference: model.contains("reasoner") || model.contains("v4")
            )
        }

        if model.contains("gpt-5") || model.contains("gpt-4.1")
            || model.contains("o3") || model.contains("o4") {
            return ModelCapability(
                contextTokens: 128_000,
                outputReserveTokens: 16_384,
                supportsVision: true,
                supportsReasoningPreference: true
            )
        }

        return ModelCapability(
            contextTokens: 64_000,
            outputReserveTokens: 8_192,
            supportsVision: true,
            supportsReasoningPreference: false
        )
    }
}

struct ContextPreparation {
    var messages: [LLMMessage]
    var estimatedTokensBefore: Int
    var estimatedTokensAfter: Int
    var didCompact: Bool
}

enum ContextBudgeter {
    private static let recentMessageFloor = 10
    private static let compactedToolLimit = 900

    static func prepare(
        _ messages: [LLMMessage],
        capability: ModelCapability
    ) -> ContextPreparation {
        let before = estimatedTokens(in: messages)
        guard before > capability.safeInputTokens else {
            return ContextPreparation(
                messages: messages,
                estimatedTokensBefore: before,
                estimatedTokensAfter: before,
                didCompact: false
            )
        }

        var prepared = messages
        let oldBoundary = max(1, prepared.count - recentMessageFloor)

        // First tier: offload bulky, old tool payloads while retaining the call
        // result's identity and both edges, which commonly contain the useful
        // path/status information.
        for index in prepared.indices where index < oldBoundary && prepared[index].role == "tool" {
            guard let content = prepared[index].content,
                  content.count > compactedToolLimit else { continue }
            prepared[index].content = compact(content, limit: compactedToolLimit)
        }

        if estimatedTokens(in: prepared) > capability.safeInputTokens {
            prepared = checkpointed(prepared, targetTokens: capability.safeInputTokens)
        }

        // Final tier: compact remaining large tool results. This only activates
        // for unusually large recent reads and preserves provider tool pairing.
        if estimatedTokens(in: prepared) > capability.safeInputTokens {
            for index in prepared.indices where prepared[index].role == "tool" {
                guard let content = prepared[index].content,
                      content.count > compactedToolLimit else { continue }
                prepared[index].content = compact(content, limit: compactedToolLimit)
            }
        }

        let after = estimatedTokens(in: prepared)
        return ContextPreparation(
            messages: prepared,
            estimatedTokensBefore: before,
            estimatedTokensAfter: after,
            didCompact: after < before
        )
    }

    static func estimatedTokens(in messages: [LLMMessage]) -> Int {
        messages.reduce(0) { partial, message in
            var bytes = message.content?.utf8.count ?? 0
            bytes += message.images?.reduce(0) { $0 + $1.base64.utf8.count } ?? 0
            bytes += message.toolCalls?.reduce(0) {
                $0 + $1.name.utf8.count + $1.argumentsJSON.utf8.count
            } ?? 0
            return partial + max(1, bytes / 4) + 8
        }
    }

    private static func checkpointed(
        _ messages: [LLMMessage],
        targetTokens: Int
    ) -> [LLMMessage] {
        guard messages.count > recentMessageFloor else { return messages }

        let system = messages.first(where: { $0.role == "system" })
        var recentStart = max(1, messages.count - recentMessageFloor)
        while recentStart < messages.count && messages[recentStart].role != "user" {
            recentStart += 1
        }
        guard recentStart < messages.count else { return messages }

        let older = messages[1..<recentStart]
        var checkpointLines: [String] = []
        for message in older {
            guard message.role == "user" || message.role == "assistant",
                  let content = message.content?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !content.isEmpty else { continue }
            let label = message.role == "user" ? "User goal" : "Agent outcome"
            checkpointLines.append("- \(label): \(singleLine(content, limit: 360))")
        }

        var result: [LLMMessage] = []
        if let system { result.append(system) }
        if !checkpointLines.isEmpty {
            result.append(.system("""
                Earlier conversation checkpoint (extractive; detailed tool payloads were offloaded):
                \(checkpointLines.suffix(12).joined(separator: "\n"))
                """))
        }
        result.append(contentsOf: messages[recentStart...])

        // Remove complete oldest user-led groups until the request fits. Never
        // start at an assistant/tool message, preserving provider history shape.
        while estimatedTokens(in: result) > targetTokens {
            guard let firstUser = result.indices.dropFirst().first(where: { result[$0].role == "user" }),
                  let nextUser = result.indices.dropFirst(firstUser + 1).first(where: { result[$0].role == "user" }),
                  nextUser < result.count - 1 else { break }
            result.removeSubrange(firstUser..<nextUser)
        }
        return result
    }

    private static func compact(_ text: String, limit: Int) -> String {
        guard text.count > limit else { return text }
        let headCount = Int(Double(limit) * 0.65)
        let tailCount = max(80, limit - headCount)
        return String(text.prefix(headCount))
            + "\n\n[… older tool output offloaded for context safety …]\n\n"
            + String(text.suffix(tailCount))
    }

    private static func singleLine(_ text: String, limit: Int) -> String {
        let flattened = text
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\t", with: " ")
        return flattened.count <= limit
            ? flattened
            : String(flattened.prefix(limit)) + "…"
    }
}

struct ToolLoopDetector {
    private var fingerprints: [String] = []
    private let historyLimit = 8

    mutating func record(
        call: LLMToolCall,
        resultPayload: String,
        succeeded: Bool
    ) -> String? {
        let normalizedArguments = call.argumentsJSON
            .replacingOccurrences(of: "\\s+", with: "", options: .regularExpression)
        let resultSignature = String(resultPayload.prefix(240))
        let fingerprint = "\(call.name)|\(normalizedArguments)|\(succeeded)|\(resultSignature)"
        fingerprints.append(fingerprint)
        if fingerprints.count > historyLimit {
            fingerprints.removeFirst(fingerprints.count - historyLimit)
        }

        if fingerprints.count >= 3,
           fingerprints.suffix(3).allSatisfy({ $0 == fingerprint }) {
            return "Stopped a repeated \(call.name) loop after the same call returned the same result three times."
        }

        if fingerprints.count >= 6 {
            let tail = Array(fingerprints.suffix(6))
            if tail[0] == tail[2], tail[2] == tail[4],
               tail[1] == tail[3], tail[3] == tail[5],
               tail[0] != tail[1] {
                return "Stopped an oscillating tool loop that repeated the same two actions three times."
            }
        }
        return nil
    }
}
