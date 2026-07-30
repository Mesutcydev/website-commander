import SwiftUI

/// A single line in a computed diff.
enum DiffLine {
    case context(String)
    case added(String)
    case removed(String)

    var text: String {
        switch self {
        case .context(let t): return t
        case .added(let t): return t
        case .removed(let t): return t
        }
    }
}

/// A small LCS-based line diff. Good enough for web-source files; falls back to
/// a coarse replace-all for very large inputs to bound memory.
enum DiffEngine {
    static func diff(old: String, new: String) -> [DiffLine] {
        let oldLines = old.components(separatedBy: "\n")
        let newLines = new.components(separatedBy: "\n")
        guard oldLines.count * newLines.count < 4_000_000 else {
            return oldLines.map { .removed($0) } + newLines.map { .added($0) }
        }
        let n = oldLines.count, m = newLines.count
        var lcs = Array(repeating: Array(repeating: 0, count: m + 1), count: n + 1)
        if n > 0 && m > 0 {
            for i in stride(from: n - 1, through: 0, by: -1) {
                for j in stride(from: m - 1, through: 0, by: -1) {
                    lcs[i][j] = oldLines[i] == newLines[j]
                        ? lcs[i + 1][j + 1] + 1
                        : max(lcs[i + 1][j], lcs[i][j + 1])
                }
            }
        }
        var result: [DiffLine] = []
        var i = 0, j = 0
        while i < n && j < m {
            if oldLines[i] == newLines[j] {
                result.append(.context(oldLines[i])); i += 1; j += 1
            } else if lcs[i + 1][j] >= lcs[i][j + 1] {
                result.append(.removed(oldLines[i])); i += 1
            } else {
                result.append(.added(newLines[j])); j += 1
            }
        }
        while i < n { result.append(.removed(oldLines[i])); i += 1 }
        while j < m { result.append(.added(newLines[j])); j += 1 }
        return result
    }
}

/// The review sheet for one staged change: a color-coded diff, risk findings,
/// stats, and approve / discard actions.
struct DiffApprovalView: View {

    @EnvironmentObject var engine: AgentEngine
    @EnvironmentObject var settings: SettingsStore
    @Environment(\.dismiss) private var dismiss
    let change: PendingChange
    @State private var isCommitting = false
    @State private var sideBySide = false

    private var lang: SyntaxHighlight.Lang { .from(path: change.path) }

    private var diffLines: [DiffLine] {
        DiffEngine.diff(old: change.oldContent ?? "", new: change.newContent)
    }

