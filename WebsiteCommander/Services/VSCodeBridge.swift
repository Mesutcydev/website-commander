import Foundation
import AppKit

/// Launches VSCode against a local workspace folder. GUI apps inherit a minimal
/// PATH, so we probe the well-known install locations rather than relying on
/// `code` being resolvable through the environment.
enum VSCodeBridge {

    /// Candidate locations for the `code` CLI, in priority order.
    private static let candidatePaths = [
        "/usr/local/bin/code",
        "/opt/homebrew/bin/code",
        "/Applications/Visual Studio Code.app/Contents/Resources/app/bin/code"
    ]

    /// The resolved path to the `code` CLI, or nil if VSCode isn't installed.
    static var cliPath: String? {
        for path in candidatePaths where FileManager.default.isExecutableFile(atPath: path) {
            return path
        }
        return nil
    }

    static var isAvailable: Bool { cliPath != nil }

    /// Open a folder in VSCode. Returns false if VSCode couldn't be located.
    @discardableResult
    static func open(folder: URL) -> Bool {
        // Prefer NSWorkspace for the .app bundle path; fall back to the CLI.
        if let cli = cliPath {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: cli)
            process.arguments = [folder.path]
            do {
                try process.run()
                return true
            } catch {
                return false
            }
        }
        // Last resort: ask the system to open the folder in whatever handles it.
        return NSWorkspace.shared.open(folder)
    }

    /// Open a specific file, optionally at a line, in VSCode.
    @discardableResult
    static func open(file: URL, line: Int? = nil) -> Bool {
        guard let cli = cliPath else { return NSWorkspace.shared.open(file) }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: cli)
        if let line {
            process.arguments = ["--goto", "\(file.path):\(line)"]
        } else {
            process.arguments = [file.path]
        }
        do {
            try process.run()
            return true
        } catch {
            return false
        }
    }
}
