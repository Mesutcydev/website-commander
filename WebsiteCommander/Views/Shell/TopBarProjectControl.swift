import SwiftUI

/// The project/site switcher, migrated out of the old sidebar footer into the
/// bar's left zone. It shows only what belongs in chrome — mark, real
/// readiness, name — and leaves the repository slug to its popover.
struct TopBarProjectControl: View {
    let metrics: TopBarMetrics
    let isOpen: Bool
    let onToggle: () -> Void

    @EnvironmentObject private var settings: SettingsStore
    @FocusState private var isFocused: Bool

    /// Everything in the control except the name: padding, mark, gaps, dot and
    /// chevron. The name gets whatever the width cap leaves over.
    private var fixedWidth: CGFloat {
        let padding: CGFloat = 18
        let mark = TopBarMetrics.projectIconSize + 7
        let dot = settings.activeWorkspace == nil ? 0 : TopBarMetrics.statusDotSize + 7
        let chevron = TopBarMetrics.chevronSize + 7
        return padding + mark + dot + chevron
    }

    var body: some View {
        Button(action: onToggle) {
            HStack(spacing: 7) {
                mark
                if let workspace = settings.activeWorkspace {
                    Circle()
                        .fill(settings.isReady(workspace) ? Theme.success : Theme.warning)
                        .frame(width: TopBarMetrics.statusDotSize,
                               height: TopBarMetrics.statusDotSize)
                }
                Text(label)
                    .font(Theme.ui(13, .medium))
                    .foregroundStyle(Theme.Chrome.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(minWidth: 0,
                           maxWidth: metrics.projectMaxWidth - fixedWidth,
                           alignment: .leading)
                Image(systemName: "chevron.down")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Theme.Chrome.textMuted)
                    .frame(width: TopBarMetrics.chevronSize,
                           height: TopBarMetrics.chevronSize)
            }
            .padding(.horizontal, 9)
            .frame(height: TopBarMetrics.controlHeight)
            .frame(minWidth: metrics.projectMinWidth, alignment: .leading)
        }
        .buttonStyle(TopBarControlButtonStyle(
            radius: TopBarMetrics.controlRadius,
            emphasis: isOpen ? .selected : .resting
        ))
        .focused($isFocused)
        .help(helpText)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityHint("Switch the active project")
        .accessibilityAddTraits(.isButton)
        .accessibilityValue(isOpen ? "Expanded" : "Collapsed")
        .topBarTrigger(.project)
        .onChange(of: isOpen) { wasOpen, open in
            // Closing returns focus to the trigger, the way a menu does.
            if wasOpen && !open { isFocused = true }
        }
    }

    @ViewBuilder
    private var mark: some View {
        if let workspace = settings.activeWorkspace {
            Image(systemName: workspace.techStack.icon)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(workspace.accentColor)
                .frame(width: TopBarMetrics.projectIconSize,
                       height: TopBarMetrics.projectIconSize)
        } else {
            Image(systemName: "folder.badge.plus")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Theme.Chrome.textMuted)
                .frame(width: TopBarMetrics.projectIconSize,
                       height: TopBarMetrics.projectIconSize)
        }
    }

    private var label: String {
        settings.activeWorkspace?.name ?? String(localized: "No project")
    }

    private var helpText: String {
        settings.activeWorkspace == nil
            ? String(localized: "Connect a website")
            : String(localized: "Switch project")
    }

    private var accessibilityLabel: String {
        guard let workspace = settings.activeWorkspace else {
            return String(localized: "Project: none connected")
        }
        let readiness = settings.isReady(workspace)
            ? String(localized: "ready")
            : String(localized: "needs setup")
        return "\(String(localized: "Project")): \(workspace.name), \(readiness)"
    }
}

// MARK: - Popover

/// The project popover: the sidebar's old switcher list, rebuilt on the shell's
/// shared popover system. Search appears only once the list is long enough to
/// need it.
struct TopBarProjectPopover: View {
    let maxHeight: CGFloat
    let onSelect: (SiteWorkspace) -> Void
    let onAddSite: () -> Void

