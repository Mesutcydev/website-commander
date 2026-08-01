import Foundation
import CryptoKit

/// File-backed storage for media used by one blog import. The agent receives
/// only the opaque asset UUID and metadata; it never receives bytes or a temp
/// path. The store is an actor so cancellation and approval cannot race a
/// write or cleanup.
actor BlogImportAssetStore {
    static let maximumAssetBytes = 10 * 1024 * 1024

    private struct StoredAsset {
        let descriptor: ImportedMediaAssetDescriptor
        let fileURL: URL
    }

    private let rootURL: URL
    private var sessions: [UUID: [UUID: StoredAsset]] = [:]

    init(rootURL: URL? = nil) {
        self.rootURL = rootURL ?? FileManager.default.temporaryDirectory
            .appendingPathComponent("WebsiteCommander-blog-imports", isDirectory: true)
        try? FileManager.default.createDirectory(at: self.rootURL,
                                                  withIntermediateDirectories: true)
    }

    func createSession() -> UUID {
        let id = UUID()
        sessions[id] = [:]
        return id
    }

    @discardableResult
    func store(data: Data, sessionID: UUID, assetID: UUID = UUID(), mimeType: String,
               pixelWidth: Int? = nil, pixelHeight: Int? = nil,
               suggestedExtension: String) throws -> ImportedMediaAssetDescriptor {
        guard data.count <= Self.maximumAssetBytes else { throw AssetStoreError.assetTooLarge }
        guard data.count > 0 else { throw AssetStoreError.emptyAsset }
        guard !mimeType.isEmpty else { throw AssetStoreError.invalidMetadata }

        if sessions[sessionID] == nil { sessions[sessionID] = [:] }
        let ext = Self.safeExtension(suggestedExtension)
        let sessionDirectory = rootURL.appendingPathComponent(sessionID.uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: sessionDirectory, withIntermediateDirectories: true)
        let fileURL = sessionDirectory.appendingPathComponent(assetID.uuidString).appendingPathExtension(ext)
        try data.write(to: fileURL, options: [.atomic, .completeFileProtection])

        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let descriptor = ImportedMediaAssetDescriptor(
            id: assetID,
            mimeType: mimeType,
            byteCount: Int64(data.count),
            pixelWidth: pixelWidth,
            pixelHeight: pixelHeight,
            sha256: digest,
            suggestedExtension: ext
        )
        sessions[sessionID]?[assetID] = StoredAsset(descriptor: descriptor, fileURL: fileURL)
        return descriptor
    }

    func data(for reference: BinaryAssetReference) throws -> Data {
        guard let stored = sessions[reference.sessionID]?[reference.assetID] else {
            throw AssetStoreError.assetMissing
        }
        return try Data(contentsOf: stored.fileURL, options: [.mappedIfSafe])
    }

    func descriptor(for reference: BinaryAssetReference) -> ImportedMediaAssetDescriptor? {
        sessions[reference.sessionID]?[reference.assetID]?.descriptor
    }

    func hasAsset(_ reference: BinaryAssetReference) -> Bool {
        sessions[reference.sessionID]?[reference.assetID] != nil
    }

    func cleanup(sessionID: UUID) {
        sessions.removeValue(forKey: sessionID)
        let directory = rootURL.appendingPathComponent(sessionID.uuidString, isDirectory: true)
        try? FileManager.default.removeItem(at: directory)
        if sessions.isEmpty {
            try? FileManager.default.removeItem(at: rootURL)
        }
    }

    func cleanupAll() {
        sessions.removeAll()
        try? FileManager.default.removeItem(at: rootURL)
        try? FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
    }

    private static func safeExtension(_ raw: String) -> String {
        let trimmed = raw.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        let filtered = trimmed.filter { $0.isLetter || $0.isNumber }
        return filtered.isEmpty ? "bin" : String(filtered.prefix(8))
    }
}

enum AssetStoreError: LocalizedError, Equatable, Sendable {
    case assetTooLarge
    case emptyAsset
    case invalidMetadata
    case assetMissing

    var errorDescription: String? {
        switch self {
        case .assetTooLarge: return "The imported asset is larger than 10 MB."
        case .emptyAsset: return "The imported asset is empty."
        case .invalidMetadata: return "The imported asset metadata is invalid."
        case .assetMissing: return "The imported asset is no longer available."
        }
    }
}
