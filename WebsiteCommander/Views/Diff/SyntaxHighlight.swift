import SwiftUI

/// A tiny, dependency-free syntax highlighter for the diff view. It is *not* a
/// real parser — just a fast regex pass that classifies strings, comments,
/// numbers and a small keyword set so a diff reads as code, not flat text. Good
/// enough for HTML/CSS/JS/TS/JSON/Swift, which is what this app edits.
enum SyntaxHighlight {

    enum Lang {
        case html, css, js, json, swift, plain

        static func from(path: String) -> Lang {
            let ext = (path as NSString).pathExtension.lowercased()
            switch ext {
            case "html", "htm", "svg", "xml", "astro", "svelte": return .html
            case "css", "scss": return .css
            case "js", "jsx", "ts", "tsx", "mjs": return .js
            case "json": return .json
            case "swift": return .swift
            default: return .plain
            }
        }

        var keywords: [String] {
            switch self {
            case .js:
                return ["const", "let", "var", "function", "return", "if", "else", "for",
                        "while", "import", "export", "from", "default", "class", "extends",
                        "new", "this", "async", "await", "true", "false", "null", "undefined",
                        "typeof", "in", "of", "switch", "case", "break", "continue"]
            case .swift:
                return ["let", "var", "func", "return", "if", "else", "for", "while", "import",
                        "struct", "class", "enum", "protocol", "extension", "guard", "self",
                        "true", "false", "nil", "in", "switch", "case", "break", "continue",
                        "public", "private", "static", "override", "async", "await", "throws"]
            case .css:
                return ["important"]
            default:
                return []
            }
        }

        var commentPattern: String? {
            switch self {
            case .html: return "<!--[\\s\\S]*?-->"
            case .css, .js, .swift: return "/\\*[\\s\\S]*?\\*/|//[^\\n]*"
            default: return nil
            }
        }
    }

    enum TokenKind: Equatable { case plain, comment, string, number, keyword }

    struct Token: Equatable {
        var text: String
        var kind: TokenKind
    }

    private static let stringPattern = "\"(?:\\\\.|[^\"\\\\])*\"|'(?:\\\\.|[^'\\\\])*'|`(?:\\\\.|[^`\\\\])*`"
    private static let numberPattern = "\\b\\d+(?:\\.\\d+)?\\b"

    /// Classify a line into tokens. Exposed (and unit-tested) independently of
    /// the SwiftUI `Text` builder so the logic is verifiable headlessly.
    static func tokens(_ line: String, lang: Lang) -> [Token] {
        guard lang != .plain, !line.isEmpty else { return [Token(text: line, kind: .plain)] }

        var parts: [String] = []
        parts.append(lang.commentPattern.map { "(\($0))" } ?? "(_)")
        parts.append("(\(stringPattern))")
        parts.append("(\(numberPattern))")
        if !lang.keywords.isEmpty {
            let kw = lang.keywords.map { NSRegularExpression.escapedPattern(for: $0) }.joined(separator: "|")
            parts.append("(\\b(?:\(kw))\\b)")
        } else {
            parts.append("(_)")
        }
        let pattern = parts.joined(separator: "|")
        guard let re = try? NSRegularExpression(pattern: pattern) else {
            return [Token(text: line, kind: .plain)]
        }

        let ns = line as NSString
        let range = NSRange(location: 0, length: ns.length)
        var out: [Token] = []
        var cursor = 0
        for m in re.matches(in: line, range: range) {
            if m.range.location > cursor {
                out.append(Token(text: ns.substring(with: NSRange(location: cursor, length: m.range.location - cursor)), kind: .plain))
            }
            let kind: TokenKind
            let g = { (i: Int) -> NSRange in i < m.numberOfRanges ? m.range(at: i) : NSRange(location: NSNotFound, length: 0) }
            if g(1).location != NSNotFound { kind = .comment }
            else if g(2).location != NSNotFound { kind = .string }
            else if g(3).location != NSNotFound { kind = .number }
            else if g(4).location != NSNotFound { kind = .keyword }
            else { kind = .plain }
            out.append(Token(text: ns.substring(with: m.range), kind: kind))
            cursor = m.range.location + m.range.length
        }
        if cursor < ns.length {
            out.append(Token(text: ns.substring(from: cursor), kind: .plain))
        }
        return out
    }

    /// Build a colored `Text` for one line from the token stream.
    static func attributed(_ line: String, lang: Lang) -> Text {
        var result = Text("")
        for token in tokens(line, lang: lang) {
            let color: Color
            switch token.kind {
            case .comment: color = Theme.codeComment
            case .string: color = Theme.codeString
            case .number: color = Theme.codeNumber
            case .keyword: color = Theme.codeKeyword
            case .plain: color = Theme.textPrimary
            }
            result = result + Text(token.text).foregroundColor(color)
        }
        return result
    }
}
