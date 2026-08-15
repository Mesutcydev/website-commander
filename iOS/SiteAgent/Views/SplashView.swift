import SwiftUI

// Animated launch splash: the app-icon mark draws itself on a deep neutral field,
// the wordmark + tagline rise in, then a circular wipe hands off to onboarding
// (first launch) or Home. Recreated natively from the design source
// (design_handoff_splash_onboarding/scene.jsx) — one clock, pure functions of
// elapsed time, so it's trivially reduce-motion-aware (settle instantly + fade).

/// The splash follows the selected accent. Its backing field stays neutral so a
/// previous hard-coded sage palette can never leak through another selection.
private enum Splash {
    static let deepA = Color(hex: "0B1016")
    static let deepB = Color(hex: "1B2630")
    static let starFill = Color(hex: "F6FBF8")   // off-white on dark
    static var brand: Color { Theme.brand }
    static var brandHi: Color { Theme.brandEnd }
    static let mark: CGFloat = 150               // logo size (pt); 420px ÷ 2.75
    // The splash reveals as soon as the app is ready, bounded by a floor (so the
    // intro always reads) and a ceiling (so slow launch work can't trap the user).
    static let floor: Double = 2.7               // min branding time before wipe
    static let ceil: Double = 3.9                // hard cap on time-to-wipe
    static let wipeDur: Double = 0.85            // circular reveal duration
    static let floorReduced: Double = 0.8        // reduce-motion: brief hold…
    static let ceilReduced: Double = 1.2
    static let fadeDur: Double = 0.4             // …then a cross-fade, not a wipe
}

/// The new app icon's open cloud contour. It remains vector-native so the mark
/// draws crisply at every device scale instead of animating a raster asset.
private struct CloudOutlineShape: Shape {
    func path(in rect: CGRect) -> Path {
        func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: rect.minX + rect.width * x, y: rect.minY + rect.height * y)
        }
        var p = Path()
        p.move(to: point(0.28, 0.73))
        p.addCurve(to: point(0.15, 0.62),
                   control1: point(0.20, 0.73), control2: point(0.15, 0.69))
        p.addCurve(to: point(0.28, 0.43),
                   control1: point(0.14, 0.52), control2: point(0.19, 0.44))
        p.addCurve(to: point(0.38, 0.42),
                   control1: point(0.31, 0.42), control2: point(0.34, 0.42))
        p.addCurve(to: point(0.59, 0.20),
                   control1: point(0.39, 0.28), control2: point(0.47, 0.19))
        p.addCurve(to: point(0.77, 0.35),
                   control1: point(0.69, 0.20), control2: point(0.75, 0.26))
        p.addCurve(to: point(0.88, 0.38),
                   control1: point(0.81, 0.34), control2: point(0.85, 0.35))
        p.addCurve(to: point(0.94, 0.52),
                   control1: point(0.93, 0.40), control2: point(0.96, 0.46))
        p.addCurve(to: point(0.84, 0.68),
                   control1: point(0.94, 0.61), control2: point(0.90, 0.67))
        p.addCurve(to: point(0.78, 0.69),
                   control1: point(0.82, 0.69), control2: point(0.80, 0.69))
        return p
    }
}

/// Latitude and longitude lines used inside the new globe mark.
private struct GlobeGridShape: Shape {
    func path(in rect: CGRect) -> Path {
        func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: rect.minX + rect.width * x, y: rect.minY + rect.height * y)
        }
        var p = Path()
        p.addEllipse(in: rect.insetBy(dx: rect.width * 0.04, dy: rect.height * 0.04))
        p.move(to: point(0.50, 0.04))
        p.addLine(to: point(0.50, 0.96))
        p.move(to: point(0.50, 0.04))
        p.addCurve(to: point(0.50, 0.96),
                   control1: point(0.18, 0.24), control2: point(0.18, 0.76))
        p.move(to: point(0.50, 0.04))
        p.addCurve(to: point(0.50, 0.96),
                   control1: point(0.82, 0.24), control2: point(0.82, 0.76))
        p.move(to: point(0.09, 0.31))
        p.addCurve(to: point(0.91, 0.31),
                   control1: point(0.31, 0.44), control2: point(0.69, 0.44))
        p.move(to: point(0.05, 0.53))
        p.addLine(to: point(0.95, 0.53))
        p.move(to: point(0.10, 0.76))
        p.addCurve(to: point(0.90, 0.76),
                   control1: point(0.31, 0.63), control2: point(0.69, 0.63))
        return p
    }
}

/// The supplied splash timing reinterpreted for the new app icon: the cloud
/// traces on first, then the globe and its grid resolve from the cloud base.
private struct CloudGlobeMark: View {
    let t: Double
    let reduce: Bool
    private var size: CGFloat { Splash.mark }

