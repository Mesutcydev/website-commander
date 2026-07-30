import Foundation

/// A persisted conversation, optionally tied to a workspace so each site can keep
/// its own history. `title` defaults to the first user message.
struct SavedConversation: Identifiable, Codable, Equatable {
    var id: UUID = UUID()
    var workspaceID: UUID?
    var title: String
    var messages: [ChatMessage]
    var updatedAt: Date = Date()
}