    private var riskLevel: RiskBadge.RiskLevel {
        if change.risks.isEmpty { return .clean }
        let joined = change.risks.joined().lowercased()
        if joined.contains("secret") || joined.contains("external script") || joined.contains("eval") { return .high }
        return .medium
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if !change.risks.isEmpty { riskBanner }
            HStack {
                Spacer()
                Picker("", selection: $sideBySide) {
                    Text("Unified").tag(false)
                    Text("Side by side").tag(true)
                }
                .pickerStyle(.segmented)
                .frame(width: 200)
            }
            .padding(.horizontal, Theme.Space.l)
            .padding(.vertical, Theme.Space.s)
            diffArea
            Divider()
            footer
        }
        .frame(width: 720, height: 620)
    }

    private var header: some View {
        HStack(spacing: Theme.Space.m) {
            IconTile(systemImage: change.category.icon, size: 38)
            VStack(alignment: .leading, spacing: 3) {
                Text(change.path).font(.headline).textSelection(.enabled)
                HStack(spacing: Theme.Space.s) {
                    Badge(text: change.category.rawValue, systemImage: change.category.icon, tint: Theme.accent)
                    Badge(text: change.isNewFile ? "New file" : "Modified",
                          systemImage: change.isNewFile ? "plus.circle.fill" : "pencil.circle.fill",
                          tint: change.isNewFile ? Theme.success : Theme.info)
                    RiskBadge(level: riskLevel)
                }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text("+\(change.addedLines)").foregroundStyle(Theme.success).font(.callout.weight(.semibold))
                Text("−\(change.removedLines)").foregroundStyle(Theme.danger).font(.callout.weight(.semibold))
            }
        }
        .padding(Theme.Space.l)
    }

    private var riskBanner: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Security findings", systemImage: "exclamationmark.shield.fill")
                .font(.callout.weight(.semibold))
                .foregroundStyle(riskLevel.color)
            ForEach(change.risks, id: \.self) { risk in
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "circle.fill").font(.system(size: 5)).padding(.top, 6)
                    Text(risk).font(.caption)
                }
                .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Theme.Space.m)
        .background(riskLevel.color.opacity(0.10), in: RoundedRectangle(cornerRadius: Theme.Radius.medium))
        .padding([.horizontal, .top], Theme.Space.l)
    }

    private var diffArea: some View {
        ScrollView([.vertical, .horizontal]) {
            if sideBySide {
                SideBySideDiff(rows: sideBySideRows(), lang: lang)
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(diffLines.enumerated()), id: \.offset) { _, line in
                        DiffLineRow(line: line, lang: lang)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .background(Color.primary.opacity(0.02))
    }

    /// Pair consecutive removed/added runs into aligned rows for side-by-side.
    private func sideBySideRows() -> [(left: DiffLine?, right: DiffLine?)] {
        var rows: [(DiffLine?, DiffLine?)] = []
        var removed: [DiffLine] = []
        var added: [DiffLine] = []
        func flush() {
            let n = max(removed.count, added.count)
            for i in 0..<n {
                rows.append((i < removed.count ? removed[i] : nil,
                             i < added.count ? added[i] : nil))
            }
            removed.removeAll(); added.removeAll()
        }
        for line in diffLines {
            switch line {
            case .removed: removed.append(line)
            case .added: added.append(line)
            case .context:
                flush()
                rows.append((line, line))
            }
        }
        flush()
        return rows
    }

    private var footer: some View {
        HStack(spacing: Theme.Space.m) {
            if let ws = settings.activeWorkspace {
                Text(ws.deployment.redeployNote)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Discard") {
                engine.discard(change)
                dismiss()
            }
            Button {
                isCommitting = true
                Task {
                    _ = await engine.approve(change)
                    isCommitting = false
                    dismiss()
                }
            } label: {
                if isCommitting { ProgressView().controlSize(.small) }
                else { Label("Approve & Commit", systemImage: "checkmark.circle.fill") }
            }
            .buttonStyle(.primary)
            .disabled(isCommitting)
        }
        .padding(Theme.Space.l)
    }
}

// MARK: - Diff line row

private struct DiffLineRow: View {
    let line: DiffLine
    var lang: SyntaxHighlight.Lang = .plain

    private var symbol: String {
        switch line {
        case .added: return "+"
        case .removed: return "−"
        case .context: return " "
        }
    }

    private var tint: Color {
        switch line {
        case .added: return Theme.success
        case .removed: return Theme.danger
        case .context: return .clear
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            Text(symbol)
                .font(.system(.caption, design: .monospaced).weight(.bold))
                .frame(width: 22)
                .foregroundStyle(tint)
            Group {
                if case .context = line {
                    SyntaxHighlight.attributed(line.text.isEmpty ? " " : line.text, lang: lang)
                } else {
                    Text(line.text.isEmpty ? " " : line.text)
                }
            }
            .font(.system(.caption, design: .monospaced))
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, Theme.Space.s)
        .padding(.vertical, 1)
        .background(tint.opacity(line.text.isEmpty ? 0 : 0.12))
    }
}

// MARK: - Side-by-side diff

private struct SideBySideDiff: View {
    let rows: [(left: DiffLine?, right: DiffLine?)]
    let lang: SyntaxHighlight.Lang

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                    DiffLineRow(line: row.left ?? .context(""), lang: lang)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Divider()
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                    DiffLineRow(line: row.right ?? .context(""), lang: lang)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
