import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

// MARK: - Apple Foundation Models providers
//
// Two SiteAgent `LLMProvider`s backed by Apple's Foundation Models framework:
//   • Apple On-Device  — SystemLanguageModel. Free, private, offline.
//   • Apple Private Cloud — PrivateCloudComputeLanguageModel, with selectable
//     reasoning via ContextOptions.ReasoningLevel + real quota/availability.
//
// They conform to the existing `LLMProvider` protocol, so they appear in the
// normal model picker / smart router with no new UI plumbing. No API key, no
// developer backend (handoff rules 3–4). Everything is `@available(iOS 27)`-gated
// so the app's iOS 17 floor and every existing provider keep working untouched.
//
// Gated at iOS 27 (not 26) on purpose: the unified, generic `LanguageModelSession`
// init and the `ContextOptions` reasoning API are iOS 27. On iOS 26 the on-device
// model exists but only via the concrete-typed init with no reasoning — a separate
// code path we skip for now (the target devices are iOS 27 / macOS 27).
//
// ponytail: tools are intentionally NOT bridged. The framework owns its own tool
// loop (the `Tool` protocol with compile-time `Arguments`), which can't drive
// SiteAgent's dynamic, runtime-defined tools without passing executors into the
// provider. So Apple models answer from the conversation context in a single
// turn — ideal for their positioned light tasks (commit messages, summaries,
// explanations, ASK with attached context). Multi-step file editing stays on the
// existing tool-using providers (Claude/Copilot/etc.).

enum AppleModelID {
    static let onDevice = "apple-ondevice"
    static let privateCloud = "apple-pcc"
    static let auto = "apple-auto"
}

// Gated behind the APPLE_FM compile flag so the app still builds without
// FoundationModels. Real PCC symbols are additionally gated behind APPLE_PCC_SDK
// so stable-Xcode builds never parse APIs that only exist in the iOS 27 SDK.
#if APPLE_FM

// AppleModelError is now defined in UnavailablePrivateCloudComputeProvider.swift to avoid duplicate symbols.

// MARK: On-Device

/// Apple's on-device model. Free, private, offline; no key.
struct AppleOnDeviceProvider: LLMProvider {
    let id = AppleModelID.onDevice
    let displayName = "Apple On-Device"
    let models = ["On-Device"]
    let defaultModel = "On-Device"

    func capabilities(for model: String) -> ModelCapabilities {
        ModelCapabilities.textOnly(supportsTools: false)
    }

    func fetchAvailableModels() async throws -> [String]? { nil }

    func complete(messages: [LLMMessage], tools: [ToolSpec], model: String) async throws -> LLMResponse {
        try await stream(messages: messages, tools: tools, model: model,
                         onActivity: { _ in }, onText: { _ in })
    }

    func stream(messages: [LLMMessage], tools: [ToolSpec], model: String,
                onActivity: @escaping (LLMStreamActivity) -> Void,
                onText: @escaping (String) -> Void) async throws -> LLMResponse {
        #if canImport(FoundationModels)
        if #available(iOS 27, macOS 27, *) {
            guard SystemLanguageModel.default.isAvailable else {
                throw AppleModelError.unavailable(AppleModels.onDeviceStatus)
            }
            return try await AppleModelRunner.run(model: SystemLanguageModel.default,
                                                  messages: messages,
                                                  maxPromptChars: AppleModelRunner.onDeviceMaxPromptChars,
                                                  maxInstructionsChars: AppleModelRunner.onDeviceMaxInstructionsChars,
                                                  maxStreamSeconds: AppleModelRunner.onDeviceStreamTimeoutSeconds,
                                                  onActivity: onActivity,
                                                  onText: onText)
        }
        #endif
        throw AppleModelError.unavailable("Apple On-Device requires iOS 27 with Apple Intelligence enabled.")
    }
}

#if canImport(FoundationModels) && APPLE_PCC_SDK

// MARK: Private Cloud Compute

