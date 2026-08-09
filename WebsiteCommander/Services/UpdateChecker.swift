import Foundation
import CryptoKit
import AppKit

/// Website-hosted updates without Sparkle or an Apple Developer account.
///
/// Feed JSON (https only, except loopback http for local tests):
/// ```
/// {
///   "version": "1.1.0",
///   "url": "https://mesut.uk/WebsiteCommander-1.1.0.zip",
///   "sha256": "<hex of the zip>",
///   "notes": "What's new…"
/// }
/// ```
///
/// Checking never polls in the background. A single quiet launch check is
/// optional. Installing downloads the ZIP, verifies SHA-256, then quits and
/// lets a short shell helper swap the `.app` and relaunch.
@MainActor
final class UpdateChecker: ObservableObject {

    struct Release: Equatable {
        var version: String
        var url: String
        var notes: String
        /// Lowercase hex SHA-256 of the ZIP at `url`. Required for Install.
        var sha256: String
    }

    /// Baked-in production feed. Empty Settings override → this URL.
    nonisolated static let defaultFeedURL = "https://mesut.uk/wc-update.json"

    @Published var checking = false
    @Published var installing = false
    @Published var installProgress: Double = 0
    @Published var available: Release?
    @Published var lastError: String?
    /// Set when a user-initiated check finds no newer release.
    @Published var upToDate = false

    /// The running app's marketing version.
    nonisolated static var currentVersion: String {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "0.0.0"
    }

    /// Prefer a user override; otherwise the baked-in mesut.uk feed.
    nonisolated static func resolvedFeedURL(_ override: String) -> String {
        let trimmed = override.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? defaultFeedURL : trimmed
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

    /// Validate + fetch the feed.
    /// - Parameter userInitiated: when false (launch check), network/parse
    ///   failures stay silent so a flaky network never pops an error alert.
    func check(feedURL: String, userInitiated: Bool = true) async {
        let resolved = Self.resolvedFeedURL(feedURL)
        guard let url = URL(string: resolved) else {
            if userInitiated { lastError = "That feed URL isn't valid." }
            return
        }
        if !isAllowed(url) {
            if userInitiated {
                lastError = "Feed must use https (loopback may use http for testing)."
            }
            return
        }
        checking = true
        if userInitiated {
            lastError = nil
            upToDate = false
        }
        available = nil
        defer { checking = false }
        do {
            var req = URLRequest(url: url)
            req.timeoutInterval = 15
            req.cachePolicy = .reloadIgnoringLocalCacheData
            let (data, response) = try await URLSession.shared.data(for: req)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                if userInitiated { lastError = "Feed request failed." }
                return
            }
            guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let version = obj["version"] as? String else {
                if userInitiated { lastError = "Feed is missing a version." }
                return
            }
            if Self.isNewer(version, than: Self.currentVersion) {
                let sha = ((obj["sha256"] as? String) ?? "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .lowercased()
                available = Release(
                    version: version,
                    url: (obj["url"] as? String) ?? "",
                    notes: (obj["notes"] as? String) ?? "",
                    sha256: sha
                )
            } else if userInitiated {
                upToDate = true
            }
        } catch {
            if userInitiated { lastError = error.localizedDescription }
        }
    }

    /// Download the ZIP, verify SHA-256, stage the app, quit, and relaunch.
    func installAndRelaunch(_ release: Release) async {
        guard !installing else { return }
        guard let downloadURL = URL(string: release.url), isAllowed(downloadURL) else {
            lastError = "Update URL must use https."
            return
        }
        guard release.sha256.count == 64,
              release.sha256.unicodeScalars.allSatisfy({ CharacterSet(charactersIn: "0123456789abcdef").contains($0) }) else {
            lastError = "This update has no SHA-256 checksum, so Install is disabled. Use Download instead."
            return
        }

        installing = true
        installProgress = 0
        lastError = nil
        defer { installing = false }

        do {
            let cache = try FileManager.default.url(
                for: .cachesDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            ).appendingPathComponent("WebsiteCommanderUpdates", isDirectory: true)
            try? FileManager.default.removeItem(at: cache)
            try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)

            let zipURL = cache.appendingPathComponent("WebsiteCommander-\(release.version).zip")
            try await download(downloadURL, to: zipURL) { [weak self] fraction in
                Task { @MainActor in self?.installProgress = fraction * 0.85 }
            }

            let digest = try sha256Hex(of: zipURL)
            guard digest == release.sha256 else {
                lastError = "Checksum mismatch — the download was rejected."
                try? FileManager.default.removeItem(at: cache)
                return
            }
            installProgress = 0.88

            let extractDir = cache.appendingPathComponent("extract", isDirectory: true)
            try FileManager.default.createDirectory(at: extractDir, withIntermediateDirectories: true)
            try dittoUnzip(zipURL, to: extractDir)

            guard let stagedApp = findAppBundle(in: extractDir) else {
                lastError = "The update archive did not contain WebsiteCommander.app."
                return
            }
            installProgress = 0.94

            let destination = Bundle.main.bundleURL
            try writeInstallHelper(
                stagedApp: stagedApp,
                destination: destination,
                pid: ProcessInfo.processInfo.processIdentifier
            )
            installProgress = 1

            // Give the helper a moment to spawn, then quit so it can replace us.
            try await Task.sleep(nanoseconds: 200_000_000)
            NSApp.terminate(nil)
        } catch {
            lastError = error.localizedDescription
        }
    }

