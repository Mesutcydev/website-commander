import SwiftUI

struct WizardGitHubStep: View {
    @ObservedObject var coordinator: ConnectWebsiteWizardCoordinator
    @EnvironmentObject var engine: AgentEngine
    var onContinue: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Connect GitHub")
                .font(.title2.bold())
            Text("Choose the repository containing your website. Website Commander uses GitHub to read and update approved files.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            accountPicker

            if coordinator.hasGitHubToken {
                VStack(alignment: .leading, spacing: 8) {
                    Label("GitHub connected", systemImage: "checkmark.seal.fill")
                        .font(.headline)
                        .foregroundStyle(.green)
                    if let login = coordinator.githubLogin {
                        Text("Signed in as \(login)")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)
                .commandCard(cornerRadius: 18)

                SettingsButton("Continue", systemImage: "arrow.right", kind: .primary) {
                    onContinue()
                }
                .frame(minHeight: 44)

                GitHubSignInView(
                    style: .inline,
                    showsStatus: false,
                    credentialID: coordinator.githubCredentialID
                ) {
                    engine.noteSecretsChanged()
                    Task { await coordinator.refreshGitHub(engine: engine) }
                }
                Text("This website will keep using this account, even when you switch between sites.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                GitHubSignInView(
                    style: .card,
                    showsStatus: true,
                    credentialID: coordinator.githubCredentialID
                ) {
                    engine.noteSecretsChanged()
                    Task {
                        await coordinator.refreshGitHub(engine: engine)
                        onContinue()
                    }
                }
            }

            if case .message(let text) = coordinator.issue, coordinator.step == .github {
                Text(text)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var accountPicker: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("GitHub account")
                .font(.headline)
            HStack(spacing: 10) {
                accountButton(
                    title: "Current account",
                    subtitle: "Use your existing sign-in",
                    icon: "person.crop.circle",
                    selected: coordinator.githubCredentialID == nil
                ) { coordinator.usePrimaryAccount(engine: engine) }
                accountButton(
                    title: "Add another",
                    subtitle: "Connect a different GitHub",
                    icon: "person.crop.circle.badge.plus",
                    selected: coordinator.githubCredentialID != nil
                ) { coordinator.useAnotherAccount() }
            }
        }
    }

    private func accountButton(
        title: String, subtitle: String, icon: String, selected: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 7) {
                Image(systemName: selected ? "checkmark.circle.fill" : icon)
                    .foregroundStyle(selected ? Theme.brand : .secondary)
                Text(title).font(.subheadline.weight(.semibold))
                Text(subtitle)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.leading)
            }
            .frame(maxWidth: .infinity, minHeight: 88, alignment: .leading)
            .padding(12)
            .background(
                selected ? Theme.brand.opacity(0.12) : Color.primary.opacity(0.05),
                in: RoundedRectangle(cornerRadius: 14, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(selected ? Theme.brand.opacity(0.7) : .clear, lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
    }
}
