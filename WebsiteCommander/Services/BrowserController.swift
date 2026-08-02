import Foundation
import WebKit
import AppKit
import SwiftUI

enum BrowserError: LocalizedError {
    case notOpen
    case evaluationFailed(String)
    case invalidURL
    case unsupportedScheme

    var errorDescription: String? {
        switch self {
        case .notOpen: return "The live preview could not open. Check that this site has a valid live URL."
        case .evaluationFailed(let m): return "Browser script failed: \(m)"
        case .invalidURL: return "That preview URL is invalid. Use a full http(s) address."
        case .unsupportedScheme: return "For safety, preview navigation only supports http and https URLs."
        }
    }
}

/// The agent's handle onto the live preview web view. The Preview tab registers
/// its WKWebView here; the AgentEngine's browser tools call through this to SEE
/// (DOM, console, network, performance, screenshots) and CONTROL (navigate,
/// click, type, run JS) the rendered site.
@MainActor
final class BrowserController: ObservableObject {

    /// Inspector data streamed from the page (console / network / performance).
    let inspector = WebInspectorModel()

    private weak var webView: WKWebView?

    @Published var currentURL: URL?
    @Published var pageTitle: String = ""
    @Published private(set) var isLoading = false
    @Published private(set) var navigationError: String?
    /// Set when a tool captures a screenshot for a vision model; the engine
    /// forwards it into the model context, then clears it.
    @Published var pendingScreenshotBase64: String?

    var isAvailable: Bool { webView != nil }
    var isReady: Bool {
        webView != nil && !isLoading && navigationError == nil
    }

    /// Browser tools may be requested while the Preview pane is closed. Ask the
    /// workspace to reveal it and briefly wait for SwiftUI/WebKit to register
    /// the live view, so model tools do not fail because of UI presentation.
    func ensureAvailable() async -> Bool {
        if isReady { return true }
        if navigationError != nil, let webView {
            // A previous load can fail while the web view remains mounted. A
            // later agent turn should be able to recover without requiring a
            // human to visit Preview and press Reload first.
            beginNavigation()
            webView.reload()
        }
        NotificationCenter.default.post(name: .requestAgentPreviewFromEngine, object: nil)
        for _ in 0..<120 {
            if isReady { return true }
            if Task.isCancelled { return false }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return isReady
    }

    func register(_ webView: WKWebView) {
        // `updateNSView` can call this many times during one SwiftUI layout
        // pass. Publishing an unchanged URL from here re-invalidates that same
        // view graph and can drive AppKit into a recursive constraint update.
        // Only publish when the browser or URL has genuinely changed.
        if self.webView !== webView {
            self.webView = webView
            isLoading = true
            navigationError = nil
        }
        if currentURL != webView.url {
            currentURL = webView.url
        }
    }

    func beginNavigation() {
        isLoading = true
        navigationError = nil
        inspector.reset()
    }

    func didStartNavigation(_ webView: WKWebView) {
        isLoading = true
        navigationError = nil
        if let url = webView.url { currentURL = url }
        inspector.reset()
    }

    func didFinishNavigation(_ webView: WKWebView) {
        isLoading = false
        navigationError = nil
        currentURL = webView.url ?? currentURL
        pageTitle = webView.title ?? ""
    }

    func didFailNavigation(_ webView: WKWebView, error: Error) {
        // Replacing a load or closing the preview produces a cancellation
        // callback. It is not a user-visible navigation failure and must not
        // poison the readiness state for the next page.
        if (error as NSError).code == NSURLErrorCancelled { return }
        isLoading = false
        navigationError = error.localizedDescription
        currentURL = webView.url ?? currentURL
        pageTitle = webView.title ?? ""
    }

    // MARK: Primitive: run JS

    /// Evaluate JavaScript in the page and return the result as a string.
    @discardableResult
    func evaluate(_ js: String) async throws -> String {
        guard let webView else { throw BrowserError.notOpen }
        return try await withCheckedThrowingContinuation { continuation in
            webView.evaluateJavaScript(js) { result, error in
                if let error {
                    continuation.resume(throwing: BrowserError.evaluationFailed(error.localizedDescription))
                } else {
                    continuation.resume(returning: Self.stringify(result))
                }
            }
        }
    }

    private static func stringify(_ result: Any?) -> String {
        switch result {
        case nil: return ""
        case let s as String: return s
        case let n as NSNumber: return n.stringValue
        default:
            if let data = try? JSONSerialization.data(withJSONObject: result as Any),
               let s = String(data: data, encoding: .utf8) { return s }
            return String(describing: result)
        }
    }

    // MARK: SEE

    /// The full rendered HTML of the page.
    func snapshotHTML() async -> String {
        guard await ensureAvailable() else { return "" }
        return (try? await evaluate("document.documentElement.outerHTML")) ?? ""
    }

    /// Capture a PNG screenshot of the web view (for vision models).
    func screenshotPNG() async -> Data? {
        guard let webView else { return nil }
        let config = WKSnapshotConfiguration()
        config.afterScreenUpdates = true
        let image: NSImage? = await withCheckedContinuation { continuation in
            webView.takeSnapshot(with: config) { image, _ in
                continuation.resume(returning: image)
            }
        }
        guard let image,
              let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .png, properties: [:])
    }