/// Apple Private Cloud Compute model. Reasoning level is chosen via the standard
/// model picker (the "models" list doubles as the reasoning picker, handoff §11),
/// and real quota/availability come from the framework.
@available(iOS 27, macOS 27, *)
struct ApplePrivateCloudProvider: LLMProvider {
    let id = AppleModelID.privateCloud
    let displayName = "Apple Private Cloud — Beta"
    let models = ["Automatic", "Light", "Moderate", "Deep"]
    let defaultModel = "Automatic"

    func capabilities(for model: String) -> ModelCapabilities {
        ModelCapabilities.textOnly(supportsTools: false)
    }

    func fetchAvailableModels() async throws -> [String]? { nil }

    func complete(messages: [LLMMessage], tools: [ToolSpec], model: String) async throws -> LLMResponse {
        try await stream(messages: messages, tools: tools, model: model,
                         onActivity: { _ in }, onText: { _ in })
    }

    func stream(messages: [LLMMessage], tools: [ToolSpec], model: String,
                onActivity: @escaping (LLMStreamActivity) -> Void,
                onText: @escaping (String) -> Void) async throws -> LLMResponse {
        let pcc = PrivateCloudComputeLanguageModel()
        guard pcc.isAvailable else {
            throw AppleModelError.unavailable(AppleModels.privateCloudStatus)
        }
        return try await AppleModelRunner.run(model: pcc, messages: messages,
                                              reasoning: AppleModels.reasoning(for: model),
                                              maxPromptChars: AppleModelRunner.privateCloudMaxPromptChars,
                                              maxInstructionsChars: AppleModelRunner.privateCloudMaxInstructionsChars,
                                              maxStreamSeconds: AppleModelRunner.privateCloudStreamTimeoutSeconds,
                                              onActivity: onActivity,
                                              onText: onText)
    }
}

// MARK: Automatic (on-device ↔ PCC)

/// Routes each request to the best Apple model: on-device for small/quick turns,
/// Private Cloud for large context, with on-device fallback when PCC is
/// unavailable or over quota (handoff §4C). The chosen sub-model actually runs;
/// the picker shows "Apple (Automatic)".
@available(iOS 27, macOS 27, *)
struct AppleAutoProvider: LLMProvider {
    let id = AppleModelID.auto
    let displayName = "Apple (Automatic)"
    let models = ["Automatic"]
    let defaultModel = "Automatic"

    func capabilities(for model: String) -> ModelCapabilities {
        ModelCapabilities.textOnly(supportsTools: false)
    }

    /// Rough context-size threshold (chars) above which we prefer Private Cloud.
    private let heavyContextChars = 6000

    func fetchAvailableModels() async throws -> [String]? { nil }

    func complete(messages: [LLMMessage], tools: [ToolSpec], model: String) async throws -> LLMResponse {
        try await stream(messages: messages, tools: tools, model: model,
                         onActivity: { _ in }, onText: { _ in })
    }

