import Foundation

// MARK: - Chat

enum ChatRole: String, Codable {
    case user
    case assistant
    case system
    case tool
}

/// A file the user attached to a chat message (an image or any file). Images go
/// to vision-capable models; text files are inlined into the prompt.
struct Attachment: Identifiable, Codable, Equatable {
    static let maximumCount = 5
    static let maximumImageBytes = 10 * 1024 * 1024
    static let maximumTextBytes = 1 * 1024 * 1024
    let id: UUID
    var filename: String
    var mimeType: String
    var data: Data

    init(id: UUID = UUID(), filename: String, mimeType: String, data: Data) {
        self.id = id
        self.filename = filename
        self.mimeType = mimeType
        self.data = data
    }

    var isImage: Bool { mimeType.hasPrefix("image/") }

    var isTextual: Bool {
        if mimeType.hasPrefix("text/") { return true }
        switch (filename as NSString).pathExtension.lowercased() {
        case "txt", "md", "markdown", "html", "htm", "css", "js", "ts", "json",
             "svg", "xml", "yml", "yaml", "csv", "sh", "py", "swift", "toml", "ini":
            return true
        default: return false
        }
    }

    var asText: String? {
        guard isTextual else { return nil }
        return String(data: data, encoding: .utf8)
    }

    var byteLabel: String {
        ByteCountFormatter.string(fromByteCount: Int64(data.count), countStyle: .file)
    }
}

/// A single message in the conversation transcript shown in the chat UI.
struct ChatMessage: Identifiable, Codable, Equatable {
    let id: UUID
    var role: ChatRole
    var text: String
    var toolEvents: [ToolEvent]
    var attachments: [Attachment]
    /// Real provider reasoning / thinking text. Nil when the model did not
    /// return any — never populated with synthetic content.
    var reasoning: String?
    var date: Date

    init(id: UUID = UUID(), role: ChatRole, text: String, toolEvents: [ToolEvent] = [],
         attachments: [Attachment] = [], reasoning: String? = nil, date: Date = Date()) {
        self.id = id
        self.role = role
        self.text = text
        self.toolEvents = toolEvents
        self.attachments = attachments
        self.reasoning = reasoning
        self.date = date
    }
}

/// A record of one tool invocation, rendered inline under an assistant message.
struct ToolEvent: Identifiable, Codable, Equatable {
    let id: UUID
    var name: String
    var summary: String
    var status: Status

    enum Status: String, Codable { case running, success, failure }

    init(id: UUID = UUID(), name: String, summary: String, status: Status = .running) {
        self.id = id
        self.name = name
        self.summary = summary
        self.status = status
    }
}

// MARK: - GitHub file model

/// A file or directory entry returned by the GitHub contents API.
struct RepoEntry: Identifiable, Hashable {
    var path: String
    var type: EntryType
    var sha: String?
    var size: Int?

    enum EntryType: String { case file, dir }

    var id: String { path }
    var name: String { (path as NSString).lastPathComponent }
}

/// Lightweight repo row for the Connect Website wizard.
struct GitHubRepoSummary: Identifiable, Equatable, Hashable {
    var id: Int
    var owner: String
    var name: String
    var fullName: String
    var defaultBranch: String
    var homepage: String?
    var isPrivate: Bool

    var displayTitle: String {
        if let homepage, !homepage.isEmpty {
            let cleaned = homepage
                .replacingOccurrences(of: "https://", with: "")
                .replacingOccurrences(of: "http://", with: "")
                .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            if !cleaned.isEmpty { return cleaned }
        }
        return name
    }
}

// MARK: - Pending change (the approval gate)

enum ChangeCategory: String, Codable {
    case content = "Content"
    case design = "Design/CSS"
    case structural = "Structural"
    case assets = "Assets"
    case other = "Other"

    var icon: String {
        switch self {
        case .content:     return "doc.text.fill"
        case .design:      return "paintbrush.fill"
        case .structural:  return "folder.fill"
        case .assets:      return "photo.fill"
        case .other:       return "doc.fill"
        }
    }

    var tintName: String {
        switch self {
        case .content:     return "blue"
        case .design:      return "purple"
        case .structural:  return "orange"
        case .assets:      return "pink"
        case .other:       return "gray"
        }
    }
}

/// A file write the agent wants to commit, held until the user approves.
struct PendingChange: Identifiable, Equatable {
    let id = UUID()
    var path: String
    var oldContent: String?   // nil for a brand-new file
    var newContent: String
    var message: String       // proposed commit message
    var isDeletion: Bool = false
    /// Security-scan findings, computed at stage time. Non-empty means "look closely".
    var risks: [String] = []
    /// Blob SHA when staged — used to detect a concurrent edit at commit time.
    var baseSHA: String? = nil

    var isNewFile: Bool { oldContent == nil && !isDeletion }

    var category: ChangeCategory {
        let p = path.lowercased()
        if p.hasSuffix(".css") { return .design }
        if p.contains("js/data/") || p.hasSuffix(".json") || p.contains("i18n") { return .content }
        if p == "index.html" || p.contains("js/pages/") || p.contains("js/router.js") { return .structural }
        if p.hasPrefix("assets/") || [".png", ".jpg", ".jpeg", ".gif", ".svg", ".webp"]
            .contains(where: { p.hasSuffix($0) }) { return .assets }
        return .other
    }

    var addedLines: Int {
        guard let old = oldContent else { return newContent.split(separator: "\n").count }
        return Self.diffCounts(old: old, new: newContent).added
    }

    var removedLines: Int {
        guard let old = oldContent else { return 0 }
        return Self.diffCounts(old: old, new: newContent).removed
    }

    /// A coarse line-set diff count (good enough for the at-a-glance badge).
    static func diffCounts(old: String, new: String) -> (added: Int, removed: Int) {
        let oldLines = old.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let newLines = new.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let oldSet = Set(oldLines)
        let newSet = Set(newLines)
        let added = newLines.filter { !oldSet.contains($0) }.count
        let removed = oldLines.filter { !newSet.contains($0) }.count
        return (added, removed)
    }
}

// MARK: - Commit history

/// A commit row from the GitHub commits API.
struct CommitEntry: Identifiable, Equatable {
    var id: String { sha }
    var sha: String
    var message: String
    var author: String
    var date: Date

    var shortSHA: String { String(sha.prefix(7)) }
}
