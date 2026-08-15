import SwiftUI

/// Browse the repo directly (independent of the agent) — tap a folder to descend,
/// tap a file to view its current contents on the live branch.
struct FileBrowserView: View {
    @EnvironmentObject var engine: AgentEngine
    @State private var mode: Int // 0 = Browser, 1 = History, 2 = Dashboard
    init(initialMode: Int = 0) { _mode = State(initialValue: initialMode) }

    var body: some View {
        // No own NavigationStack — pushed into the caller's stack (Sites tab), so
        // child NavigationLinks use the parent and there's no double nav bar.
        VStack(spacing: 0) {
                Picker("View Mode", selection: $mode) {
                    Text("Browser").tag(0)
                    Text("History").tag(1)
                    Text("Dashboard").tag(2)
                }
                .pickerStyle(.segmented)
                .padding()
                
                if mode == 0 {
                    DirectoryList(repo: engine.repo, path: "")
                } else if mode == 1 {
                    CommitHistoryList(repo: engine.repo)
                } else {
                    HealthDashboardView()
                }
            }
        .appBackground(.primary)
        .navigationTitle(engine.repo.name)
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct DirectoryList: View {
    let repo: RepoConfig
    let path: String

    @State private var entries: [RepoEntry] = []
    @State private var loading = true
    @State private var error: String?
    @State private var showAdd = false
    @State private var searchText = ""

    private var filteredEntries: [RepoEntry] {
        let trimmed = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return entries }
        return entries.filter { $0.name.localizedCaseInsensitiveContains(trimmed) }
    }

    var body: some View {
        List {
            if loading {
                HStack { ProgressView(); Text("Loading…").foregroundStyle(.secondary) }
                    .appListRowBackground()
            } else if let error {
                Text(error).foregroundStyle(.red)
                    .appListRowBackground()
            } else {
                if filteredEntries.isEmpty {
                    Text("Empty folder").foregroundStyle(.secondary)
                        .appListRowBackground()
                }
                ForEach(filteredEntries) { entry in
                    if entry.type == .dir {
                        NavigationLink {
                            DirectoryList(repo: repo, path: entry.path)
                                .navigationTitle(entry.name)
                        } label: { row(entry) }
                        .appListRowBackground()
                    } else {
                        NavigationLink {
                            FileViewer(repo: repo, path: entry.path)
                        } label: { row(entry) }
                        .appListRowBackground()
                    }
                }
            }
        }
        .appBackground(.grouped)
        .searchable(text: $searchText, prompt: "Search files")
        .task { await load() }
        .refreshable { await load() }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { Haptics.tap(); showAdd = true } label: {
                    Image(systemName: "plus")
                }
                .accessibilityLabel("Add file")
            }
        }
        .sheet(isPresented: $showAdd) {
            AddFileSheet(repo: repo, directory: path) {
                Task { await load() }
            }
        }
    }

    private func row(_ entry: RepoEntry) -> some View {
        HStack(spacing: 12) {
            Image(systemName: entry.type == .dir ? "folder.fill" : Self.icon(for: entry.name))
                .font(.body)
                .foregroundStyle(entry.type == .dir ? AnyShapeStyle(Theme.brandGradient)
                                                     : AnyShapeStyle(Self.tint(for: entry.name)))
                .frame(width: 26)
            Text(entry.name)
                .fontWeight(entry.type == .dir ? .medium : .regular)
                .lineLimit(1)
            Spacer()
            if let size = entry.size, entry.type == .file {
                Text(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file))
                    .font(.caption).foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        }
        .padding(.vertical, 2)
    }

    /// SF Symbol per file extension — a quick visual cue while browsing.
    private static func icon(for name: String) -> String {
        switch (name as NSString).pathExtension.lowercased() {
        case "html", "htm": return "chevron.left.forwardslash.chevron.right"
        case "css": return "paintbrush"
        case "js", "ts", "swift", "json": return "curlybraces"
        case "md", "txt": return "doc.text"
        case "png", "jpg", "jpeg", "gif", "svg", "webp": return "photo"
        case "mp4", "mov": return "play.rectangle"
        case "pkg", "dmg", "zip": return "shippingbox"
        default: return "doc"
        }
    }

    private static func tint(for name: String) -> Color {
        switch (name as NSString).pathExtension.lowercased() {
        case "html", "htm": return .orange
        case "css": return .blue
        case "js", "ts", "swift", "json": return .yellow
        case "png", "jpg", "jpeg", "gif", "svg", "webp": return .pink
        case "mp4", "mov": return .purple
        case "pkg", "dmg", "zip": return .brown
        default: return .secondary
        }
    }

    private func load() async {
        loading = true; error = nil
        do { entries = try await GitHubClient(repo: repo).list(path: path) }
        catch { self.error = error.localizedDescription }
        loading = false
    }
}