    @EnvironmentObject private var settings: SettingsStore
    @State private var search = ""
    @FocusState private var searchFocused: Bool

    private var needsSearch: Bool {
        TopBarMetrics.projectPopoverNeedsSearch(projectCount: settings.workspaces.count)
    }

    private var matches: [SiteWorkspace] {
        let needle = search.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else { return settings.workspaces }
        return settings.workspaces.filter {
            $0.name.lowercased().contains(needle) || $0.slug.lowercased().contains(needle)
        }
    }

    var body: some View {
        TopBarPopoverPanel {
            VStack(alignment: .leading, spacing: 2) {
                if needsSearch {
                    TopBarPopoverSearchField(text: $search, prompt: "Search projects")
                        .focused($searchFocused)
                        .padding(.bottom, 4)
                }

                if settings.workspaces.isEmpty {
                    TopBarPopoverEmptyState(
                        systemImage: "folder.badge.plus",
                        message: "No projects connected yet"
                    )
                } else {
                    ScrollView {
                        VStack(spacing: 2) {
                            ForEach(matches) { workspace in
                                TopBarPopoverRow(
                                    title: workspace.name,
                                    subtitle: workspace.slug,
                                    isSelected: workspace.id == settings.activeWorkspaceID,
                                    leading: {
                                        Image(systemName: workspace.techStack.icon)
                                            .font(.system(size: 13, weight: .medium))
                                            .foregroundStyle(workspace.accentColor)
                                            .frame(width: 18, height: 18)
                                    },
                                    trailing: {
                                        Circle()
                                            .fill(settings.isReady(workspace) ? Theme.success : Theme.warning)
                                            .frame(width: TopBarMetrics.statusDotSize,
                                                   height: TopBarMetrics.statusDotSize)
                                    },
                                    action: { onSelect(workspace) }
                                )
                            }
                            if matches.isEmpty {
                                TopBarPopoverEmptyState(
                                    systemImage: "magnifyingglass",
                                    message: "No matching project"
                                )
                            }
                        }
                    }
                    .frame(maxHeight: maxHeight)
                    // A scroll view is greedy: without this it claims the whole
                    // cap and leaves a dead band under a short list.
                    .fixedSize(horizontal: false, vertical: true)
                    .scrollBounceBehavior(.basedOnSize)
                }

                TopBarPopoverSeparator()

                TopBarPopoverRow(
                    title: String(localized: "Add Website…"),
                    leading: { TopBarRowIcon(systemImage: "plus") },
                    action: onAddSite
                )
            }
        }
        .frame(width: TopBarPopoverKind.project.width)
        .onAppear { if needsSearch { searchFocused = true } }
    }
}

// MARK: - Shared popover pieces

/// The popover system's search field. Quiet, inset, and only shown where a
/// list is genuinely long.
struct TopBarPopoverSearchField: View {
    @Binding var text: String
    let prompt: String

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Theme.Chrome.textMuted)
            TextField(LocalizedStringKey(prompt), text: $text)
                .textFieldStyle(.plain)
                .font(Theme.ui(13, .regular))
                .foregroundStyle(Theme.Chrome.textPrimary)
        }
        .padding(.horizontal, 9)
        .frame(height: 32)
        .background {
            RoundedRectangle(cornerRadius: TopBarMetrics.smallControlRadius, style: .continuous)
                .fill(Theme.Chrome.popoverRowHover)
        }
    }
}

struct TopBarPopoverSeparator: View {
    var body: some View {
        Rectangle()
            .fill(Theme.Chrome.separator)
            .frame(height: 1)
            .padding(.vertical, 4)
            .accessibilityHidden(true)
    }
}

struct TopBarPopoverEmptyState: View {
    let systemImage: String
    let message: String

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: systemImage)
                .font(.system(size: 15, weight: .regular))
                .foregroundStyle(Theme.Chrome.textMuted)
            Text(LocalizedStringKey(message))
                .font(Theme.ui(12, .medium))
                .foregroundStyle(Theme.Chrome.textMuted)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 18)
    }
}
