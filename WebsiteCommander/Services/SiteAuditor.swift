import Foundation

/// One issue found by the lightweight site audit, with a severity.
struct SiteAuditIssue: Identifiable, Equatable {
    let id = UUID()
    var title: String
    var detail: String
    var severity: Severity

    enum Severity: String, CaseIterable {
        case info = "Info"
        case warning = "Warning"
        case critical = "Critical"

        var icon: String {
            switch self {
            case .info: return "info.circle.fill"
            case .warning: return "exclamationmark.triangle.fill"
            case .critical: return "xmark.octagon.fill"
            }
        }
    }
}

/// A fast, client-side audit of the rendered page: SEO, accessibility,
/// performance, network, and runtime checks. Runs entirely on captured data —
/// no external service. Mirrors SiteAgent's LightweightSiteAuditor.
@MainActor
enum SiteAuditor {

    static func audit(html: String, inspector: WebInspectorModel) -> [SiteAuditIssue] {
        var issues: [SiteAuditIssue] = []
        let lower = html.lowercased()

        if !hasTag("title", in: lower) {
            issues.append(.init(title: "Missing title",
                                detail: "The page has no <title> tag.", severity: .critical))
        }
        if !hasMetaName("description", in: lower) {
            issues.append(.init(title: "Missing meta description",
                                detail: "Search previews may use weak fallback copy.", severity: .warning))
        }
        if !lower.contains("og:title") {
            issues.append(.init(title: "No Open Graph tags",
                                detail: "Social shares won't render a rich preview.", severity: .info))
        }
        let missingAlt = missingAltCount(in: lower)
        if missingAlt > 0 {
            issues.append(.init(title: "Images missing alt text",
                                detail: "\(missingAlt) image tag(s) have no alt text.", severity: .warning))
        }
        if let load = inspector.performance.loadTimeMs, load > 3000 {
            issues.append(.init(title: "Slow load",
                                detail: "Load time is \(load)ms (above 3s) in the preview.", severity: .warning))
        }
        // Resource Timing records intentionally have no HTTP status. They are
        // useful for performance, but must not be reported as failed requests.
        // A concrete 0, however, is the fetch/XHR failure sentinel and should
        // remain visible as a failed request.
        let failed = inspector.networkRequests.filter {
            guard let status = $0.status else { return false }
            return status == 0 || status >= 400
        }
        if !failed.isEmpty {
            issues.append(.init(title: "Failed network requests",
                                detail: "\(failed.count) request(s) failed or returned 4xx/5xx.", severity: .critical))
        }
        if inspector.errorCount > 0 {
            issues.append(.init(title: "Console errors",
                                detail: "\(inspector.errorCount) JavaScript/runtime error(s) captured.", severity: .critical))
        }
        if issues.isEmpty {
            issues.append(.init(title: "No major issues",
                                detail: "No obvious SEO, accessibility, performance, or runtime problems found.",
                                severity: .info))
        }
        return issues
    }

    private static func missingAltCount(in lowerHTML: String) -> Int {
        let pattern = "<img\\b(?![^>]*\\balt\\s*=)[^>]*>"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return 0 }
        return regex.numberOfMatches(in: lowerHTML, range: NSRange(lowerHTML.startIndex..., in: lowerHTML))
    }

    private static func hasTag(_ tag: String, in lowerHTML: String) -> Bool {
        guard let regex = try? NSRegularExpression(pattern: "<\(tag)\\b", options: []) else { return false }
        return regex.firstMatch(in: lowerHTML, range: NSRange(lowerHTML.startIndex..., in: lowerHTML)) != nil
    }

    private static func hasMetaName(_ name: String, in lowerHTML: String) -> Bool {
        let escapedName = NSRegularExpression.escapedPattern(for: name)
        let pattern = #"<meta\b[^>]*\bname\s*=\s*["']\#(escapedName)["']"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { return false }
        return regex.firstMatch(in: lowerHTML, range: NSRange(lowerHTML.startIndex..., in: lowerHTML)) != nil
    }

    /// Build an agent prompt that asks it to fix the given audit issues.
    static func fixPrompt(for issues: [SiteAuditIssue], url: String) -> String {
        let lines = issues
            .filter { $0.severity != .info }
            .map { "- [\($0.severity.rawValue)] \($0.title): \($0.detail)" }
            .joined(separator: "\n")
        return """
        I audited my live site (\(url)) and found these issues:

        \(lines.isEmpty ? "- (no critical/warning issues)" : lines)

        Use your browser tools to confirm each issue, then find the responsible file(s)
        in the repository and fix them with write_file. Keep changes minimal and explain
        what you changed.
        """
    }

    /// Build an agent prompt that asks for a free-form analysis of the live page.
    static func analyzePrompt(url: String) -> String {
        return """
        Look at my live site at \(url) using your browser tools (browser_look, and
        browser_screenshot if you can see images). Analyze the design, content, SEO,
        accessibility, and performance. Tell me the 3-5 most impactful improvements,
        ranked. Don't change anything yet — just report.
        """
    }
}
