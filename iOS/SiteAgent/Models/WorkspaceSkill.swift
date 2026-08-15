import Foundation

struct WorkspaceSkill: Identifiable, Codable, Equatable {
    let id: UUID
    var name: String
    var summary: String
    var instructions: String
    var priority: Int
    var usageCount: Int
    var isEnabled: Bool
    var workspaceID: UUID?

    init(
        id: UUID = UUID(),
        name: String,
        summary: String,
        instructions: String,
        priority: Int = 50,
        usageCount: Int = 0,
        isEnabled: Bool = true,
        workspaceID: UUID? = nil
    ) {
        self.id = id
        self.name = name
        self.summary = summary
        self.instructions = instructions
        self.priority = priority
        self.usageCount = usageCount
        self.isEnabled = isEnabled
        self.workspaceID = workspaceID
    }
}
