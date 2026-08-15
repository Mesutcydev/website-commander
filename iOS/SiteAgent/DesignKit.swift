import SwiftUI

// The "command deck" design layer: reusable, dark-first (but light-tolerant)
// surfaces, pills, metric/action cards, a deployment timeline row, and the
// glowing grid backdrop. Everything reads `Theme` tokens so the accent picker
// and light/dark still drive it. Decorative motion is reduce-motion-aware.
//
// Naming note: `MetricCard` already exists (inspector), so the dashboard tile is
// `DashboardMetricCard`; `SectionHeader` already exists, so the titled bar with a
// trailing action is `SectionHeaderBar`.

// MARK: - Backdrop: OLED black + radial brand glow + faint static grid

/// Barely-visible technical grid, drawn once with Canvas. Static content →
/// SwiftUI caches it, so it costs nothing while scrolling.
struct GridTexture: View {
    var spacing: CGFloat = 30
    var color: Color = .white.opacity(0.05)

    var body: some View {
        Canvas { ctx, size in
            var path = Path()
            var x: CGFloat = 0
            while x <= size.width {
                path.move(to: CGPoint(x: x, y: 0))
                path.addLine(to: CGPoint(x: x, y: size.height))
                x += spacing
            }
            var y: CGFloat = 0
            while y <= size.height {
                path.move(to: CGPoint(x: 0, y: y))
                path.addLine(to: CGPoint(x: size.width, y: y))
                y += spacing
            }
            ctx.stroke(path, with: .color(color), lineWidth: 0.5)
        }
        .allowsHitTesting(false)
    }
}

/// The premium backdrop for the four main screens: true-black (OLED) in dark, a
/// soft brand glow near the top, and a faint grid. `glow` lets a screen dial the
/// halo position/strength implicitly by toggling it.
struct CommandDeckBackground: View {
    var glow: Bool = true
    // Captured at init so a skin toggle re-runs the body (see CardSurfaceModifier).
    private let glass = Theme.isGlass

    var body: some View {
        ZStack(alignment: .top) {
            if glass {
                GlassBackground()
            } else {
                CC.bg
                if glow {
                    RadialGradient(
                        colors: [CC.accent.opacity(0.11), CC.accent.opacity(0.035), .clear],
                        center: UnitPoint(x: 0.54, y: 0.20),
                        startRadius: 18,
                        endRadius: 260
                    )
                    .frame(height: 420)
                    .blur(radius: 12)
                    .opacity(0.55)
                }
            }
            // Grid texture is a classic-skin artifact; real glass sits over a
            // clean canvas so nothing reads as a painted pattern through panes.
            if !glass {
                GridTexture(spacing: 12, color: CC.accent.opacity(0.018))
                    .opacity(0.55)
            }
        }
        .ignoresSafeArea()
    }
}

extension View {
    /// Opt-in command-deck backdrop. Used only by the four redesigned screens so
    /// Settings / Onboarding / sheets keep the standard `appBackground()`.
    func commandBackground(glow: Bool = true) -> some View {
        self.scrollContentBackground(.hidden)
            .background(CommandDeckBackground(glow: glow))
            .glassScrollEdge()
    }
}

// MARK: - Glass card surface (dark glass + hairline + optional brand glow)

private struct CommandCardModifier: ViewModifier {
    var cornerRadius: CGFloat = 16
    var glow: Bool = false
    // Captured at init so a skin toggle re-runs the body (see CardSurfaceModifier).
    private let glass = Theme.isGlass

    @ViewBuilder
    func body(content: Content) -> some View {
        // Glass keeps the classic radius so card geometry is identical across
        // skins — only the surface material changes.
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        if glass {
            // Colorless Liquid Glass — no brand tint. `glow` only picks the
            // larger hero role for elevation, never a green fill.
            content.glassSurface(
                glow ? .hero : .card,
                cornerRadius: cornerRadius,
                accentReflection: nil
            )
        } else {
            // Flat CC card — same fill/stroke as the Home cards so every screen's
            // surfaces match. `glow` = the single emerald-stroked accent card.
            content
                .background(shape.fill(glow ? CC.cardHi : CC.card))
                .overlay(shape.strokeBorder(glow ? CC.strokeGreen : CC.stroke, lineWidth: 1))
                .clipShape(shape)
        }
    }
}

extension View {
    /// Dark glass card: layered fill + hairline; `glow` adds the emerald halo +
    /// brand-tinted border used on hero / primary cards.
    func commandCard(cornerRadius: CGFloat = Theme.corner, glow: Bool = false) -> some View {
        modifier(CommandCardModifier(cornerRadius: cornerRadius, glow: glow))
    }
}

// MARK: - Pills

