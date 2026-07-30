import SwiftUI
import AppKit

/// The five top-level destinations shown in the sidebar.
enum SidebarItem: String, CaseIterable, Identifiable, Hashable {
    case commandCenter = "Command Center"
    case sites = "Sites"
    case agent = "Agent"
    case preview = "Preview"
    case history = "History"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .commandCenter: return "square.grid.2x2.fill"
        case .sites:         return "folder.fill"
        case .agent:         return "bubble.left.and.text.bubble.right.fill"
        case .preview:       return "eye.fill"
        case .history:       return "clock.fill"
        }
    }
}

/// The Mac shell: a NavigationSplitView with a visual sidebar and a detail pane
/// that swaps between the five destinations. Onboarding gates first launch.
struct RootView: View {

    @EnvironmentObject var settings: SettingsStore
    @EnvironmentObject var engine: AgentEngine
    @EnvironmentObject var updater: UpdateChecker
    @State private var selection: SidebarItem? = .commandCenter
    @State private var showDebug = false
    @State private var showPalette = false
    @State private var showUpdateAlert = false
    @State private var showUpdateError = false

    var body: some View {
        Group {
            if !settings.hasCompletedOnboarding {
                OnboardingView()
            } else {
                NavigationSplitView {
                    sidebar
                } detail: {
                    detail
                }
                .navigationSplitViewStyle(.balanced)
            }
        }
        .environment(\.sidebarSelection, $selection)
        .sheet(isPresented: $showDebug) {
            DebugBriefSheet(onSendToAgent: { prompt in
                showDebug = false
                engine.prefilledPrompt = prompt
                selection = .agent
            })
        }
        .onReceive(NotificationCenter.default.publisher(for: .requestDebug)) { _ in
            showDebug = true
        }
        .sheet(isPresented: $showPalette) {
            CommandPaletteView(
                selection: $selection,
                onNewChat: { engine.newChat() },
                onDebug: {
                    // Let the palette dismiss first, then open the debug sheet.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) { showDebug = true }
                },
                onAddSite: {
                    selection = .sites
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) {
                        NotificationCenter.default.post(name: .requestAddSite, object: nil)
                    }
                }
            )
        }
        .onReceive(NotificationCenter.default.publisher(for: .requestPalette)) { _ in
            showPalette = true
        }
        .onChange(of: updater.available) { _, new in if new != nil { showUpdateAlert = true } }
        .onChange(of: updater.lastError) { _, new in
            if new != nil && updater.available == nil { showUpdateError = true }
        }
        .alert("Update available", isPresented: $showUpdateAlert, presenting: updater.available) { rel in
            if !rel.url.isEmpty {
                Button("Download \(rel.version)") {
                    if let u = URL(string: rel.url) { NSWorkspace.shared.open(u) }
                }
            }
            Button("Later", role: .cancel) { updater.available = nil }
        } message: { rel in
            Text(rel.notes.isEmpty ? "Version \(rel.version) is available." : rel.notes)
        }
        .alert("Couldn't check for updates", isPresented: $showUpdateError) {
            Button("OK", role: .cancel) { updater.lastError = nil }
        } message: {
            Text(updater.lastError ?? "")
        }
    }

    // MARK: Sidebar

    private var sidebar: some View {
        List(selection: $selection) {
            Section {
                ForEach(SidebarItem.allCases) { item in
                    Label {
                        Text(item.rawValue)
                    } icon: {
                        Image(systemName: item.icon)
                            .foregroundStyle(selection == item ? .white : Theme.accent)
                            .frame(width: 22)
                    }
                    .tag(item)
                    .badge(badgeCount(for: item))
                }
            }
            .listRowInsets(EdgeInsets(top: 4, leading: 8, bottom: 4, trailing: 8))
        }
        .listStyle(.sidebar)
        .navigationSplitViewColumnWidth(min: 210, ideal: 230, max: 280)
        .safeAreaInset(edge: .bottom) {
            ActiveWorkspaceFooter()
        }
    }

    private func badgeCount(for item: SidebarItem) -> Int {
        switch item {
        case .agent: return engine.pendingChanges.count
        case .sites: return settings.workspaces.count
        default: return 0
        }
    }

    // MARK: Detail

    @ViewBuilder
    private var detail: some View {
        switch selection ?? .commandCenter {
        case .commandCenter: CommandCenterView()
        case .sites:         SitesView()
        case .agent:         ChatView()
        case .preview:       PreviewView()
        case .history:       HistoryView()
        }
    }
}

// MARK: - Sidebar selection environment (lets deep views navigate)

private struct SidebarSelectionKey: EnvironmentKey {
    static let defaultValue: Binding<SidebarItem?> = .constant(.commandCenter)
}

