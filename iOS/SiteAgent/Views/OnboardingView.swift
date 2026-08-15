import SwiftUI

struct OnboardingView: View {
    var onDismiss: () -> Void
    /// True while the launch splash is still covering the screen. Page 1 holds
    /// its entrance until the wipe reveals it.
    var splashActive: Bool = false
    @EnvironmentObject var engine: AgentEngine
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var currentPage = 0
    @State private var finishing = false

    let pages: [OnboardingPage] = [
        OnboardingPage(
            title: "Update Sites by Chat",
            subtitle: "Ask for a website change in plain English. Website Commander edits the repo and stages the result for review.",
            imageName: "message.fill",
            color: Theme.brand,
            features: [
                "Edit content, styles, files, and assets",
                "Start a change hands-free with Shortcuts & Siri",
                "Preview changes before they go live"
            ]
        ),
        OnboardingPage(
            title: "Connect GitHub Securely",
            subtitle: "Sign in once so Website Commander can read, stage, and commit changes to your repository.",
            imageName: "arrow.up.forward.app",
            color: Theme.brand,
            features: [
                "Credentials sync with iCloud Keychain",
                "Direct requests to GitHub and your AI provider",
                "No hand-built tokens to misconfigure",
                "Manual token setup remains available later"
            ],
            showsGitHubSignIn: true
        ),
        OnboardingPage(
            title: "Review, Verify, Undo",
            subtitle: "AI can make mistakes, so Website Commander shows diffs, confirms deploys, and keeps you in control.",
            imageName: "checkmark.seal.fill",
            color: Theme.brand,
            features: [
                "Approve or reject every staged change",
                "Confirm the change went live — then undo any commit in a tap",
                "Track cost per session and set a spend cap",
                "Inspect the live site and send fixes to the agent",
                "Try a guided demo from Home before setup"
            ]
        ),
        OnboardingPage(
            title: "Colorless Clear Glass",
            subtitle: "Prefer a quieter interface? Open Settings → Appearance and pair Colorless with Clear Glass for a neutral, translucent look.",
            imageName: "circle.lefthalf.filled",
            color: Theme.brand,
            features: [
                "Colorless removes accent hue while preserving readable controls",
                "Clear Glass adds translucent depth across cards and controls",
                "Switch icons, accents, theme, and surface style at any time"
            ]
        ),
        OnboardingPage(
            title: "Help Is Built In",
            subtitle: "New here? A visual, step-by-step User Guide walks you through everything.",
            imageName: "book.pages.fill",
            color: Theme.brand,
            features: [
                "Open it anytime from Settings → User Guide",
                "Covers setup, chatting, reviewing diffs, deploying & undo",
                "Plus a guided demo from Home to see the flow with no setup"
            ]
        )
    ]

    /// A page runs its entrance when it's current, except page 1 waits for the
    /// splash wipe to reveal it.
    private func isActive(_ index: Int) -> Bool {
        index == currentPage && !(index == 0 && splashActive)
    }

    var body: some View {
        GeometryReader { viewport in
            let contentWidth = min(viewport.size.width, 680)

            ZStack {
                CommandDeckBackground()

                VStack(spacing: 0) {
                    OnboardingTopBar(onSkip: {
                        Haptics.tap()
                        onDismiss()
                    })
                    .frame(width: contentWidth)

                    TabView(selection: $currentPage) {
                        ForEach(pages.indices, id: \.self) { index in
                            OnboardingPageView(page: pages[index], active: isActive(index))
                                .tag(index)
                        }
                    }
                    .tabViewStyle(.page(indexDisplayMode: .never))

                    OnboardingControls(
                        pageCount: pages.count,
                        currentPage: currentPage,
                        isLast: currentPage == pages.count - 1,
                        finishing: finishing,
                        reduceMotion: reduceMotion,
                        color: pages[currentPage].color
                    ) {
                        Haptics.tap()
                        if currentPage < pages.count - 1 {
                            // PageTabViewStyle owns this transition. Wrapping its
                            // selection in an additional spring can leave the next
                            // page transparent on iOS 27 after the swipe completes.
                            currentPage += 1
                        } else {
                            Haptics.success()
                            withAnimation(Theme.spring) { finishing = true }
                            Task {
                                try? await Task.sleep(nanoseconds: 450_000_000)
                                onDismiss()
                            }
                        }
                    }
                    .disabled(finishing)
                    .padding(.horizontal, 24)
                    .padding(.bottom, 24)
                    .frame(width: contentWidth)
                }
            }
        }
    }
}

