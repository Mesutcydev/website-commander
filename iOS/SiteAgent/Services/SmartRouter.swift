import Foundation

enum RoutingStrategy: String, Codable, CaseIterable, Identifiable {
    case budget = "Budget Mode (DeepSeek)"
    case quality = "Quality Mode (Claude)"
    case codeEdition = "Code Mode (Copilot)"

    var id: String { rawValue }
}

enum TaskDifficulty: String, Equatable {
    case quickFix
    case planning
    case bulkUpdates
}

struct SmartRoute: Equatable {
    let providerID: String
    let modelID: String
    let task: TaskDifficulty
    let reason: String
}

final class SmartRouter {
    static let shared = SmartRouter()
    private init() {}

    private struct Candidate {
        let providerID: String
        let modelID: String
        let isAvailable: Bool
        let quality: Int
        let coding: Int
        let planning: Int
        let bulk: Int
        let speed: Int
        let economy: Int
        let vision: Bool
    }

    /// Uses task language as well as size. A short “audit the whole repo” request
    /// is broad work; a long pasted error can still be a focused fix.
    func classifyTask(prompt: String) -> TaskDifficulty {
        let text = prompt.lowercased()
        let bulkSignals = [
            "all files", "whole site", "entire site", "entire repo", "across the",
            "every page", "all pages", "migrate", "large refactor", "bulk", "codebase-wide"
        ]
        if bulkSignals.contains(where: text.contains) || prompt.count >= 1_200 {
            return .bulkUpdates
        }

        let planningSignals = [
            "plan", "architecture", "architect", "audit", "analyze", "analyse",
            "review", "strategy", "investigate", "compare", "recommend", "seo"
        ]
        if planningSignals.contains(where: text.contains) || prompt.count >= 500 {
            return .planning
        }
        return .quickFix
    }

    /// Scores every configured provider instead of walking a fixed fallback
    /// chain. The strategy supplies the main preference and task signals adjust
    /// it for broad changes, planning/audits, speed, and image input.
    func selectModel(
        strategy: RoutingStrategy,
        prompt: String,
        needsVision: Bool,
        hasClaude: Bool,
        hasCopilot: Bool,
        hasDeepSeek: Bool,
        hasOpenAI: Bool,
        hasGemini: Bool = false,
        hasGrok: Bool = false,
        hasMistral: Bool = false,
        hasOpenCode: Bool = false,
        hasOpenRouter: Bool = false,
        hasGroq: Bool = false,
        hasQwenCode: Bool = false,
        hasKimiCode: Bool = false,
        preferredModels: [String: String] = [:]
    ) -> SmartRoute {
        let task = classifyTask(prompt: prompt)
        let candidates = [
            Candidate(providerID: "anthropic", modelID: task == .planning ? "claude-opus-4-8" : "claude-sonnet-4-6", isAvailable: hasClaude, quality: 10, coding: 9, planning: 10, bulk: 9, speed: 5, economy: 3, vision: true),
            Candidate(providerID: "openai", modelID: "gpt-5.4", isAvailable: hasOpenAI, quality: 9, coding: 9, planning: 9, bulk: 9, speed: 6, economy: 3, vision: true),
            Candidate(providerID: "grok", modelID: "grok-4.5", isAvailable: hasGrok, quality: 9, coding: 10, planning: 9, bulk: 9, speed: 7, economy: 5, vision: true),
            Candidate(providerID: "gemini", modelID: task == .quickFix ? "gemini-3.5-flash" : "gemini-3.1-pro-preview", isAvailable: hasGemini, quality: 8, coding: 8, planning: 9, bulk: 10, speed: 8, economy: 7, vision: true),
            Candidate(providerID: "copilot", modelID: task == .quickFix ? "gpt-5-mini" : "claude-sonnet-4.5", isAvailable: hasCopilot, quality: 8, coding: 9, planning: 8, bulk: 8, speed: 8, economy: 10, vision: true),
            Candidate(providerID: "qwen-code", modelID: "qwen3-coder-plus", isAvailable: hasQwenCode, quality: 8, coding: 10, planning: 7, bulk: 9, speed: 7, economy: 8, vision: false),
            Candidate(providerID: "kimi-code", modelID: "kimi-for-coding", isAvailable: hasKimiCode, quality: 8, coding: 9, planning: 8, bulk: 9, speed: 7, economy: 8, vision: false),
            Candidate(providerID: "deepseek", modelID: "deepseek-v4-flash", isAvailable: hasDeepSeek, quality: 7, coding: 9, planning: 7, bulk: 8, speed: 9, economy: 10, vision: false),
            // Keep the fallback inside the current OpenCode Go catalog. The
            // old qwen2.5-coder-32b id was retired and could be selected when
            // Smart Routing had no saved model preference.
            Candidate(providerID: "opencode", modelID: "qwen3.7-plus", isAvailable: hasOpenCode, quality: 7, coding: 9, planning: 6, bulk: 8, speed: 8, economy: 10, vision: false),
            Candidate(providerID: "mistral", modelID: task == .quickFix ? "mistral-small-latest" : "mistral-large-latest", isAvailable: hasMistral, quality: 7, coding: 7, planning: 7, bulk: 8, speed: 8, economy: 7, vision: false),
            Candidate(providerID: "groq", modelID: "llama-3.3-70b-versatile", isAvailable: hasGroq, quality: 6, coding: 6, planning: 5, bulk: 5, speed: 10, economy: 9, vision: false),
            Candidate(providerID: "openrouter", modelID: strategy == .budget ? "openai/gpt-4o-mini" : "anthropic/claude-sonnet-4", isAvailable: hasOpenRouter, quality: 7, coding: 7, planning: 7, bulk: 7, speed: 7, economy: 6, vision: true)
        ]

        let eligible = candidates.filter { $0.isAvailable && (!needsVision || $0.vision) }
        let pool = eligible.isEmpty ? candidates.filter(\.isAvailable) : eligible
        let winner = pool.max { score($0, strategy: strategy, task: task) < score($1, strategy: strategy, task: task) }
            ?? Candidate(providerID: "copilot", modelID: "claude-sonnet-4.5", isAvailable: true, quality: 8, coding: 9, planning: 8, bulk: 8, speed: 8, economy: 10, vision: true)

        return SmartRoute(
            providerID: winner.providerID,
            modelID: preferredModels[winner.providerID] ?? winner.modelID,
            task: task,
            reason: routeReason(strategy: strategy, task: task, needsVision: needsVision)
        )
    }

    private func score(_ candidate: Candidate, strategy: RoutingStrategy, task: TaskDifficulty) -> Int {
        var value: Int
        switch strategy {
        case .budget:
            value = candidate.economy * 5 + candidate.speed * 2 + candidate.coding
        case .quality:
            value = candidate.quality * 5 + candidate.planning * 2 + candidate.coding
        case .codeEdition:
            value = candidate.coding * 5 + candidate.quality * 2 + candidate.speed
        }

        switch task {
        case .quickFix:
            value += candidate.speed * 2
        case .planning:
            value += candidate.planning * 4 + candidate.quality * 2
        case .bulkUpdates:
            value += candidate.bulk * 4 + candidate.coding * 2
        }
        return value
    }

    private func routeReason(strategy: RoutingStrategy, task: TaskDifficulty, needsVision: Bool) -> String {
        var parts = [strategy.rawValue, task.rawValue]
        if needsVision { parts.append("image input") }
        return parts.joined(separator: " · ")
    }
}
