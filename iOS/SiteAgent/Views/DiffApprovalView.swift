import SwiftUI

/// Non-blocking conflict/status message embedded in the review surface. The
/// staged baseline has already been refreshed, so the useful next step is to
/// inspect the new diff—not dismiss a generic modal alert.
struct ReviewIssueBanner: View {
    let message: String

    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: "arrow.triangle.2.circlepath.circle.fill")
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text("Review updated changes")
                    .font(.caption.weight(.bold))
                Text(message)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.12),
                    in: RoundedRectangle(cornerRadius: Theme.cornerSmall, style: .continuous))
    }
}

/// A bar that appears above the input when the agent has staged changes.
struct PendingChangesBar: View {
    @EnvironmentObject var engine: AgentEngine
    @Environment(\.colorScheme) var colorScheme
    @State private var reviewing: PendingChange?
    @State private var showApproveAllConfirm = false
    @State private var committing = false

    private var approvalLocked: Bool { engine.state.isActive || engine.commitInFlight || committing }

    var body: some View {
        VStack(spacing: 8) {
            HStack {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    .symbolEffect(.bounce, value: engine.pendingChanges.count)
                Text("\(engine.pendingChanges.count) change\(engine.pendingChanges.count == 1 ? "" : "s") awaiting approval")
                    .font(.subheadline.weight(.medium))
                    .contentTransition(.numericText())
                Spacer()
                if engine.state == .awaitingUserApproval, engine.pendingApprovalHasSideEffects {
                    Text("Use approval card")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                } else if committing {
                    Label("Committing…", systemImage: "arrow.triangle.2.circlepath")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                } else {
                    Button("Approve all") { Haptics.tap(); showApproveAllConfirm = true }
                        .font(.subheadline.weight(.semibold))
                }
            }
            if let issue = engine.reviewIssueMessage {
                ReviewIssueBanner(message: issue)
            }
            ForEach(engine.pendingChanges) { change in
                Button { Haptics.tap(); reviewing = change } label: {
                    HStack(spacing: 10) {
                        Image(systemName: change.category.icon)
                            .foregroundStyle(change.isDeletion ? Color.red : (change.isNewFile ? Color.green : Theme.brand))
                        VStack(alignment: .leading, spacing: 2) {
                            Text(change.path).font(.callout.weight(.medium)).lineLimit(1)
                                .foregroundStyle(.primary)
                            Text(change.category.rawValue)
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
                    }
                    .padding(10)
                    .background(Theme.cardFill,
                                in: RoundedRectangle(cornerRadius: Theme.cornerSmall, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: Theme.cornerSmall, style: .continuous)
                            .strokeBorder(Theme.separator, lineWidth: 1))
                }
                .buttonStyle(.pressable)
            }
        }
        .padding(12)
        .background(
            Theme.cardFill,
            in: RoundedRectangle(cornerRadius: Theme.corner, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Theme.corner, style: .continuous)
                .strokeBorder(Theme.separator, lineWidth: 1)
        )
        .padding(.horizontal, AppSize.screenHorizontalPadding)
        .sheet(item: $reviewing) { change in
            DiffSheet(change: change)
        }
        .confirmationDialog("Approve all \(engine.pendingChanges.count) changes?",
                            isPresented: $showApproveAllConfirm, titleVisibility: .visible) {
            Button("Approve & Commit All", role: .destructive) {
                guard !approvalLocked else { return }
                Task {
                    committing = true
                    _ = await engine.approveAll()
                    committing = false
                }
            }
            .disabled(approvalLocked)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Commits every staged change at once. Your site will redeploy.")
        }
    }
}

/// Full-screen diff review for a single staged change.
struct DiffSheet: View {
    @EnvironmentObject var engine: AgentEngine
    @Environment(\.dismiss) var dismiss
    @Environment(\.colorScheme) var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let change: PendingChange

    @State private var commitMessage: String = ""
    @State private var selectedTab = 0 // 0 = Diff, 1 = Before/After, 2 = Preview, 3 = Files
    @State private var showSuccess = false
    @State private var showRejectConfirm = false
    @State private var committing = false

