import SwiftUI

/// Edits the per-site agent memory: free text the agent prepends to its context
/// on every run for this site.
struct MemorySheet: View {
    @EnvironmentObject var settings: SettingsStore
    @Environment(\.dismiss) private var dismiss
    let workspace: SiteWorkspace
    @State private var text: String

    init(workspace: SiteWorkspace) {
        self.workspace = workspace
        _text = State(initialValue: workspace.memory)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: Theme.Space.m) {
                IconTile(systemImage: "brain.head.profile", tint: workspace.accentColor, size: 34, gradient: false)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Agent memory").font(.title3.weight(.semibold))
                    Text(workspace.name).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(Theme.Space.l)
            Divider()
            VStack(alignment: .leading, spacing: Theme.Space.s) {
                Text("The agent reads this at the start of every conversation for this site. Use it for durable facts: where forms post, files to never touch, tone, conventions.")
                    .font(.caption).foregroundStyle(.secondary)
                TextEditor(text: $text)
                    .font(.callout)
                    .frame(minHeight: 220)
                    .padding(6)
                    .background(Theme.cardFill, in: RoundedRectangle(cornerRadius: Theme.Radius.medium))
                    .overlay(RoundedRectangle(cornerRadius: Theme.Radius.medium).strokeBorder(Theme.hairline))
            }
            .padding(Theme.Space.l)
            Divider()
            HStack {
                Button("Cancel") { dismiss() }
                Spacer()
                Button("Save") {
                    var updated = workspace
                    updated.memory = text
                    settings.updateWorkspace(updated)
                    dismiss()
                }
                .buttonStyle(.primary)
            }
            .padding(Theme.Space.l)
        }
        .frame(width: 520, height: 460)
    }
}
