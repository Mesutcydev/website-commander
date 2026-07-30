import SwiftUI

/// A short, visual welcome tour shown on first launch.
struct OnboardingView: View {

    @EnvironmentObject var settings: SettingsStore
    @State private var page = 0

    private struct Page {
        let icon: String
        let title: String
        let body: String
    }

    private let pages: [Page] = [
        Page(icon: "square.grid.2x2.fill",
             title: "Welcome to Website Commander",
             body: "Edit your websites with plain English. Connect a GitHub repo, describe a change, and let the agent build it."),
        Page(icon: "checkmark.shield.fill",
             title: "You approve everything",
             body: "The agent stages each edit as a color-coded diff with a security scan. Nothing commits until you say so."),
        Page(icon: "cpu.fill",
             title: "Your AI, your choice",
             body: "Use OpenAI, Claude, Gemini, DeepSeek, Grok, Mistral, Copilot, or any OpenAI-compatible endpoint. Keys stay in your Keychain."),
        Page(icon: "chevron.left.forwardslash.chevron.right",
             title: "Made for your Mac",
             body: "Open any site in VSCode, preview it live, and browse history — all in a calm, native Mac interface.")
    ]

    var body: some View {
        VStack(spacing: Theme.Space.xl) {
            Spacer()
            Image(systemName: pages[page].icon)
                .font(.system(size: 64, weight: .light))
                .foregroundStyle(Theme.brandGradient)
                .frame(height: 90)
            VStack(spacing: Theme.Space.m) {
                Text(pages[page].title)
                    .font(Theme.display(30, weight: .heavy))
                    .multilineTextAlignment(.center)
                Text(pages[page].body)
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 460)
            }
            .id(page)
            .transition(.asymmetric(
                insertion: .opacity.combined(with: .move(edge: .trailing)),
                removal: .opacity.combined(with: .move(edge: .leading))))
            Spacer()
            HStack(spacing: 8) {
                ForEach(pages.indices, id: \.self) { i in
                    Capsule()
                        .fill(i == page ? Theme.accent : Color.secondary.opacity(0.3))
                        .frame(width: i == page ? 22 : 8, height: 8)
                }
            }
            HStack {
                Button("Skip") { finish() }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                Spacer()
                if page > 0 {
                    Button("Back") { withAnimation { page -= 1 } }
                }
                Button(page == pages.count - 1 ? "Get Started" : "Continue") {
                    if page == pages.count - 1 { finish() }
                    else { withAnimation { page += 1 } }
                }
                .buttonStyle(.primary)
                .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, Theme.Space.xxl)
            .padding(.bottom, Theme.Space.xl)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.brandWash.opacity(0.5).ignoresSafeArea())
    }

    private func finish() {
        settings.hasCompletedOnboarding = true
    }
}
