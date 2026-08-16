import SwiftUI

/// Lists conversations (scoped to the active site) and lets you open, rename,
/// or delete one. There is no "save" action: the agent saves every chat as it
/// happens, so this list is always current.
struct ConversationsSheet: View {
    @EnvironmentObject var engine: AgentEngine
    @EnvironmentObject var settings: SettingsStore
    @EnvironmentObject var conversations: ConversationStore
    @Environment(\.dismiss) private var dismiss
    @State private var showAll = false
    @State private var renamingID: UUID?
    @State private var renameText = ""
    @State private var pendingDelete: SavedConversation?
    @FocusState private var renameFocused: Bool

    private var rows: [SavedConversation] {
        showAll ? conversations.conversations
                : conversations.list(forWorkspaceID: settings.activeWorkspace?.id)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Conversations").font(.title3.weight(.semibold))
                    Label("Saved automatically", systemImage: "checkmark.icloud")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .labelStyle(.titleAndIcon)
                }
                Spacer()
                Toggle("All sites", isOn: $showAll).toggleStyle(.switch)
            }
            .padding(Theme.Space.l)
            Divider()

            if rows.isEmpty {
                EmptyStateView(systemImage: "bubble.left.and.text.bubble.right",
                               title: "No conversations yet",
                               message: "Start a chat — it is saved as you go, and shows up here.")
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
        .confirmationDialog(
            "Delete conversation?",
            isPresented: Binding(
                get: { pendingDelete != nil },
                set: { if !$0 { pendingDelete = nil } }
            ),
            titleVisibility: .visible,
            presenting: pendingDelete
        ) { conv in
            Button("Delete", role: .destructive) { delete(conv) }
            Button("Cancel", role: .cancel) { pendingDelete = nil }
        } message: { conv in
            Text("“\(conv.title)” and its \(conv.messages.count) message\(conv.messages.count == 1 ? "" : "s") will be permanently removed. This can't be undone.")
        }
    }

    private func delete(_ conv: SavedConversation) {
        conversations.delete(conv.id)
        if engine.currentConversationID == conv.id {
            // Clear the live transcript too, or the next autosave re-persists
            // the deleted chat under a fresh id.
            engine.clearCurrentConversation()
        }
        pendingDelete = nil
    }

    private func row(_ conv: SavedConversation) -> some View {
        HStack(spacing: Theme.Space.m) {
            IconTile(systemImage: conv.id == engine.currentConversationID ? "checkmark.bubble.fill" : "bubble.left.fill",
                     tint: Theme.accent, size: 32, gradient: false)
            VStack(alignment: .leading, spacing: 2) {
                if renamingID == conv.id {
                    TextField("Title", text: $renameText)
                        .textFieldStyle(.roundedBorder)
                        .focused($renameFocused)
                        .onSubmit { commitRename(conv) }
                } else {
                    Text(conv.title).font(.callout.weight(.medium)).lineLimit(1)
                }
                Text("\(conv.messages.count) messages · \(conv.updatedAt.formatted(date: .abbreviated, time: .shortened))")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            Spacer()
            if renamingID == conv.id {
                Button("Done") { commitRename(conv) }
                    .buttonStyle(.primarySoft)
            } else {
                Button {
                    engine.loadConversation(conv)
                    dismiss()
                } label: {
                    Text("Open").font(.callout.weight(.medium))
                }
                .buttonStyle(.primarySoft)
                Button {
                    renameText = conv.title
                    renamingID = conv.id
                    renameFocused = true
                } label: {
                    Image(systemName: "pencil")
                }
                .buttonStyle(.icon)
                .help("Rename conversation")
            }
            Button(role: .destructive) {
                pendingDelete = conv
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.icon)
            .help("Delete conversation")
        }
        .padding(Theme.Space.s)
        .background(Theme.cardFill, in: RoundedRectangle(cornerRadius: Theme.Radius.medium))
    }

    private func commitRename(_ conv: SavedConversation) {
        if conv.id == engine.currentConversationID {
            engine.renameCurrentConversation(renameText)
        } else {
            conversations.rename(conv.id, to: renameText)
        }
        renamingID = nil
        renameText = ""
    }
}
