import SwiftUI

/// Website Commander's "Living Tab" signature: a browser-tab silhouette with
/// one precise command spark. It remains legible at toolbar and app-icon sizes.
struct LivingTabMark: View {
    enum Style { case monochrome, gradient }

    var size: CGFloat = 24
    var style: Style = .gradient
    var animated = false
    /// The toolbar uses this separate, very small signal. The mark itself
    /// never rotates or scales continuously.
    var ambientSignal = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @EnvironmentObject private var motion: AmbientMotionCoordinator
    @State private var revealed = false

    var body: some View {
        ZStack {
            LivingTabShape()
                .strokeBorder(markStyle, lineWidth: max(1.4, size * 0.075))

            CommandSpark()
                .fill(markStyle)
                .frame(width: size * 0.34, height: size * 0.34)
                .offset(x: size * 0.20, y: -size * 0.16)
                .scaleEffect(revealed || !animated || reduceMotion ? 1 : 0.35)
                .opacity(revealed || !animated || reduceMotion ? 1 : 0)

            if ambientSignal, !reduceMotion, motion.isRunning,
               let travel = motion.traversal(period: 6.0, activeDuration: 0.9) {
                Circle()
                    .fill(Theme.accentDeep)
                    .frame(width: 2.5, height: 2.5)
                    .opacity(travel.opacity)
                    .offset(x: size * (0.22 + 0.48 * travel.progress) - size / 2,
                            y: size * 0.20 - size / 2)
            }
        }
        .frame(width: size, height: size)
        .onAppear {
            guard animated, !reduceMotion else { revealed = true; return }
            withAnimation(.easeOut(duration: 0.34).delay(0.08)) { revealed = true }
        }
        .accessibilityHidden(true)
    }

    private var markStyle: AnyShapeStyle {
        switch style {
        case .monochrome: AnyShapeStyle(Color.primary)
        case .gradient: AnyShapeStyle(Theme.brandGradient)
        }
    }
}

private struct LivingTabShape: InsettableShape {
    var insetAmount: CGFloat = 0

    func path(in rect: CGRect) -> Path {
        let r = rect.insetBy(dx: insetAmount, dy: insetAmount)
        let corner = min(r.width, r.height) * 0.18
        var path = Path()
        path.move(to: CGPoint(x: r.minX + corner, y: r.maxY))
        path.addQuadCurve(to: CGPoint(x: r.minX, y: r.maxY - corner),
                          control: CGPoint(x: r.minX, y: r.maxY))
        path.addLine(to: CGPoint(x: r.minX, y: r.minY + corner))
        path.addQuadCurve(to: CGPoint(x: r.minX + corner, y: r.minY),
                          control: CGPoint(x: r.minX, y: r.minY))
        path.addLine(to: CGPoint(x: r.midX - r.width * 0.05, y: r.minY))
        path.addLine(to: CGPoint(x: r.midX + r.width * 0.10, y: r.minY + r.height * 0.18))
        path.addLine(to: CGPoint(x: r.maxX - corner, y: r.minY + r.height * 0.18))
        path.addQuadCurve(to: CGPoint(x: r.maxX, y: r.minY + r.height * 0.18 + corner),
                          control: CGPoint(x: r.maxX, y: r.minY + r.height * 0.18))
        path.addLine(to: CGPoint(x: r.maxX, y: r.maxY - corner))
        path.addQuadCurve(to: CGPoint(x: r.maxX - corner, y: r.maxY),
                          control: CGPoint(x: r.maxX, y: r.maxY))
        path.closeSubpath()
        return path
    }

    func inset(by amount: CGFloat) -> LivingTabShape {
        var copy = self
        copy.insetAmount += amount
        return copy
    }
}

private struct CommandSpark: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.midX, y: rect.minY))
        path.addCurve(to: CGPoint(x: rect.maxX, y: rect.midY),
                      control1: CGPoint(x: rect.midX, y: rect.midY * 0.45),
                      control2: CGPoint(x: rect.midX * 1.55, y: rect.midY))
        path.addCurve(to: CGPoint(x: rect.midX, y: rect.maxY),
                      control1: CGPoint(x: rect.midX * 1.55, y: rect.midY),
                      control2: CGPoint(x: rect.midX, y: rect.midY * 1.55))
        path.addCurve(to: CGPoint(x: rect.minX, y: rect.midY),
                      control1: CGPoint(x: rect.midX, y: rect.midY * 1.55),
                      control2: CGPoint(x: rect.midX * 0.45, y: rect.midY))
        path.addCurve(to: CGPoint(x: rect.midX, y: rect.minY),
                      control1: CGPoint(x: rect.midX * 0.45, y: rect.midY),
                      control2: CGPoint(x: rect.midX, y: rect.midY * 0.45))
        return path
    }
}
