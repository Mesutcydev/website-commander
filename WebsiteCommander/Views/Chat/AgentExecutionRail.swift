import SwiftUI

/// The execution rail: a full-height workspace surface beside the conversation
/// that answers "what is the agent actually doing right now".
///
/// Every section is backed by real engine state — live tool events and staged
/// changes. Nothing is invented to fill the column, and when there is no real
/// content the rail is not shown at all (see `hasContent`), which lets the
/// conversation reclaim the full width.
struct AgentExecutionRail: View {
    let events: [ToolEvent]
    let pendingChanges: [PendingChange]
    let state: AgentState
    var onReview: (PendingChange) -> Void

    /// True when the rail has something real to show.
    static func hasContent(events: [ToolEvent], pendingChanges: [PendingChange]) -> Bool {
        !events.isEmpty || !pendingChanges.isEmpty
    }

    private var running: [ToolEvent] { events.filter { $0.status == .running } }
    private var finished: [ToolEvent] { events.filter { $0.status != .running } }

    /// Distinct files the agent has staged. Real paths only.
    private var touchedFiles: [PendingChange] {
        var seen = Set<String>()
        return pendingChanges.filter { seen.insert($0.path).inserted }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if !running.isEmpty {
                        section(String(localized: "Current operation")) {
                            ForEach(running) { event in
                                eventRow(event)
                            }
                        }
                    }
                    if !finished.isEmpty {
                        section(String(localized: "Completed")) {
                            ForEach(finished) { event in
                                eventRow(event)
                            }
                        }
                    }
                    if !touchedFiles.isEmpty {
                        section(String(localized: "Files touched")) {
                            ForEach(touchedFiles) { change in
                                fileRow(change)
                            }
                        }
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 14)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .background(Theme.raisedFill.opacity(0.55))
        .overlay(alignment: .leading) {
            Rectangle()
                .fill(Theme.borderSubtle)
                .frame(width: 1)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(String(localized: "Agent execution activity"))
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 7) {
            Image(systemName: "sparkles")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Theme.Chrome.accent)
            Text("Activity")
                .font(Theme.ui(13, .semibold))
                .foregroundStyle(Theme.Chrome.textPrimary)
            Spacer(minLength: 8)
            if !pendingChanges.isEmpty {
                Text("\(pendingChanges.count)")
                    .font(Theme.ui(11, .semibold))
                    .foregroundStyle(Theme.warning)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Theme.warning.opacity(0.14), in: Capsule())
                    .accessibilityLabel("\(pendingChanges.count) changes awaiting approval")
            } else if state.isActive {
                ProgressView().controlSize(.mini)
            }
        }
        .padding(.horizontal, 14)
        .frame(height: 40)
    }

    // MARK: Sections

    @ViewBuilder
    private func section<Content: View>(_ title: String,
                                        @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title)
                .font(Theme.ui(10.5, .semibold))
                .tracking(0.6)
                .textCase(.uppercase)
                .foregroundStyle(Theme.Chrome.textMuted)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func eventRow(_ event: ToolEvent) -> some View {
        HStack(alignment: .top, spacing: 7) {
            statusIcon(event.status)
                .frame(width: 14, height: 14)
            Text(event.summary)
                .font(Theme.ui(12))
                .foregroundStyle(event.status == .failure
                                 ? Theme.danger
                                 : Theme.Chrome.textSecondary)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private func statusIcon(_ status: ToolEvent.Status) -> some View {
        switch status {
        case .running:
            ProgressView().controlSize(.mini)
        case .success:
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 11))
                .foregroundStyle(Theme.success)
        case .failure:
            Image(systemName: "xmark.circle.fill")
                .font(.system(size: 11))
                .foregroundStyle(Theme.danger)
        }
    }

    private func fileRow(_ change: PendingChange) -> some View {
        Button {
            onReview(change)
        } label: {
            HStack(spacing: 7) {
                Image(systemName: change.category.icon)
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.Chrome.accent)
                    .frame(width: 14)
                Text(change.path)
                    .font(Theme.ui(12))
                    .foregroundStyle(Theme.Chrome.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 4)
                if !change.risks.isEmpty {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 9))
                        .foregroundStyle(Theme.warning)
                }
            }
            .padding(.horizontal, 7)
            .padding(.vertical, 5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.panelFill.opacity(0.6),
                        in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .buttonStyle(.plain)
        .help("Review \(change.path)")
        .accessibilityLabel("Review \(change.path)")
    }
}
