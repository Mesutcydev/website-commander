import Foundation

struct ConfigurationAuditEntry: Identifiable, Codable, Equatable {
    let id: UUID
    let createdAt: Date
    let source: String
    let before: ProviderConfigurationArchive
    let after: ProviderConfigurationArchive

    init(
        id: UUID = UUID(),
        createdAt: Date = Date(),
        source: String,
        before: ProviderConfigurationArchive,
        after: ProviderConfigurationArchive
    ) {
        self.id = id
        self.createdAt = createdAt
        self.source = source
        self.before = before
        self.after = after
    }
}

@MainActor
final class ConfigurationAuditStore: ObservableObject {
    static let shared = ConfigurationAuditStore()

    @Published private(set) var entries: [ConfigurationAuditEntry] = []
    private let defaultsKey = "provider_configuration_audit_v1"

    private init() {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey),
              let stored = try? JSONDecoder().decode([ConfigurationAuditEntry].self, from: data)
        else { return }
        entries = stored
    }

    func record(source: String, before: ProviderConfigurationArchive, after: ProviderConfigurationArchive) {
        guard before != after else { return }
        entries.insert(ConfigurationAuditEntry(source: source, before: before, after: after), at: 0)
        entries = Array(entries.prefix(20))
        persist()
    }

    func remove(_ id: UUID) {
        entries.removeAll { $0.id == id }
        persist()
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(entries) {
            UserDefaults.standard.set(data, forKey: defaultsKey)
        }
    }
}
