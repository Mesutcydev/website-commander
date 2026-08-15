import Foundation
import Hub
import MLXLMCommon

/// Owns where on-device weights are downloaded and how they're discovered.
/// A single shared download base is used for BOTH explicit downloads from the
/// picker and the engine's lazy `loadContainer`, so they share one cache dir.
@MainActor
final class OnDeviceModelManager: ObservableObject {
    enum DownloadPhase: Equatable {
        case connecting
        case downloading
        case reconnecting(Int)
    }

    static let shared = OnDeviceModelManager()
    private let hub: HubApi

    private init() {
        // Keep one client alive for the whole transfer. Recreating HubApi also
        // recreates its foreground clients and can discard connection pooling.
        // This client is used only by the explicit Download button. Do not let
        // HubApi's NWPath snapshot divert it into offline integrity hashing:
        // hashing a partial multi-GB shard leaves the UI at "Connecting" and no
        // request is ever started. The engine's lazy loader keeps automatic
        // offline behavior through `downloader` below.
        hub = HubApi(downloadBase: Self.downloadBase, useOfflineMode: false)
        refreshDownloaded()
    }

    /// 0…1 while a model is downloading, keyed by model id.
    @Published private(set) var progress: [String: Double] = [:]
    @Published private(set) var downloading: Set<String> = []
    @Published private(set) var downloadPhase: [String: DownloadPhase] = [:]

    /// Cached set of downloaded model ids, so SwiftUI `body` (re-run on every
    /// progress tick) reads memory instead of scanning the filesystem per row.
    /// Refreshed on launch and after each download/delete; `isDownloaded(_:)`
    /// stays the filesystem source of truth for generation-time checks.
    @Published private(set) var downloadedIDs: Set<String> = []

    /// Recompute `downloadedIDs` from disk. Call after a download or delete.
    func refreshDownloaded() {
        downloadedIDs = Set(OnDeviceModelCatalog.all.filter { isDownloaded($0) }.map(\.id))
    }

