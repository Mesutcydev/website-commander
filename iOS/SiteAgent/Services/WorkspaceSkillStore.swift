import Foundation

@MainActor
final class WorkspaceSkillStore: ObservableObject {
    static let shared = WorkspaceSkillStore()

    @Published private(set) var skills: [WorkspaceSkill] = []
    private let defaults: UserDefaults
    private let key = "workspaceSkillsV1"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: key),
           let decoded = try? JSONDecoder().decode([WorkspaceSkill].self, from: data) {
            skills = decoded
        } else {
            skills = Self.builtins
            persist()
        }
        sort()
    }

    func save(_ skill: WorkspaceSkill) {
        if let index = skills.firstIndex(where: { $0.id == skill.id }) {
            skills[index] = skill
        } else {
            skills.append(skill)
        }
        sort()
        persist()
    }

    func delete(_ skill: WorkspaceSkill) {
        skills.removeAll { $0.id == skill.id }
        persist()
    }

    func enabledInstructions(workspaceID: UUID?) -> String {
        skills
            .filter { $0.isEnabled && ($0.workspaceID == nil || $0.workspaceID == workspaceID) }
            .sorted {
                if $0.priority != $1.priority { return $0.priority > $1.priority }
                return $0.usageCount > $1.usageCount
            }
            .map { "### \($0.name)\n\($0.instructions)" }
            .joined(separator: "\n\n")
    }

    private func sort() {
        skills.sort {
            if $0.priority != $1.priority { return $0.priority > $1.priority }
            if $0.usageCount != $1.usageCount { return $0.usageCount > $1.usageCount }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    private func persist() {
        defaults.set(try? JSONEncoder().encode(skills), forKey: key)
    }

    private static let builtins: [WorkspaceSkill] = [
        WorkspaceSkill(
            name: "Accessibility Guard",
            summary: "Preserve semantic structure, contrast, keyboard access, and descriptive alternatives.",
            instructions: "For visible changes, preserve semantic HTML, keyboard navigation, focus visibility, readable contrast, reduced-motion behavior, and useful alt text. Report any requirement you cannot verify.",
            priority: 90
        ),
        WorkspaceSkill(
            name: "SEO Hygiene",
            summary: "Protect metadata, headings, canonical URLs, and structured content.",
            instructions: "When editing pages, preserve or improve the title, meta description, canonical URL, heading hierarchy, link meaning, and relevant structured data. Avoid keyword stuffing.",
            priority: 70
        ),
        WorkspaceSkill(
            name: "Performance Budget",
            summary: "Avoid unnecessary JavaScript, oversized assets, and render-blocking changes.",
            instructions: "Prefer the smallest dependency-free implementation. Do not add render-blocking resources or oversized assets. Preserve lazy loading and explicit image dimensions where applicable.",
            priority: 60
        )
    ]
}
