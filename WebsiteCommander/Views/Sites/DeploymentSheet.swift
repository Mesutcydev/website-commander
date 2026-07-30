import SwiftUI

/// Configure and trigger deployment for one workspace: set a deploy-hook URL
/// (for hook-capable hosts) and fire a rebuild on demand.
struct DeploymentSheet: View {

    @Environment(\.dismiss) private var dismiss
    let workspace: SiteWorkspace

    @State private var hookURL = ""
    @State private var result: DeployResult?
    @State private var isDeploying = false

    private var supportsHook: Bool { DeploymentService.supportsHook(workspace.deployment) }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            VStack(alignment: .leading, spacing: Theme.Space.l) {
                HStack(spacing: Theme.Space.s) {
                    IconTile(systemImage: workspace.deployment.icon, size: 34, gradient: false)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(workspace.deployment.rawValue).font(.headline)
                        Text(workspace.slug).font(.caption).foregroundStyle(.secondary)
                    }
                }

                if supportsHook {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Deploy hook URL").font(.caption).foregroundStyle(.secondary)
                        SecureField("https://…", text: $hookURL)
                            .textFieldStyle(.roundedBorder)
                        Text(DeploymentService.hookHelp(for: workspace.deployment))
                            .font(.caption2).foregroundStyle(.secondary)
                        Button("Save Hook") {
                            DeploymentService.setHookURL(hookURL, for: workspace.id)
                            result = nil
                        }
                        .buttonStyle(.primarySoft)
                    }
                } else {
                    Text(DeploymentService.hookHelp(for: workspace.deployment))
                        .font(.callout).foregroundStyle(.secondary)
                }

                if let result {
                    Label(result.note, systemImage: result.isSuccess ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .font(.callout)
                        .foregroundStyle(result.isSuccess ? Theme.success : Theme.warning)
                        .padding(Theme.Space.m)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background((result.isSuccess ? Theme.success : Theme.warning).opacity(0.12),
                                    in: RoundedRectangle(cornerRadius: Theme.Radius.medium))
                }

                Spacer()
            }
            .padding(Theme.Space.xl)
            Divider()
            footer
        }
        .frame(width: 500, height: 420)
        .onAppear { hookURL = DeploymentService.hookURL(for: workspace.id) ?? "" }
    }

    private var header: some View {
        HStack {
            Text("Deployment").font(.title3.weight(.semibold))
            Spacer()
        }
        .padding(Theme.Space.l)
    }

    private var footer: some View {
        HStack {
            Button("Close") { dismiss() }
            Spacer()
            Button {
                trigger()
            } label: {
                if isDeploying { ProgressView().controlSize(.small) }
                else { Label("Trigger Deploy", systemImage: "paperplane.fill") }
            }
            .buttonStyle(.primary)
            .disabled(isDeploying)
        }
        .padding(Theme.Space.l)
    }

    private func trigger() {
        isDeploying = true
        Task {
            let outcome = await DeploymentService.trigger(for: workspace)
            result = outcome
            isDeploying = false
        }
    }
}
