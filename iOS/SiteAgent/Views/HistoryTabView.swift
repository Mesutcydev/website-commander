import SwiftUI

struct HistoryTabView: View {
    @EnvironmentObject var engine: AgentEngine
    @State private var selectedSiteID: UUID?
    
    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                HStack {
                    Image(systemName: "slider.horizontal.3")
                        .foregroundStyle(Theme.brand)
                    Text("Workspace:")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.secondary)
                    
                    Spacer()
                    
                    Picker("Filter Site", selection: $selectedSiteID) {
                        Text("Active Workspace").tag(Optional<UUID>.none)
                        ForEach(engine.workspaces) { ws in
                            Text(ws.name).tag(Optional(ws.id))
                        }
                    }
                    .pickerStyle(.menu)
                    .tint(Theme.brand)
                }
                .padding(.horizontal)
                .padding(.vertical, 8)
                .appBackground(.secondary)
                
                Divider()
                
                let targetRepo: RepoConfig = {
                    if let filterID = selectedSiteID,
                       let found = engine.workspaces.first(where: { $0.id == filterID }) {
                        return RepoConfig(
                            owner: found.gitOwner,
                            name: found.gitRepo,
                            branch: found.gitBranch,
                            githubCredentialID: found.githubCredentialID
                        )
                    }
                    return engine.repo
                }()
                
                CommitHistoryList(repo: targetRepo)
            }
            .appBackground(.primary)
            .navigationTitle("History Log")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}
