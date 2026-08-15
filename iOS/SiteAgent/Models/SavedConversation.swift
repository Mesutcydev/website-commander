import Foundation

struct SavedConversation: Identifiable, Codable {
    var id: UUID = UUID()
    var title: String
    var date: Date = Date()
    /// Additive; old saved chats decode as `false` via `decodeIfPresent`.
    var isPinned: Bool = false
    var transcript: [ChatMessage]
    var history: [LLMMessage]

    init(
        id: UUID = UUID(),
        title: String,
        date: Date = Date(),
        isPinned: Bool = false,
        transcript: [ChatMessage],
        history: [LLMMessage]
    ) {
        self.id = id
        self.title = title
        self.date = date
        self.isPinned = isPinned
        self.transcript = transcript
        self.history = history
    }

    private enum CodingKeys: String, CodingKey {
        case id, title, date, isPinned, transcript, history
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        title = try values.decode(String.self, forKey: .title)
        date = try values.decodeIfPresent(Date.self, forKey: .date) ?? Date()
        isPinned = try values.decodeIfPresent(Bool.self, forKey: .isPinned) ?? false
        transcript = try values.decode([ChatMessage].self, forKey: .transcript)
        history = try values.decode([LLMMessage].self, forKey: .history)
    }
}
