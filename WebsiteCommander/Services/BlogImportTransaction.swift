import Foundation

/// In-memory transaction for an import. GitHub is not touched while changes
/// are buffered; the engine publishes the complete list through the Git Data
/// API only after the user approves it.
actor BlogImportTransaction {
    let sessionID: UUID
    let baseCommitSHA: String
    private var bufferedChanges: [PendingChange] = []

    init(sessionID: UUID, baseCommitSHA: String) {
        self.sessionID = sessionID
        self.baseCommitSHA = baseCommitSHA
    }

    func add(_ change: PendingChange) throws {
        guard change.importSessionID == sessionID else {
            throw BlogImportTransactionError.wrongSession
        }
        guard BlogPathRules.normalizedRelativePath(change.path) != nil else {
            throw BlogImportTransactionError.invalidPath(change.path)
        }
        if let index = bufferedChanges.firstIndex(where: { $0.path.caseInsensitiveCompare(change.path) == .orderedSame }) {
            bufferedChanges[index] = change
        } else {
            bufferedChanges.append(change)
        }
    }

    func add(contentsOf changes: [PendingChange]) throws {
        for change in changes { try add(change) }
    }

    func changes() -> [PendingChange] { bufferedChanges }

    /// Validate the buffer and return a publish snapshot. No network or disk
    /// mutation happens here, which makes a failed preparation rollback-safe.
    func publish() throws -> [PendingChange] {
        guard !bufferedChanges.isEmpty else { throw BlogImportTransactionError.empty }
        for change in bufferedChanges {
            guard change.importSessionID == sessionID else {
                throw BlogImportTransactionError.wrongSession
            }
        }
        return bufferedChanges
    }

    func rollback() {
        bufferedChanges.removeAll()
    }
}

enum BlogImportTransactionError: LocalizedError, Equatable, Sendable {
    case empty
    case wrongSession
    case invalidPath(String)

    var errorDescription: String? {
        switch self {
        case .empty: return "The blog import contains no changes."
        case .wrongSession: return "The blog change belongs to a different import session."
        case .invalidPath(let path): return "The blog import produced an unsafe repository path: \(path)"
        }
    }
}

enum BlogPathRules {
    /// Normalize a model-provided repository path without resolving it against
    /// a local filesystem. This rejects traversal before any GitHub call.
    static func normalizedRelativePath(_ raw: String) -> String? {
        guard !raw.isEmpty,
              !raw.contains("\\"),
              !raw.contains("\0"),
              !raw.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            return nil
        }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("/"), !trimmed.hasPrefix("~") else { return nil }
        let components = trimmed.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard !components.isEmpty,
              !components.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }),
              !components.contains(where: { $0.caseInsensitiveCompare(".git") == .orderedSame }) else {
            return nil
        }
        return components.joined(separator: "/")
    }

    static func isPath(_ path: String, inside root: String) -> Bool {
        guard let path = normalizedRelativePath(path),
              let root = normalizedRelativePath(root) else { return false }
        let foldedPath = path.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
        let foldedRoot = root.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
        return foldedPath == foldedRoot || foldedPath.hasPrefix(foldedRoot + "/")
    }

    static func normalizedFilenameStem(_ raw: String) -> String? {
        guard !raw.isEmpty,
              !raw.contains("\\"),
              !raw.contains("/"),
              !raw.contains("\0"),
              !raw.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            return nil
        }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.hasPrefix(".") else { return nil }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        let scalars = trimmed.unicodeScalars.map { allowed.contains($0) ? Character($0) : "-" }
        let stem = String(scalars).replacingOccurrences(of: "-{2,}", with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        guard !stem.isEmpty,
              stem.caseInsensitiveCompare(".git") != .orderedSame,
              stem.caseInsensitiveCompare("git") != .orderedSame else { return nil }
        return String(stem.prefix(100))
    }
}