struct FileViewer: View {
    let repo: RepoConfig
    let path: String

    @State private var content = ""
    @State private var loading = true
    @State private var error: String?
    @State private var editing = false

    var body: some View {
        ScrollView {
            if loading {
                ProgressView().padding()
            } else if let error {
                ContentUnavailableView {
                    Label("Couldn’t load file", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(error)
                } actions: {
                    Button("Try Again") { Task { await load() } }
                        .buttonStyle(.borderedProminent)
                        .tint(Theme.brand)
                }
                .padding(.top, 40)
            } else {
                Text(content)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
            }
        }
        .appBackground(.primary)
        .navigationTitle((path as NSString).lastPathComponent)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button {
                    Haptics.tap()
                    editing = true
                } label: {
                    Image(systemName: "pencil")
                }
                .accessibilityLabel("Edit file")
                .disabled(loading || error != nil)

                Button {
                    UIPasteboard.general.string = content
                    Haptics.success()
                } label: {
                    Image(systemName: "doc.on.doc")
                }
                .accessibilityLabel("Copy file contents")
                .disabled(content.isEmpty)
            }
        }
        .sheet(isPresented: $editing) {
            EditFileSheet(repo: repo, path: path, initialContent: content) { newContent in
                content = newContent
            }
        }
        .task { await load() }
    }

    private func load() async {
        loading = true; error = nil
        do { content = try await GitHubClient(repo: repo).read(path: path).content }
        catch { self.error = error.localizedDescription }
        loading = false
    }
}

struct CommitHistoryList: View {
    let repo: RepoConfig
    
    @EnvironmentObject var engine: AgentEngine
    @Environment(\.colorScheme) var colorScheme
    
    @State private var commits: [CommitEntry] = []
    @State private var loading = true
    @State private var error: String?
    
