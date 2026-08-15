import Foundation
import OSLog

@MainActor
final class ConversationStore: ObservableObject {
    static let shared = ConversationStore()
    private init() { loadAll() }

    @Published var savedConversations: [SavedConversation] = []
    /// Last persistence error surfaced for UI (nil when healthy).
    @Published private(set) var lastError: String?

    private let log = Logger(subsystem: "uk.mesut.SiteAgent", category: "ConversationStore")

    private var directoryURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SiteAgent_Chats", isDirectory: true)
    }

    func loadAll() {
        let fm = FileManager.default
        if !fm.fileExists(atPath: directoryURL.path) {
            do {
                try fm.createDirectory(at: directoryURL, withIntermediateDirectories: true)
            } catch {
                lastError = "Could not create chat folder."
                log.error("createDirectory failed: \(error.localizedDescription, privacy: .public)")
            }
            return
        }
        guard let urls = try? fm.contentsOfDirectory(at: directoryURL, includingPropertiesForKeys: nil) else {
            lastError = "Could not list saved chats."
            return
        }

        var loaded: [SavedConversation] = []
        var corrupt = 0
        for url in urls where url.pathExtension == "json" {
            do {
                let data = try Data(contentsOf: url)
                let conv = try JSONDecoder().decode(SavedConversation.self, from: data)
                loaded.append(conv)
            } catch {
                corrupt += 1
                log.error("Skipping corrupt chat \(url.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }
        savedConversations = Self.sorted(loaded)
        if corrupt > 0 {
            lastError = "Skipped \(corrupt) unreadable chat file\(corrupt == 1 ? "" : "s")."
        }
    }

    @discardableResult
    func save(_ conversation: SavedConversation) -> Bool {
        let fm = FileManager.default
        if !fm.fileExists(atPath: directoryURL.path) {
            do {
                try fm.createDirectory(at: directoryURL, withIntermediateDirectories: true)
            } catch {
                lastError = "Could not create chat folder."
                log.error("createDirectory failed: \(error.localizedDescription, privacy: .public)")
                return false
            }
        }
        let fileURL = directoryURL.appendingPathComponent("\(conversation.id.uuidString).json")
        do {
            let data = try JSONEncoder().encode(conversation)
            try data.write(to: fileURL, options: .atomic)
            // .completeFileProtectionUntilFirstUserAuthentication: strongest class that still allows
            // reads after first unlock (chats load on app foreground). Chats may contain pasted secrets.
            try FileManager.default.setAttributes(
                [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
                ofItemAtPath: fileURL.path)
            // Upsert in-memory instead of reloading the whole directory (O(1) vs O(n)).
            if let idx = savedConversations.firstIndex(where: { $0.id == conversation.id }) {
                savedConversations[idx] = conversation
            } else {
                savedConversations.insert(conversation, at: 0)
            }
            savedConversations = Self.sorted(savedConversations)
            lastError = nil
            return true
        } catch {
            lastError = "Could not save chat."
            log.error("save failed: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    func delete(_ id: UUID) {
        let fileURL = directoryURL.appendingPathComponent("\(id.uuidString).json")
        do {
            try FileManager.default.removeItem(at: fileURL)
            savedConversations.removeAll { $0.id == id }
            lastError = nil
        } catch {
            // Missing file is fine (already gone); other errors are logged.
            let ns = error as NSError
            if ns.domain == NSCocoaErrorDomain && ns.code == NSFileNoSuchFileError {
                savedConversations.removeAll { $0.id == id }
                return
            }
            lastError = "Could not delete chat."
            log.error("delete failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Pins sort first; each group keeps the existing newest-first ordering.
    private static func sorted(_ conversations: [SavedConversation]) -> [SavedConversation] {
        conversations.sorted {
            if $0.isPinned != $1.isPinned { return $0.isPinned }
            return $0.date > $1.date
        }
    }

    func setPinned(_ isPinned: Bool, for id: UUID) {
        guard var conversation = savedConversations.first(where: { $0.id == id }) else { return }
        conversation.isPinned = isPinned
        save(conversation)
    }
}