    func stream(messages: [LLMMessage], tools: [ToolSpec], model: String,
                onActivity: @escaping (LLMStreamActivity) -> Void,
                onText: @escaping (String) -> Void) async throws -> LLMResponse {
        let approxChars = messages.reduce(0) { $0 + ($1.content?.count ?? 0) }
        let heavy = approxChars > heavyContextChars
        // One PCC instance per request: the availability we check is the instance
        // we run (and we avoid constructing it two or three times per turn).
        let pcc = PrivateCloudComputeLanguageModel()
        let pccOK = pcc.isAvailable && AppleModels.privateCloudBelowQuota
        let onDeviceOK = SystemLanguageModel.default.isAvailable

        // Heavy + PCC ready → PCC. Otherwise on-device. PCC as last resort if
        // on-device can't serve. (handoff §4C routing table.)
        if heavy && pccOK {
            return try await AppleModelRunner.run(model: pcc,
                                                  messages: messages, reasoning: .moderate,
                                                  maxPromptChars: AppleModelRunner.privateCloudMaxPromptChars,
                                                  maxInstructionsChars: AppleModelRunner.privateCloudMaxInstructionsChars,
                                                  maxStreamSeconds: AppleModelRunner.privateCloudStreamTimeoutSeconds,
                                                  onActivity: onActivity,
                                                  onText: onText)
        }
        if onDeviceOK {
            return try await AppleModelRunner.run(model: SystemLanguageModel.default,
                                                  messages: messages,
                                                  maxPromptChars: AppleModelRunner.onDeviceMaxPromptChars,
                                                  maxInstructionsChars: AppleModelRunner.onDeviceMaxInstructionsChars,
                                                  maxStreamSeconds: AppleModelRunner.onDeviceStreamTimeoutSeconds,
                                                  onActivity: onActivity,
                                                  onText: onText)
        }
        if pccOK {
            return try await AppleModelRunner.run(model: pcc,
                                                  messages: messages, reasoning: nil,
                                                  maxPromptChars: AppleModelRunner.privateCloudMaxPromptChars,
                                                  maxInstructionsChars: AppleModelRunner.privateCloudMaxInstructionsChars,
                                                  maxStreamSeconds: AppleModelRunner.privateCloudStreamTimeoutSeconds,
                                                  onActivity: onActivity,
                                                  onText: onText)
        }
        throw AppleModelError.unavailable(AppleModels.onDeviceStatus)
    }
}

#endif // canImport(FoundationModels) && APPLE_PCC_SDK

// MARK: - Shared runner

#if canImport(FoundationModels)
@available(iOS 27, macOS 27, *)
enum AppleModelRunner {
    /// Drives one turn through a Foundation Models session and streams cumulative
    /// text back. Stateless per call (a fresh session each time) to match how
    /// SiteAgent hands the full message history to a provider on every loop turn.
    ///
    /// `maxPromptChars` caps the conversation actually sent: the on-device model
    /// has a small (~4k-token) context window, and SiteAgent's full coding-agent
    /// history overflows it after a couple turns — which in the beta stalls the
    /// session instead of erroring (the "stuck after 1–2 tasks" symptom). We keep
    /// the most recent turns within the cap so the window is never exceeded.
    static func run<Model: LanguageModel>(model: Model,
                                          messages: [LLMMessage],
                                          reasoning: ContextOptions.ReasoningLevel? = nil,
                                          maxPromptChars: Int,
                                          maxInstructionsChars: Int,
                                          maxStreamSeconds: Int,
                                          onActivity: @escaping (LLMStreamActivity) -> Void,
                                          onText: @escaping (String) -> Void) async throws -> LLMResponse {
        let (instructions, prompt) = serialize(messages,
                                               maxPromptChars: maxPromptChars,
                                               maxInstructionsChars: maxInstructionsChars)
        let session = LanguageModelSession(model: model, instructions: instructions)
        onActivity(.connected)

        // The Foundation Models beta can stall silently when the context window
        // overflows — `streamResponse` just stops yielding instead of erroring.
        // A naive `for try await` then hangs forever, latching `isRunning` in the
        // engine and making Stop ineffective (cancellation only checks between
        // yields, which never arrive). We race the stream against a hard timeout
        // so a stall throws and the engine's `finishRun` actually runs. The
        // stream runs in an unstructured task so a timeout can abandon it
        // immediately instead of waiting for the hung iterator to unwind.
        let streamTask = Task {
            var local = ""
            let stream = session.streamResponse(to: prompt,
                                                options: GenerationOptions(),
                                                contextOptions: ContextOptions(reasoningLevel: reasoning))
            for try await partial in stream {
                try Task.checkCancellation()
                local = partial.content        // cumulative snapshot for String content
                onText(local)
            }
            return local
        }

        let timedOut: Bool
        do {
            timedOut = try await withThrowingTaskGroup(of: Bool.self) { group in
                group.addTask { _ = try await streamTask.value; return false }
                group.addTask {
                    try await Task.sleep(nanoseconds: UInt64(maxStreamSeconds) * 1_000_000_000)
                    return true
                }
                let first = try await group.next() ?? false
                group.cancelAll()
                return first
            }
        } catch is CancellationError {
            streamTask.cancel()
            throw CancellationError()
        } catch {
            // The streaming response parser in the Foundation Models beta can throw
            // "failed to parse the generated content" (GenerationError.decodingFailure)
            // on otherwise valid prompts. Retry once non-streaming — `respond` uses a
            // different code path and usually succeeds where the stream parser fails.
            streamTask.cancel()
            do {
                let response = try await session.respond(to: prompt,
                                                         options: GenerationOptions(),
                                                         contextOptions: ContextOptions(reasoningLevel: reasoning))
                onText(response.content)
                return LLMResponse(content: response.content, toolCalls: [], usage: nil)
            } catch is CancellationError {
                throw CancellationError()
            } catch let retryError {
                throw AppleModelError.unavailable(Self.describe(retryError))
            }
        }

        if timedOut {
            streamTask.cancel()
            throw AppleModelError.unavailable(
                "The model stalled — likely a context overflow. Try a shorter prompt or clear the conversation.")
        }
        let last = try await streamTask.value
        return LLMResponse(content: last, toolCalls: [], usage: nil)
    }

