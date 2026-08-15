import Foundation
import SwiftUI
import os
import UIKit
import MLX
import MLXLLM
import MLXLMCommon
import MLXLMTransformers   // provides the loadContainer(from:configuration:) overload

/// First touch of the MLX GPU constructs a Metal device, which calls abort() on
/// the Simulator (it has no GPU MLX can bind to). Routing every app-side cache
/// clear through here keeps the app navigable in the Simulator; on device it
/// compiles straight to `Memory.clearCache()`.
@inline(__always)
func mlxClearCache() {
    #if !targetEnvironment(simulator)
    Memory.clearCache()
    #endif
}

/// iOS kills an app at its jetsam high-water mark even when the phone has more
/// physical RAM available. MLX otherwise sizes its reusable buffer cache from
/// Metal's much larger recommended working set, which can push a 4-bit 4B model
/// over that process limit during first-run kernel compilation and prefill.
enum OnDeviceMemoryBudget {
    static let mlxCacheBytes = 20 * 1024 * 1024
    // iOS 27 beta can abort the process from MLX's Metal completion handler
    // (rather than returning a Swift error) when Qwen3 prefill peaks too high.
    // Small chunks trade some prompt-processing speed for a much lower,
    // predictable activation footprint on physical iPhones.
    static let prefillChunkTokens = 32
    // The working prompt is capped at 8K. Rotate beyond that during decode
    // instead of reserving an unnecessary 12K attention cache.
    static let maxKVTokens = 8_192
}

@inline(__always)
func mlxConfigureMemoryBudget() {
    #if !targetEnvironment(simulator)
    Memory.cacheLimit = OnDeviceMemoryBudget.mlxCacheBytes
    #endif
}

/// A Sendable conversation turn. The MLX `[Chat.Message]` is **not** Sendable,
/// so we never build it outside the generation closure — we pass these across
/// the actor boundary and map to `Chat.Message` at the use site instead.
struct OnDeviceTurn: Sendable {
    let role: String       // "system" | "user" | "assistant"
    let content: String
}

// MARK: - OnDeviceContextBudget

/// Enforces a genuinely tokenized 8K working prompt. System instructions stay
/// pinned, older user-task segments are removed first, and tool call/result
/// pairs are kept atomic so the model never sees an orphaned tool result.
enum OnDeviceContextBudget {
    static let maxInputTokens = 8_192
    private static let compactionFloor = 512

    static func removingOldestRound(from turns: [OnDeviceTurn]) -> [OnDeviceTurn]? {
        let plainUsers = turns.indices.filter {
            turns[$0].role == "user" && !isToolResult(turns[$0])
        }

        if plainUsers.count > 1 {
            let removal = plainUsers[0]..<plainUsers[1]
            return turns.enumerated().compactMap { index, turn in
                removal.contains(index) && turn.role != "system" ? nil : turn
            }
        }

        let anchor = plainUsers.last
        var groups: [Range<Int>] = []
        var index = anchor.map { $0 + 1 } ?? 0
        while index < turns.count {
            if turns[index].role == "system" {
                index += 1
            } else if isToolCall(turns[index]), index + 1 < turns.count,
                      isToolResult(turns[index + 1]) {
                groups.append(index..<(index + 2))
                index += 2
            } else {
                groups.append(index..<(index + 1))
                index += 1
            }
        }

        // Retain the newest complete round. If it alone is oversized, compact
        // its largest payload while preserving both edges and its structure.
        guard groups.count > 1, let removal = groups.first else { return nil }
        return turns.enumerated().compactMap { removal.contains($0.offset) ? nil : $0.element }
    }

    static func compactingLargestTurn(in turns: [OnDeviceTurn]) -> [OnDeviceTurn]? {
        let candidates = turns.indices.filter { turns[$0].content.count > compactionFloor }
        guard let index = candidates.max(by: {
            let lhsPenalty = turns[$0].role == "system" ? 0 : 1
            let rhsPenalty = turns[$1].role == "system" ? 0 : 1
            return (lhsPenalty, turns[$0].content.count) < (rhsPenalty, turns[$1].content.count)
        }) else { return nil }

        let content = turns[index].content
        let target = max(compactionFloor, content.count / 2)
        if let structured = structurallyCompactingToolTurn(turns[index]) {
            var result = turns
            result[index] = structured
            return result
        }
        let edge = max(1, (target - 80) / 2)
        let shortened = String(content.prefix(edge))
            + "\n… [older context compacted to fit the on-device 8K budget] …\n"
            + String(content.suffix(edge))

        var result = turns
        result[index] = .init(role: turns[index].role, content: shortened)
        return result
    }