struct OnboardingPage {
    let title: String
    let subtitle: String
    let imageName: String
    let color: Color
    let features: [String]
    /// When true, the page shows the GitHub OAuth control before Settings.
    var showsGitHubSignIn: Bool = false
}

private struct OnboardingTopBar: View {
    let onSkip: () -> Void

    var body: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Website Commander")
                    .font(.display(24, .bold, relativeTo: .title2))
                    .foregroundStyle(CC.text)
                Text("Command Center".localized.uppercased(with: .current))
                    .font(.mono(11, .semibold))
                    .kerning(1.4)
                    .foregroundStyle(CC.textSub)
            }
            Spacer(minLength: 16)
            Button("Skip", action: onSkip)
                .font(.ui(14, .semibold))
                .foregroundStyle(CC.text)
                .padding(.horizontal, 14)
                .frame(height: 38)
                .adaptiveGlassSurface(.button, cornerRadius: 19, classicFill: CC.card)
                .buttonStyle(.glassPress)
        }
        .padding(.horizontal, 24)
        .padding(.top, 12)
        .padding(.bottom, 6)
    }
}

struct OnboardingPageView: View {
    let page: OnboardingPage
    /// True when this page should be playing its entrance.
    var active: Bool = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { viewport in
            let contentWidth = min(viewport.size.width, 680)

            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 14) {
                    OnboardingHeroPanel(page: page)
                        .entrance(active, delay: 0, rise: 18, scaleFrom: 0.97, reduce: reduceMotion)

                    OnboardingFeatureList(features: page.features)
                        .entrance(active, delay: 0.12, rise: 22, reduce: reduceMotion)

                    if page.showsGitHubSignIn {
                        GitHubSignInView(style: .card)
                            .entrance(active, delay: 0.2, rise: 22, reduce: reduceMotion)
                    }
                }
                .padding(.horizontal, 24)
                .padding(.top, 16)
                .padding(.bottom, 28)
                // A vertical ScrollView can propose an effectively unbounded
                // cross-axis width. Pin the complete padded page to the actual
                // viewport so the 680 pt reading cap never overflows an iPhone.
                .frame(width: contentWidth, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .center)
            }
        }
    }
}

private struct OnboardingHeroPanel: View {
    let page: OnboardingPage

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(alignment: .top) {
                Image(systemName: page.imageName)
                    .font(.system(size: 23, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 54, height: 54)
                    .background(Theme.brandGradient, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .shadow(color: Theme.brand.opacity(0.32), radius: 14, y: 8)
                    .accessibilityHidden(true)
                Spacer(minLength: 12)
                StatusPill(text: "System Online".localized, tint: Theme.brand, kind: .outline)
            }

            VStack(alignment: .leading, spacing: 9) {
                Text(page.title.localized)
                    .font(.display(34, .heavy, relativeTo: .largeTitle))
                    .foregroundStyle(CC.text)
                    .fixedSize(horizontal: false, vertical: true)
                Text(page.subtitle.localized)
                    .font(.ui(16))
                    .foregroundStyle(CC.textSub)
                    .fixedSize(horizontal: false, vertical: true)
            }

            OnboardingFlowStrip()
        }
        // Full-screen layout: hero content sits directly on the backdrop.
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct OnboardingFlowStrip: View {
    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) {
                OnboardingFlowStep(title: "Chat", icon: "message.fill")
                OnboardingFlowConnector()
                OnboardingFlowStep(title: "Review", icon: "doc.text.magnifyingglass")
                OnboardingFlowConnector()
                OnboardingFlowStep(title: "Deploy", icon: "paperplane.fill")
            }

            VStack(alignment: .leading, spacing: 8) {
                OnboardingFlowStep(title: "Chat", icon: "message.fill")
                OnboardingFlowStep(title: "Review", icon: "doc.text.magnifyingglass")
                OnboardingFlowStep(title: "Deploy", icon: "paperplane.fill")
            }
        }
        .padding(.top, 2)
        .accessibilityElement(children: .combine)
    }
}

private struct OnboardingFlowStep: View {
    let title: String
    let icon: String

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .semibold))
            Text(title.localized)
                .font(.mono(11, .semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        }
        .foregroundStyle(CC.text)
        .padding(.horizontal, 9)
        .frame(height: 30)
        .background(Theme.chip, in: Capsule())
        .overlay(Capsule().strokeBorder(CC.stroke, lineWidth: 1))
    }
}