    /// Turn a Foundation Models error into a clear, actionable message instead of
    /// the raw "failed to parse the generated content".
    private static func describe(_ error: Error) -> String {
        let d = error.localizedDescription.lowercased()
        if d.contains("parse") || d.contains("decod") {
            return "The model couldn't produce a usable response for this prompt. Try rephrasing, shortening the conversation, or switching models."
        }
        if d.contains("context") || d.contains("window") || d.contains("exceed") {
            return "The conversation is too long for this model. Clear the chat or start a new conversation."
        }
        if d.contains("guardrail") || d.contains("safety") {
            return "The model declined to respond to this request."
        }
        return "The model couldn't complete a response: \(error.localizedDescription)"
    }

    /// Map SiteAgent's role-tagged messages onto (instructions, prompt): system
    /// turns become session instructions; the rest become a readable transcript,
    /// trimmed from the most recent backwards so it fits the model's window.
    private static func serialize(_ messages: [LLMMessage],
                                  maxPromptChars: Int,
                                  maxInstructionsChars: Int) -> (String?, String) {
        // System turns become session instructions — also capped, since the
        // on-device window is shared between instructions + prompt + response.
        // An uncapped system prompt (rules + repo structure + custom rules) can
        // overflow on its own once the workspace context loads, which was the
        // primary remaining stall path after the prompt-only cap.
        let systemRaw = messages.filter { $0.role == "system" }
            .compactMap { $0.content }.joined(separator: "\n\n")
        let system: String? = systemRaw.isEmpty
            ? nil
            : (systemRaw.count > maxInstructionsChars
                ? String(systemRaw.prefix(maxInstructionsChars))
                    + "\n\n[...system instructions truncated to fit the model window...]"
                : systemRaw)

        var lines: [String] = []
        var used = 0
        for m in messages.reversed() where m.role != "system" {
            guard let c = m.content, !c.isEmpty else { continue }
            var line: String
            switch m.role {
            case "user":      line = "User: \(c)"
            case "assistant": line = "Assistant: \(c)"
            case "tool":      line = "Tool result (\(m.name ?? "tool")): \(c)"
            default:          line = c
            }
            // Truncate an over-long single turn so even the latest message can't
            // blow the window on its own (previously the "always keep latest"
            // rule let a huge paste exceed the cap in full).
            if line.count > maxPromptChars {
                line = String(line.prefix(maxPromptChars))
                    + "\n[...truncated to fit the model window...]"
            }
            // Always keep at least the latest turn, then stop once the cap is hit.
            if used + line.count > maxPromptChars && !lines.isEmpty { break }
            lines.insert(line, at: 0)
            used += line.count
        }
        let prompt = lines.isEmpty ? " " : lines.joined(separator: "\n\n")
        return (system, prompt)
    }