    /// A conflict refreshes the staged baseline in AgentEngine. Keep this sheet
    /// bound to that live value so the updated diff can be reviewed immediately
    /// without closing and reopening a stale copy.
    private var reviewedChange: PendingChange {
        engine.pendingChanges.first(where: { $0.id == change.id }) ?? change
    }

    private var approvalLocked: Bool { engine.state.isActive || engine.commitInFlight }
    /// A file opened from the approval card is review-only. Publishing one file
    /// from inside a multi-file approval breaks atomicity and leaves every later
    /// file comparing against a different branch transaction.
    private var isPartOfAtomicApproval: Bool { engine.pendingApproval != nil }

    /// Brief checkmark beat so publishing to a live site feels resolved, instead
    /// of the sheet just vanishing. Shows an in-flight state during the push so
    /// the button doesn't look dead (and can't be double-tapped) on slow networks.
    private func celebrateApprove(_ run: @escaping () async -> Bool) {
        Task {
            committing = true
            let ok = await run()
            committing = false
            if ok {
                if reduceMotion { showSuccess = true }
                else { withAnimation(Theme.spring) { showSuccess = true } }
                try? await Task.sleep(nanoseconds: 800_000_000)
                dismiss()
            }
        }
    }

    // MARK: - Branded action buttons (was: stock .bordered/.borderedProminent,
    // which rendered in the system accent and looked un-branded on the app's
    // highest-stakes screen).

    @ViewBuilder
    private func primaryActionButton(_ title: String, loading: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Group {
                if loading { ProgressView().tint(.white) }
                else { Text(title) }
            }
            .font(.headline).foregroundStyle(.white)
            .frame(maxWidth: .infinity).padding(.vertical, 14)
            .background(Theme.actionGradient, in: RoundedRectangle(cornerRadius: Theme.corner, style: .continuous))
        }
        .buttonStyle(.pressable)
    }

