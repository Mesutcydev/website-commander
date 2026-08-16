import Foundation

/// Scrubs likely secrets out of free-form text before it leaves the app (debug
/// briefs, exported prompts). Defense-in-depth over the Keychain: even if a
/// console log, network URL, or error message happens to contain a credential,
/// it is reduced to a placeholder before export.
///
/// Patterns are intentionally conservative (high-entropy token shapes and
/// `key = value` assignments); they err toward redacting, never toward revealing.
enum SecretRedactor {

    private struct Rule {
        let pattern: String
        let replacement: String
        var options: NSRegularExpression.Options = [.caseInsensitive]
    }

    private static let rules: [Rule] = [
        // GitHub classic PAT
        Rule(pattern: "ghp_[A-Za-z0-9]{16,}", replacement: "ghp_***"),
        // GitHub fine-grained PAT
        Rule(pattern: "github_pat_[A-Za-z0-9_]{16,}", replacement: "github_pat_***"),
        // OpenAI / Anthropic / generic sk- keys (sk-, sk-proj-, sk-ant-, …)
        Rule(pattern: "sk-[A-Za-z0-9_\\-]{12,}", replacement: "sk-***"),
        // AWS access key id
        Rule(pattern: "AKIA[0-9A-Z]{16}", replacement: "AKIA***", options: []),
        // Authorization: Bearer <token>
        Rule(pattern: "(Bearer\\s+)[^\\s,;\"']+", replacement: "$1***"),
        // Authorization: Basic <base64>
        Rule(pattern: "(Basic\\s+)[A-Za-z0-9=+/]+", replacement: "$1***"),
        // token embedded in a URL userinfo (x-access-token:SECRET@)
        Rule(pattern: "x-access-token:[^@\\s]+@", replacement: "x-access-token:***@"),
        // query-string secrets (?token=…, &api_key=…)
        Rule(pattern: "([?&](?:token|key|api[_-]?key|access[_-]?token|secret|password|passwd)=)[^&\\s\"']+",
             replacement: "$1***"),
        // generic assignment: api_key: "…", token = '…', secret: …
        Rule(pattern: "(\\b(?:api[_-]?key|access[_-]?token|auth[_-]?token|token|secret|password|passwd|authorization)\\b\\s*[:=]\\s*[\"']?)[^\\s\"'&,;}]+",
             replacement: "$1***"),
        // JSON-style double-quoted keys: "apiKey": "…", "password": "…"
        Rule(pattern: "(\"(?:api[_-]?key|access[_-]?token|auth[_-]?token|token|secret|password|passwd|authorization)\"\\s*:\\s*\")[^\"]+",
             replacement: "$1***"),
        // GitHub OAuth tokens (gho_/ghu_/ghs_/ghr_)
        Rule(pattern: "gh[ousr]_[A-Za-z0-9]{16,}", replacement: "gh***"),
        // Bare JWTs (header.payload.signature)
        Rule(pattern: "eyJ[A-Za-z0-9_-]{8,}\\.[A-Za-z0-9_-]{8,}\\.[A-Za-z0-9_-]{8,}", replacement: "eyJ***")
    ]

    private static let compiled: [(NSRegularExpression, String)] = rules.compactMap { rule in
        guard let re = try? NSRegularExpression(pattern: rule.pattern, options: rule.options) else { return nil }
        return (re, rule.replacement)
    }

    /// Return `text` with every matched secret replaced by a placeholder.
    static func redact(_ text: String) -> String {
        var out = text
        for (re, replacement) in compiled {
            out = re.stringByReplacingMatches(
                in: out, range: NSRange(out.startIndex..., in: out),
                withTemplate: replacement)
        }
        return out
    }

    /// Redact every string in a collection, preserving order.
    static func redact(_ values: [String]) -> [String] { values.map(redact) }
}