    // MARK: - Networking / crypto

    private func isAllowed(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), let host = url.host?.lowercased() else { return false }
        if scheme == "https" { return true }
        if scheme == "http" { return host == "127.0.0.1" || host == "localhost" || host == "::1" }
        return false
    }

    private func download(
        _ url: URL,
        to destination: URL,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws {
        progress(0.05)
        let (temp, response) = try await URLSession.shared.download(from: url)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw UpdateError.downloadFailed
        }
        progress(0.9)
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        try FileManager.default.moveItem(at: temp, to: destination)
        progress(1)
    }

    private func sha256Hex(of file: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hasher = SHA256()
        while autoreleasepool(invoking: {
            let chunk = handle.readData(ofLength: 1024 * 1024)
            if chunk.isEmpty { return false }
            hasher.update(data: chunk)
            return true
        }) {}
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private func dittoUnzip(_ zip: URL, to directory: URL) throws {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        proc.arguments = ["-x", "-k", zip.path, directory.path]
        let err = Pipe()
        proc.standardError = err
        try proc.run()
        proc.waitUntilExit()
        guard proc.terminationStatus == 0 else {
            let message = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            throw UpdateError.extractFailed(message)
        }
    }

    private func findAppBundle(in directory: URL) -> URL? {
        let preferred = directory.appendingPathComponent("WebsiteCommander.app")
        if FileManager.default.fileExists(atPath: preferred.path) { return preferred }
        guard let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return nil }
        for case let url as URL in enumerator {
            if url.pathExtension == "app", url.lastPathComponent == "WebsiteCommander.app" {
                return url
            }
        }
        return nil
    }

    private func writeInstallHelper(stagedApp: URL, destination: URL, pid: Int32) throws {
        let fm = FileManager.default
        let helper = fm.temporaryDirectory.appendingPathComponent("wc-install-\(pid).sh")
        let log = fm.temporaryDirectory.appendingPathComponent("wc-install-\(pid).log")

        func shQuote(_ path: String) -> String {
            "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
        }

        let script = """
        #!/bin/bash
        set -euo pipefail
        PID=\(pid)
        SRC=\(shQuote(stagedApp.path))
        DST=\(shQuote(destination.path))
        LOG=\(shQuote(log.path))
        exec >>"$LOG" 2>&1
        echo "Waiting for pid $PID to exit…"
        while kill -0 "$PID" 2>/dev/null; do sleep 0.2; done
        sleep 0.4
        if [[ ! -d "$SRC" ]]; then
          echo "Missing staged app at $SRC"
          exit 1
        fi
        xattr -cr "$SRC" 2>/dev/null || true
        BACKUP="${DST}.wc-bak"
        rm -rf "$BACKUP"
        if [[ -d "$DST" ]]; then
          mv "$DST" "$BACKUP"
        fi
        # ditto preserves the bundle structure cleanly.
        /usr/bin/ditto "$SRC" "$DST"
        xattr -cr "$DST" 2>/dev/null || true
        rm -rf "$BACKUP"
        echo "Launching $DST"
        /usr/bin/open "$DST"
        rm -f -- "$0"
        """
        try script.write(to: helper, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: helper.path)

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/bash")
        proc.arguments = [helper.path]
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice
        try proc.run()
    }

    private enum UpdateError: LocalizedError {
        case downloadFailed
        case extractFailed(String)

        var errorDescription: String? {
            switch self {
            case .downloadFailed: return "The update download failed."
            case .extractFailed(let detail):
                let trimmed = detail.trimmingCharacters(in: .whitespacesAndNewlines)
                return trimmed.isEmpty ? "Could not unpack the update." : "Could not unpack the update: \(trimmed)"
            }
        }
    }
}