    @ViewBuilder
    private func destructiveActionButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(role: .destructive, action: action) {
            Text(title)
                .font(.headline).foregroundStyle(.red)
                .frame(maxWidth: .infinity).padding(.vertical, 14)
                .background(Color.red.opacity(0.12), in: RoundedRectangle(cornerRadius: Theme.corner, style: .continuous))
        }
        .buttonStyle(.pressable)
    }

    /// Honest, provider-aware description of what committing actually does
    /// (replaces the old placebo "Deploy after commit" toggle, which only print()ed).
    private var deployNote: String {
        engine.activeWorkspace?.deployment.redeployNote ?? "Committing pushes to your repo."
    }

    /// Shown when SecurityScan flagged patterns in this change (e.g. eval(),
    /// external <script src>) — a non-color signal to look closely before committing.
    private var riskBanner: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.shield.fill").foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text("Review carefully").font(.caption.weight(.bold))
                Text("Contains: \(reviewedChange.risks.joined(separator: ", ")).")
                    .font(.caption2).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.12))
    }

    private var demoBanner: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "play.circle.fill").foregroundStyle(Theme.brand)
            VStack(alignment: .leading, spacing: 2) {
                Text("Guided demo").font(.caption.weight(.bold))
                Text("This sample change is local only. Finishing it will not commit to GitHub.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.brand.opacity(0.12))
    }

    private var stats: (added: Int, removed: Int) {
        let lines = diffLines
        return (lines.filter { $0.kind == .add }.count,
                lines.filter { $0.kind == .remove }.count)
    }

    private var riskScore: (label: String, color: Color) {
        let total = stats.added + stats.removed
        if total > 100 { return ("High Risk", .red) }
        if total > 30 { return ("Medium Risk", .orange) }
        return ("Low Risk", .green)
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("View Mode", selection: $selectedTab) {
                    Text("Diff").tag(0)
                    Text("Before/After").tag(1)
                    Text("Preview").tag(2)
                    Text("Files").tag(3)
                }
                .pickerStyle(.segmented)
                .padding()

                Divider()

                if reviewedChange.isDemo { demoBanner }
                if !reviewedChange.risks.isEmpty { riskBanner }

                if selectedTab == 0 {
                    // Diff View Content
                    HStack(spacing: 12) {
                        if reviewedChange.isUpload {
                            Label("Upload", systemImage: "arrow.up.doc").foregroundStyle(Theme.brand)
                        } else if reviewedChange.isDeletion {
                            Label("Delete", systemImage: "trash").foregroundStyle(.red)
                        } else {
                            Label("\(stats.added)", systemImage: "plus").foregroundStyle(.green)
                            Label("\(stats.removed)", systemImage: "minus").foregroundStyle(.red)
                        }
                        
                        let risk = riskScore
                        Text(risk.label)
                            .font(.caption2.weight(.bold))
                            .padding(.horizontal, 8).padding(.vertical, 3)
                            .background(risk.color.opacity(0.12), in: Capsule())
                            .foregroundStyle(risk.color)
                        
                        HStack(spacing: 4) {
                            Image(systemName: reviewedChange.category.icon)
                            Text(reviewedChange.category.rawValue)
                        }
                        .font(.caption2.weight(.bold))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Theme.brand.opacity(0.12), in: Capsule())
                        .foregroundStyle(Theme.brand)
                        
                        Spacer()
                        Text(reviewedChange.isUpload ? "New asset" : (reviewedChange.isDeletion ? "Deleted file" : (reviewedChange.isNewFile ? "New file" : "Edit")))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    .font(.footnote.weight(.medium))
                    .padding(.horizontal).padding(.vertical, 8)
                    .appSecondaryBackground()
                    
                    if reviewedChange.isUpload {
                        uploadPreview
                    } else {
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 1) {
                                ForEach(Array(diffLines.enumerated()), id: \.offset) { _, line in
                                    DiffLineRow(line: line)
                                }
                            }
                            .font(.system(.caption, design: .monospaced))
                            .padding(.vertical, 8)
                        }
                    }
                } else if selectedTab == 1 {
                    beforeAfterPreview
                } else if selectedTab == 2 {
                    // Inline Site Preview
                    SitePreviewView(repo: engine.repo, pendingChanges: engine.pendingChanges)
                        .id("approval-preview-\(engine.activeWorkspace?.id.uuidString ?? "none")")
                } else {
                    // Files List
                    List {
                        ForEach(engine.pendingChanges) { ch in
                            HStack {
                                Image(systemName: ch.category.icon)
                                    .foregroundStyle(Theme.brand)
                                Text(ch.path)
                                    .font(.subheadline)
                                Spacer()
                                Text(ch.category.rawValue)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            .appBackground(.primary)
            .navigationTitle(reviewedChange.path)
            .navigationBarTitleDisplayMode(.inline)
            .safeAreaInset(edge: .bottom) {
                VStack(spacing: 12) {
                    if let issue = engine.reviewIssueMessage {
                        ReviewIssueBanner(message: issue)
                    }
                    if approvalLocked {
                        HStack(spacing: 6) {
                            Image(systemName: "hourglass").foregroundStyle(.secondary)
                            Text("Wait for the current agent run to finish before committing.")
                                .font(.caption).foregroundStyle(.secondary)
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 4)
                    }
                    if reviewedChange.isDemo {
                        HStack(spacing: 6) {
                            Image(systemName: "info.circle").foregroundStyle(.secondary)
                            Text("Demo changes are never committed.")
                                .font(.caption).foregroundStyle(.secondary)
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 4)

                        HStack(spacing: 12) {
                            destructiveActionButton("Dismiss Demo") {
                                engine.reject(reviewedChange); dismiss()
                            }
                            primaryActionButton("Finish Demo", loading: committing) {
                                celebrateApprove { await engine.approve(reviewedChange) }
                            }
                            .disabled(committing || approvalLocked)
                        }
                    } else if isPartOfAtomicApproval {
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: "square.stack.3d.up.fill")
                                .foregroundStyle(Theme.brand)
                            Text("This file belongs to one atomic approval. Review it here, then return to commit the complete batch together.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 4)

                        primaryActionButton("Done Reviewing") {
                            dismiss()
                        }
                    } else {
                        HStack(spacing: 6) {
                            Image(systemName: "arrow.up.forward.app").foregroundStyle(.secondary)
                            Text(deployNote)
                                .font(.caption).foregroundStyle(.secondary)
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 4)

                        HStack(spacing: 6) {
                            Image(systemName: "text.alignleft").foregroundStyle(.secondary)
                            TextField("Commit message", text: $commitMessage)
                                .textFieldStyle(.plain)
                                .padding(.horizontal, 12).padding(.vertical, 10)
                                .background(Theme.cardFill,
                                            in: RoundedRectangle(cornerRadius: Theme.cornerSmall, style: .continuous))
                                .overlay(RoundedRectangle(cornerRadius: Theme.cornerSmall, style: .continuous)
                                    .strokeBorder(Theme.separator, lineWidth: 1))
                        }

                        HStack(spacing: 12) {
                            destructiveActionButton("Reject") {
                                Haptics.tap(); showRejectConfirm = true
                            }
                            .disabled(committing)
                            primaryActionButton(reviewedChange.isDeletion ? "Approve & Delete" : "Approve & Commit",
                                                loading: committing) {
                                engine.updateMessage(for: reviewedChange, to: commitMessage)
                                var edited = reviewedChange; edited.message = commitMessage
                                // Celebrate only on a real commit. On failure the change
                                // stays staged and the error surfaces via the alert.
                                celebrateApprove { await engine.approve(edited) }
                            }
                            .disabled(committing || approvalLocked || commitMessage.trimmingCharacters(in: .whitespaces).isEmpty)
                        }
                    }
                }
                .padding()
                .background(.bar)
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Close") { dismiss() }
                }
            }
            .overlay {
                if showSuccess {
                    ZStack {
                        Color.black.opacity(0.5).ignoresSafeArea()
                        VStack(spacing: 14) {
                            SuccessCheck(size: 68)
                            Text(reviewedChange.isDemo ? "Demo complete"
                                 : (reviewedChange.isDeletion ? "Deleted" : "Committed"))
                                .font(.headline).foregroundStyle(.white)
                        }
                    }
                    .transition(.opacity)
                }
            }
            .onAppear {
                // Prefill a sensible default so Approve isn't silently greyed out
                // when the agent staged a change without a message.
                if reviewedChange.message.trimmingCharacters(in: .whitespaces).isEmpty {
                    let file = (reviewedChange.path as NSString).lastPathComponent
                    commitMessage = reviewedChange.isDeletion ? "Delete \(file)"
                        : (reviewedChange.isNewFile ? "Add \(file)" : "Update \(file)")
                } else {
                    commitMessage = reviewedChange.message
                }
            }
            .alert("Commit failed", isPresented: Binding(
                get: { MainActor.assumeIsolated {
                    engine.lastError != nil && engine.reviewIssueMessage == nil
                } },
                set: { show in MainActor.assumeIsolated { if !show { engine.lastError = nil } } }
            )) {
                Button("OK", role: .cancel) { engine.lastError = nil }
            } message: {
                Text(engine.lastError ?? "")
            }
            .confirmationDialog("Reject this change?", isPresented: $showRejectConfirm, titleVisibility: .visible) {
                Button("Reject", role: .destructive) {
                    Haptics.error()
                    engine.reject(reviewedChange); dismiss()
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Discards the staged change. You can ask the agent to redo it.")
            }
        }
    }

    private var diffLines: [DiffLine] {
        DiffEngine.lineDiff(old: reviewedChange.oldContent ?? "", new: reviewedChange.newContent)
    }

    private var beforeAfterPreview: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if reviewedChange.isUpload {
                    uploadPreview
                } else if reviewedChange.isDeletion {
                    SnapshotPane(title: "Before", text: reviewedChange.oldContent ?? "", tint: Theme.danger)
                } else {
                    SnapshotPane(title: "Before", text: reviewedChange.oldContent ?? "", tint: Theme.danger)
                    SnapshotPane(title: "After", text: reviewedChange.newContent, tint: Theme.ok)
                }
            }
            .padding()
        }
    }

    /// Preview for a staged binary upload — the image itself, or a file summary.
    @ViewBuilder private var uploadPreview: some View {
        let data = reviewedChange.uploadData ?? Data()
        ScrollView {
            VStack(spacing: 14) {
                if let ui = UIImage(data: data) {
                    Image(uiImage: ui).resizable().scaledToFit()
                        .frame(maxHeight: 360)
                        .clipShape(RoundedRectangle(cornerRadius: Theme.corner, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: Theme.corner, style: .continuous)
                            .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1))
                } else {
                    Image(systemName: "doc.fill")
                        .font(.system(size: 56))
                        .foregroundStyle(Theme.brandGradient)
                        .padding(.top, 40)
                }
                Text(ByteCountFormatter.string(fromByteCount: Int64(data.count), countStyle: .file))
                    .font(.footnote).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding()
        }
    }
}

