import SwiftUI

struct ExtensibilityView: View {
    var body: some View {
        List {
            Section {
                NavigationLink {
                    SiteProfileView()
                } label: {
                    Label("Site Profile", systemImage: "person.text.rectangle")
                }
                NavigationLink {
                    MCPServersView()
                } label: {
                    Label("MCP Integrations", systemImage: "point.3.connected.trianglepath.dotted")
                }
                NavigationLink {
                    WorkspaceSkillsView()
                } label: {
                    Label("Workspace Skills", systemImage: "wand.and.stars")
                }
            } header: {
                Text("Workspace Intelligence")
            } footer: {
                Text("Site Profiles are workspace-scoped. MCP tools are namespaced and external writes remain disabled unless you explicitly allow them per server.")
            }

            Section {
                DeepLinkExampleRow(
                    title: "Open Chat",
                    value: "siteagent://chat?workspace=MySite&prompt=Review%20the%20homepage"
                )
                DeepLinkExampleRow(
                    title: "Open Preview",
                    value: "siteagent://preview?workspace=MySite"
                )
            } header: {
                Text("Automation Links")
            } footer: {
                Text("Deep links may select a workspace and prefill a prompt, but they never contain or modify secrets.")
            }
        }
        .navigationTitle("Extensibility")
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct WorkspaceSkillsView: View {
    @StateObject private var store = WorkspaceSkillStore.shared
    @State private var editingSkill: WorkspaceSkill?
    @State private var showAdd = false

    var body: some View {
        List {
            ForEach(store.skills) { skill in
                VStack(alignment: .leading, spacing: 8) {
                    Toggle(
                        isOn: Binding(
                            get: { skill.isEnabled },
                            set: { enabled in
                                var updated = skill
                                updated.isEnabled = enabled
                                store.save(updated)
                            }
                        )
                    ) {
                        Text(skill.name)
                            .font(.headline)
                    }
                    Text(skill.summary)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    HStack {
                        Text("Priority \(skill.priority)")
                        Spacer()
                        Button("Edit") { editingSkill = skill }
                    }
                    .font(.caption)
                }
                .padding(.vertical, 4)
                .swipeActions {
                    Button(role: .destructive) {
                        store.delete(skill)
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                }
            }
        }
        .navigationTitle("Workspace Skills")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showAdd = true
                } label: {
                    Image(systemName: "plus")
                }
                .accessibilityLabel("Add workspace skill")
            }
        }
        .sheet(isPresented: $showAdd) {
            WorkspaceSkillEditor(skill: nil)
        }
        .sheet(item: $editingSkill) { skill in
            WorkspaceSkillEditor(skill: skill)
        }
    }
}

private struct WorkspaceSkillEditor: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var store = WorkspaceSkillStore.shared
    @State private var draft: WorkspaceSkill

    init(skill: WorkspaceSkill?) {
        _draft = State(initialValue: skill ?? WorkspaceSkill(
            name: "",
            summary: "",
            instructions: ""
        ))
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Skill") {
                    TextField("Name", text: $draft.name)
                    TextField("Summary", text: $draft.summary, axis: .vertical)
                    TextField("Agent instructions", text: $draft.instructions, axis: .vertical)
                        .lineLimit(4...12)
                }
                Section("Behavior") {
                    Toggle("Enabled", isOn: $draft.isEnabled)
                    Stepper("Priority \(draft.priority)", value: $draft.priority, in: 0...100, step: 10)
                }
            }
            .navigationTitle("Workspace Skill")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Save") {
                        store.save(draft)
                        dismiss()
                    }
                    .disabled(
                        draft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            || draft.instructions.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    )
                }
            }
        }
    }
}

private struct DeepLinkExampleRow: View {
    let title: LocalizedStringKey
    let value: String

    var body: some View {
        Button {
            UIPasteboard.general.string = value
            Haptics.success()
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .foregroundStyle(.primary)
                Text(value)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
    }
}

struct MCPServersView: View {
    @StateObject private var store = MCPStore.shared
    @State private var showAddServer = false
    @State private var editingServer: MCPServerConfiguration?
    @State private var busyServerID: UUID?
    @State private var errorMessage: String?

