import Foundation

// MARK: - Tech stack icon

extension TechStack {
    /// SF Symbol for the stack, shared by the Sites tab and workspace picker.
    var icon: String {
        switch self {
        case .vanillaHTML: return "globe"
        case .hugo:        return "doc.text.fill"
        case .jekyll:      return "book.closed.fill"
        case .nextjs:      return "app.window.reference"
        case .astro:       return "sparkles"
        case .sveltekit:   return "s.square.fill"
        case .eleventy:    return "11.square.fill"
        case .custom:      return "terminal.fill"
        }
    }
}

// MARK: - Repo configuration

/// Identifies the GitHub repository the agent manages.
struct RepoConfig: Codable, Equatable {
    var owner: String
    var name: String
    var branch: String
    var githubCredentialID: UUID? = nil

    /// Placeholder when no workspace is connected yet. GitHub calls against it
    /// fail cleanly; the UI gates on `activeWorkspace` / `isReady` before using it.
    static let none = RepoConfig(owner: "", name: "", branch: "main")

    var isEmpty: Bool { owner.isEmpty || name.isEmpty }
    var slug: String { isEmpty ? "—" : "\(owner)/\(name)" }
}

// MARK: - Chat

enum ChatRole: String, Codable {
    case user
    case assistant
    case system
    case tool
}

/// A file the user attached to a chat message (an image or any file). Images are
/// shown to vision-capable models; text files are inlined; and any attachment can
/// be committed to the repo by the agent via the `upload_attachment` tool.
struct Attachment: Identifiable, Codable, Equatable {
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
    var byteCount: Int { data.count }

    /// Whether this looks like a UTF-8 text file (so its contents can be inlined).
    var isTextual: Bool {
        if mimeType.hasPrefix("text/") { return true }
        switch (filename as NSString).pathExtension.lowercased() {
        case "txt", "md", "markdown", "html", "htm", "css", "js", "ts", "json",
             "svg", "xml", "yml", "yaml", "csv", "sh", "py", "swift", "toml", "ini":
            return true
        default: return false
        }
    }

