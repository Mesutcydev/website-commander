import SwiftUI

/// Shows the results of a site audit: a severity summary and one card per issue,
/// with a "Fix with AI" action that hands the issues to the agent.
struct AuditSheet: View {

    @Environment(\.dismiss) private var dismiss
    let issues: [SiteAuditIssue]
    let url: String
    let onFix: () -> Void

    private var criticalCount: Int { issues.filter { $0.severity == .critical }.count }
    private var warningCount: Int { issues.filter { $0.severity == .warning }.count }
    private var infoCount: Int { issues.filter { $0.severity == .info }.count }

    /// A 0-100 health score: start at 100, subtract per issue by severity.
    private var score: Int {
        let raw = 100 - criticalCount * 20 - warningCount * 8 - infoCount * 2
        return max(0, min(100, raw))
    }

    private var scoreTint: Color {
        switch score {
        case 80...: return Theme.success
        case 50..<80: return Theme.warning
        default: return Theme.danger
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(spacing: Theme.Space.m) {
                    ForEach(issues) { issue in
                        IssueRow(issue: issue)
                    }
                }
                .padding(Theme.Space.l)
            }
            Divider()
            footer
        }
        .frame(width: 560, height: 560)
    }

    private var header: some View {
        HStack(spacing: Theme.Space.l) {
            ZStack {
                Circle()
                    .stroke(scoreTint.opacity(0.2), lineWidth: 8)
                Circle()
                    .trim(from: 0, to: CGFloat(score) / 100)
                    .stroke(scoreTint, style: StrokeStyle(lineWidth: 8, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                Text("\(score)")
                    .font(Theme.display(26, weight: .heavy))
            }
            .frame(width: 74, height: 74)

            VStack(alignment: .leading, spacing: 4) {
                Text("Site Audit").font(.title3.weight(.semibold))
                Text(url).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                HStack(spacing: Theme.Space.s) {
                    Badge(text: "\(criticalCount) critical", systemImage: "xmark.octagon.fill", tint: Theme.danger)
                    Badge(text: "\(warningCount) warnings", systemImage: "exclamationmark.triangle.fill", tint: Theme.warning)
                    Badge(text: "\(infoCount) info", systemImage: "info.circle.fill", tint: Theme.info)
                }
            }
            Spacer()
        }
        .padding(Theme.Space.l)
    }

    private var footer: some View {
        HStack {
            Button("Close") { dismiss() }
            Spacer()
            if criticalCount + warningCount > 0 {
                Button {
                    onFix()
                } label: {
                    Label("Fix with AI", systemImage: "wand.and.stars")
                }
                .buttonStyle(.primary)
            }
        }
        .padding(Theme.Space.l)
    }
}

private struct IssueRow: View {
    let issue: SiteAuditIssue

    private var tint: Color {
        switch issue.severity {
        case .critical: return Theme.danger
        case .warning: return Theme.warning
        case .info: return Theme.info
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: Theme.Space.m) {
            Image(systemName: issue.severity.icon)
                .foregroundStyle(tint)
                .font(.title3)
                .frame(width: 26)
            VStack(alignment: .leading, spacing: 3) {
                Text(issue.title).font(.body.weight(.semibold))
                Text(issue.detail).font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .commandCard()
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.card)
                .strokeBorder(tint.opacity(0.25), lineWidth: 1)
        )
    }
}