private struct OnboardingFlowConnector: View {
    var body: some View {
        Capsule()
            .fill(CC.strokeGreen)
            .frame(width: 12, height: 2)
            .accessibilityHidden(true)
    }
}

private struct OnboardingFeatureList: View {
    let features: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(features.enumerated()), id: \.element) { index, feature in
                OnboardingFeatureRow(text: feature)
                if index < features.count - 1 {
                    Divider().overlay(Theme.separator)
                }
            }
        }
        // No box — the rows read as a screen-level list on the backdrop.
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct OnboardingFeatureRow: View {
    let text: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(Theme.brand)
                .accessibilityHidden(true)
            Text(text.localized)
                .font(.ui(15))
                .foregroundStyle(CC.text)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 12)
    }
}

private struct OnboardingControls: View {
    let pageCount: Int
    let currentPage: Int
    let isLast: Bool
    let finishing: Bool
    let reduceMotion: Bool
    let color: Color
    let action: () -> Void

    var body: some View {
        VStack(spacing: 18) {
            OnboardingPageDots(pageCount: pageCount, currentPage: currentPage, color: color, reduceMotion: reduceMotion)
            OnboardingCTA(isLast: isLast, finishing: finishing, color: color, action: action)
        }
    }
}

private struct OnboardingPageDots: View {
    let pageCount: Int
    let currentPage: Int
    let color: Color
    let reduceMotion: Bool

    var body: some View {
        HStack(spacing: 8) {
            ForEach(0..<pageCount, id: \.self) { index in
                Capsule()
                    .fill(index == currentPage ? color : CC.stroke)
                    .frame(width: index == currentPage ? 24 : 8, height: 8)
                    .animation(reduceMotion ? nil : Theme.spring, value: currentPage)
            }
        }
        .accessibilityHidden(true)
    }
}

/// The onboarding primary button: shows "Continue"/"Start Building", swaps to a
/// success checkmark on finish, and breathes a soft accent glow on the last page.
struct OnboardingCTA: View {
    let isLast: Bool
    let finishing: Bool
    let color: Color
    let action: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if finishing {
                    Image(systemName: "checkmark")
                        .symbolEffect(.bounce, options: .nonRepeating, value: finishing)
                } else {
                    Text((isLast ? "Start Building" : "Continue").localized)
                    Image(systemName: isLast ? "checkmark.circle.fill" : "arrow.right")
                        .font(.system(size: 14, weight: .bold))
                        .accessibilityHidden(true)
                }
            }
            .font(.ui(16, .semibold))
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .frame(height: 56)
            .background(Theme.actionGradient, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .modifier(GlowShadow(color: color, breathing: isLast && !reduceMotion))
            .animation(reduceMotion ? nil : Theme.snappy, value: isLast)
        }
        .buttonStyle(.pressable)
    }
}

/// A soft colored shadow that optionally breathes between two radii/opacities.
private struct GlowShadow: ViewModifier {
    let color: Color
    let breathing: Bool

    func body(content: Content) -> some View {
        if breathing {
            TimelineView(.animation) { tl in
                let s = 0.5 + 0.5 * sin(tl.date.timeIntervalSinceReferenceDate * 2.4)
                content.shadow(color: color.opacity(0.3 + 0.2 * s), radius: 18 + 6 * s, y: 8)
            }
        } else {
            content.shadow(color: color.opacity(0.28), radius: 16, y: 7)
        }
    }
}

// MARK: - Entrance choreography

/// Staggered fade + rise (+ optional scale). Under Reduce Motion it collapses
/// to a plain cross-fade.
private struct Entrance: ViewModifier {
    let shown: Bool
    var delay: Double = 0
    var rise: CGFloat = 24
    var scaleFrom: CGFloat = 1
    let reduce: Bool

    func body(content: Content) -> some View {
        content
            .opacity(shown ? 1 : 0)
            .offset(y: (shown || reduce) ? 0 : rise)
            .scaleEffect((shown || reduce) ? 1 : scaleFrom)
            .animation(reduce ? .easeInOut(duration: 0.3) : Theme.motion.enter.delay(delay), value: shown)
    }
}

extension View {
    func entrance(_ shown: Bool, delay: Double = 0, rise: CGFloat = 24,
                  scaleFrom: CGFloat = 1, reduce: Bool) -> some View {
        modifier(Entrance(shown: shown, delay: delay, rise: rise, scaleFrom: scaleFrom, reduce: reduce))
    }
}

#Preview("Onboarding") {
    OnboardingView(onDismiss: {})
        .environmentObject(AgentEngine())
}