    /// Weights live in Application Support: excluded from the user's document
    /// browser, not backed up to iCloud noise, and preserved across updates.
    static let downloadBase: URL = {
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("OnDeviceModels", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }()

    /// The MLXLMCommon `Downloader` the engine hands to `loadContainer`.
    var downloader: HubApiDownloader { HubApiDownloader(downloadBase: Self.downloadBase) }

    func localDirectory(for model: OnDeviceModel) -> URL {
        hub.localRepoLocation(Hub.Repo(id: model.repoID))
    }

    /// A model counts as downloaded only when it has a config and at least one
    /// weight shard — so a partial/aborted transfer never reads as "ready".
    func isDownloaded(_ model: OnDeviceModel) -> Bool {
        let dir = localDirectory(for: model)
        let fm = FileManager.default
        guard fm.fileExists(atPath: dir.appendingPathComponent("config.json").path) else { return false }
        guard let items = try? fm.contentsOfDirectory(atPath: dir.path) else { return false }
        let weights = Set(items.filter { $0.hasSuffix(".safetensors") || $0.hasSuffix(".npz") })
        guard !weights.isEmpty else { return false }

        // Multi-shard repositories publish an index listing every required
        // weight file. One completed shard must not make a partial model appear
        // installed and become selectable.
        let indexURL = dir.appendingPathComponent("model.safetensors.index.json")
        if let data = try? Data(contentsOf: indexURL),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let weightMap = object["weight_map"] as? [String: String] {
            let requiredWeights = Set(weightMap.values)
            return !requiredWeights.isEmpty && requiredWeights.isSubset(of: weights)
        }
        return true
    }

    func downloadedModels() -> [OnDeviceModel] {
        OnDeviceModelCatalog.all.filter { downloadedIDs.contains($0.id) }
    }

    func diskSize(of model: OnDeviceModel) -> Int64 {
        let dir = localDirectory(for: model)
        guard let en = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        var total: Int64 = 0
        for case let url as URL in en {
            total += Int64((try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
        }
        return total
    }

    /// Pre-download a model's files, reporting progress. Safe to call when the
    /// model is already present (HubApi skips up-to-date files).
    func download(_ model: OnDeviceModel) async throws {
        guard !downloading.contains(model.id) else { return }
        if let activeID = downloading.first,
           let active = OnDeviceModelCatalog.model(id: activeID) {
            throw OnDeviceDownloadError.anotherDownloadActive(active.displayName)
        }
        downloading.insert(model.id)
        downloadPhase[model.id] = .connecting
        progress[model.id] = nil
        defer {
            downloading.remove(model.id)
            downloadPhase[model.id] = nil
        }
        do {
            _ = try await resilientSnapshot(
                hub: hub,
                repo: Hub.Repo(id: model.repoID),
                matching: ["*.safetensors", "*.json", "*.txt", "*.jinja", "tokenizer*"],
                progressHandler: { [weak self] p in
                    let f = p.fractionCompleted
                    Task { @MainActor in
                        self?.downloadPhase[model.id] = .downloading
                        self?.progress[model.id] = f
                    }
                },
                retryHandler: { [weak self] attempt in
                    Task { @MainActor in
                        self?.downloadPhase[model.id] = .reconnecting(attempt)
                    }
                }
            )
            progress[model.id] = 1
            refreshDownloaded()
        } catch {
            progress[model.id] = nil
            throw error
        }
    }

    func delete(_ model: OnDeviceModel) {
        try? FileManager.default.removeItem(at: localDirectory(for: model))
        progress[model.id] = nil
        refreshDownloaded()
    }

    /// Removes only unfinished model snapshots and Hugging Face's resumable
    /// `.incomplete` blobs. Completed model directories and completed cache
    /// blobs are deliberately preserved.
    func clearPartialDownloads() async throws -> Int64 {
        guard downloading.isEmpty else {
            throw OnDeviceDownloadError.downloadActive
        }

        let partialModelDirectories = OnDeviceModelCatalog.all.compactMap { model in
            isDownloaded(model) ? nil : localDirectory(for: model)
        }
        let cacheRoot = FileManager.default
            .urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("huggingface", isDirectory: true)
            .appendingPathComponent("hub", isDirectory: true)

        let bytesRemoved = try await Task.detached(priority: .userInitiated) {
            try Self.removePartialArtifacts(
                modelDirectories: partialModelDirectories,
                cacheRoot: cacheRoot
            )
        }.value

        refreshDownloaded()
        return bytesRemoved
    }

    /// Kept synchronous so Foundation's directory enumerator is never consumed
    /// directly from an async context (which becomes an error in Swift 6 mode).
    nonisolated private static func removePartialArtifacts(
        modelDirectories: [URL],
        cacheRoot: URL
    ) throws -> Int64 {
        let fm = FileManager.default
        var targets = Set(modelDirectories.map(\.standardizedFileURL))

        if let enumerator = fm.enumerator(
            at: cacheRoot,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) {
            for case let url as URL in enumerator where url.lastPathComponent.hasSuffix(".incomplete") {
                targets.insert(url.standardizedFileURL)
            }
        }

        var removedBytes: Int64 = 0
        for target in targets where fm.fileExists(atPath: target.path) {
            removedBytes += allocatedSize(at: target, fileManager: fm)
            try fm.removeItem(at: target)
        }
        return removedBytes
    }

    nonisolated private static func allocatedSize(at url: URL, fileManager: FileManager) -> Int64 {
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .fileAllocatedSizeKey, .totalFileAllocatedSizeKey]
        let values = try? url.resourceValues(forKeys: keys)
        if values?.isDirectory != true {
            return Int64(values?.totalFileAllocatedSize ?? values?.fileAllocatedSize ?? 0)
        }

        guard let enumerator = fileManager.enumerator(
            at: url,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles]
        ) else { return 0 }
        var total: Int64 = 0
        for case let child as URL in enumerator {
            let childValues = try? child.resourceValues(forKeys: keys)
            guard childValues?.isDirectory != true else { continue }
            total += Int64(childValues?.totalFileAllocatedSize ?? childValues?.fileAllocatedSize ?? 0)
        }
        return total
    }
}

enum OnDeviceDownloadError: LocalizedError {
    case anotherDownloadActive(String)
    case downloadActive

    var errorDescription: String? {
        switch self {
        case .anotherDownloadActive(let name):
            return "\(name) is already downloading. Let it finish before starting another model."
        case .downloadActive:
            return "Wait for the active model download to finish before clearing partial downloads."
        }
    }
}

/// Bridges MLXLMCommon's `Downloader` onto swift-transformers' `HubApi.snapshot`.
/// mlx-swift-lm 3.x dropped its built-in Hub client, so the app must supply one;
/// the tokenizer side is handled by MLXLMTransformers' default loader.
struct HubApiDownloader: Downloader {
    let downloadBase: URL

