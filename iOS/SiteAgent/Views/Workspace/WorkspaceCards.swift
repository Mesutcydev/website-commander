import SwiftUI

// MARK: - Shared chrome for Workspace sheet cards

struct WorkspacePill: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold, design: .rounded))
            .foregroundStyle(Theme.t1)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Theme.brand.opacity(0.12), in: Capsule())
    }
}

struct WorkspaceStatusRow: View {
    let title: String
    let isComplete: Bool
    var detail: String? = nil

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: isComplete ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(isComplete ? Color.green : Color.orange)
                .contentTransition(.symbolEffect(.replace))
            VStack(alignment: .leading, spacing: 2) {
                Text(title.localized)
                    .font(.ui(14, .semibold))
                if let detail, !detail.isEmpty {
                    Text(detail.localized)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            Spacer(minLength: 8)
        }
        .padding(.vertical, 10)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title), \(isComplete ? "connected" : "needs attention")")
    }
}

/// Website summary — display name + connection pills. No owner/repo/branch.
struct WebsiteSummaryCard: View {
    let status: WorkspaceStatus
    var onEdit: () -> Void
    var onConnect: () -> Void

    var body: some View {
        SettingsSection("Website") {
            if status.hasWebsite {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: "globe")
                        .font(.title2.weight(.semibold))
                        .foregroundStyle(Theme.brand)
                        .frame(width: 36, height: 36)
                    VStack(alignment: .leading, spacing: 6) {
                        Text(status.websiteDisplayName)
                            .font(.ui(18, .bold))
                            .foregroundStyle(Theme.t1)
                            .lineLimit(2)
                        HStack(spacing: 6) {
                            Circle()
                                .fill(status.agentReady ? Color.green : Color.orange)
                                .frame(width: 7, height: 7)
                            Text(status.agentReady ? "Connected" : "Setup needed")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                        }
                        VStack(alignment: .leading, spacing: 4) {
                            if status.githubConnected {
                                Text("GitHub · Connected")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.secondary)
                            }
                            if status.hasWebsite {
                                Text(status.deploymentDisplayName)
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.secondary)
                            }
                            if status.assistantReady {
                                Text("Assistant · \(status.assistantDisplayName)")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.secondary)
                            } else if !status.connectedPills.isEmpty {
                                FlowPills(items: status.connectedPills)
                            }
                        }
                    }
                    Spacer(minLength: 8)
                    Button("Edit") {
                        Haptics.tap()
                        onEdit()
                    }
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.brand)
                }
                .padding(.vertical, 10)
            } else {
                Text("No website connected yet.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 10)
                SettingsDivider()
                SettingsButton("Connect Website", systemImage: "plus.circle", kind: .primary, action: onConnect)
            }
        }
    }
}

/// Compact wrapping pill row without a heavy FlowLayout dependency.
private struct FlowPills: View {
    let items: [String]
    var body: some View {
        // Simple wrapping via flexible HStack lines (max ~3 pills typical).
        HStack(spacing: 6) {
            ForEach(items, id: \.self) { pill in
                WorkspacePill(text: pill)
            }
        }
    }
}

struct ConnectionStatusCard: View {
    let status: WorkspaceStatus
    var verifying: Bool
    var verifyResult: String?
    var onVerify: () -> Void
    var onFixGitHub: () -> Void
    var onFixAssistant: () -> Void
    var onFixDeployment: () -> Void

    var body: some View {
        SettingsSection("Connection Status", footer: status.statusSummary) {
            Button(action: onFixGitHub) {
                WorkspaceStatusRow(
                    title: "GitHub",
                    isComplete: status.githubConnected,
                    detail: status.githubConnected ? "Connected" : "Sign in to continue"
                )
            }
            .buttonStyle(.plain)
            SettingsDivider()
            Button(action: onFixAssistant) {
                WorkspaceStatusRow(
                    title: "AI Ready",
                    isComplete: status.assistantReady,
                    detail: status.assistantReady ? status.assistantDisplayName : "Choose an assistant"
                )
            }
            .buttonStyle(.plain)
            SettingsDivider()
            WorkspaceStatusRow(
                title: "Deployment",
                isComplete: status.deploymentReady,
                detail: status.deploymentReady
                    ? status.deploymentDisplayName
                    : "Optional — connect hosting when ready"
            )
            // This row is status-only. Deployment configuration is intentionally
            // available from the dedicated Configure button below; keeping this
            // row outside any Button prevents the old sideload-only navigation
            // crash when the green status line is tapped.
            .allowsHitTesting(false)
            .accessibilityAddTraits(.isStaticText)

            if status.allGreen {
                SettingsDivider()
                Label("Everything is working.", systemImage: "checkmark.seal.fill")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.green)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 10)
            } else if status.agentReady && !status.deploymentReady {
                // Deployment incomplete is optional — one soft action, not a critical failure.
                SettingsDivider()
                SettingsButton(
                    "Connect Deployment",
                    systemImage: "shippingbox",
                    kind: .secondary,
                    action: onFixDeployment
                )
            } else if status.hasWebsite && (!status.githubConnected || !status.assistantReady) {
                SettingsDivider()
                SettingsButton(
                    "Verify Connection",
                    systemImage: "checkmark.shield",
                    kind: .secondary,
                    loading: verifying,
                    action: onVerify
                )
                .disabled(verifying)
            }

            if let verifyResult {
                SettingsBanner(message: verifyResult, ok: verifyResult.hasPrefix("✓"), errorTint: .red)
            }
        }
    }
}

struct AssistantSummaryCard: View {
    let displayName: String
    let modelLabel: String
    var onChange: () -> Void

    var body: some View {
        SettingsSection("Assistant") {
            Button(action: onChange) {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(displayName)
                            .font(.ui(16, .bold))
                            .foregroundStyle(Theme.t1)
                        if !modelLabel.isEmpty {
                            Text(modelLabel)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    Text("Change")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Theme.brand)
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 12)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }
}

struct DeploymentSummaryCard: View {
    let status: WorkspaceStatus
    var onConfigure: () -> Void

    var body: some View {
        SettingsSection("Deployment") {
            VStack(alignment: .leading, spacing: 8) {
                Text(status.hasWebsite ? status.deploymentDisplayName : "Not connected")
                    .font(.ui(16, .bold))
                if status.deploymentReady {
                    Text("Automatic Deploy")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Theme.brand)
                    Text("Every change is published automatically.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text("Connect hosting so pushes can publish automatically.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 10)
            SettingsDivider()
            SettingsButton(
                status.deploymentReady ? "Configure" : "Connect Deployment",
                systemImage: "shippingbox",
                kind: .secondary,
                action: onConfigure
            )
        }
    }
}
