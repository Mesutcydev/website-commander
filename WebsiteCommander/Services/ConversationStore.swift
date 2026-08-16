import Foundation

/// Persists conversations to Application Support. Conversations are saved
/// automatically by `AgentEngine` — there is no manual "save" step — so this
/// store's job is to make every upsert cheap, id-stable, and durable.
///
/// Tolerant of older files and injectable path so tests never touch the
/// user's data.
@MainActor
final class ConversationStore: ObservableObject {

    @Published private(set) var conversations: [SavedConversation] = []

    private static func defaultFileURL() -> URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("WebsiteCommander", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("conversations.json")
    }

    static var fileURL: URL = ConversationStore.defaultFileURL()

    init() { load() }

    func load() {
        let url = Self.fileURL
        guard let data = try? Data(contentsOf: url) else {
            conversations = []; return
        }
        guard let list = try? JSONDecoder().decode([SavedConversation].self, from: data) else {
            // A corrupt or version-incompatible file must never be silently
            // overwritten by the next autosave. Quarantine it so the user can
            // recover their history instead of losing it permanently.
            Self.quarantineCorruptFile(url)
            conversations = []; return
        }
        conversations = list.sorted { $0.updatedAt > $1.updatedAt }
    }

    /// Move a file that failed to decode aside so a subsequent `persist()` cannot
    /// clobber the user's real history with an empty list.
    private static func quarantineCorruptFile(_ url: URL) {
        let stamp = Int(Date().timeIntervalSince1970)
        let backup = url.deletingLastPathComponent()
            .appendingPathComponent("conversations.corrupt-\(stamp).json")
        try? FileManager.default.moveItem(at: url, to: backup)
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(conversations) else { return }
        // The parent directory can be missing on a first run or after a manual
        // cleanup; autosave must not silently fail because of it.
        let dir = Self.fileURL.deletingLastPathComponent()
        if !FileManager.default.fileExists(atPath: dir.path) {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        try? data.write(to: Self.fileURL, options: .atomic)
    }

    /// Conversations for a workspace (nil = unscoped / all-site).
    func list(forWorkspaceID id: UUID?) -> [SavedConversation] {
        conversations.filter { $0.workspaceID == id }.sorted { $0.updatedAt > $1.updatedAt }
    }

    func conversation(id: UUID) -> SavedConversation? {
        conversations.first { $0.id == id }
    }

    /// Create or update a conversation and write it to disk.
    ///
    /// - `id` is honoured even when the record is missing (a fresh install, a
    ///   pruned file), so a live chat keeps the same identity for its whole
    ///   life instead of forking a new row on every autosave.
    /// - A nil/blank `title` never overwrites a title the user set; it only
    ///   seeds one derived from the first user message.
    @discardableResult
    func save(title: String?, messages: [ChatMessage], pendingChanges: [PendingChange] = [],
              workspaceID: UUID?, id: UUID? = nil) -> SavedConversation? {
        guard !messages.isEmpty else { return nil }
        let requested = title?.trimmingCharacters(in: .whitespacesAndNewlines)
        let explicitTitle = (requested?.isEmpty == false) ? requested : nil

        if let id, let idx = conversations.firstIndex(where: { $0.id == id }) {
            if let explicitTitle {
                conversations[idx].title = explicitTitle
            } else if conversations[idx].title.trimmingCharacters(in: .whitespaces).isEmpty {
                conversations[idx].title = Self.deriveTitle(from: messages)
            }
            conversations[idx].messages = messages
            conversations[idx].pendingChanges = pendingChanges
            conversations[idx].updatedAt = Date()
            persist(); return conversations[idx]
        }

        let conv = SavedConversation(id: id ?? UUID(),
                                     workspaceID: workspaceID,
                                     title: explicitTitle ?? Self.deriveTitle(from: messages),
                                     messages: messages,
                                     pendingChanges: pendingChanges)
        conversations.insert(conv, at: 0)
        persist(); return conv
    }

    /// Rename a conversation in place. Blank titles are ignored.
    @discardableResult
    func rename(_ id: UUID, to title: String) -> Bool {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let idx = conversations.firstIndex(where: { $0.id == id }) else { return false }
        conversations[idx].title = trimmed
        conversations[idx].updatedAt = Date()
        persist()
        return true
    }

    func delete(_ id: UUID) {
        conversations.removeAll { $0.id == id }
        persist()
    }

    private static func deriveTitle(from messages: [ChatMessage]) -> String {
        let first = messages.first(where: { $0.role == .user })?.text ?? "Conversation"
        let oneLine = first.split(separator: "\n").first.map(String.init) ?? first
        let trimmed = oneLine.trimmingCharacters(in: .whitespacesAndNewlines)
        return String((trimmed.isEmpty ? "Conversation" : trimmed).prefix(48))
    }
}
