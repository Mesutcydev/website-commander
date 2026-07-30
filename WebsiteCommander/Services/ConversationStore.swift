import Foundation

/// Persists saved conversations to Application Support. Tolerant of older files
/// and injectable path so tests never touch the user's data.
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
        guard let data = try? Data(contentsOf: Self.fileURL),
              let list = try? JSONDecoder().decode([SavedConversation].self, from: data) else {
            conversations = []; return
        }
        conversations = list.sorted { $0.updatedAt > $1.updatedAt }
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(conversations) else { return }
        try? data.write(to: Self.fileURL, options: .atomic)
    }

    /// Conversations for a workspace (nil = unscoped / all-site).
    func list(forWorkspaceID id: UUID?) -> [SavedConversation] {
        conversations.filter { $0.workspaceID == id }.sorted { $0.updatedAt > $1.updatedAt }
    }

    @discardableResult
    func save(title: String?, messages: [ChatMessage], workspaceID: UUID?, id: UUID? = nil) -> SavedConversation? {
        guard !messages.isEmpty else { return nil }
        let resolvedTitle = (title?.trimmingCharacters(in: .whitespaces).isEmpty == false)
            ? title! : Self.deriveTitle(from: messages)
        if let id, let idx = conversations.firstIndex(where: { $0.id == id }) {
            conversations[idx].title = resolvedTitle
            conversations[idx].messages = messages
            conversations[idx].updatedAt = Date()
            persist(); return conversations[idx]
        }
        let conv = SavedConversation(workspaceID: workspaceID, title: resolvedTitle, messages: messages)
        conversations.insert(conv, at: 0)
        persist(); return conv
    }

    func delete(_ id: UUID) {
        conversations.removeAll { $0.id == id }
        persist()
    }

    private static func deriveTitle(from messages: [ChatMessage]) -> String {
        let first = messages.first(where: { $0.role == .user })?.text ?? "Conversation"
        let oneLine = first.split(separator: "\n").first.map(String.init) ?? first
        return String(oneLine.prefix(48))
    }
}
