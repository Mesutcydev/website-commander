import SwiftUI

struct StandalonePreviewView: View {
    @EnvironmentObject var engine: AgentEngine
    
    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if engine.activeWorkspace == nil {
                    VStack(spacing: 12) {
                        Image(systemName: "folder.badge.questionmark")
                            .font(.largeTitle)
                            .foregroundStyle(.secondary)
                        Text("No active workspace selected.")
                            .font(.headline)
                        Text("Choose a site in the Home or Sites tab to preview.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .padding()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .commandBackground(glow: false)
                } else {
                    SitePreviewView(repo: engine.repo, pendingChanges: engine.pendingChanges)
                        .id("standalone-preview-\(engine.activeWorkspace?.id.uuidString ?? "none")")
                }
            }
            .navigationTitle("Live Preview")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}