/// Status chip: a colored dot + label. For Live / Active / Clean / Up to date /
/// Production / Verified. `tint` carries the semantic color (ok / warn / gray).
struct StatusPill: View {
    enum Kind { case soft, outline }
    let text: String
    var tint: Color = Theme.ok
    var dot: Bool = true
    var kind: Kind = .soft

    var body: some View {
        HStack(spacing: 5) {
            if dot {
                if Theme.isGlass { GlassLED(color: tint, size: 5) }
                else { Circle().fill(tint).frame(width: 6, height: 6) }
            }
            Text(text).font(.mono(12, .medium)).lineLimit(1)
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .modifier(StatusPillSurface(tint: tint, kind: kind))
        .fixedSize()   // never let a parent HStack compress/wrap the pill
        .accessibilityElement(children: .combine)
    }
}

/// Metadata chip: optional SF Symbol + monospace label. For branch / framework /
/// deploy-target tags (e.g. "main", "Vanilla HTML/JS", "Cloudflare Workers").
struct MetadataPill: View {
    let text: String
    var systemImage: String? = nil
    var tint: Color = Theme.t2
    // Captured at init so a skin toggle re-runs the body (see CardSurfaceModifier).
    private let glass = Theme.isGlass

    var body: some View {
        HStack(spacing: 5) {
            if let systemImage {
                Image(systemName: systemImage).font(.system(size: 11, weight: .semibold))
            }
            Text(text).font(.mono(12, .medium))
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .modifier(MetadataPillSurface(glass: glass))
        .accessibilityElement(children: .combine)
    }
}

private struct StatusPillSurface: ViewModifier {
    let tint: Color
    let kind: StatusPill.Kind

    @ViewBuilder
    func body(content: Content) -> some View {
        if Theme.isGlass {
            content.glassSurface(.badge, cornerRadius: 999, accentReflection: tint)
        } else {
            content.background {
                if kind == .soft {
                    Capsule().fill(tint.opacity(0.14))
                } else {
                    Capsule().strokeBorder(tint.opacity(0.5), lineWidth: 1)
                }
            }
        }
    }
}

private struct MetadataPillSurface: ViewModifier {
    let glass: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        if glass {
            content.glassSurface(.capsule, cornerRadius: 999)
        } else {
            content
                .background(Capsule().fill(Theme.chip))
                .overlay(Capsule().strokeBorder(Theme.glassBorder, lineWidth: 0.5))
        }
    }
}

// MARK: - Avatar & decorative waveform

/// Brand-gradient circle with a centered SF Symbol — the site/workspace avatar.
struct GlobeAvatar: View {
    var systemImage: String = "globe"
    var size: CGFloat = 52
    private let glass = Theme.isGlass

    var body: some View {
        Group {
            if glass {
                Image(systemName: systemImage)
                    .font(.system(size: size * 0.46, weight: .semibold))
                    .foregroundStyle(Theme.brand)
                    .frame(width: size, height: size)
                    .glassSurface(.icon, cornerRadius: size / 2, accentReflection: nil)
            } else {
                ZStack {
                    Circle().fill(Theme.brandGradient)
                    Image(systemName: systemImage)
                        .font(.system(size: size * 0.46, weight: .semibold))
                        .foregroundStyle(.white)
                }
                .frame(width: size, height: size)
                .shadow(color: Theme.brand.opacity(0.4), radius: 10, y: 4)
            }
        }
        .accessibilityHidden(true)
    }
}

/// Decorative ECG / heart-monitor line (static, no data) — the "alive" accent on
/// hero cards. Fades in from the left so it reads as trailing detail.
struct ECGWaveform: View {
    var color: Color = Theme.ok
    var beats: Int = 3

    // One beat as (xFraction, yFraction) where y=0.5 is the baseline.
    private let beat: [(CGFloat, CGFloat)] = [
        (0.00, 0.50), (0.20, 0.50), (0.30, 0.42), (0.38, 0.50),
        (0.46, 0.50), (0.50, 0.10), (0.54, 0.92), (0.58, 0.50),
        (0.70, 0.50), (0.80, 0.46), (0.88, 0.50), (1.00, 0.50),
    ]