    /// Conservative per-model caps (chars). On-device window is small (~4k
    /// tokens shared across instructions + prompt + response); PCC is much
    /// larger. Instructions are capped separately so the system prompt (rules
    /// + repo structure + custom rules) can't overflow the window on its own.
    static let onDeviceMaxPromptChars = 6000
    static let onDeviceMaxInstructionsChars = 2000
    static let privateCloudMaxPromptChars = 40000
    static let privateCloudMaxInstructionsChars = 8000
    /// Hard stream timeout (seconds). The Foundation Models beta can stall
    /// silently on overflow; this turns a stall into a thrown error so the
    /// engine's `finishRun` runs and `isRunning` doesn't latch. PCC gets a
    /// longer budget because network + reasoning legitimately take longer.
    static let onDeviceStreamTimeoutSeconds = 90
    static let privateCloudStreamTimeoutSeconds = 180
}
#endif

// MARK: - Availability / quota façade (UI + routing read this)

/// Single source of truth for whether the Apple models are usable and why not,
/// plus reasoning mapping. Safe on any OS — returns false/`nil` when the
/// framework or a capable OS isn't present.
enum AppleModels {

    static var onDeviceAvailable: Bool {
        #if canImport(FoundationModels)
        if #available(iOS 27, macOS 27, *) { return SystemLanguageModel.default.isAvailable }
        #endif
        return false
    }

    static var privateCloudAvailable: Bool {
        #if canImport(FoundationModels)
        #if APPLE_PCC_SDK
        if #available(iOS 27, macOS 27, *) { return PrivateCloudComputeLanguageModel().isAvailable }
        #endif
        #endif
        return false
    }

    /// True when PCC is available AND today's quota isn't exhausted.
    static var privateCloudBelowQuota: Bool {
        #if canImport(FoundationModels)
        #if APPLE_PCC_SDK
        if #available(iOS 27, macOS 27, *) {
            let pcc = PrivateCloudComputeLanguageModel()
            guard pcc.isAvailable else { return false }
            if case .belowLimit = pcc.quotaUsage.status { return true }
            return false
        }
        #endif
        #endif
        return false
    }

    /// Human-readable reason the on-device model isn't ready (for the picker).
    static var onDeviceStatus: String {
        #if canImport(FoundationModels)
        if #available(iOS 27, macOS 27, *) {
            switch SystemLanguageModel.default.availability {
            case .available: return "Ready"
            case .unavailable(let reason):
                switch reason {
                case .deviceNotEligible: return "This device doesn't support Apple Intelligence."
                case .appleIntelligenceNotEnabled: return "Turn on Apple Intelligence in Settings."
                case .modelNotReady: return "The model is still downloading — try again shortly."
                @unknown default: return "Unavailable."
                }
            }
        }
        #endif
        return "Requires iOS 27 or later."
    }

    /// PCC status incl. quota (handoff §23).
    static var privateCloudStatus: String {
        #if canImport(FoundationModels)
        #if APPLE_PCC_SDK
        if #available(iOS 27, macOS 27, *) {
            let pcc = PrivateCloudComputeLanguageModel()
            switch pcc.availability {
            case .available:
                switch pcc.quotaUsage.status {
                case .belowLimit: return "Ready"
                case .limitReached: return "Today's Apple Private Cloud limit has been reached."
                @unknown default: return "Ready"
                }
            case .unavailable(let reason):
                switch reason {
                case .deviceNotEligible: return "This device doesn't support Apple Private Cloud."
                case .systemNotReady: return "Apple Private Cloud isn't ready yet — try again shortly."
                @unknown default: return "Apple Private Cloud is unavailable right now."
                }
            }
        }
        #endif
        #endif
        return "Requires iOS 27 or later."
    }

    #if canImport(FoundationModels) && APPLE_PCC_SDK
    /// Map a PCC picker entry to a reasoning level. "Automatic" → nil (framework default).
    @available(iOS 27, macOS 27, *)
    static func reasoning(for model: String) -> ContextOptions.ReasoningLevel? {
        switch model.lowercased() {
        case "light":    return .light
        case "moderate": return .moderate
        case "deep":     return .deep
        default:         return nil
        }
    }
    #endif
}

#endif  // APPLE_FM
