import SwiftUI

/// Lists saved conversations (scoped to the active site) and lets you load,
/// delete, or save the current chat.
struct ConversationsSheet: View {
    @EnvironmentObject var engine: AgentEngine
    @EnvironmentObject var settings: SettingsStore
    @EnvironmentObject var conversations: ConversationStore
    @Environment(\.dismiss) private var dismiss
    @State private var showAll = false
    @State private var saveTitle = ""
    @State private var showSave = false

    private var rows: [SavedConversation] {
        showAll ? conversations.conversations
                : conversations.list(forWorkspaceID: settings.activeWorkspace?.id)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Conversations").font(.title3.weight(.semibold))
                Spacer()
                Toggle("All sites", isOn: $showAll).toggleStyle(.switch)
                Button {
                    showSave = true
                } label: {
                    Label("Save current", systemImage: "tray.and.arrow.down.fill")
                }
                .buttonStyle(.primarySoft)
                .disabled(engine.transcript.isEmpty)
            }
            .padding(Theme.Space.l)
            Divider()

            if rows.isEmpty {
                EmptyStateView(systemImage: "bubble.left.and.text.bubble.right",
                               title: "No saved conversations",
                               message: "Save a chat to pick up where you left off later.")
            } else {
                ScrollView {
                    LazyVStack(spacing: 6) {
                        ForEach(rows) { conv in
                            row(conv)
                        }
                    }
                    .padding(Theme.Space.m)
                }
            }
            Divider()
            HStack {
                Button("Close") { dismiss() }
                Spacer()
            }
            .padding(Theme.Space.l)
        }
        .frame(width: 520, height: 520)
        .popover(isPresented: $showSave, arrowEdge: .top) {
            VStack(alignment: .leading, spacing: Theme.Space.s) {
                Text("Save conversation").font(.headline)
                TextField("Title (optional)", text: $saveTitle)
                    .textFieldStyle(.roundedBorder)
                HStack {
                    Button("Cancel") { showSave = false; saveTitle = "" }
                    Spacer()
                    Button("Save") {
                        engine.saveCurrentConversation(title: saveTitle)
                        saveTitle = ""; showSave = false
                    }
                    .buttonStyle(.primary)
                }
            }
            .padding(Theme.Space.l)
            .frame(width: 300)
        }
    }

    private func row(_ conv: SavedConversation) -> some View {
        HStack(spacing: Theme.Space.m) {
            IconTile(systemImage: conv.id == engine.currentConversationID ? "checkmark.bubble.fill" : "bubble.left.fill",
                     tint: Theme.accent, size: 32, gradient: false)
            VStack(alignment: .leading, spacing: 2) {
                Text(conv.title).font(.callout.weight(.medium)).lineLimit(1)
                Text("\(conv.messages.count) messages · \(conv.updatedAt.formatted(date: .abbreviated, time: .shortened))")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                engine.loadConversation(conv)
                dismiss()
            } label: {
                Text("Open").font(.callout.weight(.medium))
            }
            .buttonStyle(.primarySoft)
            Button(role: .destructive) {
                conversations.delete(conv.id)
                if engine.currentConversationID == conv.id { engine.currentConversationID = nil }
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.icon)
        }
        .padding(Theme.Space.s)
        .background(Theme.cardFill, in: RoundedRectangle(cornerRadius: Theme.Radius.medium))
    }
}
