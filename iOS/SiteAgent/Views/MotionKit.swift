import SwiftUI

// Shared motion primitives so delight moments and loading states use one
// consistent, reduce-motion-aware vocabulary across the app.

// MARK: - Reduce-motion-aware animation

private struct MotionAnimation<V: Equatable>: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let animation: Animation
    let value: V
    func body(content: Content) -> some View {
        content.animation(reduceMotion ? nil : animation, value: value)
    }
}

extension View {
    /// `.animation(_:value:)` that no-ops under Reduce Motion. Use for decorative,
    /// value-driven motion so motion-sensitive users get instant updates.
    func motion<V: Equatable>(_ animation: Animation = Theme.snappy, value: V) -> some View {
        modifier(MotionAnimation(animation: animation, value: value))
    }
}

// MARK: - Success beat

/// A green checkmark that springs/bounces in once — the shared "it worked"
/// moment for commit/deploy/purchase success. Appears instantly (no scale)
/// under Reduce Motion.
struct SuccessCheck: View {
    var size: CGFloat = 64
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var shown = false

    var body: some View {
        Image(systemName: "checkmark.circle.fill")
            .font(.system(size: size, weight: .semibold))
            .foregroundStyle(.green)
            .symbolEffect(.bounce, options: .nonRepeating, value: shown)
            .scaleEffect(reduceMotion ? 1 : (shown ? 1 : 0.6))
            .opacity(reduceMotion ? 1 : (shown ? 1 : 0))
            .shadow(color: .green.opacity(0.4), radius: 16)
            .onAppear {
                guard !reduceMotion else { return }
                withAnimation(Theme.spring) { shown = true }
            }
    }
}

// MARK: - Branded progress

/// A determinate bar filled with the brand gradient — for the app's longest
/// wait (multi-GB model download) instead of a thin stock bar.
struct BrandProgressBar: View {
    var value: Double            // 0...1
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.10))
                Capsule()
                    .fill(Theme.brandGradient)
                    .frame(width: max(0, min(1, value)) * geo.size.width)
            }
        }
        .frame(height: 6)
        .animation(reduceMotion ? nil : Theme.snappy, value: value)
    }
}

// MARK: - Shimmer skeleton

/// A subtle moving sheen for `.redacted(.placeholder)` loading rows. Static
/// (no sweep) under Reduce Motion.
private struct ShimmerModifier: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var move = false

    func body(content: Content) -> some View {
        if reduceMotion {
            content
        } else {
            content.overlay {
                GeometryReader { geo in
                    let w = geo.size.width
                    LinearGradient(colors: [.clear, .white.opacity(0.45), .clear],
                                   startPoint: .leading, endPoint: .trailing)
                        .frame(width: w * 0.7)
                        .offset(x: move ? w : -w)
                        .blendMode(.plusLighter)
                }
                .clipped()
                .allowsHitTesting(false)
            }
            .onAppear {
                withAnimation(.linear(duration: 1.25).repeatForever(autoreverses: false)) {
                    move = true
                }
            }
        }
    }
}

extension View {
    /// Animated sheen for placeholder/loading content (use with `.redacted`).
    func shimmering() -> some View { modifier(ShimmerModifier()) }
}

/// Placeholder list rows (icon + two text lines) with a shimmer sweep — a
/// loading state that previews the real row shape instead of a bare spinner.
struct SkeletonRows: View {
    var count: Int = 4
    private let fill = Color.secondary.opacity(0.18)

    var body: some View {
        VStack(spacing: 0) {
            ForEach(0..<count, id: \.self) { i in
                HStack(spacing: 12) {
                    Circle().fill(fill).frame(width: 22, height: 22)
                    VStack(alignment: .leading, spacing: 5) {
                        RoundedRectangle(cornerRadius: 4).fill(fill).frame(height: 11)
                        RoundedRectangle(cornerRadius: 4).fill(fill).frame(width: 120, height: 9)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.vertical, 12)
                if i < count - 1 { Divider() }
            }
        }
        .shimmering()
        .accessibilityLabel("Loading")
    }
}

// MARK: - Scroll-driven appearance

/// Gently fades + scales content as it scrolls into view. No-op under Reduce
/// Motion. Scroll-only (on-screen items render at full identity), so it never
/// flashes on first paint.
private struct ScrollAppear: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func body(content: Content) -> some View {
        if reduceMotion {
            content
        } else {
            content.scrollTransition { view, phase in
                view
                    .opacity(phase.isIdentity ? 1 : 0.35)
                    .scaleEffect(phase.isIdentity ? 1 : 0.97)
            }
        }
    }
}

extension View {
    func appearOnScroll() -> some View { modifier(ScrollAppear()) }
}
