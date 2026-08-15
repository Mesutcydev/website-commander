import Foundation

struct MountedFolder: Identifiable, Codable, Equatable {
    let id: UUID
    var displayName: String
    var bookmarkData: Data
    var addedAt: Date

    init(
        id: UUID = UUID(),
        displayName: String,
        bookmarkData: Data,
        addedAt: Date = Date()
    ) {
        self.id = id
        self.displayName = displayName
        self.bookmarkData = bookmarkData
        self.addedAt = addedAt
    }
}

struct SharedAsset: Identifiable, Equatable {
    var id: URL { url }
    var url: URL
    var name: String
    var byteCount: Int64
    var modifiedAt: Date?
}

struct ProviderConfigurationArchive: Codable, Equatable {
    static let currentVersion = 1

    var version: Int
    var exportedAt: Date
    var activeProviderID: String
    var activeModelID: String
    var customBaseURL: String
    var customModel: String
    var smartRoutingEnabled: Bool
    var routingStrategy: RoutingStrategy
    var reasoningPreference: ReasoningPreference
    var launchPreference: LaunchPreference

    init(
        version: Int = currentVersion,
        exportedAt: Date = Date(),
        activeProviderID: String,
        activeModelID: String,
        customBaseURL: String,
        customModel: String,
        smartRoutingEnabled: Bool,
        routingStrategy: RoutingStrategy,
        reasoningPreference: ReasoningPreference,
        launchPreference: LaunchPreference
    ) {
        self.version = version
        self.exportedAt = exportedAt
        self.activeProviderID = activeProviderID
        self.activeModelID = activeModelID
        self.customBaseURL = customBaseURL
        self.customModel = customModel
        self.smartRoutingEnabled = smartRoutingEnabled
        self.routingStrategy = routingStrategy
        self.reasoningPreference = reasoningPreference
        self.launchPreference = launchPreference
    }

    func validated() throws -> ProviderConfigurationArchive {
        guard version == Self.currentVersion else {
            throw PortabilityError.unsupportedVersion(version)
        }
        guard customBaseURL.isEmpty || URL(string: customBaseURL)?.scheme == "https" else {
            throw PortabilityError.insecureProviderURL
        }
        return self
    }
}

enum PortabilityError: LocalizedError {
    case unsupportedVersion(Int)
    case insecureProviderURL
    case invalidFilename
    case folderUnavailable

    var errorDescription: String? {
        switch self {
        case .unsupportedVersion(let version):
            return "This configuration uses unsupported format version \(version)."
        case .insecureProviderURL:
            return "Custom provider URLs must use HTTPS."
        case .invalidFilename:
            return "The filename is not safe to store in the shared workspace."
        case .folderUnavailable:
            return "The mounted folder is no longer available. Choose it again to restore access."
        }
    }
}