    /// The file decoded as UTF-8 text, if it's textual and valid.
    var asText: String? {
        guard isTextual else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

/// A single message in the conversation transcript shown in the chat UI.
struct ChatMessage: Identifiable, Codable, Equatable {
    let id: UUID
    var role: ChatRole
    var text: String
    /// Tool activity attached to an assistant turn (e.g. "read file", "wrote file").
    var toolEvents: [ToolEvent]
    /// Files the user attached to this (user) message.
    var attachments: [Attachment]
    var date: Date

    init(id: UUID = UUID(), role: ChatRole, text: String, toolEvents: [ToolEvent] = [],
         attachments: [Attachment] = [], date: Date = Date()) {
        self.id = id
        self.role = role
        self.text = text
        self.toolEvents = toolEvents
        self.attachments = attachments
        self.date = date
    }
}

/// A record of one tool invocation, rendered inline under the assistant message.
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

/// Lightweight repo row for the Connect Website wizard (`GET /user/repos`).
struct GitHubRepoSummary: Identifiable, Equatable, Hashable {
    var id: Int
    var owner: String
    var name: String
    var fullName: String
    var defaultBranch: String
    var homepage: String?
    var description: String?
    var isPrivate: Bool

    /// Friendly title: homepage host when present, otherwise the repo name.
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

    init?(json: [String: Any]) {
        guard let id = json["id"] as? Int,
              let name = json["name"] as? String,
              let fullName = json["full_name"] as? String,
              let ownerObj = json["owner"] as? [String: Any],
              let owner = ownerObj["login"] as? String else { return nil }
        self.id = id
        self.owner = owner
        self.name = name
        self.fullName = fullName
        self.defaultBranch = (json["default_branch"] as? String) ?? "main"
        let home = (json["homepage"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.homepage = (home?.isEmpty == false) ? home : nil
        self.description = json["description"] as? String
        self.isPrivate = (json["private"] as? Bool) ?? false
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
        case .content: return "doc.text.fill"
        case .design: return "paintbrush.fill"
        case .structural: return "folder.fill"
        case .assets: return "photo.fill"
        case .other: return "doc.fill"
        }
    }
}

// MARK: - Approval Data Model

/// A pending approval that the user must act on before the agent continues.
struct PendingApproval: Identifiable, Equatable {
    let id: UUID
    let sessionID: UUID
    let originatingRunID: Int
    let title: String
    let summary: String
    let proposedActions: [ProposedAction]
    let createdAt: Date
    let expiresAt: Date?

    var isExpired: Bool {
        guard let expiresAt else { return false }
        return Date() > expiresAt
    }

    init(id: UUID = UUID(), sessionID: UUID, originatingRunID: Int,
         title: String, summary: String, proposedActions: [ProposedAction],
         createdAt: Date = Date(), expiresAt: Date? = nil) {
        self.id = id
        self.sessionID = sessionID
        self.originatingRunID = originatingRunID
        self.title = title
        self.summary = summary
        self.proposedActions = proposedActions
        self.createdAt = createdAt
        self.expiresAt = expiresAt
    }
}

/// A concrete action proposed by the agent that requires user approval.
enum ProposedAction: Equatable {
    case applyPatch(path: String, patch: String)
    case replaceText(path: String, oldText: String, newText: String, expectedOccurrences: Int)
    case executeTool(name: String, arguments: [String: Any])

    static func == (lhs: ProposedAction, rhs: ProposedAction) -> Bool {
        switch (lhs, rhs) {
        case let (.applyPatch(lp, lpatch), .applyPatch(rp, rpatch)):
            return lp == rp && lpatch == rpatch
        case let (.replaceText(lp, lo, ln, le), .replaceText(rp, ro, rn, re)):
            return lp == rp && lo == ro && ln == rn && le == re
        case let (.executeTool(ln, la), .executeTool(rn, ra)):
            return ln == rn && NSDictionary(dictionary: la).isEqual(to: ra)
        default: return false
        }
    }
}

/// Result of an approval action.
enum ApprovalResult {
    case accepted
    case alreadyHandled
    case notReady
    case expired
    case missing
    case sessionMismatch
    case failed(Error)

    var isAccepted: Bool {
        if case .accepted = self { return true }
        return false
    }
}

/// Risk classification for a tool or proposed action.
enum ToolRisk: Comparable {
    case readOnly
    case reversibleLocalEdit
    case destructiveLocalEdit
    case externalSideEffect
    case securitySensitive
}

/// Records an approval event to prevent loops.
struct ApprovalRecord: Identifiable, Equatable {
    let id: UUID
    let approvalID: UUID
    let sessionID: UUID
    let runID: Int
    let outcome: Outcome
    let timestamp: Date

    enum Outcome: Equatable { case approved, rejected, expired }

    init(id: UUID = UUID(), approvalID: UUID, sessionID: UUID, runID: Int,
         outcome: Outcome, timestamp: Date = Date()) {
        self.id = id
        self.approvalID = approvalID
        self.sessionID = sessionID
        self.runID = runID
        self.outcome = outcome
        self.timestamp = timestamp
    }
}

// MARK: - Structured Logging

/// A lightweight structured log entry for debugging agent lifecycle issues.
/// Never includes secrets or full repository contents.
struct RunLogEntry: Identifiable {
    let id = UUID()
    let timestamp: Date
    let event: String
    let details: [String: String]

    init(event: String, details: [String: String] = [:]) {
        self.timestamp = Date()
        self.event = event
        self.details = details
    }

    var formatted: String {
        let df = DateFormatter()
        df.dateFormat = "HH:mm:ss.SSS"
        let detailStr = details.map { "\($0.key)=\($0.value)" }.joined(separator: " ")
        return "[\(df.string(from: timestamp))] \(event) \(detailStr)"
    }
}

// MARK: - Safe Arguments Wrapper

/// A dictionary wrapper that avoids logging potentially sensitive values.
struct SafeToolArguments: Equatable {
    let raw: [String: Any]

    static func == (lhs: SafeToolArguments, rhs: SafeToolArguments) -> Bool {
        NSDictionary(dictionary: lhs.raw).isEqual(to: rhs.raw)
    }
}

/// A file write the agent wants to commit, held until the user approves.
struct PendingChange: Identifiable, Equatable {
    let id = UUID()
    var path: String
    var oldContent: String?   // nil for a brand-new file
    var newContent: String
    var message: String       // proposed commit message
    /// Set when staging a binary/attachment upload (then `newContent` is unused
    /// and the diff view shows a preview instead of a line diff).
    var uploadData: Data?
    var isDeletion: Bool = false
    /// SecurityScan findings, computed at stage time for every change. Non-empty
    /// means "a human should look closely"; surfaced in the diff review.
    var risks: [String] = []
    /// Blob SHA of the file when this change was staged — used to detect a
    /// concurrent edit (TOCTOU) at commit time so a stale review can't clobber.
    var baseSHA: String? = nil
    /// Local-only sample change used by the guided demo. It is never committed.
    var isDemo: Bool = false

    var isNewFile: Bool { oldContent == nil && !isDeletion }
    var isUpload: Bool { uploadData != nil }

    var category: ChangeCategory {
        if isUpload {
            return .assets
        }
        let lowerPath = path.lowercased()
        if lowerPath.hasSuffix(".css") {
            return .design
        }
        if lowerPath.contains("js/data/") || lowerPath.hasSuffix(".json") || lowerPath.contains("i18n") {
            return .content
        }
        if lowerPath == "index.html" || lowerPath.contains("js/pages/") || lowerPath.contains("js/router.js") {
            return .structural
        }
        if lowerPath.hasPrefix("assets/") || lowerPath.hasSuffix(".png") || lowerPath.hasSuffix(".jpg") || lowerPath.hasSuffix(".jpeg") || lowerPath.hasSuffix(".gif") || lowerPath.hasSuffix(".svg") || lowerPath.hasSuffix(".webp") {
            return .assets
        }
        return .other
    }
}

// MARK: - Operation Tracking

struct ToolExecutionRecord: Codable, Equatable {
    let toolCallID: String
    let toolName: String
    let arguments: String
    let timestamp: Date
    let isMutating: Bool
    let success: Bool
    let error: String?
}

enum AgentOperationOutcome: Codable, Equatable {
    case completed(OperationSuccess)
    case partiallyCompleted(PartialResult)
    case failed(AgentError)
    case cancelled
    case timedOut
}

struct OperationSuccess: Codable, Equatable {
    let message: String
}

struct PartialResult: Codable, Equatable {
    let message: String
}

struct AgentError: Codable, Equatable {
    let code: Int
    let message: String
}

struct MutationIdentity: Hashable, Codable {
    let operationID: UUID
    let path: String
    let normalizedPatchHash: String
}

struct AgentOperationState: Codable, Equatable {
    let operationID: UUID
    let sessionID: UUID
    let originatingUserMessageID: UUID

    var requestedMutation: Bool
    var editingToolInvoked: Bool
    var editingToolSucceeded: Bool
    var mutationCommitted: Bool
    var verificationSucceeded: Bool

    var changedFiles: Set<String>
    var successfulToolCalls: [ToolExecutionRecord]
    var failedToolCalls: [ToolExecutionRecord]

    var recoveryAttempts: Int
    var terminalOutcome: AgentOperationOutcome?
}
