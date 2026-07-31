import SwiftUI

// MARK: - Icon tile

/// A compact SF Symbol tile. Neutral tint is the default; callers opt into the
/// brand gradient only for a genuinely primary action.
struct IconTile: View {
    let systemImage: String
    var tint: Color = Theme.slateAccent
    var size: CGFloat = 40
    var gradient: Bool = false

    var body: some View {
        Image(systemName: systemImage)
            .font(.system(size: size * 0.46, weight: .semibold))
            .foregroundStyle(gradient ? .white : tint)
            .frame(width: size, height: size)
            .background(
                gradient ? AnyShapeStyle(Theme.brandGradient) : AnyShapeStyle(tint.opacity(0.16)),
                in: RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
            )
    }
}

// MARK: - Stat tile

/// A visual metric card: big rounded number, label, and an icon tile.
struct StatTile: View {
    let title: String
    let value: String
    let systemImage: String
    var tint: Color = Theme.slateAccent
    /// When set, the icon slot shows this official brand mark instead of the SF Symbol.
    var brandID: BrandMarkID? = nil
    /// When true, the value is rendered as a medium label (for words like a
    /// provider name) instead of a large heavy number.
    var compact: Bool = false
    var caption: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            HStack {
                if let brandID {
                    BrandMark(id: brandID)
                        .fill(tint)
                        .padding(7)
                        .frame(width: 34, height: 34)
                        .background(tint.opacity(0.14),
                                    in: RoundedRectangle(cornerRadius: 34 * 0.28, style: .continuous))
                } else {
                    IconTile(systemImage: systemImage, tint: tint, size: 34, gradient: false)
                }
                Spacer()
            }
            VStack(alignment: .leading, spacing: 2) {
                if compact {
                    Text(value)
                        .font(.title3.weight(.semibold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                } else {
                    Text(value)
                        .font(Theme.display(28, weight: .heavy))
                        .contentTransition(.numericText())
                }
                Text(LocalizedStringKey(title))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                if let caption {
                    Text(caption)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .commandCard()
        .wcAppear()
    }
}

// MARK: - Badge

/// A small pill badge (tech stack, deployment target, status).
struct Badge: View {
    let text: String
    var systemImage: String? = nil
    var tint: Color = .secondary

    var body: some View {
        HStack(spacing: 4) {
            if let systemImage {
                Image(systemName: systemImage).font(.caption2)
            }
            Text(text).font(.caption.weight(.medium))
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .foregroundStyle(tint)
        .background(tint.opacity(0.14), in: Capsule())
    }
}

// MARK: - Status dot

/// A tiny colored presence dot (green = ready, amber = needs attention, etc.).
struct StatusDot: View {
    var color: Color = Theme.success
    var pulse: Bool = false
    var size: CGFloat = 9

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: size, height: size)
            .overlay(
                Circle().stroke(color.opacity(0.35), lineWidth: pulse ? 3 : 0)
            )
            .shadow(color: color.opacity(0.6), radius: pulse ? 4 : 1)
    }
}

// MARK: - Section header

/// A compact section title with an optional trailing accessory.
struct SectionHeader<Accessory: View>: View {
    let title: String
    var systemImage: String? = nil
    @ViewBuilder var accessory: Accessory

    var body: some View {
        HStack(spacing: Theme.Space.s) {
            if let systemImage {
                Image(systemName: systemImage)
                    .foregroundStyle(Theme.slateAccent)
            }
            Text(LocalizedStringKey(title))
                .font(.headline)
            Spacer()
            accessory
        }
    }
}

extension SectionHeader where Accessory == EmptyView {
    init(title: String, systemImage: String? = nil) {
        self.title = title
        self.systemImage = systemImage
        self.accessory = EmptyView()
    }
}

// MARK: - Button styles

/// The hero action style: brand gradient fill, white label, soft shadow.
struct PrimaryButtonStyle: ButtonStyle {
    var prominent: Bool = true

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.body.weight(.semibold))
            .foregroundStyle(prominent ? .white : Theme.accent)
            .padding(.horizontal, Theme.Space.l)
            .padding(.vertical, Theme.Space.s + 2)
            .background(
                prominent ? AnyShapeStyle(Theme.brandGradient) : AnyShapeStyle(Theme.accent.opacity(0.14)),
                in: RoundedRectangle(cornerRadius: Theme.Radius.medium, style: .continuous)
            )
            .shadow(color: prominent ? Color.black.opacity(0.14) : .clear,
                    radius: configuration.isPressed ? 1 : 5, y: 2)
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.7), value: configuration.isPressed)
    }
}

