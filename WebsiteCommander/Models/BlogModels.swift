import Foundation

// MARK: - X import

/// A warning is deliberately non-fatal. The importer can still prepare an
/// article when X does not expose a usable media URL or publication date.
enum XPostImportWarning: String, CaseIterable, Identifiable, Sendable {
    case mediaUnavailable
    case imageUnavailable
    case publicationDateUnavailable

    var id: String { rawValue }

    var message: String {
        switch self {
        case .mediaUnavailable:
            return "The post references media that is not available through the public X embed response. The canonical X post will be linked instead."
        case .imageUnavailable:
            return "The post's image could not be safely copied. The article can link to the canonical X post instead."
        case .publicationDateUnavailable:
            return "The source publication date was not available. The article date will follow the repository convention."
        }
    }
}

enum XPostImportError: LocalizedError, Equatable, Sendable {
    case invalidURL
    case unsupportedURL
    case unavailablePost
    case networkUnavailable
    case xServiceUnavailable
    case malformedResponse
    case emptyPost
    case cancelled

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "Enter a valid public X post URL."
        case .unsupportedURL:
            return "That URL is not a supported public X post URL."
        case .unavailablePost:
            return "X did not return a public embeddable post for that URL."
        case .networkUnavailable:
            return "The X embed service could not be reached. Check the connection and try again."
        case .xServiceUnavailable:
            return "The X embed service is temporarily unavailable. Try again shortly."
        case .malformedResponse:
            return "The X embed response was not in the expected format."
        case .emptyPost:
            return "The public X embed did not contain post text."
        case .cancelled:
            return "The X import was cancelled."
        }
    }
}

struct ImportedMediaAssetDescriptor: Identifiable, Equatable, Sendable {
    let id: UUID
    let mimeType: String
    let byteCount: Int64
    let pixelWidth: Int?
    let pixelHeight: Int?
    let sha256: String
    let suggestedExtension: String

    init(id: UUID = UUID(), mimeType: String, byteCount: Int64,
         pixelWidth: Int? = nil, pixelHeight: Int? = nil,
         sha256: String, suggestedExtension: String) {
        self.id = id
        self.mimeType = mimeType
        self.byteCount = byteCount
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.sha256 = sha256
        self.suggestedExtension = suggestedExtension
    }
}

struct XPostImportDraft: Identifiable, Equatable, Sendable {
    let id: UUID
    let postID: String
    let canonicalURL: URL
    let authorDisplayName: String?
    let authorHandle: String?
    let authorProfileURL: URL?
    let sourceText: String
    let sourcePublishedAt: Date?
    let fetchedAt: Date
    let media: [ImportedMediaAssetDescriptor]
    let hasVideo: Bool
    let warnings: [XPostImportWarning]

    init(id: UUID = UUID(), postID: String, canonicalURL: URL,
         authorDisplayName: String? = nil, authorHandle: String? = nil,
         authorProfileURL: URL? = nil, sourceText: String,
         sourcePublishedAt: Date? = nil, fetchedAt: Date = Date(),
         media: [ImportedMediaAssetDescriptor] = [], hasVideo: Bool = false,
         warnings: [XPostImportWarning] = []) {
        self.id = id
        self.postID = postID
        self.canonicalURL = canonicalURL
        self.authorDisplayName = authorDisplayName
        self.authorHandle = authorHandle
        self.authorProfileURL = authorProfileURL
        self.sourceText = sourceText
        self.sourcePublishedAt = sourcePublishedAt
        self.fetchedAt = fetchedAt
        self.media = media
        self.hasVideo = hasVideo
        self.warnings = warnings
    }

    /// Only trusted, structured fields are sent to the model. In particular,
    /// this never includes the oEmbed HTML, downloaded bytes, or temp paths.
    var modelContext: String {
        var lines = [
            "Source type: public X post",
            "Canonical source URL: \(canonicalURL.absoluteString)",
            "Post ID: \(postID)",
            PromptGuard.fence(source: "imported X post text", sourceText)
        ]
        if let authorHandle, !authorHandle.isEmpty {
            let handle = authorHandle.trimmingCharacters(in: CharacterSet(charactersIn: "@"))
            lines.append("Author handle: \(handle)")
        }
        if let authorDisplayName, !authorDisplayName.isEmpty {
            lines.append("Author display name: \(authorDisplayName)")
        }
        if let sourcePublishedAt {
            lines.append("Source publication date (reliable metadata only): \(ISO8601DateFormatter().string(from: sourcePublishedAt))")
        } else {
            lines.append("Source publication date: unavailable; do not guess one.")
        }
        if !media.isEmpty {
            let mediaLines = media.map {
                let dimensions = ($0.pixelWidth != nil && $0.pixelHeight != nil)
                    ? " (\($0.pixelWidth!)×\($0.pixelHeight!))px"
                    : ""
                return "- asset \($0.id.uuidString): \($0.mimeType), \($0.byteCount) bytes\(dimensions), .\($0.suggestedExtension), sha256 \($0.sha256)"
            }
            lines.append("Safely imported media descriptors (bytes remain file-backed):\n" + mediaLines.joined(separator: "\n"))
        }
        if hasVideo { lines.append("The source includes video or media that cannot be copied anonymously; preserve a canonical X link.") }
        if !warnings.isEmpty {
            lines.append("Importer warnings:\n" + warnings.map { "- \($0.message)" }.joined(separator: "\n"))
        }
        return lines.joined(separator: "\n")
    }
}

// MARK: - Blog convention and transaction state

struct BlogMediaDirectory: Identifiable, Equatable, Sendable {
    let id: String
    let path: String

    init(id: String, path: String) {
        self.id = id
        self.path = path
    }
}

struct BlogConvention: Equatable, Sendable {
    let evidencePaths: [String]
    let articleDirectory: String
    let mediaDirectories: [BlogMediaDirectory]
    let frontmatterFields: [String]
    let fileExtension: String?
    let indexUpdateRequired: Bool
}

enum BlogImportRunPhase: Equatable, Sendable {
    case inspectingRepository
    case conventionDeclared(BlogConvention)
    case staging
    case readyForReview
    case failed(String)

    var label: String {
        switch self {
        case .inspectingRepository: return "Inspecting repository"
        case .conventionDeclared: return "Convention accepted"
        case .staging: return "Preparing changes"
        case .readyForReview: return "Ready for review"
        case .failed: return "Import stopped"
        }
    }
}

struct BinaryAssetReference: Equatable, Sendable, Codable {
    let sessionID: UUID
    let assetID: UUID
}

struct TextPendingContent: Equatable, Sendable, Codable {
    let value: String
}

struct BinaryPendingContent: Equatable, Sendable, Codable {
    let assetReference: BinaryAssetReference
    let mimeType: String
    let byteCount: Int64
    let pixelWidth: Int?
    let pixelHeight: Int?
    let sha256: String
    let suggestedExtension: String
}

enum PendingChangeContent: Equatable, Sendable, Codable {
    case text(TextPendingContent)
    case binary(BinaryPendingContent)
}

enum PendingChangeStatistics: Equatable, Sendable {
    case text(linesAdded: Int, linesRemoved: Int)
    case binary(byteCount: Int64, pixelWidth: Int?, pixelHeight: Int?)

    var summary: String {
        switch self {
        case .text(let added, let removed):
            return "+\(added) / −\(removed) lines"
        case .binary(let bytes, let width, let height):
            let size = ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
            if let width, let height { return "\(size) · \(width)×\(height) px" }
            return size
        }
    }
}