    private static func isToolCall(_ turn: OnDeviceTurn) -> Bool {
        turn.role == "assistant" && turn.content.contains("```tool\n")
    }

    private static func isToolResult(_ turn: OnDeviceTurn) -> Bool {
        turn.role == "user" && turn.content.contains("```tool_result\n")
    }

    /// Keep historical tool blocks syntactically valid while shrinking large
    /// file contents/results. Generic prefix/suffix truncation can cut a JSON
    /// string in half, teaching a small local model a malformed tool format.
    private static func structurallyCompactingToolTurn(_ turn: OnDeviceTurn) -> OnDeviceTurn? {
        let kind: String
        if isToolCall(turn) { kind = "tool" }
        else if isToolResult(turn) { kind = "tool_result" }
        else { return nil }

        let pattern = "```\(kind)\\s*([\\s\\S]*?)```"
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(
                in: turn.content,
                range: NSRange(turn.content.startIndex..., in: turn.content)
              ),
              match.numberOfRanges >= 2,
              let bodyRange = Range(match.range(at: 1), in: turn.content),
              let data = String(turn.content[bodyRange]).data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }

        let (compacted, changed) = compactingLongStrings(in: object)
        guard changed,
              let compactedObject = compacted as? [String: Any],
              let encoded = try? JSONSerialization.data(withJSONObject: compactedObject, options: [.sortedKeys]),
              let json = String(data: encoded, encoding: .utf8) else { return nil }

        var content = turn.content
        content.replaceSubrange(bodyRange, with: json + "\n")
        return .init(role: turn.role, content: content)
    }

    private static func compactingLongStrings(in value: Any) -> (Any, Bool) {
        if let string = value as? String, string.count > compactionFloor {
            let edge = max(1, (max(compactionFloor, string.count / 2) - 80) / 2)
            return (
                String(string.prefix(edge))
                    + "\n… [older tool payload compacted for the on-device 8K budget] …\n"
                    + String(string.suffix(edge)),
                true
            )
        }
        if let dictionary = value as? [String: Any] {
            var result: [String: Any] = [:]
            var changed = false
            for (key, item) in dictionary {
                let (next, didChange) = compactingLongStrings(in: item)
                result[key] = next
                changed = changed || didChange
            }
            return (result, changed)
        }
        if let array = value as? [Any] {
            var changed = false
            let result = array.map { item -> Any in
                let (next, didChange) = compactingLongStrings(in: item)
                changed = changed || didChange
                return next
            }
            return (result, changed)
        }
        return (value, false)
    }
}

/// On-device sampler knobs. Defaults reproduce the prior hardcoded values so
/// default generation is byte-identical; threaded through the generate entry
/// point as an internal-only knob (no UI surface).
struct SamplingOptions: Sendable {
    var temperature: Float = 0.6
    var topP: Float = 0.95
    var topK: Int = 40
    var minP: Float = 0.0
    var repetitionPenalty: Float = 1.05

    static let `default` = SamplingOptions()
}

