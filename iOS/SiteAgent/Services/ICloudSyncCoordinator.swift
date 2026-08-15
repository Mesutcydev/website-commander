import Foundation

private struct CloudRecordEnvelope: Codable {
    var kind: String
    var id: UUID
    var modifiedAt: Date
    var tombstone: Bool
    var payload: Data?
}

/// Opt-in, record-level iCloud key-value sync for the small continuity records
/// SiteAgent owns. Every workspace/conversation is independent, deletes use
/// tombstones, and secrets are never part of any synced payload.
@MainActor
final class ICloudSyncCoordinator: ObservableObject {
    static let shared = ICloudSyncCoordinator()

    @Published private(set) var status = "Off"
    @Published private(set) var lastSyncAt: Date?

    private let store = NSUbiquitousKeyValueStore.default
    private let prefix = "siteagent.sync.v1."
    private let maximumRecordBytes = 60_000
    private weak var engine: AgentEngine?
    private var observing = false
    private var applyingRemote = false

    var isEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: "icloud_record_sync_enabled") }
        set {
            UserDefaults.standard.set(newValue, forKey: "icloud_record_sync_enabled")
            objectWillChange.send()
            if newValue {
                status = "Syncing…"
                store.synchronize()
                mergeRemoteRecords()
            } else {
                status = "Off"
            }
        }
    }

    private init() {}

    func start(engine: AgentEngine) {
        self.engine = engine
        guard !observing else { return }
        observing = true
        NotificationCenter.default.addObserver(
            forName: NSUbiquitousKeyValueStore.didChangeExternallyNotification,
            object: store,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.mergeRemoteRecords() }
        }
        if isEnabled {
            status = "Syncing…"
            store.synchronize()
            mergeRemoteRecords()
        }
    }

    func syncNow() {
        guard isEnabled else { return }
        store.synchronize()
        mergeRemoteRecords()
    }

    func pushConversation(_ conversation: SavedConversation) {
        push(kind: "conversation", id: conversation.id, payload: conversation, modifiedAt: conversation.date)
    }

    func deleteConversation(_ id: UUID) {
        pushTombstone(kind: "conversation", id: id)
    }

    func pushWorkspace(_ workspace: SiteWorkspace) {
        push(kind: "workspace", id: workspace.id, payload: workspace)
    }

    func deleteWorkspace(_ id: UUID) {
        pushTombstone(kind: "workspace", id: id)
    }

    func pushConfiguration(_ archive: ProviderConfigurationArchive) {
        push(kind: "configuration", id: Self.configurationID, payload: archive)
    }

    private func push<T: Encodable>(
        kind: String,
        id: UUID,
        payload: T,
        modifiedAt: Date = Date()
    ) {
        guard isEnabled, !applyingRemote else { return }
        do {
            let payloadData = try JSONEncoder().encode(payload)
            let envelope = CloudRecordEnvelope(
                kind: kind,
                id: id,
                modifiedAt: modifiedAt,
                tombstone: false,
                payload: payloadData
            )
            let data = try JSONEncoder().encode(envelope)
            guard data.count <= maximumRecordBytes else {
                status = "\(kind.capitalized) too large to sync; kept safely on this device."
                return
            }
            store.set(data, forKey: key(kind: kind, id: id))
            store.synchronize()
            didSync()
        } catch {
            status = "Sync error: \(error.localizedDescription)"
        }
    }

    private func pushTombstone(kind: String, id: UUID) {
        guard isEnabled, !applyingRemote else { return }
        let envelope = CloudRecordEnvelope(
            kind: kind,
            id: id,
            modifiedAt: Date(),
            tombstone: true,
            payload: nil
        )
        if let data = try? JSONEncoder().encode(envelope) {
            store.set(data, forKey: key(kind: kind, id: id))
            store.synchronize()
            didSync()
        }
    }

    private func mergeRemoteRecords() {
        guard isEnabled, !applyingRemote else { return }
        applyingRemote = true
        defer { applyingRemote = false }

        let records = store.dictionaryRepresentation
            .filter { $0.key.hasPrefix(prefix) }
            .compactMap { _, value -> CloudRecordEnvelope? in
                guard let data = value as? Data else { return nil }
                return try? JSONDecoder().decode(CloudRecordEnvelope.self, from: data)
            }
            .sorted { $0.modifiedAt < $1.modifiedAt }

        for record in records {
            switch record.kind {
            case "conversation":
                mergeConversation(record)
            case "workspace":
                mergeWorkspace(record)
            case "configuration":
                mergeConfiguration(record)
            default:
                continue
            }
        }
        ConversationStore.shared.loadAll()
        engine?.loadWorkspaces()
        didSync()
    }

    private func mergeConversation(_ record: CloudRecordEnvelope) {
        let local = ConversationStore.shared.savedConversations.first { $0.id == record.id }
        if record.tombstone {
            if let local, local.date <= record.modifiedAt {
                ConversationStore.shared.delete(local.id)
            }
            return
        }
        guard local == nil || (local?.date ?? .distantPast) < record.modifiedAt,
              let data = record.payload,
              let conversation = try? JSONDecoder().decode(SavedConversation.self, from: data)
        else { return }
        ConversationStore.shared.save(conversation)
    }

    private func mergeWorkspace(_ record: CloudRecordEnvelope) {
        guard let engine else { return }
        let exists = engine.workspaces.contains { $0.id == record.id }
        if record.tombstone {
            if exists { engine.deleteWorkspace(record.id) }
            return
        }
        guard !exists,
              let data = record.payload,
              let workspace = try? JSONDecoder().decode(SiteWorkspace.self, from: data)
        else { return }
        engine.saveWorkspace(workspace)
    }

    private func mergeConfiguration(_ record: CloudRecordEnvelope) {
        guard !record.tombstone,
              let data = record.payload,
              let archive = try? JSONDecoder().decode(ProviderConfigurationArchive.self, from: data)
        else { return }
        try? engine?.applyProviderConfiguration(archive)
    }

    private func key(kind: String, id: UUID) -> String {
        "\(prefix)\(kind).\(id.uuidString)"
    }

    private func didSync() {
        lastSyncAt = Date()
        status = "Up to date"
    }

    private static let configurationID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
}
