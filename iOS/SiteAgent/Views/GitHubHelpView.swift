import SwiftUI

/// In-app explainer for connecting GitHub: *why* Website Commander needs access and the
/// two ways a user can grant it. Presented as a sheet from Settings and the
/// connect-website sheet. Note: users never register an OAuth App — that's a
/// one-time developer step. A user either taps "Sign in with GitHub" or, as a
/// fallback, creates a personal access token.
struct GitHubHelpView: View {
    @Environment(\.dismiss) private var dismiss

    private let classicTokenURL = SiteAgentURL.constant("https://github.com/settings/tokens/new?scopes=repo&description=Website%20Commander")

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    why
                    methodSignIn
                    methodToken
                    security
                }
                .padding(20)
            }
            .background(Color(.systemGroupedBackground).ignoresSafeArea())
            .navigationTitle("Connecting GitHub")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    // MARK: Why

    private var why: some View {
        card(icon: "questionmark.circle.fill", title: "Why Website Commander needs GitHub") {
            Text("Website Commander edits your website's files and saves them (a “commit”) to your GitHub repository. To do that, it needs your permission to read and write that one repository.")
            Text("There's nothing to install or register — you just grant access once, in one of the two ways below.")
                .foregroundStyle(.secondary)
        }
    }

    // MARK: Method 1 — Sign in

    private var methodSignIn: some View {
        card(icon: "person.badge.key.fill", title: "Easiest: Sign in with GitHub") {
            step(1, "Tap “Sign in with GitHub”.")
            step(2, "Website Commander shows a short code and opens github.com/login/device.")
            step(3, "Enter the code and tap Authorize.")
            Text("That's it. This grants exactly the access needed to commit — nothing to configure, and it can't end up unable to push.")
                .foregroundStyle(.secondary)
        }
    }

    // MARK: Method 2 — Token

    private var methodToken: some View {
        card(icon: "key.fill", title: "Alternative: paste a token") {
            Text("Prefer a token? Create a **classic** one with the **repo** scope:")
            step(1, "On GitHub: Settings → Developer settings → Personal access tokens → Tokens (classic).")
            step(2, "Generate new token (classic), then under “Select scopes” check **repo**.")
            step(3, "Generate it, copy the token, and paste it into Website Commander's “GitHub token” field.")
            Link(destination: classicTokenURL) {
                Label("Open the token page (repo pre-selected)", systemImage: "arrow.up.forward.app")
                    .font(.subheadline.weight(.semibold))
            }
            .padding(.top, 2)
            Text("Use a **classic** token, not fine-grained: its repo scope is all-or-nothing read+write, so it can't accidentally be created without the write access committing requires.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: Security

    private var security: some View {
        card(icon: "lock.shield.fill", title: "Where your access is stored") {
            Text("Your token is saved in iCloud Keychain when available. Requests go straight to GitHub's API — no proxy servers and no telemetry. You can revoke Website Commander's access anytime from your GitHub settings.")
        }
    }

    // MARK: Building blocks

    @ViewBuilder private func card<Content: View>(icon: String, title: String,
                                                  @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(title, systemImage: icon)
                .font(.headline)
                .foregroundStyle(Theme.brand)
            VStack(alignment: .leading, spacing: 8) {
                content()
            }
            .font(.subheadline)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(Color(.secondarySystemGroupedBackground),
                    in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    @ViewBuilder private func step(_ n: Int, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text("\(n)")
                .font(.footnote.weight(.bold))
                .foregroundStyle(.white)
                .frame(width: 20, height: 20)
                .background(Theme.brand, in: Circle())
            Text(.init(text))   // .init enables **markdown** bold
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }
}
