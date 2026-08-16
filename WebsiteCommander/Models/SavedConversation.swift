import Foundation

/// A persisted conversation, optionally tied to a workspace so each site can keep
/// its own history. `title` defaults to the first user message. Unreviewed
/// staged changes are persisted alongside the conversation so a quit/relaunch
/// does not silently drop the user's review work.
struct SavedConversation: Identifiable, Codable, Equatable {
    var id: UUID = UUID()
    var workspaceID: UUID?
    var title: String
    var messages: [ChatMessage]
    var updatedAt: Date = Date()
    var pendingChanges: [PendingChange] = []

    init(id: UUID = UUID(), workspaceID: UUID?, title: String, messages: [ChatMessage],
         updatedAt: Date = Date(), pendingChanges: [PendingChange] = []) {
        self.id = id
        self.workspaceID = workspaceID
        self.title = title
        self.messages = messages
        self.updatedAt = updatedAt
        self.pendingChanges = pendingChanges
    }

    private enum CodingKeys: String, CodingKey {
        case id, workspaceID, title, messages, updatedAt, pendingChanges
    }

    /// Tolerant decode: older saved conversations predate `pendingChanges`, so a
    /// missing key falls back to an empty list instead of failing the whole load.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        workspaceID = try c.decodeIfPresent(UUID.self, forKey: .workspaceID)
        title = try c.decode(String.self, forKey: .title)
        messages = try c.decode([ChatMessage].self, forKey: .messages)
        updatedAt = try c.decodeIfPresent(Date.self, forKey: .updatedAt) ?? Date()
        pendingChanges = try c.decodeIfPresent([PendingChange].self, forKey: .pendingChanges) ?? []
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encodeIfPresent(workspaceID, forKey: .workspaceID)
        try c.encode(title, forKey: .title)
        try c.encode(messages, forKey: .messages)
        try c.encode(updatedAt, forKey: .updatedAt)
        try c.encode(pendingChanges, forKey: .pendingChanges)
    }
}
