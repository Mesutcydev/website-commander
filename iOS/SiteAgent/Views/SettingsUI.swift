import SwiftUI

// Shared building blocks for every settings / inner screen, so the whole app
// has one consistent card-based look (instead of stock `Form` on some screens
// and custom cards on others). Compose these inside a ScrollView.

/// A titled card: uppercase header, themed surface (matches the app shell),
/// optional footer caption. Rows go inside, separated by `SettingsDivider`.
struct SettingsSection<Content: View>: View {
    let title: String?
    let footer: String?
    @ViewBuilder var content: () -> Content

    init(_ title: String? = nil, footer: String? = nil, @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.footer = footer
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let title {
                Text(title.localized.uppercased(with: .current))
                    .font(.mono(11, .semibold)).kerning(1.5)
                    .foregroundStyle(Theme.t3)
                    .padding(.horizontal, 4)
            }
            VStack(spacing: 0) { content() }
                .padding(.horizontal, 14)
                .padding(.vertical, 2)
                .commandCard()
            if let footer {
                Text(footer.localized)
                    .font(.caption).foregroundStyle(.secondary)
                    .padding(.horizontal, 4)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// Hairline divider between rows inside a card.
struct SettingsDivider: View {
    var body: some View { Divider().background(Theme.separator) }
}

/// A simple label / value row.
struct SettingsValueRow: View {
    let label: String
    let value: String
    init(_ label: String, _ value: String) { self.label = label; self.value = value }
    var body: some View {
        HStack {
            Text(label.localized).font(.ui(14)).foregroundStyle(Theme.t2)
            Spacer(minLength: 12)
            Text(value).font(.ui(14, .semibold)).foregroundStyle(Theme.t1)
                .multilineTextAlignment(.trailing)
        }
        .padding(.vertical, 11)
    }
}

enum SettingsButtonKind { case primary, secondary, destructive }

/// A full-width, centered button matching the app's CTAs.
struct SettingsButton: View {
    let title: String
    var systemImage: String? = nil
    var kind: SettingsButtonKind = .secondary
    var loading: Bool = false
    let action: () -> Void

    init(_ title: String, systemImage: String? = nil, kind: SettingsButtonKind = .secondary,
         loading: Bool = false, action: @escaping () -> Void) {
        self.title = title
        self.systemImage = systemImage
        self.kind = kind
        self.loading = loading
        self.action = action
    }

    var body: some View {
        Button {
            Haptics.tap(); action()
        } label: {
            HStack(spacing: 8) {
                if loading {
                    ProgressView().controlSize(.small).tint(foreground)
                } else if let systemImage {
                    Image(systemName: systemImage).font(.subheadline.weight(.semibold))
                }
                Text(title.localized).fontWeight(.semibold)
            }
            .font(.subheadline)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 13)
            .foregroundStyle(foreground)
            .background(background)
        }
        .buttonStyle(.pressable)
        .padding(.vertical, 8)
    }

    private var foreground: Color {
        switch kind {
        case .primary: return .white
        case .secondary: return Theme.brand
        case .destructive: return .red
        }
    }

    @ViewBuilder private var background: some View {
        let shape = RoundedRectangle(cornerRadius: Theme.cornerSmall, style: .continuous)
        switch kind {
        case .primary:
            shape.fill(Theme.actionGradient)
        case .secondary:
            shape.fill(Theme.brand.opacity(0.12))
                .overlay(shape.strokeBorder(Theme.brand.opacity(0.25), lineWidth: 1))
        case .destructive:
            shape.fill(Color.red.opacity(0.12))
        }
    }
}

/// A status/result banner (green = ok, orange/red = problem).
struct SettingsBanner: View {
    let message: String
    var ok: Bool
    var errorTint: Color = Theme.warn
    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: ok ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(ok ? Theme.ok : errorTint)
            Text(message.localized).font(.footnote).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background((ok ? Theme.ok : errorTint).opacity(0.12),
                    in: RoundedRectangle(cornerRadius: Theme.cornerSmall, style: .continuous))
        .padding(.vertical, 8)
    }
}

extension View {
    /// Standard vertical inset for a row sitting inside a `SettingsSection`.
    func settingsRow() -> some View { self.padding(.vertical, 11) }
}
