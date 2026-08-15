import SwiftUI

struct SiteProfileView: View {
    @EnvironmentObject private var engine: AgentEngine
    @Environment(\.dismiss) private var dismiss
    @State private var profile = SiteProfile()
    @State private var hasWorkspace = false

    var body: some View {
        Form {
            if !hasWorkspace {
                ContentUnavailableView(
                    "No Active Workspace",
                    systemImage: "folder.badge.questionmark",
                    description: Text("Connect or select a website before creating its profile.")
                )
            } else {
                SiteProfileIdentitySection(profile: $profile)
                SiteProfileStandardsSection(profile: $profile)
                SiteProfileProtectionSection(profile: $profile)
            }
        }
        .navigationTitle("Site Profile")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Save") { save() }
                    .disabled(!hasWorkspace)
            }
        }
        .onAppear {
            if let workspace = engine.activeWorkspace {
                hasWorkspace = true
                profile = workspace.siteProfile ?? SiteProfile()
            }
        }
    }

    private func save() {
        guard var workspace = engine.activeWorkspace else { return }
        profile.lastConfirmedAt = Date()
        workspace.siteProfile = profile.isEmpty ? nil : profile
        engine.saveWorkspace(workspace)
        Haptics.success()
        dismiss()
    }
}

private struct SiteProfileIdentitySection: View {
    @Binding var profile: SiteProfile

    var body: some View {
        Section {
            TextField("Brand voice", text: $profile.brandVoice, axis: .vertical)
            TextField("Primary audience", text: $profile.audience, axis: .vertical)
            TextField("Approved terminology", text: $profile.approvedTerminology, axis: .vertical)
        } header: {
            Text("Identity")
        } footer: {
            Text("These approved facts are injected only into conversations for this workspace.")
        }
    }
}

private struct SiteProfileStandardsSection: View {
    @Binding var profile: SiteProfile

    var body: some View {
        Section {
            TextField("Colors, type, and design tokens", text: $profile.designTokens, axis: .vertical)
            TextField("Accessibility requirements", text: $profile.accessibilityRequirements, axis: .vertical)
            TextField("Deployment conventions", text: $profile.deploymentConventions, axis: .vertical)
        } header: {
            Text("Standards")
        }
    }
}

private struct SiteProfileProtectionSection: View {
    @Binding var profile: SiteProfile

    var body: some View {
        Section {
            TextField(
                "Protected files, behaviors, or content",
                text: $profile.protectedRules,
                axis: .vertical
            )
        } header: {
            Text("Approval Boundaries")
        } footer: {
            Text("The agent must ask before changing anything listed here.")
        }
    }
}