    /// A compact text snapshot for non-vision "look" calls: URL, title, console
    /// errors, failed requests, performance, and a trimmed DOM text outline.
    func snapshotSummary() async -> String {
        guard await ensureAvailable() else {
            if let navigationError { return "The preview browser could not load the page: \(navigationError)" }
            return "The preview browser isn't open."
        }
        let url = (try? await evaluate("location.href")) ?? currentURL?.absoluteString ?? "?"
        let title = (try? await evaluate("document.title")) ?? ""
        let domText = (try? await evaluate("document.body ? document.body.innerText.replace(/\\n{2,}/g,'\\n').slice(0, 4000) : ''")) ?? ""

        var lines: [String] = []
        lines.append("URL: \(url)")
        lines.append("Title: \(title)")
        lines.append("Console: \(inspector.errorCount) error(s), \(inspector.warnCount) warning(s)")
        for log in inspector.consoleLogs.filter({ $0.level == .error }).suffix(5) {
            lines.append("  console.error: \(log.text)")
        }
        let failed = inspector.networkRequests.filter {
            guard let status = $0.status else { return false }
            return status == 0 || status >= 400
        }
        if !failed.isEmpty {
            lines.append("Failed requests: \(failed.count)")
            for r in failed.suffix(5) { lines.append("  \(r.method) \(r.url) → \(r.status ?? 0)") }
        }
        if let load = inspector.performance.loadTimeMs { lines.append("Load time: \(load)ms") }
        lines.append("Visible text (truncated):\n\(domText)")
        return lines.joined(separator: "\n")
    }

    // MARK: CONTROL

    func navigate(_ urlString: String) throws {
        guard let url = URL(string: urlString) else {
            throw BrowserError.invalidURL
        }
        guard let webView else { throw BrowserError.notOpen }
        guard let scheme = url.scheme?.lowercased(),
              ["http", "https"].contains(scheme),
              url.host != nil else {
            throw BrowserError.unsupportedScheme
        }
        beginNavigation()
        webView.load(URLRequest(url: url))
        currentURL = url
    }

    @discardableResult
    func click(selector: String) async throws -> String {
        let js = """
        (function(){ var el = document.querySelector(\(Self.jsString(selector)));
        if(!el){ return 'not found'; } el.scrollIntoView({block:'center'}); el.click();
        return 'clicked <' + el.tagName.toLowerCase() + '>'; })()
        """
        return try await evaluate(js)
    }

    @discardableResult
    func type(selector: String, text: String) async throws -> String {
        let js = """
        (function(){ var el = document.querySelector(\(Self.jsString(selector)));
        if(!el){ return 'not found'; } el.focus();
        el.value = \(Self.jsString(text));
        el.dispatchEvent(new Event('input', {bubbles:true}));
        el.dispatchEvent(new Event('change', {bubbles:true}));
        return 'typed into <' + el.tagName.toLowerCase() + '>'; })()
        """
        return try await evaluate(js)
    }

    /// Escape an arbitrary Swift string into a safe JS string literal.
    static func jsString(_ s: String) -> String {
        let escaped = s
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
        return "\"\(escaped)\""
    }
}