    var body: some View {
        let M = Theme.motion
        let cloudE = reduce ? 1 : Ease.inOutCubic(Ease.ramp(t, 0.12, 0.12 + 1.05 * M.entry))
        let globeE = reduce ? 1 : Ease.inOutCubic(Ease.ramp(t, 0.62, 0.62 + 0.85 * M.entry))
        let gridE = reduce ? 1 : Ease.inOutCubic(Ease.ramp(t, 0.92, 0.92 + 0.82 * M.entry))
        let resolve = reduce ? 1 : Ease.outCubic(Ease.ramp(t, 0.62, 0.62 + 0.55 * M.entry))
        let breathe = reduce ? 1 : 1 + 0.006 * sin(t * 1.5)

        ZStack {
            CloudOutlineShape()
                .trim(from: 0, to: cloudE)
                .stroke(
                    Splash.starFill,
                    style: StrokeStyle(lineWidth: 8, lineCap: .round, lineJoin: .round)
                )
                .frame(width: size, height: size * 0.86)
                .offset(y: -size * 0.08)

            GlobeGridShape()
                .trim(from: 0, to: globeE)
                .stroke(
                    Splash.brandHi,
                    style: StrokeStyle(lineWidth: 6.5, lineCap: .round, lineJoin: .round)
                )
                .frame(width: size * 0.54, height: size * 0.54)
                .scaleEffect(0.94 + 0.06 * resolve)
                .opacity(resolve)
                .offset(x: size * 0.12, y: size * 0.20)

            GlobeGridShape()
                .trim(from: 0.18, to: max(0.18, gridE))
                .stroke(
                    Splash.starFill.opacity(0.92),
                    style: StrokeStyle(lineWidth: 3.2, lineCap: .round, lineJoin: .round)
                )
                .frame(width: size * 0.54, height: size * 0.54)
                .opacity(gridE)
                .offset(x: size * 0.12, y: size * 0.20)
        }
        .frame(width: size, height: size)
        .scaleEffect(breathe)
        .shadow(color: Splash.brand.opacity(0.32), radius: 18)
    }
}

struct SplashView: View {
    /// Called when the wipe has fully covered the screen — the caller removes
    /// the splash to reveal onboarding/Home beneath.
    var onFinish: () -> Void
    /// Whether first-launch work has finished. Once the branding floor has
    /// elapsed, the splash reveals as soon as this returns true (capped by the
    /// ceiling), so a ready app doesn't wait out the full fixed timeline.
    var isReady: () -> Bool = { true }
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var start = Date()
    @State private var wiping = false   // circular reveal running / done
    @State private var faded = false    // reduce-motion cross-fade

    var body: some View {
        GeometryReader { geo in
            ZStack {
                LinearGradient(colors: [Splash.deepA, Splash.deepB],
                               startPoint: UnitPoint(x: 0.15, y: 0),
                               endPoint: UnitPoint(x: 0.85, y: 1))
                    .ignoresSafeArea()

                // Intro choreography — pure functions of elapsed time.
                TimelineView(.animation) { tl in
                    let t = tl.date.timeIntervalSince(start)
                    let M = Theme.motion
                    let wordP = reduceMotion ? 1 : M.ease(Ease.ramp(t, 1.5 * M.entry + 0.4, 1.5 * M.entry + 1.1))
                    let tagP  = reduceMotion ? 1 : M.ease(Ease.ramp(t, 1.9 * M.entry + 0.5, 1.9 * M.entry + 1.2))
                    VStack(spacing: 20) {
                        CloudGlobeMark(t: t, reduce: reduceMotion)
                            .padding(.bottom, 36)
                        Text("Website Commander")
                            .font(.display(35, .heavy))
                            .tracking(-0.7)
                            .foregroundStyle(Splash.starFill)
                            .opacity(wordP)
                            .offset(y: (1 - wordP) * 10)
                        Text("YOUR AI WEBSITE COMMAND CENTER")
                            .font(.mono(11, .medium))
                            .tracking(1.6)
                            .foregroundStyle(Splash.brandHi)
                            .opacity(tagP)
                            .offset(y: (1 - tagP) * 7)
                    }
                }
                // Content drifts up as the reveal begins.
                .offset(y: wiping && !reduceMotion ? -16 : 0)
                .animation(reduceMotion ? nil : .easeIn(duration: 0.6), value: wiping)

                // Circular reveal: a destination-colored disc grows from the
                // lower center to cover the splash, then the caller removes it.
                if !reduceMotion {
                    let center = CGPoint(x: geo.size.width * 0.5, y: geo.size.height * 0.57)
                    let maxR = hypot(max(center.x, geo.size.width - center.x),
                                     max(center.y, geo.size.height - center.y)) * 1.03
                    Circle()
                        .fill(Color(.systemGroupedBackground))
                        .frame(width: maxR * 2, height: maxR * 2)
                        .scaleEffect(wiping ? 1 : 0.02)
                        .position(center)
                        .ignoresSafeArea()
                        .animation(.easeInOut(duration: Splash.wipeDur), value: wiping)
                }
            }
            .opacity(faded ? 0 : 1)
            .animation(.easeInOut(duration: Splash.fadeDur), value: faded)
        }
        .task { await run() }
    }

    /// Hold for the branding floor, reveal once the app is ready (or the ceiling
    /// hits), then hand off after the reveal completes.
    private func run() async {
        let floor = reduceMotion ? Splash.floorReduced : Splash.floor
        let ceiling = reduceMotion ? Splash.ceilReduced : Splash.ceil
        try? await Task.sleep(for: .seconds(floor))
        // Wait for launch work, but never past the ceiling.
        while !isReady() && start.timeIntervalSinceNow > -ceiling {
            try? await Task.sleep(for: .milliseconds(50))
        }
        if reduceMotion { faded = true } else { wiping = true }
        try? await Task.sleep(for: .seconds(reduceMotion ? Splash.fadeDur : Splash.wipeDur))
        onFinish()
    }
}

#Preview("Splash") {
    SplashView(onFinish: {})
}