extension EnvironmentValues {
    var sidebarSelection: Binding<SidebarItem?> {
        get { self[SidebarSelectionKey.self] }
        set { self[SidebarSelectionKey.self] = newValue }
    }
}

// MARK: - Active workspace footer

/// A compact card at the bottom of the sidebar showing the active site and its
/// readiness, with a quick switcher menu.
struct ActiveWorkspaceFooter: View {
    @EnvironmentObject var settings: SettingsStore
    @Environment(\.sidebarSelection) private var sidebarSelection
    @State private var showSwitcher = false

    var body: some View {
        Button { showSwitcher = true } label: {
            HStack(spacing: Theme.Space.s) {
                if let ws = settings.activeWorkspace {
                    IconTile(systemImage: ws.techStack.icon, tint: ws.accentColor, size: 30, gradient: false)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(ws.name).font(.callout.weight(.semibold)).lineLimit(1)
                        HStack(spacing: 4) {
                            StatusDot(color: isReady(ws) ? Theme.success : Theme.warning)
                            Text(ws.slug).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                } else {
                    IconTile(systemImage: "folder.badge.plus", size: 30, gradient: false)
                    Text("No site connected").font(.callout.weight(.medium))
                }
                Spacer()
                Image(systemName: "chevron.up.chevron.down")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.secondary)
            }
            .padding(Theme.Space.m)
            .background(Theme.cardFill, in: RoundedRectangle(cornerRadius: Theme.Radius.medium))
            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.medium).strokeBorder(Theme.hairline))
            .contentShape(RoundedRectangle(cornerRadius: Theme.Radius.medium))
        }
        .buttonStyle(.plain)
        .padding(Theme.Space.s)
        .popover(isPresented: $showSwitcher, arrowEdge: .bottom) {
            SiteSwitcherPanel(onAdd: {
                showSwitcher = false
                sidebarSelection.wrappedValue = .sites
                NotificationCenter.default.post(name: .requestAddSite, object: nil)
            })
            .frame(width: 320)
        }
    }

    private func isReady(_ ws: SiteWorkspace) -> Bool {
        settings.resolvedGitHubToken(for: ws) != nil
    }
}

/// The modern site switcher: a scrollable list of every connected site with its
/// tech tile, slug, active check, and readiness dot, plus an add-site action.
struct SiteSwitcherPanel: View {
    @EnvironmentObject var settings: SettingsStore
    @Environment(\.dismiss) private var dismiss
    let onAdd: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Switch Site").font(.headline)
                Spacer()
                Text("\(settings.workspaces.count)")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding(.horizontal, Theme.Space.m)
            .padding(.top, Theme.Space.m)
            .padding(.bottom, Theme.Space.s)

            Divider()

            if settings.workspaces.isEmpty {
                VStack(spacing: Theme.Space.s) {
                    Image(systemName: "folder").font(.title2).foregroundStyle(.secondary)
                    Text("No sites yet").font(.callout).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity).padding(Theme.Space.xl)
            } else {
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(settings.workspaces) { ws in
                            SwitcherRow(ws: ws, isActive: ws.id == settings.activeWorkspace?.id) {
                                settings.setActive(ws)
                                dismiss()
                            }
                        }
                    }
                    .padding(Theme.Space.s)
                }
                .frame(maxHeight: 340)
            }

            Divider()

            Button(action: onAdd) {
                Label("Add Website…", systemImage: "plus.circle.fill")
                    .font(.callout.weight(.semibold))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(Theme.Space.m)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }
}

private struct SwitcherRow: View {
    @EnvironmentObject var settings: SettingsStore
    let ws: SiteWorkspace
    let isActive: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: Theme.Space.s) {
                IconTile(systemImage: ws.techStack.icon, tint: ws.accentColor, size: 30, gradient: false)
                VStack(alignment: .leading, spacing: 1) {
                    Text(ws.name).font(.callout.weight(.medium)).lineLimit(1)
                    Text(ws.slug).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                if isActive {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(ws.accentColor)
                } else {
                    StatusDot(color: settings.resolvedGitHubToken(for: ws) != nil ? Theme.success : Theme.warning, size: 7)
                }
            }
            .padding(.horizontal, Theme.Space.s)
            .padding(.vertical, 6)
            .background(isActive ? ws.accentColor.opacity(0.14) : Color.clear,
                        in: RoundedRectangle(cornerRadius: Theme.Radius.small))
            .contentShape(RoundedRectangle(cornerRadius: Theme.Radius.small))
            .animation(Motion.snappy, value: isActive)
        }
        .buttonStyle(.plain)
    }
}