private struct SnapshotPane: View {
    let title: String
    let text: String
    var tint: Color = .secondary

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Circle().fill(tint).frame(width: 6, height: 6)
                Text(title.uppercased())
                    .font(.mono(10, .semibold)).kerning(1.2)
                    .foregroundStyle(Theme.t3)
            }
            Text(text.isEmpty ? "Empty file" : text)
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .cardSurface(cornerRadius: Theme.cornerSmall)
        }
    }
}

struct DiffLineRow: View {
    let line: DiffLine

    var body: some View {
        HStack(spacing: 0) {
            Text(prefix).frame(width: 16)
            Text(line.text.isEmpty ? " " : line.text)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 8).padding(.vertical, 1)
        .background(background)
    }

    private var prefix: String {
        switch line.kind { case .add: return "+"; case .remove: return "-"; case .context: return " " }
    }
    private var background: Color {
        switch line.kind {
        case .add: return Color.green.opacity(0.18)
        case .remove: return Color.red.opacity(0.18)
        case .context: return .clear
        }
    }
}

// MARK: - Minimal line diff (LCS-based)

struct DiffLine { enum Kind { case add, remove, context }; var kind: Kind; var text: String }

enum DiffEngine {
    /// Classic LCS line diff with common prefix/suffix optimization.
    /// Eliminates O(N*M) calculation for large identical code blocks.
    static func lineDiff(old: String, new: String) -> [DiffLine] {
        let a = old.isEmpty ? [] : old.components(separatedBy: "\n")
        let b = new.components(separatedBy: "\n")
        
        let n = a.count, m = b.count
        
        // Find common prefix
        var prefixMatch = 0
        while prefixMatch < n && prefixMatch < m && a[prefixMatch] == b[prefixMatch] {
            prefixMatch += 1
        }
        
        // Find common suffix (avoid overlapping with prefix)
        var suffixMatch = 0
        while suffixMatch < (n - prefixMatch) && suffixMatch < (m - prefixMatch) && a[n - 1 - suffixMatch] == b[m - 1 - suffixMatch] {
            suffixMatch += 1
        }
        
        // Middle section to diff
        let midA = Array(a[prefixMatch..<(n - suffixMatch)])
        let midB = Array(b[prefixMatch..<(m - suffixMatch)])
        
        let midN = midA.count
        let midM = midB.count
        var lcs = Array(repeating: Array(repeating: 0, count: midM + 1), count: midN + 1)
        if midN > 0 && midM > 0 {
            for i in stride(from: midN - 1, through: 0, by: -1) {
                for j in stride(from: midM - 1, through: 0, by: -1) {
                    lcs[i][j] = midA[i] == midB[j] ? lcs[i+1][j+1] + 1 : max(lcs[i+1][j], lcs[i][j+1])
                }
            }
        }
        
        var result: [DiffLine] = []
        // Add prefix
        for k in 0..<prefixMatch {
            result.append(DiffLine(kind: .context, text: a[k]))
        }
        
        // Add middle diff
        var i = 0, j = 0
        while i < midN && j < midM {
            if midA[i] == midB[j] {
                result.append(DiffLine(kind: .context, text: midA[i])); i += 1; j += 1
            } else if lcs[i+1][j] >= lcs[i][j+1] {
                result.append(DiffLine(kind: .remove, text: midA[i])); i += 1
            } else {
                result.append(DiffLine(kind: .add, text: midB[j])); j += 1
            }
        }
        while i < midN { result.append(DiffLine(kind: .remove, text: midA[i])); i += 1 }
        while j < midM { result.append(DiffLine(kind: .add, text: midB[j])); j += 1 }
        
        // Add suffix
        for k in (n - suffixMatch)..<n {
            result.append(DiffLine(kind: .context, text: a[k]))
        }
        
        return result
    }
}
