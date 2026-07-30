import Foundation

/// A minimal, manual check-for-updates feed — appropriate for an app distributed
/// from a website (no Sparkle, no App Store). **Inert by default**: nothing is
/// fetched until the user sets a feed URL, and there is no background polling.
///
/// Feed JSON:
///   { "version": "1.1.0", "url": "https://example.com/WebsiteCommander-1.1.0.zip",
///     "notes": "What's new…" }
///
/// Safety: only `https` feeds are accepted, except loopback (`127.0.0.1` /
/// `localhost`) which may use `http` so you can test against a local server.
@MainActor
final class UpdateChecker: ObservableObject {

    struct Release: Equatable {
        var version: String
        var url: String
        var notes: String
    }

    @Published var checking = false
    @Published var available: Release?
    @Published var lastError: String?

    /// The running app's marketing version.
    nonisolated static var currentVersion: String {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "0.0.0"
    }

    /// True when `candidate` is strictly newer than `current` (numeric compare).
    nonisolated static func isNewer(_ candidate: String, than current: String) -> Bool {
        let c = candidate.split(separator: ".").compactMap { Int($0) }
        let cur = current.split(separator: ".").compactMap { Int($0) }
        guard !c.isEmpty, !cur.isEmpty else { return false }
        for i in 0..<max(c.count, cur.count) {
            let a = i < c.count ? c[i] : 0
            let b = i < cur.count ? cur[i] : 0
            if a != b { return a > b }
        }
        return false
    }

    /// Validate + fetch the feed. `feedURL` empty → no-op (feature off).
    func check(feedURL: String) async {
        let trimmed = feedURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard let url = URL(string: trimmed) else {
            lastError = "That feed URL isn't valid."; return
        }
        if !isAllowed(url) {
            lastError = "Feed must use https (loopback may use http for testing)."; return
        }
        checking = true
        lastError = nil
        available = nil
        defer { checking = false }
        do {
            var req = URLRequest(url: url)
            req.timeoutInterval = 15
            let (data, response) = try await URLSession.shared.data(for: req)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                lastError = "Feed request failed."; return
            }
            guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let version = obj["version"] as? String else {
                lastError = "Feed is missing a version."; return
            }
            if Self.isNewer(version, than: Self.currentVersion) {
                available = Release(version: version,
                                    url: (obj["url"] as? String) ?? "",
                                    notes: (obj["notes"] as? String) ?? "")
            }
        } catch {
            lastError = error.localizedDescription
        }
    }

    private func isAllowed(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), let host = url.host?.lowercased() else { return false }
        if scheme == "https" { return true }
        if scheme == "http" { return host == "127.0.0.1" || host == "localhost" || host == "::1" }
        return false
    }
}