    var animated: Bool = true
    var period: Double = 1.6   // seconds for one beat-width sweep

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height
            let beatW = w / CGFloat(max(1, beats))
            // Draw one extra beat so the looping offset is seamless (the strip is
            // periodic, so jumping back from -beatW to 0 is invisible).
            let strip = Path { p in
                var started = false
                for b in 0...max(1, beats) {
                    for pt in beat {
                        let point = CGPoint(x: (CGFloat(b) + pt.0) * beatW, y: pt.1 * h)
                        if started { p.addLine(to: point) } else { p.move(to: point); started = true }
                    }
                }
            }
            // TimelineView drives the sweep frame-by-frame off the display clock,
            // so it animates identically on the simulator AND a real device — the
            // old `.repeatForever` started from `onAppear` silently failed to kick
            // off on device.
            Group {
                // The live "heartbeat" keeps sweeping even under Reduce Motion —
                // it's a status (connection-alive) signal, not decorative motion.
                if animated {
                    TimelineView(.animation) { tl in
                        let t = tl.date.timeIntervalSinceReferenceDate
                        let phase = (t.truncatingRemainder(dividingBy: period)) / period
                        line(strip, w: w, h: h, beatW: beatW, offset: -beatW * CGFloat(phase))
                    }
                } else {
                    line(strip, w: w, h: h, beatW: beatW, offset: 0)
                }
            }
            // Fade in from the left so the scrolling line reads as a live feed.
            .mask(LinearGradient(colors: [.clear, .black, .black],
                                 startPoint: .leading, endPoint: .trailing))
        }
        .accessibilityHidden(true)
    }

    private func line(_ strip: Path, w: CGFloat, h: CGFloat, beatW: CGFloat, offset: CGFloat) -> some View {
        strip.stroke(color, style: StrokeStyle(lineWidth: 1.8, lineCap: .round, lineJoin: .round))
            .frame(width: w + beatW, height: h, alignment: .leading)
            .offset(x: offset)
            .frame(width: w, height: h, alignment: .leading)
            .clipped()
    }
}

// MARK: - Section header with trailing action

/// `SectionHeader` (uppercase mono eyebrow) + an optional trailing "View all"
/// affordance, matching the mockup section rows.
struct SectionHeaderBar: View {
    let title: String
    var actionTitle: String? = nil
    var action: (() -> Void)? = nil

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            SectionHeader(title)
            Spacer(minLength: 8)
            if let actionTitle, let action {
                Button(action: action) {
                    HStack(spacing: 3) {
                Text(actionTitle).font(.mono(12, .medium))
                Image(systemName: "chevron.right").font(.system(size: 9, weight: .bold))
                    }
                    .foregroundStyle(Theme.brand)
                }
                .buttonStyle(.plain)
            }
        }
    }
}

// MARK: - Dashboard metric tile (2x2 grid)

/// One cell of the Command Center / Sites metric grid: icon tile, big value,
/// title, and an optional accent caption + trailing pill.
struct DashboardMetricCard: View {
    let icon: String
    let value: String
    let title: String
    var iconTint: Color = Theme.brand
    var caption: String? = nil
    var captionTint: Color = Theme.ok
    var trailingPill: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Top row: icon tile (left) + small pill (right) — matches the mockup.
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(iconTint)
                    .frame(width: 36, height: 36)
                    .background(Circle().fill(iconTint.opacity(0.14)))
                    .overlay(Circle().strokeBorder(iconTint.opacity(0.25), lineWidth: 0.5))
                Spacer(minLength: 0)
                if let trailingPill {
                    Text(trailingPill)
                        .font(.mono(10.5, .medium))
                        .foregroundStyle(Theme.t3)
                        .lineLimit(1)
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(Capsule().fill(Theme.chip))
                        .fixedSize()
                }
            }
            Spacer(minLength: 0)   // expands within the fixed height → value sits lower like the target
            // Value (prominent), label, accent caption.
            VStack(alignment: .leading, spacing: 2) {
                Text(value)
                    .font(.display(27, .bold, relativeTo: .title))
                    .foregroundStyle(Theme.t1)
                    .contentTransition(.numericText())
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
                    .allowsTightening(true)
                Text(title)
                    .font(.ui(14))
                    .foregroundStyle(Theme.t2)
                    .lineLimit(1).minimumScaleFactor(0.7)
                if let caption {
                    Text(caption).font(.mono(11, .medium)).foregroundStyle(captionTint)
                        .lineLimit(1).minimumScaleFactor(0.7)
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, minHeight: 144, maxHeight: 144, alignment: .topLeading)
        .commandCard(cornerRadius: 22)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title): \(value)")
    }
}

// MARK: - Quick-action card (icon + title + subtitle, optional primary glow)

/// A quick-action row/cell. `primary` gets the emerald glow + filled icon (the
/// distinguished "New Chat" action). Pass the existing screen closure as `action`
/// (haptics stay with the caller so behavior is unchanged).
struct ActionCard: View {
    let title: String
    let subtitle: String
    let icon: String
    var primary: Bool = false
    var enabled: Bool = true
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 13) {
                Image(systemName: icon)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(primary ? Color.white : Theme.brand)
                    .frame(width: 42, height: 42)
                    .background(Circle().fill(primary ? AnyShapeStyle(Theme.brandGradient)
                                                       : AnyShapeStyle(Theme.brand.opacity(0.14))))
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.ui(17, .semibold)).foregroundStyle(Theme.t1)
                        .lineLimit(1).minimumScaleFactor(0.7)
                    Text(subtitle).font(.ui(13)).foregroundStyle(Theme.t2)
                        .lineLimit(1).minimumScaleFactor(0.7)
                }
                Spacer(minLength: 4)
                Image(systemName: "chevron.right").font(.caption.weight(.bold)).foregroundStyle(Theme.t3)
            }
            .padding(16)
            .frame(maxWidth: .infinity, minHeight: 82, alignment: .leading)
            .commandCard(cornerRadius: 22, glow: primary)
            .opacity(enabled ? 1 : 0.5)
        }
        .buttonStyle(.pressable)
        .disabled(!enabled)
        .cardHover()
        .accessibilityLabel(title)
        .accessibilityHint(subtitle)
    }
}

