import SwiftUI

/// A ⌘K command palette: a searchable list of everything you can do — switch
/// site, jump to a tab, new chat, debug, preview, add site, settings. Keyboard
/// driven (↑/↓ to move, ↩ to run, esc to close).
struct CommandPaletteView: View {
    @EnvironmentObject var settings: SettingsStore
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openSettings) private var openSettings
    @Binding var selection: Destination?

    var onNewChat: () -> Void
    var onDebug: () -> Void
    var onAddSite: () -> Void

    @State private var query = ""
    @State private var cursor = 0
    @FocusState private var focused: Bool

    private struct Action: Identifiable {
        let id: String
        let title: String
        let subtitle: String
        let systemImage: String
        var brandID: BrandMarkID? = nil
        let run: () -> Void
    }

    private var actions: [Action] {
        var list: [Action] = []
        // Site switching
        for ws in settings.workspaces {
            let active = ws.id == settings.activeWorkspace?.id
            list.append(Action(
                id: "site-\(ws.id)",
                title: "Switch to \(ws.name)",
                subtitle: active ? "\(ws.slug) · active" : ws.slug,
                systemImage: ws.techStack.icon) {
                    settings.setActive(ws); dismiss()
            })
        }
        // Navigation
        for item in Destination.allCases {
            list.append(Action(id: "go-\(item.rawValue)", title: "Go to \(item.rawValue)",
                               subtitle: "Switch destination", systemImage: item.icon) {
                selection = item; dismiss()
            })
        }
        // Commands
        list.append(Action(id: "new-chat", title: "New Chat", subtitle: "Start a fresh conversation",
                           systemImage: "plus.message") { onNewChat(); selection = .agent; dismiss() })
        list.append(Action(id: "debug", title: "Debug Current Site", subtitle: "Build a brief & export to any agent",
                           systemImage: "ladybug.fill") { onDebug(); dismiss() })
        list.append(Action(id: "preview", title: "Open Live Preview", subtitle: "Render the site",
                           systemImage: "eye.fill") { selection = .preview; dismiss() })
        list.append(Action(id: "add", title: "Add Website", subtitle: "Connect a GitHub repository",
                           systemImage: "plus.circle.fill") { onAddSite(); dismiss() })
        list.append(Action(id: "settings", title: "Open Settings", subtitle: "Providers, accounts, behavior",
                           systemImage: "gearshape.fill") { dismiss(); openSettings() })
        list.append(Action(id: "vscode", title: "Open Active Site in VS Code", subtitle: "Edit the local clone",
                           systemImage: "chevron.left.forwardslash.chevron.right") {
            NotificationCenter.default.post(name: .openInVSCode, object: nil); dismiss()
        })
        return list
    }

    private var filtered: [Action] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return actions }
        return actions.filter { $0.title.lowercased().contains(q) || $0.subtitle.lowercased().contains(q) }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: Theme.Space.s) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Type a command or site…", text: $query)
                    .textFieldStyle(.plain)
                    .font(.title3)
                    .focused($focused)
                    .onKeyPress(.upArrow) { move(-1); return .handled }
                    .onKeyPress(.downArrow) { move(1); return .handled }
                    .onKeyPress(.return) { runCursor(); return .handled }
                    .onKeyPress(.escape) { dismiss(); return .handled }
            }
            .padding(Theme.Space.l)

            Divider()

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 2) {
                        if filtered.isEmpty {
                            Text("No matches").foregroundStyle(.secondary)
                                .padding(Theme.Space.xl)
                        }
                        ForEach(Array(filtered.enumerated()), id: \.element.id) { idx, action in
                            row(action, selected: idx == cursor)
                                .id(idx)
                                .onTapGesture { action.run() }
                        }
                    }
                    .padding(Theme.Space.s)
                }
                .frame(height: min(CGFloat(filtered.count) * 46 + 16, 360))
                .onChange(of: cursor) { _, new in
                    withAnimation { proxy.scrollTo(new, anchor: .center) }
                }
            }
        }
        .frame(width: 520)
        .onAppear { focused = true; cursor = 0 }
        .onChange(of: query) { _, _ in cursor = 0 }
    }

    private func row(_ action: Action, selected: Bool) -> some View {
        HStack(spacing: Theme.Space.m) {
            Group {
                if let brandID = action.brandID {
                    BrandMark(id: brandID).fill(Color.primary).padding(6)
                        .frame(width: 30, height: 30)
                        .background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
                } else {
                    Image(systemName: action.systemImage)
                        .foregroundStyle(selected ? .white : Theme.secondaryText)
                        .frame(width: 30, height: 30)
                        .background((selected ? AnyShapeStyle(Theme.brandGradient) : AnyShapeStyle(Theme.raisedFill)),
                                    in: RoundedRectangle(cornerRadius: 8))
                }
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(LocalizedStringKey(action.title)).font(.callout.weight(.medium))
                Text(LocalizedStringKey(action.subtitle)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            if selected {
                Image(systemName: "return.left").font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, Theme.Space.s)
        .padding(.vertical, 7)
        .background(selected ? Color.primary.opacity(0.08) : Color.clear,
                    in: RoundedRectangle(cornerRadius: Theme.Radius.small))
        .contentShape(RoundedRectangle(cornerRadius: Theme.Radius.small))
        .animation(Motion.snappy, value: selected)
    }

    private func move(_ delta: Int) {
        guard !filtered.isEmpty else { return }
        cursor = (cursor + delta + filtered.count) % filtered.count
    }

    private func runCursor() {
        guard filtered.indices.contains(cursor) else { return }
        filtered[cursor].run()
    }
}
