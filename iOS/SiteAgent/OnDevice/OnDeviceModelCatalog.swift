import Foundation

/// A locally-runnable text model — MLX, 4-bit, from the `mlx-community` org on
/// Hugging Face. Kept deliberately small: SiteAgent only needs a handful of
/// strong code/chat models for editing websites, not a full model zoo.
struct OnDeviceModel: Identifiable, Hashable {
    let id: String                  // stable key (also the active-model id)
    let repoID: String              // Hugging Face repo, e.g. "mlx-community/…"
    let displayName: String
    let subtitle: String            // "4-bit · ~2.3 GB · recommended"
    let approxDownloadBytes: Int64  // drives the download UI estimate
    let approxRAMBytes: Int64       // working-set estimate, for tier flagging
    let contextTokens: Int
    let tags: [String]              // "code", "fast", "default", …

    /// Public model card and manual-download destination. Catalog entries are
    /// curated constants, so this URL is safe to expose directly in the UI.
    var huggingFaceURL: URL {
        URL(string: "https://huggingface.co/\(repoID)")!
    }

    /// Larger models are flagged so 8 GB devices aren't surprised by an OOM;
    /// the picker recommends these only on 12 GB+ ("max") hardware.
    var needsMaxTier: Bool { approxRAMBytes > 5_000_000_000 }

    /// Qwen3-family checkpoints understand `/think`; Qwen2.5 and Llama do not.
    var supportsThinking: Bool {
        id.hasPrefix("qwen3") || tags.contains("qwen")
    }

    /// Qwen's lower top-k profile is more reliable for precise code edits and
    /// strict JSON tool blocks than the generic local-model defaults. Bonsai is
    /// Qwen3-based even though its repository name does not begin with Qwen.
    var sampling: SamplingOptions {
        if id == "ternary-bonsai-8b-2bit" {
            // Two-bit quantization is capable but less instruction-stable. A
            // deterministic profile materially improves exact tool grammar.
            return SamplingOptions(
                temperature: 0.2,
                topP: 0.9,
                topK: 20,
                minP: 0,
                repetitionPenalty: 1.0
            )
        }
        if id.hasPrefix("qwen") || tags.contains("qwen") {
            return SamplingOptions(
                temperature: 0.6,
                topP: 0.95,
                topK: 20,
                minP: 0,
                repetitionPenalty: 1.0
            )
        }
        return .default
    }
}

/// The curated on-device roster. All entries are public MLX repositories, so no
/// Hugging Face token is required to download them.
enum OnDeviceModelCatalog {
    static let all: [OnDeviceModel] = [
        OnDeviceModel(
            id: "qwen2.5-coder-1.5b",
            repoID: "mlx-community/Qwen2.5-Coder-1.5B-Instruct-4bit",
            displayName: "Qwen2.5 Coder 1.5B",
            subtitle: "4-bit · ~1.0 GB · fastest",
            approxDownloadBytes: 1_000_000_000,
            approxRAMBytes: 1_500_000_000,
            contextTokens: 8_192,
            tags: ["code", "fast"]
        ),
        OnDeviceModel(
            id: "qwen3-4b-2507",
            repoID: "mlx-community/Qwen3-4B-Instruct-2507-4bit",
            displayName: "Qwen3 4B",
            subtitle: "4-bit · ~2.3 GB · recommended",
            approxDownloadBytes: 2_300_000_000,
            approxRAMBytes: 3_800_000_000,
            contextTokens: 8_192,
            tags: ["code", "chat", "default"]
        ),
        OnDeviceModel(
            id: "qwen3.5-4b",
            repoID: "mlx-community/Qwen3.5-4B-MLX-4bit",
            displayName: "Qwen3.5 4B",
            subtitle: "4-bit · ~3.1 GB · experimental best",
            approxDownloadBytes: 3_100_000_000,
            approxRAMBytes: 4_800_000_000,
            contextTokens: 8_192,
            tags: ["code", "chat", "experimental", "best"]
        ),
        OnDeviceModel(
            id: "llama-3.2-3b",
            repoID: "mlx-community/Llama-3.2-3B-Instruct-4bit",
            displayName: "Llama 3.2 3B",
            subtitle: "4-bit · ~1.8 GB · general",
            approxDownloadBytes: 1_800_000_000,
            approxRAMBytes: 3_000_000_000,
            contextTokens: 8_192,
            tags: ["chat", "general"]
        ),
        OnDeviceModel(
            id: "qwen3-8b",
            repoID: "mlx-community/Qwen3-8B-4bit",
            displayName: "Qwen3 8B",
            subtitle: "4-bit · ~4.8 GB · highest quality",
            approxDownloadBytes: 4_800_000_000,
            approxRAMBytes: 6_500_000_000,
            contextTokens: 8_192,
            tags: ["quality"]
        ),
        OnDeviceModel(
            id: "ternary-bonsai-8b-2bit",
            repoID: "prism-ml/Ternary-Bonsai-8B-mlx-2bit",
            displayName: "Ternary Bonsai 8B",
            subtitle: "2-bit · ~2.3 GB · experimental efficient",
            approxDownloadBytes: 2_320_000_000,
            approxRAMBytes: 4_500_000_000,
            contextTokens: 8_192,
            tags: ["code", "chat", "quality", "experimental", "efficient", "qwen"]
        ),
        OnDeviceModel(
            id: "qwen3.5-9b",
            repoID: "mlx-community/Qwen3.5-9B-MLX-4bit",
            displayName: "Qwen3.5 9B",
            subtitle: "4-bit · ~6.0 GB · experimental max",
            approxDownloadBytes: 6_000_000_000,
            approxRAMBytes: 8_500_000_000,
            contextTokens: 8_192,
            tags: ["code", "quality", "experimental", "max"]
        ),
    ]

    static let defaultModelID = "qwen3-4b-2507"
    static let stableFallbackModelID = "qwen3-4b-2507"

    static func model(id: String) -> OnDeviceModel? { all.first { $0.id == id } }
    static var defaultModel: OnDeviceModel { model(id: defaultModelID) ?? all[0] }
    static var stableFallbackModel: OnDeviceModel { model(id: stableFallbackModelID) ?? defaultModel }
}