    var body: some View {
        List {
            Section {
                if store.servers.isEmpty {
                    ContentUnavailableView(
                        "No MCP Servers",
                        systemImage: "point.3.connected.trianglepath.dotted",
                        description: Text("Add a trusted HTTPS MCP endpoint to discover its tools.")
                    )
                } else {
                    ForEach(store.servers) { server in
                        MCPServerRow(
                            server: server,
                            toolCount: store.tools.filter { $0.serverID == server.id }.count,
                            isBusy: busyServerID == server.id,
                            onToggle: { enabled in setEnabled(enabled, server: server) },
                            onRefresh: { refresh(server) },
                            onEdit: { editingServer = server },
                            onDelete: { store.delete(server) }
                        )
                    }
                }
            } footer: {
                Text("Only HTTPS endpoints are accepted. Authentication stays in Keychain, responses are size-limited, and write-like tools require explicit permission.")
            }

            if !store.activity.isEmpty {
                Section("Recent Activity") {
                    ForEach(store.activity, id: \.self) { entry in
                        Text(entry)
                            .font(.footnote)
                    }
                }
            }
        }
        .navigationTitle("MCP Integrations")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showAddServer = true
                } label: {
                    Image(systemName: "plus")
                }
                .accessibilityLabel("Add MCP server")
            }
        }
        .sheet(isPresented: $showAddServer) {
            MCPServerEditor(server: nil)
        }
        .sheet(item: $editingServer) { server in
            MCPServerEditor(server: server)
        }
        .alert("MCP Error", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private func setEnabled(_ enabled: Bool, server: MCPServerConfiguration) {
        var updated = server
        updated.isEnabled = enabled
        do {
            try store.save(updated, token: nil)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func refresh(_ server: MCPServerConfiguration) {
        busyServerID = server.id
        Task {
            defer { busyServerID = nil }
            do {
                try await store.refreshTools(for: server)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}

private struct MCPServerRow: View {
    let server: MCPServerConfiguration
    let toolCount: Int
    let isBusy: Bool
    let onToggle: (Bool) -> Void
    let onRefresh: () -> Void
    let onEdit: () -> Void
    let onDelete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle(isOn: Binding(get: { server.isEnabled }, set: onToggle)) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(server.name)
                        .font(.headline)
                    Text(server.endpoint.host ?? server.endpoint.absoluteString)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            HStack {
                Label("\(toolCount) tools", systemImage: "hammer")
                if server.allowsWriteTools {
                    Label("Writes allowed", systemImage: "exclamationmark.shield")
                        .foregroundStyle(.orange)
                } else {
                    Label("Read-only", systemImage: "lock")
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .font(.caption)
            HStack {
                Button("Refresh Tools", action: onRefresh)
                    .disabled(isBusy || !server.isEnabled)
                Spacer()
                Button("Edit", action: onEdit)
                Button("Delete", role: .destructive, action: onDelete)
            }
            .font(.caption.weight(.semibold))
            if isBusy {
                ProgressView()
                    .controlSize(.small)
            }
        }
        .padding(.vertical, 4)
    }
}

private struct MCPServerEditor: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var store = MCPStore.shared
    @State private var draft: MCPServerConfiguration
    @State private var endpointText: String
    @State private var token: String
    @State private var errorMessage: String?

    init(server: MCPServerConfiguration?) {
        let value = server ?? MCPServerConfiguration(
            name: "",
            endpoint: SiteAgentURL.constant("https://example.com/mcp")
        )
        _draft = State(initialValue: value)
        _endpointText = State(initialValue: server?.endpoint.absoluteString ?? "")
        _token = State(initialValue: Keychain.get(Keychain.mcpToken(serverID: value.id)) ?? "")
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Server") {
                    TextField("Name", text: $draft.name)
                    TextField("HTTPS endpoint", text: $endpointText)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    SecureField("Bearer token (optional)", text: $token)
                }
                Section {
                    Toggle("Enabled", isOn: $draft.isEnabled)
                    Toggle("Allow external write tools", isOn: $draft.allowsWriteTools)
                    Stepper(
                        "Timeout: \(draft.timeoutSeconds, format: .number.precision(.fractionLength(0))) seconds",
                        value: $draft.timeoutSeconds,
                        in: 5...60,
                        step: 5
                    )
                } header: {
                    Text("Permissions")
                } footer: {
                    Text("Write permission applies only to tools that are not marked or inferred as read-only. Website Commander still records every call in chat.")
                }
                if let errorMessage {
                    Section {
                        Text(errorMessage)
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("MCP Server")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Save") { save() }
                }
            }
        }
    }

    private func save() {
        do {
            guard let endpoint = URL(string: endpointText) else {
                throw MCPError.invalidConfiguration("Enter a valid endpoint URL.")
            }
            draft.endpoint = endpoint
            try store.save(draft, token: token)
            Haptics.success()
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
