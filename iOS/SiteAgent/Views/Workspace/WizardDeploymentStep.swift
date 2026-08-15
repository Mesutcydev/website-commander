import SwiftUI

struct WizardDeploymentStep: View {
    @ObservedObject var coordinator: ConnectWebsiteWizardCoordinator
    @State private var showAdvanced = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Connect Deployment")
                .font(.title2.bold())

            if let host = coordinator.suggestedDeployment {
                Text("We found \(host.displayName) in this repository.")
                    .font(.headline)
                    .fixedSize(horizontal: false, vertical: true)
                Text("Detection is not the same as Connected. Connect credentials to publish approved changes.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                switch host {
                case .cloudflareWorkers:
                    workersFields
                case .cloudflarePages:
                    Text("Connect with a Cloudflare API token after finishing this wizard — open Workspace → Deployment.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                case .githubPages:
                    Label("GitHub Pages will use your GitHub sign-in. No extra token needed.", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .font(.subheadline)
                case .vercel, .netlify:
                    Text("You’ll finish \(host.displayName) tokens in Deployment settings after setup.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                default:
                    Text("You can configure \(host.displayName) from Workspace → Deployment later.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            } else {
                Text("We couldn’t detect a host automatically.")
                    .font(.headline)
                Text("Set up later from Workspace — Chat and editing still work.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            if let notes = coordinator.detection?.notes, !notes.isEmpty {
                ForEach(notes, id: \.self) { note in
                    Text(note)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    @ViewBuilder
    private var workersFields: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Deploy hook")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Text("Required to trigger deployments.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
            SecureField("https://api.cloudflare.com/…", text: $coordinator.deployHookDraft)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .padding(12)
                .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 10))
                .frame(minHeight: 44)

            if let worker = coordinator.detection?.suggestedWorkerName {
                Text("Detected worker: \(worker)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            DisclosureGroup("Advanced", isExpanded: $showAdvanced) {
                Text("API token")
                    .font(.caption.weight(.semibold))
                Text("Optional. Enables deployment status and history. Configure under Workspace → Deployment → Advanced after setup.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .font(.subheadline.weight(.semibold))
            .padding(.top, 4)
        }
    }
}
