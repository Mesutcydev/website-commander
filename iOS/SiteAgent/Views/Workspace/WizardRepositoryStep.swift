import SwiftUI

struct WizardRepositoryStep: View {
    @ObservedObject var coordinator: ConnectWebsiteWizardCoordinator
    @EnvironmentObject var engine: AgentEngine
    @State private var showBranchPicker = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Choose Website")
                .font(.title2.bold())
            Text("Pick the repository Website Commander should manage. We’ll detect hosting automatically.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Search repositories", text: $coordinator.repoSearch)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            }
            .padding(12)
            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
            .frame(minHeight: 44)

            if coordinator.loadingRepos {
                ProgressView("Loading your repositories…")
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 40)
            } else if coordinator.filteredRepositories.isEmpty {
                ContentUnavailableView(
                    coordinator.repositories.isEmpty ? "No repositories" : "No matches",
                    systemImage: "folder",
                    description: Text(coordinator.repositories.isEmpty
                                       ? "No repositories found for this GitHub account."
                                       : "Try a different search.")
                )
                .frame(maxWidth: .infinity)
                SettingsButton("Try Again", systemImage: "arrow.clockwise", kind: .secondary) {
                    Task { await coordinator.refreshGitHub(engine: engine) }
                }
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(coordinator.filteredRepositories.enumerated()), id: \.element.id) { index, repo in
                        if index > 0 { Divider() }
                        Button {
                            Haptics.tap()
                            Task { await coordinator.selectRepository(repo, engine: engine) }
                        } label: {
                            repoRow(repo)
                        }
                        .buttonStyle(.plain)
                        .disabled(coordinator.detecting)
                        .frame(minHeight: 56)
                    }
                }
                .padding(.horizontal, 14)
                .commandCard()
            }

            if let selected = coordinator.selectedRepository {
                DisclosureGroup("Branch", isExpanded: $showBranchPicker) {
                    Text("Using \(coordinator.selectedBranch ?? selected.defaultBranch)")
                        .font(.subheadline)
                    TextField("Branch name", text: Binding(
                        get: { coordinator.selectedBranch ?? selected.defaultBranch },
                        set: { coordinator.selectedBranch = $0 }
                    ))
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .padding(10)
                    .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 10))
                }
                .font(.subheadline.weight(.semibold))
            }
        }
    }

    private func repoRow(_ repo: GitHubRepoSummary) -> some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(repo.displayTitle)
                        .font(.headline)
                        .foregroundStyle(Theme.t1)
                        .lineLimit(1)
                    if repo.isPrivate {
                        Text("Private")
                            .font(.caption2.weight(.bold))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.orange.opacity(0.15), in: Capsule())
                            .foregroundStyle(.orange)
                    }
                }
                if let homepage = repo.homepage, !homepage.isEmpty, repo.displayTitle != repo.name {
                    Text(repo.name)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if let description = repo.description, !description.isEmpty {
                    Text(description)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Text("\(repo.owner) · \(repo.defaultBranch)")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            Spacer(minLength: 8)
            if coordinator.selectedRepository?.id == repo.id, coordinator.detecting {
                ProgressView().controlSize(.small)
            } else {
                Image(systemName: "chevron.right")
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 12)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(repo.displayTitle), \(repo.owner), branch \(repo.defaultBranch)\(repo.isPrivate ? ", private" : "")")
    }
}