    func download(
        id: String,
        revision: String?,
        matching patterns: [String],
        useLatest: Bool,
        progressHandler: @Sendable @escaping (Progress) -> Void
    ) async throws -> URL {
        try await resilientSnapshot(
            hub: HubApi(downloadBase: downloadBase),
            repo: Hub.Repo(id: id),
            revision: revision ?? "main",
            matching: patterns,
            progressHandler: progressHandler
        )
    }
}

/// Runs one snapshot attempt with an idle-progress watchdog, then relies on the
/// Hugging Face cache's Range support to resume the shard on a retry.
private func resilientSnapshot(
    hub: HubApi,
    repo: Hub.Repo,
    revision: String = "main",
    matching patterns: [String],
    progressHandler: @Sendable @escaping (Progress) -> Void,
    retryHandler: @Sendable @escaping (Int) -> Void = { _ in }
) async throws -> URL {
    try await withTransientDownloadRetries(onRetry: retryHandler) {
        try await withDownloadStallTimeout(seconds: 60) { watchdog in
            try await hub.snapshot(
                from: repo,
                revision: revision,
                matching: patterns
            ) { progress in
                watchdog.note(progressFraction: progress.fractionCompleted)
                progressHandler(progress)
            }
        }
    }
}

private final class DownloadProgressWatchdog: @unchecked Sendable {
    private let lock = NSLock()
    private var lastProgressDate = Date()
    private var greatestProgressFraction: Double = -1

    func note(progressFraction: Double) {
        lock.lock()
        defer { lock.unlock() }
        guard progressFraction > greatestProgressFraction else { return }
        greatestProgressFraction = progressFraction
        lastProgressDate = Date()
    }

    var idleSeconds: TimeInterval {
        lock.lock()
        defer { lock.unlock() }
        return Date().timeIntervalSince(lastProgressDate)
    }
}

private func withDownloadStallTimeout<T: Sendable>(
    seconds: TimeInterval,
    operation: @Sendable @escaping (DownloadProgressWatchdog) async throws -> T
) async throws -> T {
    let watchdog = DownloadProgressWatchdog()
    return try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await operation(watchdog) }
        group.addTask {
            while !Task.isCancelled {
                try await Task.sleep(for: .seconds(5))
                if watchdog.idleSeconds >= seconds {
                    throw URLError(.timedOut)
                }
            }
            throw CancellationError()
        }
        defer { group.cancelAll() }
        guard let result = try await group.next() else { throw CancellationError() }
        return result
    }
}

/// Hugging Face stores interrupted weight shards in its cache and resumes them
/// with a Range request on the next attempt. Retry only connectivity failures;
/// authentication, missing models, bad metadata and disk errors remain terminal.
private func withTransientDownloadRetries<T>(
    maxAttempts: Int = 7,
    onRetry: @Sendable (Int) -> Void = { _ in },
    operation: () async throws -> T
) async throws -> T {
    var attempt = 1
    while true {
        do {
            return try await operation()
        } catch {
            guard !Task.isCancelled,
                  attempt < maxAttempts,
                  isTransientDownloadError(error) else {
                throw error
            }

            // Covers brief Wi-Fi/cellular hand-offs without making the user tap
            // Download again. The cached partial shard is reused on every retry.
            let delaySeconds = min(2 << (attempt - 1), 16)
            attempt += 1
            onRetry(attempt)
            try await Task.sleep(for: .seconds(delaySeconds))
        }
    }
}

private func isTransientDownloadError(_ error: Error) -> Bool {
    if let urlError = error as? URLError {
        return transientURLCodes.contains(urlError.code)
    }
    if case let Hub.HubClientError.networkError(urlError) = error {
        return transientURLCodes.contains(urlError.code)
    }

    // HubApi currently wraps some URLSession failures in downloadError(String),
    // losing the original URLError code. Match Foundation's stable descriptions
    // so those failures still receive the same resumable retry treatment.
    let description = error.localizedDescription.lowercased()
    return [
        "network connection was lost",
        "internet connection appears to be offline",
        "not connected to the internet",
        "request timed out",
        "cannot connect to the host",
        "could not connect to the server",
        "dns lookup failed"
    ].contains { description.contains($0) }
}

private let transientURLCodes: Set<URLError.Code> = [
    .timedOut,
    .cannotFindHost,
    .cannotConnectToHost,
    .dnsLookupFailed,
    .networkConnectionLost,
    .notConnectedToInternet,
    .internationalRoamingOff,
    .callIsActive,
    .dataNotAllowed
]