/// A borderless icon button used in toolbars and card corners.
struct IconButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 15, weight: .medium))
            .foregroundStyle(.secondary)
            .frame(width: 30, height: 30)
            .background(
                Circle().fill(Color.primary.opacity(configuration.isPressed ? 0.10 : 0.05))
            )
            .contentShape(Circle())
            .scaleEffect(configuration.isPressed ? 0.9 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

extension ButtonStyle where Self == PrimaryButtonStyle {
    static var primary: PrimaryButtonStyle { PrimaryButtonStyle() }
    static var primarySoft: PrimaryButtonStyle { PrimaryButtonStyle(prominent: false) }
}

extension ButtonStyle where Self == IconButtonStyle {
    static var icon: IconButtonStyle { IconButtonStyle() }
}

// MARK: - Empty state

/// A friendly visual placeholder for lists/areas with no content yet. The hero is
/// the app's brand illustration; the state-specific `systemImage` is shown as a
/// small gradient chip so each empty state stays meaningful *and* on-brand.
struct EmptyStateView: View {
    let systemImage: String
    let title: String
    var message: String? = nil
    var actionTitle: String? = nil
    var action: (() -> Void)? = nil
    var useBrandArt: Bool = true

    var body: some View {
        VStack(spacing: Theme.Space.m) {
            ZStack(alignment: .bottomTrailing) {
                if useBrandArt {
                    BrandIllustration(size: 132)
                } else {
                    Image(systemName: systemImage)
                        .font(.system(size: 44, weight: .light))
                        .foregroundStyle(Theme.brandGradient)
                        .frame(width: 132, height: 108)
                }
                Image(systemName: systemImage)
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 34, height: 34)
                    .background(Theme.brandGradient, in: Circle())
                    .overlay(Circle().strokeBorder(.white.opacity(0.6), lineWidth: 2))
                    .shadow(color: .black.opacity(0.2), radius: 3, y: 1)
                    .offset(x: 6, y: 6)
            }
            .padding(.bottom, Theme.Space.s)
            Text(title)
                .font(.title3.weight(.semibold))
            if let message {
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 360)
            }
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .buttonStyle(.primary)
                    .padding(.top, Theme.Space.s)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(Theme.Space.xxl)
    }
}

/// Shared recoverable failure state. Copy always explains that user work remains
/// safe and provides one clear recovery action supplied by the caller.
struct ErrorStateView: View {
    let title: String
    let message: String
    var retryTitle = "Try Again"
    let retry: () -> Void

    var body: some View {
        VStack(spacing: Theme.Space.m) {
            LivingTabMark(size: 58, style: .monochrome)
                .foregroundStyle(Theme.danger)
            Text(title)
                .font(.title3.weight(.semibold))
                .foregroundStyle(Theme.textPrimary)
            Text(message)
                .font(.callout)
                .foregroundStyle(Theme.secondaryText)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
            Button(retryTitle, action: retry)
                .buttonStyle(.primarySoft)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(Theme.Space.xxl)
    }
}

// MARK: - Help button

/// A small "?" affordance that opens a popover with a plain-language explanation
/// and direct links to the relevant external configuration page (e.g. where to
/// create a GitHub token or a deploy hook).
struct HelpButton: View {
    let title: String
    let message: String
    var links: [(label: String, url: String)] = []

    @State private var showing = false

    var body: some View {
        Button { showing = true } label: {
            Image(systemName: "questionmark.circle")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .help(title)
        .popover(isPresented: $showing, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: Theme.Space.m) {
                Text(title).font(.headline)
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if !links.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(links, id: \.url) { link in
                            Link(destination: URL(string: link.url)!) {
                                HStack(spacing: 4) {
                                    Text(link.label)
                                    Image(systemName: "arrow.up.right")
                                        .font(.caption2)
                                }
                                .font(.callout.weight(.medium))
                            }
                        }
                    }
                    .padding(.top, 2)
                }
            }
            .padding(Theme.Space.l)
            .frame(width: 330)
        }
    }
}

// MARK: - Field header

/// A field label row with an optional inline help popover.
struct FieldHeader: View {
    let label: String
    var help: HelpButton? = nil

    var body: some View {
        HStack(spacing: 5) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            if let help { help }
        }
    }
}

// MARK: - Risk badge

/// Security-risk indicator for a staged change (High / Medium / Low / Clean).
struct RiskBadge: View {
    let level: RiskLevel

    enum RiskLevel: String {
        case high = "High risk"
        case medium = "Medium risk"
        case low = "Low risk"
        case clean = "No risks"

        var color: Color {
            switch self {
            case .high: return Theme.danger
            case .medium: return Theme.warning
            case .low: return Theme.info
            case .clean: return Theme.success
            }
        }

        var icon: String {
            switch self {
            case .high: return "exclamationmark.octagon.fill"
            case .medium: return "exclamationmark.triangle.fill"
            case .low: return "info.circle.fill"
            case .clean: return "checkmark.shield.fill"
            }
        }
    }

    var body: some View {
        Badge(text: level.rawValue, systemImage: level.icon, tint: level.color)
    }
}