// MARK: - MLXGenerationGate
//
// App-wide serial gate for all MLX inference and model loads. MLX submits work
// to Metal's global command queue; two concurrent `container.perform { … }`
// calls can make the command buffer return an error state, which MLX reports by
// throwing a C++ std::runtime_error from a completion handler — Swift can't
// catch it and the process aborts (SIGABRT). Funnelling every load/generate
// through `MLXGenerationGate.shared.run { }` serializes them. iOS also revokes
// GPU access when backgrounded, so we refuse submissions while not foreground.
// (Pattern lifted from the on-device reference app.)
actor MLXGenerationGate {
    static let shared = MLXGenerationGate()

    struct Cancelled: Error {}

    private var tail: Task<Void, Never> = Task {}
    private var isForegrounded = true

    private init() {
        Task { [weak self] in await self?.installObservers() }
    }

    private func installObservers() {
        let center = NotificationCenter.default
        Task { [weak self] in
            for await _ in center.notifications(named: UIApplication.willResignActiveNotification) {
                await self?.setForeground(false)
            }
        }
        Task { [weak self] in
            for await _ in center.notifications(named: UIApplication.didBecomeActiveNotification) {
                await self?.setForeground(true)
            }
        }
    }

    private func setForeground(_ v: Bool) { isForegrounded = v }

    /// Run `body` after every previously-submitted gate operation finishes.
    /// Throws `Cancelled` if the caller's Task is cancelled while queued, or if
    /// the app is/Goes to the background (the earliest reliable signal before
    /// the OS revokes GPU access).
    func run<T: Sendable>(_ body: @Sendable @escaping () async throws -> T) async throws -> T {
        if !isForegrounded { throw Cancelled() }
        let previous = tail
        let task = Task<T, Error> { [weak self] in
            await previous.value
            if Task.isCancelled { throw Cancelled() }
            if let fg = await self?.isForegrounded, !fg { throw Cancelled() }
            return try await body()
        }
        tail = Task { _ = try? await task.value }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }
}

// MARK: - MLXTextEngine

/// Loads and runs on-device text models via MLX. Text in, text out — tool calls
/// are handled one level up by `OnDeviceProvider` (prompt injection + parsing).
@MainActor
final class MLXTextEngine: ObservableObject {
    static let shared = MLXTextEngine()
    private init() { installMemoryWarningHandlers() }

    enum State: Equatable {
        case unloaded
        case loading(String)   // human status, e.g. "Downloading 42%"
        case ready
        case generating
        case failed(String)
    }

    @Published private(set) var state: State = .unloaded
    @Published private(set) var loadedModelID: String?
    @Published private(set) var tokensPerSecond: Double = 0
    /// The text generated so far in the current run, updated token-by-token so
    /// the UI can stream it live. Reset at the start of each generation.
    @Published private(set) var liveText: String = ""

    /// Monotonic generation id. Incremented at the start of every generation
    /// and on `resetLiveText()`. Streaming publish closures capture the id at
    /// schedule time and skip the publish if it no longer matches — so a chunk
    /// scheduled for a finished turn can't write into the bubble after it has
    /// been cleared for the next turn.
    private var liveTextGeneration: Int = 0

    private var container: ModelContainer?
    private var memoryWarningTask: Task<Void, Never>?
    private var kernelPressureTask: Task<Void, Never>?
    private var activeGenerationTask: Task<Void, Error>?

    var isReady: Bool { if case .ready = state { return true } else { return false } }

    /// Ensure `model` is loaded and ready, downloading on first use (progress is
    /// surfaced through `state`). No-op if it's already the active, ready model.
    func ensureLoaded(_ model: OnDeviceModel) async throws {
        if loadedModelID == model.id, container != nil, isReady { return }
        if loadedModelID != nil { unload() }   // switching models → free the old one first

        state = .loading("Preparing…")
        let config = ModelConfiguration(id: model.repoID)
        let downloader = OnDeviceModelManager.shared.downloader
        let loadStart = Date()
        do {
            let loaded = try await MLXGenerationGate.shared.run {
                mlxConfigureMemoryBudget()
                mlxClearCache()
                return try await LLMModelFactory.shared.loadContainer(
                    from: downloader,
                    configuration: config
                ) { progress in
                    let frac = progress.fractionCompleted
                    let pct = Int(frac * 100)
                    // Cached loads sweep to 100% in well under 3s; a slow, early
                    // sweep means a real network download is happening.
                    let verb = (Date().timeIntervalSince(loadStart) > 3 && frac < 0.95)
                        ? "Downloading" : "Preparing"
                    Task { @MainActor in
                        MLXTextEngine.shared.state = .loading("\(verb) \(pct)%")
                    }
                }
            }
            container = loaded
            loadedModelID = model.id
            state = .ready
        } catch is MLXGenerationGate.Cancelled {
            state = .unloaded
            throw CancellationError()
        } catch {
            state = .failed(error.localizedDescription)
            throw error
        }
    }