    var body: some View {
        List {
            if loading {
                HStack { ProgressView(); Text("Loading history…").foregroundStyle(.secondary) }
                    .appListRowBackground()
            } else if let error {
                Text(error).foregroundStyle(.red)
                    .appListRowBackground()
            } else if commits.isEmpty {
                Text("No commits found").foregroundStyle(.secondary)
                    .appListRowBackground()
            } else {
                ForEach(commits) { c in
                    HStack(alignment: .top, spacing: 12) {
                        if let urlString = c.avatarURL, let url = URL(string: urlString) {
                            AsyncImage(url: url) { phase in
                                switch phase {
                                case .success(let image):
                                    image.resizable().scaledToFill()
                                default:
                                    Image(systemName: "person.circle.fill").foregroundStyle(.secondary)
                                }
                            }
                            .frame(width: 34, height: 34)
                            .clipShape(Circle())
                        } else {
                            Image(systemName: "person.circle.fill")
                                .font(.system(size: 34))
                                .foregroundStyle(.secondary)
                        }
                        
                        VStack(alignment: .leading, spacing: 3) {
                            Text(c.message)
                                .font(.subheadline.weight(.semibold))
                                .lineLimit(2)
                            
                            HStack(spacing: 6) {
                                Text(c.authorName)
                                    .font(.caption.weight(.medium))
                                    .foregroundStyle(.secondary)
                                Text("•")
                                    .font(.caption)
                                    .foregroundStyle(.tertiary)
                                Text(c.formattedDate)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        Text(c.shortSHA)
                            .font(.system(.caption2, design: .monospaced))
                            .padding(.horizontal, 6).padding(.vertical, 3)
                            .background(engine.oledMode && colorScheme == .dark ? Color(white: 0.12) : Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 6))
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 4)
                    .appListRowBackground()
                }
            }
        }
        .appBackground(.grouped)
        .task { await load() }
        .refreshable { await load() }
    }
    
    private func load() async {
        loading = true; error = nil
        do {
            commits = try await GitHubClient(repo: repo).commits()
        } catch {
            self.error = error.localizedDescription
        }
        loading = false
    }
}

struct HealthDashboardView: View {
    @EnvironmentObject var engine: AgentEngine
    @State private var diagnosis: GitHubClient.Diagnosis?
    @State private var diagnosing = false
    
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                // Connection Card
                VStack(alignment: .leading, spacing: 12) {
                    Label("GitHub Integration", systemImage: "link")
                        .font(.headline)
                        .foregroundStyle(Theme.brandGradient)
                    
                    if diagnosing {
                        HStack {
                            ProgressView()
                            Text("Diagnosing repository connection…")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    } else if let diagnosis {
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Image(systemName: diagnosis.ok ? "checkmark.circle.fill" : "xmark.circle.fill")
                                    .foregroundStyle(diagnosis.ok ? .green : .red)
                                Text(diagnosis.ok ? "System Online" : "Configuration Issue")
                                    .fontWeight(.bold)
                            }
                            Text(diagnosis.message)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    } else {
                        Text("No diagnostics run yet.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    
                    Button {
                        Task { await runDiagnostics() }
                    } label: {
                        Text("Run Diagnostics")
                            .font(.subheadline.weight(.semibold))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                            .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
                    }
                    .disabled(diagnosing)
                }
                .padding()
                .cardSurface()
                
                // Deployment details — provider-aware, no fabricated status.
                VStack(alignment: .leading, spacing: 12) {
                    Label(engine.activeWorkspace?.deployment.rawValue ?? "Deployment",
                          systemImage: "shippingbox")
                        .font(.headline)
                        .foregroundStyle(.blue)

                    VStack(alignment: .leading, spacing: 4) {
                        Text("Target Branch")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(engine.repo.branch)
                            .font(.subheadline.monospaced())
                            .fontWeight(.semibold)
                    }

                    Divider()

                    VStack(alignment: .leading, spacing: 4) {
                        Text("On commit")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        // Honest description of what a commit does for this host —
                        // not a fabricated "webhook active" indicator.
                        Text(engine.activeWorkspace?.deployment.redeployNote ?? "Pushes to your repo.")
                            .font(.subheadline)
                    }

                    // Show a live-site link only if the workspace actually has one
                    // configured (was previously a hardcoded mesut.uk for everyone).
                    if let urlString = engine.activeWorkspace?.deploymentConfig["liveURL"]
                        ?? engine.activeWorkspace?.deploymentConfig["url"],
                       let url = URL(string: urlString) {
                        Divider()
                        Link(destination: url) {
                            Label("Visit Live Site", systemImage: "arrow.up.right.app")
                                .font(.subheadline.weight(.semibold))
                        }
                    }
                }
                .padding()
                .cardSurface()
                
                // Model Config & Token Pricing
                VStack(alignment: .leading, spacing: 12) {
                    Label("Model Cost Metrics", systemImage: "creditcard.fill")
                        .font(.headline)
                        .foregroundStyle(.purple)
                    
                    let pid = engine.activeProviderID
                    if pid == "copilot" {
                        Text("Copilot usage is fully covered by your subscription plan.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    } else {
                        let prompt = engine.promptTokens(for: pid)
                        let completion = engine.completionTokens(for: pid)
                        let cost = engine.estimatedCost(for: pid)
                        
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text("Provider")
                                Spacer()
                                Text(engine.activeProvider.displayName).fontWeight(.semibold)
                            }
                            HStack {
                                Text("Prompt Tokens")
                                Spacer()
                                Text("\(prompt)").monospacedDigit()
                            }
                            HStack {
                                Text("Completion Tokens")
                                Spacer()
                                Text("\(completion)").monospacedDigit()
                            }
                            Divider()
                            HStack {
                                Text("Accrued Session Cost")
                                    .fontWeight(.bold)
                                Spacer()
                                Text(String(format: "$%.4f", cost))
                                    .font(.headline)
                                    .monospacedDigit()
                                    .foregroundStyle(Theme.brand)
                            }
                        }
                        .font(.subheadline)
                    }
                }
                .padding()
                .cardSurface()
            }
            .padding()
        }
        .appBackground(.primary)
        .task {
            await runDiagnostics()
        }
    }
    
    private func runDiagnostics() async {
        diagnosing = true
        let client = GitHubClient(repo: engine.repo)
        diagnosis = await client.diagnose()
        diagnosing = false
    }
}
