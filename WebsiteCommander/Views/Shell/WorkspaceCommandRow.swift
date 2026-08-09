import SwiftUI

/// A destination's own controls, on the workspace grid.
///
/// The application bar carries everything that is true of the whole app; a
/// screen's own filters and actions live here instead, one row inside the
/// workspace, aligned to the same gutter as the content beneath it. This is
/// where the controls that used to sit in the native window toolbar moved to
/// when the shell stopped having one.
struct WorkspaceCommandRow<Content: View>: View {
    let gutter: CGFloat
    @ViewBuilder var content: Content

    var body: some View {
        HStack(spacing: TopBarMetrics.groupGap) { content }
            .padding(.horizontal, gutter)
            .padding(.top, 16)
            .padding(.bottom, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A search field for a workspace command row. Same height, radius, and surface
/// language as the bar's controls, so the two rows read as one system.
struct WorkspaceSearchField: View {
    @Binding var text: String
    let prompt: String
    var width: CGFloat = 240

    @FocusState private var isFocused: Bool

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Theme.Chrome.textMuted)
            TextField(LocalizedStringKey(prompt), text: $text)
                .textFieldStyle(.plain)
                .font(Theme.ui(13, .regular))
                .foregroundStyle(Theme.Chrome.textPrimary)
                .focused($isFocused)
            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Theme.Chrome.textMuted)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, 9)
        .frame(width: width, height: Theme.Height.input)
        .background {
            let shape = RoundedRectangle(cornerRadius: TopBarMetrics.controlRadius, style: .continuous)
            shape
                .fill(Theme.recessedSurface)
                .overlay {
                    shape.strokeBorder(isFocused ? Theme.Chrome.accent.opacity(0.44)
                                                 : Theme.borderSubtle,
                                       lineWidth: 1)
                }
        }
        .animation(Theme.Chrome.Timing.hover, value: isFocused)
    }
}

/// A labelled menu control (a filter or a scope picker) in the shell's control
/// language rather than the system's bordered picker.
struct WorkspaceMenuControl<Content: View>: View {
    let title: String
    let value: String
    var systemImage: String?
    @ViewBuilder var content: Content

    var body: some View {
        Menu {
            content
        } label: {
            HStack(spacing: 7) {
                if let systemImage {
                    Image(systemName: systemImage)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Theme.Chrome.textSecondary)
                }
                Text(value)
                    .font(Theme.ui(13, .medium))
                    .foregroundStyle(Theme.Chrome.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Image(systemName: "chevron.down")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Theme.Chrome.textMuted)
            }
            .padding(.horizontal, 9)
            .frame(height: Theme.Height.input)
            .background {
                let shape = RoundedRectangle(cornerRadius: TopBarMetrics.controlRadius,
                                             style: .continuous)
                shape
                    .fill(Theme.Chrome.barControlFill)
                    .overlay { shape.strokeBorder(Theme.borderSubtle, lineWidth: 1) }
            }
            .contentShape(RoundedRectangle(cornerRadius: TopBarMetrics.controlRadius,
                                           style: .continuous))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(title)
        .accessibilityLabel("\(title): \(value)")
    }
}

/// A workspace-level action button. Text plus optional glyph, 34pt tall, on the
/// same surfaces as the bar's controls.
struct WorkspaceActionButton: View {
    let title: String
    var systemImage: String?
    var isProminent: Bool = false
    var isEnabled: Bool = true
    var isLoading: Bool = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if isLoading {
                    ProgressView()
                        .controlSize(.small)
                        .frame(width: TopBarMetrics.iconSize, height: TopBarMetrics.iconSize)
                } else if let systemImage {
                    Image(systemName: systemImage)
                        .font(.system(size: TopBarMetrics.iconSize, weight: .medium))
                }
                Text(LocalizedStringKey(title))
                    .font(Theme.ui(13, .medium))
                    .lineLimit(1)
            }
            .foregroundStyle(isProminent ? AnyShapeStyle(Color.white)
                                        : AnyShapeStyle(Theme.Chrome.textPrimary))
            .padding(.horizontal, 11)
            .frame(height: Theme.Height.input)
        }
        .buttonStyle(TopBarControlButtonStyle(
            radius: TopBarMetrics.controlRadius,
            emphasis: isProminent ? .accent : .resting
        ))
        .disabled(!isEnabled)
        .accessibilityLabel(title)
    }
}