    /// Generate a full completion for `turns` (non-streaming: accumulates every
    /// token, then returns the whole string). The model must already be loaded.
    func generate(
        turns: [OnDeviceTurn],
        maxTokens: Int = 2048,
        tokenDelayNanoseconds: UInt64 = 0,
        sampling: SamplingOptions = .default
    ) async throws -> String {
        guard let container else { throw OnDeviceError.notLoaded }
        liveTextGeneration &+= 1
        let genId = liveTextGeneration
        state = .generating
        liveText = ""
        defer { if case .generating = state { state = .ready } }

        let params = GenerateParameters(
            maxTokens: maxTokens,
            // Bound persistent attention state across long coding-agent turns.
            // The first four tokens remain pinned by RotatingKVCache, preserving
            // the chat-template prefix while old history rolls out safely.
            maxKVSize: OnDeviceMemoryBudget.maxKVTokens,
            kvBits: 8,                 // ~halves KV-cache memory, near-lossless
            temperature: sampling.temperature,
            topP: sampling.topP,
            topK: sampling.topK,
            minP: sampling.minP,
            repetitionPenalty: sampling.repetitionPenalty,
            // Prefill workspace contains attention tensors that grow sharply
            // with chunk length. 32 avoids an unrecoverable MLX Metal abort seen
            // on iPhone18,2 / iOS 27 while preserving the full 8K token budget.
            prefillStepSize: OnDeviceMemoryBudget.prefillChunkTokens
        )

        let accumulated = OSAllocatedUnfairLock<String>(initialState: "")
        let rateLock = OSAllocatedUnfairLock<Double>(initialState: 0)

        let generationTask = Task {
            try await MLXGenerationGate.shared.run { [container, turns, genId] in
            mlxConfigureMemoryBudget()
            // Free GPU buffers from any prior generation before starting a new
            // one — serialized inside the gate to avoid racing with teardown.
            mlxClearCache()
            try await container.perform { context in
                // Build the non-Sendable [Chat.Message] here, inside the closure,
                // from the Sendable turns — never across the actor boundary.
                func prepare(_ source: [OnDeviceTurn]) async throws -> LMInput {
                    let chat: [Chat.Message] = source.map { turn in
                        switch turn.role {
                        case "system":    return .system(turn.content)
                        case "assistant": return .assistant(turn.content)
                        default:          return .user(turn.content)
                        }
                    }
                    return try await context.processor.prepare(input: UserInput(chat: chat))
                }

                var budgetedTurns = turns
                var input = try await prepare(budgetedTurns)
                // Text-only chat preparation produces one token sequence. Check
                // the exact post-template/tokenizer size, not a character guess.
                while input.text.tokens.size > OnDeviceContextBudget.maxInputTokens {
                    if let pruned = OnDeviceContextBudget.removingOldestRound(from: budgetedTurns) {
                        budgetedTurns = pruned
                    } else if let compacted = OnDeviceContextBudget.compactingLargestTurn(in: budgetedTurns) {
                        budgetedTurns = compacted
                    } else {
                        throw OnDeviceError.contextTooLarge
                    }
                    input = try await prepare(budgetedTurns)
                }
                let cache = context.model.newCache(parameters: params)
                for await gen in try MLXLMCommon.generate(
                    input: input, cache: cache, parameters: params, context: context
                ) {
                    if Task.isCancelled { break }
                    if let chunk = gen.chunk {
                        // Append, then publish the running text to the main actor
                        // for live streaming. The length guard drops any out-of-
                        // order hop so the visible text only ever grows.
                        let snapshot = accumulated.withLock { $0 += chunk; return $0 }
                        Task { @MainActor in
                            let engine = MLXTextEngine.shared
                            guard engine.liveTextGeneration == genId else { return }
                            if snapshot.count >= engine.liveText.count {
                                engine.liveText = snapshot
                            }
                        }
                    }
                    if let info = gen.info { rateLock.withLock { $0 = info.tokensPerSecond } }
                    if tokenDelayNanoseconds > 0 {
                        try await Task.sleep(nanoseconds: tokenDelayNanoseconds)
                    }
                }
            }
            // Clear GPU cache only after perform completes — calling
            // Memory.clearCache() inside perform can race with MLX's internal
            // context teardown and cause a SIGABRT from a C++ exception that
            // Swift cannot catch.
            mlxClearCache()
            }
        }
        activeGenerationTask = generationTask
        defer { activeGenerationTask = nil }
        try await generationTask.value

        tokensPerSecond = rateLock.withLock { $0 }
        return accumulated.withLock { $0 }
    }