// MARK: - Compact tool tile (Sites "Active Repository" grid)

/// Small navigational tile: icon + title + subtitle + chevron. Wrap in your own
/// Button/NavigationLink — this is the label content only.
struct ToolTile: View {
    let title: String
    let subtitle: String
    let icon: String
    var tint: Color = Theme.brand

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 36, height: 36)
                .background(Circle().fill(tint.opacity(0.14)))
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.ui(14, .semibold)).foregroundStyle(Theme.t1)
                    .lineLimit(1).minimumScaleFactor(0.7)
                Text(subtitle).font(.ui(11)).foregroundStyle(Theme.t2)
                    .lineLimit(1).minimumScaleFactor(0.7)
            }
            Spacer(minLength: 2)
            Image(systemName: "chevron.right").font(.caption2.weight(.bold)).foregroundStyle(Theme.t3)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .commandCard()
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Labeled stat (Agent Ready card columns / hero metadata)

/// icon + small mono label + value, with an optional ✓ seal. Used for the Chat
/// "Agent Ready" card's Model / Provider / Workspace columns.
struct LabeledStat: View {
    var icon: String
    var label: String
    var value: String
    var valueTint: Color = Theme.t1
    var verified: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Image(systemName: icon).font(.system(size: 10, weight: .semibold)).foregroundStyle(Theme.t3)
                Text(label.uppercased()).font(.mono(10, .medium)).kerning(0.6).foregroundStyle(Theme.t3)
            }
            HStack(spacing: 4) {
                Text(value).font(.mono(14, .medium)).foregroundStyle(valueTint)
                    .lineLimit(1).minimumScaleFactor(0.6)
                if verified { Image(systemName: "checkmark.seal.fill").font(.system(size: 11)).foregroundStyle(Theme.ok) }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(label): \(value)")
    }
}

// MARK: - Timeline row (deployments)

/// A timeline entry: left icon + connecting line, free-form content, trailing
/// badge. Set `isLast` on the final row to stop the connector.
struct TimelineRow<Content: View, Trailing: View>: View {
    var icon: String
    var iconTint: Color = Theme.ok
    var isLast: Bool = false
    @ViewBuilder var content: () -> Content
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(spacing: 0) {
                ZStack {
                    Circle().fill(iconTint.opacity(0.16)).frame(width: 32, height: 32)
                    Image(systemName: icon).font(.system(size: 13, weight: .bold)).foregroundStyle(iconTint)
                }
                if !isLast {
                    Rectangle().fill(Theme.brand.opacity(0.30)).frame(width: 2).frame(maxHeight: .infinity)
                }
            }
            .frame(width: 32)
            VStack(alignment: .leading, spacing: 5) { content() }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.bottom, isLast ? 0 : 16)
            trailing()
        }
        .fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: - Checklist row (Live Preview staged loader)

enum StepState: Equatable { case done, active, pending, failed }

/// One step of the "Preparing Preview" checklist: state glyph + title + detail,
/// with an optional trailing pill ("Up to date", duration, …).
struct ChecklistRow: View {
    var title: String
    var detail: String?
    var state: StepState
    var trailing: String? = nil

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            glyph.frame(width: 26, height: 26)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.ui(15, .semibold))
                    .foregroundStyle(state == .active ? Theme.brand : (state == .pending ? Theme.t2 : Theme.t1))
                if let detail {
                    Text(detail).font(.ui(12)).foregroundStyle(Theme.t2).lineLimit(1)
                }
            }
            Spacer(minLength: 4)
            if let trailing {
                Text(trailing).font(.mono(10, .medium)).foregroundStyle(Theme.t3)
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(Capsule().fill(Theme.chip))
            }
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder private var glyph: some View {
        switch state {
        case .done:
            Image(systemName: "checkmark.circle.fill").font(.system(size: 22)).foregroundStyle(Theme.ok)
        case .active:
            ProgressView().controlSize(.small).tint(Theme.brand)
        case .pending:
            Image(systemName: "circle").font(.system(size: 20)).foregroundStyle(Theme.t3)
        case .failed:
            Image(systemName: "xmark.circle.fill").font(.system(size: 22)).foregroundStyle(Theme.danger)
        }
    }
}
