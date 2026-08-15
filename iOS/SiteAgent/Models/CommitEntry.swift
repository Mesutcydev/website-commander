import Foundation

struct CommitEntry: Identifiable, Codable {
    var id: String { sha }
    var sha: String
    var message: String
    var authorName: String
    var dateString: String
    var avatarURL: String?

    var formattedDate: String {
        // GitHub API dates are ISO8601 strings (e.g., 2026-06-14T12:00:00Z)
        let formatter = ISO8601DateFormatter()
        guard let date = formatter.date(from: dateString) else { return dateString }
        
        let output = DateFormatter()
        output.dateStyle = .medium
        output.timeStyle = .short
        return output.string(from: date)
    }

    var shortSHA: String {
        String(sha.prefix(7))
    }
}