    func unload() {
        container = nil
        loadedModelID = nil
        tokensPerSecond = 0
        liveTextGeneration &+= 1
        liveText = ""
        state = .unloaded
        // GPU cache is cleared inside generate() via the serialization gate.
        // Calling mlxClearCache() here would race with any in-progress
        // generation and can cause a SIGABRT.
    }

    /// Clear the streamed text before a new turn starts, so the bubble can't
    /// flash the *previous* generation's output while the next one warms up or
    /// queues behind the generation gate (generate() only clears once it runs).
    func resetLiveText() {
        liveTextGeneration &+= 1
        liveText = ""
    }

    // MARK: - Main-actor convenience entry points
    //
    // Let non-isolated callers (e.g. the LLMProvider struct) drive the engine
    // with a plain `await`, mirroring how providers call
    // `ProviderCredentials.resolve(_:)`. The hop to the main actor is implicit.

    static func ensureLoaded(_ model: OnDeviceModel) async throws {
        try await shared.ensureLoaded(model)
    }

    static func generate(
        turns: [OnDeviceTurn],
        maxTokens: Int = 2048,
        tokenDelayNanoseconds: UInt64 = 0,
        sampling: SamplingOptions = .default
    ) async throws -> String {
        try await shared.generate(
            turns: turns,
            maxTokens: maxTokens,
            tokenDelayNanoseconds: tokenDelayNanoseconds,
            sampling: sampling
        )
    }

    private func installMemoryWarningHandlers() {
        memoryWarningTask = Task { @MainActor [weak self] in
            for await _ in NotificationCenter.default.notifications(named: UIApplication.didReceiveMemoryWarningNotification) {
                self?.releaseIdleModelForMemoryPressure()
            }
        }
        kernelPressureTask = Task { @MainActor [weak self] in
            for await _ in NotificationCenter.default.notifications(named: .siteAgentCriticalMemoryPressure) {
                self?.cancelGenerationForCriticalMemoryPressure()
            }
        }
    }

    /// Stop decode first, then release weights/cache only after the serialized
    /// MLX operation unwinds. This avoids both Jetsam and command-buffer races.
    private func cancelGenerationForCriticalMemoryPressure() {
        guard let activeGenerationTask else {
            releaseIdleModelForMemoryPressure()
            return
        }
        activeGenerationTask.cancel()
        state = .failed("On-device generation stopped because iOS reported critical memory pressure. Try a smaller model.")
        Task { @MainActor [weak self] in
            _ = try? await activeGenerationTask.value
            try? await MLXGenerationGate.shared.run { mlxClearCache() }
            guard let self else { return }
            container = nil
            loadedModelID = nil
            tokensPerSecond = 0
            liveText = ""
        }
    }

    /// On memory pressure, drop a loaded but idle model. Active generations keep
    /// running so MLX teardown doesn't race command-buffer completion.
    private func releaseIdleModelForMemoryPressure() {
        guard case .ready = state else { return }
        container = nil
        loadedModelID = nil
        tokensPerSecond = 0
        liveText = ""
        state = .unloaded
        Task {
            try? await MLXGenerationGate.shared.run {
                mlxClearCache()
            }
        }
    }
}

// MARK: - Errors

enum OnDeviceError: LocalizedError {
    case notLoaded
    case notDownloaded(String)
    case notCapable
    case locked
    case thermalCritical
    case contextTooLarge

    var errorDescription: String? {
        switch self {
        case .notLoaded:
            return "No on-device model is loaded. Open Settings → On-Device to download and load a model."
        case .notDownloaded(let name):
            return "“\(name)” isn’t downloaded yet. Open Settings → On-Device to download it."
        case .notCapable:
            return "On-device models require iPhone 15 Pro or newer."
        case .locked:
            return "Your on-device free trial has ended. Unlock Super to keep using local models."
        case .thermalCritical:
            return "Your iPhone needs to cool down before running another local model request."
        case .contextTooLarge:
            return "This request is too large for the on-device 8K context budget. Shorten the latest message or attachment and try again."
        }
    }
}
