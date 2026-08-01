import SwiftUI
import AppKit

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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let change: PendingChange
    @State private var isCommitting = false
    @State private var sideBySide = false
    @State private var approvalError: String?
    @State private var showRiskDetails = true
    @State private var showFind = false
    @State private var findText = ""
    @State private var isPresented = false
    @State private var approvalConfirmed = false
    @State private var showSecurityScan = false
    @State private var securityScanProgress: CGFloat = 0
    @State private var binaryPreview: NSImage?

    private var lang: SyntaxHighlight.Lang { .from(path: change.path) }

    private var targetWorkspace: SiteWorkspace? {
        if let id = change.workspaceID {
            return settings.workspaces.first { $0.id == id }
        }
        return settings.activeWorkspace
    }

    private var diffLines: [DiffLine] {
        DiffEngine.diff(old: change.oldContent ?? "", new: change.newContent)
    }

    private var numberedDiffLines: [NumberedDiffLine] {
        var old = 1
        var new = 1
        return diffLines.enumerated().map { index, line in
            let result: NumberedDiffLine
            switch line {
            case .context:
                result = NumberedDiffLine(id: index, line: line, oldNumber: old, newNumber: new)
                old += 1
                new += 1
            case .removed:
                result = NumberedDiffLine(id: index, line: line, oldNumber: old, newNumber: nil)
                old += 1
            case .added:
                result = NumberedDiffLine(id: index, line: line, oldNumber: nil, newNumber: new)
                new += 1
            }
            return result
        }
    }

    private var visibleDiffLines: [NumberedDiffLine] {
        let needle = findText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return numberedDiffLines }
        return numberedDiffLines.filter { $0.line.text.localizedCaseInsensitiveContains(needle) }
    }

    private var riskLevel: RiskBadge.RiskLevel {
        if change.risks.isEmpty { return .clean }
        let joined = change.risks.joined().lowercased()
        if joined.contains("secret") || joined.contains("external script") || joined.contains("eval") { return .high }
        return .medium
    }

    var body: some View {
        VStack(spacing: 0) {
            reviewHeader
            Divider()
            if let approvalError { errorBanner(approvalError) }
            reviewSummary
            if !change.risks.isEmpty { riskBanner }
            if change.isBinary {
                binaryReviewArea
            } else {
                diffToolbar
                diffArea
                    .animation(.easeOut(duration: 0.16), value: sideBySide)
            }
            Divider()
            footer
        }
        .frame(minWidth: 720, idealWidth: 820, maxWidth: 920,
               minHeight: 560, idealHeight: 640, maxHeight: 760)
        .background(Theme.standardSurface)
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.modal, style: .continuous))
        .cardElevation(raised: true)
        .opacity(isPresented ? 1 : 0)
        .scaleEffect(isPresented || reduceMotion ? 1 : 0.985)
        .offset(y: isPresented || reduceMotion ? 0 : 6)
        // Errors belong to the attempt shown in this sheet. Do not carry a
        // failed approval from another staged file into the next review.
        .onAppear {
            approvalError = nil
            showSecurityScan = !change.risks.isEmpty
            securityScanProgress = 0
            if reduceMotion {
                isPresented = true
            } else {
                withAnimation(.easeOut(duration: 0.20)) { isPresented = true }
                if !change.risks.isEmpty {
                    withAnimation(.linear(duration: 0.80)) { securityScanProgress = 1 }
                    Task {
                        try? await Task.sleep(for: .milliseconds(850))
                        showSecurityScan = false
                    }
                }
            }
        }
        .onChange(of: change.id) { _, _ in
            approvalError = nil
            approvalConfirmed = false
        }
    }

    private var reviewHeader: some View {
        HStack(spacing: Theme.Space.s) {
            VStack(alignment: .leading, spacing: 3) {
                Text(change.path)
                    .font(.system(size: 13, weight: .semibold, design: .monospaced))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                HStack(spacing: Theme.Space.xs) {
                    Badge(text: change.category.rawValue, systemImage: change.category.icon,
                          tint: Theme.secondaryText, surface: Theme.secondarySurface)
                    Badge(text: change.isNewFile ? "New file" : "Modified",
                          systemImage: change.isNewFile ? "plus" : "pencil",
                          tint: Theme.secondaryText, surface: Theme.secondarySurface)
                }
            }
            Spacer()
            if change.isBinary {
                Label(change.statistics.summary, systemImage: "photo")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.secondaryText)
            } else {
                Text("+\(change.addedLines)")
                    .font(.system(size: 11, design: .monospaced).weight(.semibold))
                    .foregroundStyle(Theme.success)
                Text("−\(change.removedLines)")
                    .font(.system(size: 11, design: .monospaced).weight(.semibold))
                    .foregroundStyle(Theme.danger)
            }
            if let targetWorkspace {
                Badge(text: targetWorkspace.name, systemImage: "folder",
                      tint: Theme.secondaryText, surface: Theme.secondarySurface)
            }
            Button("Close") { dismiss() }
                .buttonStyle(.primarySoftCompact)
                .keyboardShortcut(.escape, modifiers: [])
        }
        .padding(.horizontal, Theme.Space.l)
        .frame(height: 60)
        .background(Theme.modalHeader)
    }

    private var reviewSummary: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            HStack(spacing: Theme.Space.s) {
                RiskBadge(level: riskLevel)
                Spacer()
                Label("Staged for review", systemImage: "lock.shield")
                    .font(Theme.ui(11.5, .medium))
                    .foregroundStyle(Theme.secondaryText)
            }
            if !change.message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                HStack(alignment: .top, spacing: Theme.Space.s) {
                    Image(systemName: "text.quote")
                        .foregroundStyle(Theme.tertiaryText)
                    Text(change.message)
                        .font(Theme.ui(12.5, .medium))
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(1)
                    Spacer()
                }
            }
            if change.importSessionID != nil {
                Label("Part of one atomic import", systemImage: "link.circle.fill")
                    .font(Theme.ui(11.5, .medium))
                    .foregroundStyle(Theme.accent)
            }
        }
        .padding(.horizontal, Theme.Space.l)
        .padding(.vertical, Theme.Space.s)
        .background(Theme.secondarySurface, in: RoundedRectangle(cornerRadius: Theme.Radius.panel, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: Theme.Radius.panel, style: .continuous)
                .strokeBorder(Theme.borderSubtle)
        }
        .padding(.horizontal, Theme.Space.l)
        .padding(.top, Theme.Space.s)
    }

    private func errorBanner(_ message: String) -> some View {
        HStack(alignment: .top, spacing: Theme.Space.s) {
            Image(systemName: "xmark.octagon.fill")
                .foregroundStyle(Theme.danger)
            VStack(alignment: .leading, spacing: 3) {
                Text("Couldn't approve this change")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(Theme.textPrimary)
                Text(message)
                    .font(.caption)
                    .foregroundStyle(Theme.secondaryText)
                    .textSelection(.enabled)
            }
            Spacer()
            Button("Dismiss") { approvalError = nil }
                .buttonStyle(.primarySoftCompact)
        }
        .padding(.horizontal, Theme.Space.m)
        .padding(.vertical, Theme.Space.s)
        .background(Theme.destructiveSoft, in: RoundedRectangle(cornerRadius: Theme.Radius.panel, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: Theme.Radius.panel, style: .continuous)
                .strokeBorder(Theme.danger.opacity(0.25))
        }
        .padding(.horizontal, Theme.Space.l)
        .padding(.top, Theme.Space.s)
    }

    private var riskBanner: some View {
        DisclosureGroup(isExpanded: $showRiskDetails) {
            VStack(alignment: .leading, spacing: Theme.Space.xs) {
                ForEach(change.risks, id: \.self) { risk in
                    HStack(alignment: .top, spacing: Theme.Space.s) {
                        Image(systemName: "circle.fill")
                            .font(.system(size: 5))
                            .padding(.top, 5)
                        Text(risk)
                            .font(Theme.ui(11.5))
                    }
                    .foregroundStyle(Theme.secondaryText)
                }
            }
            .padding(.top, Theme.Space.xs)
        } label: {
            HStack(spacing: Theme.Space.s) {
                Image(systemName: "exclamationmark.shield.fill")
                    .foregroundStyle(riskLevel.color)
                Text("Security findings")
                    .font(Theme.ui(12, .semibold))
                    .foregroundStyle(Theme.textPrimary)
                Badge(text: "\(change.risks.count)", tint: riskLevel.color,
                      surface: riskLevel.color.opacity(0.12))
                Spacer()
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, Theme.Space.m)
        .padding(.vertical, Theme.Space.s)
        .background(riskLevel.color.opacity(0.08),
                    in: RoundedRectangle(cornerRadius: Theme.Radius.panel, style: .continuous))
        .overlay {
            if showSecurityScan && !reduceMotion {
                GeometryReader { proxy in
                    Rectangle()
                        .fill(riskLevel.color.opacity(0.32))
                        .frame(width: 1)
                        .offset(x: securityScanProgress * proxy.size.width)
                }
                .clipped()
            }
        }
        .padding([.horizontal, .top], Theme.Space.l)
    }

    private var diffToolbar: some View {
        HStack(spacing: Theme.Space.s) {
            if change.isBinary {
                Label("Binary asset", systemImage: "photo.on.rectangle")
                    .font(Theme.ui(12, .semibold))
                    .foregroundStyle(Theme.secondaryText)
                Spacer()
                Text("Contents stay file-backed until approval")
                    .font(Theme.ui(11))
                    .foregroundStyle(Theme.tertiaryText)
            } else {
                Label("File diff", systemImage: "arrow.left.arrow.right")
                    .font(Theme.ui(12, .semibold))
                    .foregroundStyle(Theme.secondaryText)
                if showFind {
                    TextField("Find in diff", text: $findText)
                        .textFieldStyle(.plain)
                        .font(.system(size: 11, design: .monospaced))
                        .padding(.horizontal, Theme.Space.s)
                        .frame(width: 160, height: Theme.Height.compact)
                        .background(Theme.recessedSurface,
                                    in: RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous))
                }
                Spacer()
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(change.newContent, forType: .string)
                } label: {
                    Label("Copy", systemImage: "doc.on.doc")
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.iconCompact)
                .help("Copy new file contents")
                .keyboardShortcut("f", modifiers: [.command, .option])
                Button {
                    showFind.toggle()
                    if !showFind { findText = "" }
                } label: {
                    Label("Find", systemImage: "magnifyingglass")
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.iconCompact)
                .help("Find in diff")
                .keyboardShortcut("f", modifiers: [.command])
                Picker("Diff layout", selection: $sideBySide) {
                    Text("Unified").tag(false)
                    Text("Side by side").tag(true)
                }
                .pickerStyle(.segmented)
                .frame(width: 168, height: Theme.Height.compact)
            }
        }
        .padding(.horizontal, Theme.Space.l)
        .frame(height: 40)
    }

    private var binaryReviewArea: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.l) {
                HStack(alignment: .top, spacing: Theme.Space.m) {
                    Image(systemName: "photo")
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(Theme.teal)
                        .frame(width: 42, height: 42)
                        .background(Theme.tealSoft,
                                    in: RoundedRectangle(cornerRadius: Theme.Radius.medium,
                                                         style: .continuous))
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Binary asset")
                            .font(Theme.ui(14, .semibold))
                            .foregroundStyle(Theme.textPrimary)
                        if let binary = change.binaryContent {
                            Text("\(binary.mimeType) · \(binary.byteCount) bytes")
                                .font(.system(size: 11.5, design: .monospaced))
                                .foregroundStyle(Theme.secondaryText)
                            if let width = binary.pixelWidth, let height = binary.pixelHeight {
                                Text("\(width) × \(height) px · SHA-256 \(binary.sha256)")
                                    .font(.system(size: 10.5, design: .monospaced))
                                    .foregroundStyle(Theme.tertiaryText)
                                    .textSelection(.enabled)
                            } else {
                                Text("SHA-256 \(binary.sha256)")
                                    .font(.system(size: 10.5, design: .monospaced))
                                    .foregroundStyle(Theme.tertiaryText)
                                    .textSelection(.enabled)
                            }
                        }
                    }
                    Spacer()
                }

                Group {
                    if let binaryPreview {
                        Image(nsImage: binaryPreview)
                            .resizable()
                            .scaledToFit()
                            .frame(maxWidth: .infinity, minHeight: 220, maxHeight: 360)
                            .padding(Theme.Space.m)
                    } else {
                        VStack(spacing: Theme.Space.s) {
                            Image(systemName: "photo.on.rectangle.angled")
                                .font(.system(size: 34, weight: .light))
                                .foregroundStyle(Theme.tertiaryText)
                            Text("Preview unavailable")
                                .font(Theme.ui(12, .medium))
                                .foregroundStyle(Theme.secondaryText)
                            Text("The file remains reviewable by MIME type, size, dimensions, and SHA-256.")
                                .font(Theme.ui(11.5))
                                .foregroundStyle(Theme.tertiaryText)
                        }
                        .frame(maxWidth: .infinity, minHeight: 220)
                    }
                }
                .background(Theme.editorSurface,
                            in: RoundedRectangle(cornerRadius: Theme.Radius.medium,
                                                 style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: Theme.Radius.medium, style: .continuous)
                        .strokeBorder(Theme.borderHairline)
                }

                Text("This binary is part of an atomic blog import. Approving it also commits the reviewed article and any other files from the same import session.")
                    .font(Theme.ui(11.5))
                    .foregroundStyle(Theme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(Theme.Space.l)
            .frame(maxWidth: 680, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .center)
        }
        .background(Theme.editorSurface)
        .task(id: change.id) {
            guard let reference = change.binaryContent?.assetReference,
                  let data = await engine.blogAssetData(for: reference) else { return }
            binaryPreview = NSImage(data: data)
        }
    }

    private var diffArea: some View {
        ScrollView([.vertical, .horizontal]) {
            if sideBySide {
                SideBySideDiff(rows: sideBySideRows(), lang: lang)
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(visibleDiffLines) { entry in
                        DiffLineRow(line: entry.line, oldNumber: entry.oldNumber,
                                    newNumber: entry.newNumber, lang: lang)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .background(Theme.editorSurface)
    }

    /// Pair consecutive removed/added runs into aligned rows for side-by-side.
    private func sideBySideRows() -> [(left: NumberedDiffLine?, right: NumberedDiffLine?)] {
        var rows: [(NumberedDiffLine?, NumberedDiffLine?)] = []
        var removed: [NumberedDiffLine] = []
        var added: [NumberedDiffLine] = []
        func flush() {
            let n = max(removed.count, added.count)
            for i in 0..<n {
                rows.append((i < removed.count ? removed[i] : nil,
                             i < added.count ? added[i] : nil))
            }
            removed.removeAll(); added.removeAll()
        }
        for line in visibleDiffLines {
            switch line.line {
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
            VStack(alignment: .leading, spacing: 2) {
                Text(isCommitting ? "Committing securely…" : "Ready to apply")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Theme.textPrimary)
                if let ws = targetWorkspace {
                    Text(ws.deployment.redeployNote)
                        .font(.caption2)
                        .foregroundStyle(Theme.tertiaryText)
                }
            }
            Spacer()
            Button("Decline", role: .destructive) {
                engine.discard(change)
                dismiss()
            }
            .buttonStyle(.destructiveText)
            Button {
                guard !isCommitting else { return }
                isCommitting = true
                Task {
                    let succeeded = await engine.approve(change)
                    if succeeded {
                        approvalError = nil
                        approvalConfirmed = true
                        if !reduceMotion {
                            try? await Task.sleep(for: .milliseconds(360))
                        }
                        isCommitting = false
                        dismiss()
                    } else {
                        isCommitting = false
                        approvalError = engine.lastApprovalError ?? engine.lastError ?? "The change was not committed."
                    }
                }
            } label: {
                if approvalConfirmed {
                    Label("Approved", systemImage: "checkmark.circle.fill")
                } else if isCommitting {
                    ApprovalProgressArc()
                        .frame(width: 16, height: 16)
                }
                else {
                    Label(change.importSessionID == nil ? "Approve change" : "Approve import",
                          systemImage: "checkmark.circle.fill")
                }
            }
            .buttonStyle(.primary)
            .disabled(isCommitting || approvalConfirmed)
            .keyboardShortcut(.return, modifiers: [.command])
        }
        .padding(Theme.Space.l)
        .frame(minHeight: Theme.Height.modalFooter)
        .background(Theme.modalFooter)
    }
}

private struct ApprovalProgressArc: View {
    @EnvironmentObject private var motion: AmbientMotionCoordinator
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let phase = motion.phase(period: 1.2)
        ZStack {
            Circle()
                .stroke(Color.white.opacity(0.24), lineWidth: 1.4)
            Circle()
                .trim(from: 0.08, to: 0.58)
                .stroke(Color.white, style: StrokeStyle(lineWidth: 1.6, lineCap: .round))
                .rotationEffect(.degrees(reduceMotion || !motion.isRunning ? -45 : phase * 360))
        }
    }
}

// MARK: - Diff line row

private struct NumberedDiffLine: Identifiable {
    let id: Int
    let line: DiffLine
    let oldNumber: Int?
    let newNumber: Int?
}

private struct DiffLineRow: View {
    let line: DiffLine
    var oldNumber: Int?
    var newNumber: Int?
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
            Text(oldNumber.map(String.init) ?? "")
                .frame(width: 36, alignment: .trailing)
                .foregroundStyle(Theme.quaternaryText)
            Text(newNumber.map(String.init) ?? "")
                .frame(width: 36, alignment: .trailing)
                .foregroundStyle(Theme.quaternaryText)
            Text(symbol)
                .font(.system(.caption, design: .monospaced).weight(.bold))
                .frame(width: 18)
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
        .font(.system(size: 11, design: .monospaced))
        .background(tint.opacity(line.text.isEmpty ? 0 : 0.10))
    }
}

// MARK: - Side-by-side diff

private struct SideBySideDiff: View {
    let rows: [(left: NumberedDiffLine?, right: NumberedDiffLine?)]
    let lang: SyntaxHighlight.Lang

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                    DiffLineRow(line: row.left?.line ?? .context(""),
                                oldNumber: row.left?.oldNumber,
                                newNumber: row.left?.newNumber, lang: lang)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Divider()
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                    DiffLineRow(line: row.right?.line ?? .context(""),
                                oldNumber: row.right?.oldNumber,
                                newNumber: row.right?.newNumber, lang: lang)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
