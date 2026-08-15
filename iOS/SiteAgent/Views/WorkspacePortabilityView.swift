import SwiftUI
import UniformTypeIdentifiers
import WebKit

struct WorkspacePortabilityView: View {
    @EnvironmentObject private var engine: AgentEngine
    @StateObject private var store = WorkspacePortabilityStore.shared
    @StateObject private var auditStore = ConfigurationAuditStore.shared
    @StateObject private var iCloudSync = ICloudSyncCoordinator.shared
    @State private var showFileImporter = false
    @State private var showFolderImporter = false
    @State private var showConfigurationImporter = false
    @State private var showConfigurationExporter = false
    @State private var configurationDocument: JSONExportDocument?
    @State private var selectedAsset: SharedAsset?
    @State private var statusMessage: String?

    var body: some View {
        List {
            Section {
                Toggle("Record-level iCloud Sync (Beta)", isOn: Binding(
                    get: { iCloudSync.isEnabled },
                    set: { iCloudSync.isEnabled = $0 }
                ))
                HStack {
                    Label(iCloudSync.status, systemImage: "icloud")
                    Spacer()
                    if iCloudSync.isEnabled {
                        Button("Sync Now") { iCloudSync.syncNow() }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                    }
                }
                .font(.subheadline)
            } header: {
                Text("Continuity")
            } footer: {
                Text("Syncs independent workspace, conversation, pin, and secret-free configuration records. API keys and tokens stay in this device's Keychain; oversized records stay local with a visible warning.")
            }
            SharedAssetSection(
                assets: store.assets,
                onImport: { showFileImporter = true },
                onPreview: { selectedAsset = $0 },
                onDelete: delete
            )
            MountedFoldersSection(
                folders: store.mountedFolders,
                onMount: { showFolderImporter = true },
                onUnmount: store.unmountFolder
            )
            ProviderPortabilitySection(
                statusMessage: statusMessage,
                auditEntries: auditStore.entries,
                onExport: exportConfiguration,
                onImport: { showConfigurationImporter = true },
                onRevert: revertConfiguration
            )
        }
        .navigationTitle("Workspace & Portability")
        .navigationBarTitleDisplayMode(.inline)
        .fileImporter(
            isPresented: $showFileImporter,
            allowedContentTypes: [.item],
            allowsMultipleSelection: true,
            onCompletion: importFiles
        )
        .fileImporter(
            isPresented: $showFolderImporter,
            allowedContentTypes: [.folder],
            allowsMultipleSelection: false,
            onCompletion: mountFolder
        )
        .fileImporter(
            isPresented: $showConfigurationImporter,
            allowedContentTypes: [.json],
            allowsMultipleSelection: false,
            onCompletion: importConfiguration
        )
        .fileExporter(
            isPresented: $showConfigurationExporter,
            document: configurationDocument,
            contentType: .json,
            defaultFilename: "WebsiteCommander-Provider-Configuration"
        ) { result in
            switch result {
            case .success:
                statusMessage = "Exported without API keys or tokens."
            case .failure(let error):
                statusMessage = error.localizedDescription
            }
        }
        .sheet(item: $selectedAsset) { asset in
            ResourcePreviewView(asset: asset)
        }
        .onAppear {
            store.refreshAssets()
        }
    }

    private func importFiles(_ result: Result<[URL], Error>) {
        do {
            for url in try result.get() {
                try store.importFile(from: url)
            }
            statusMessage = "Imported files into Website Commander Shared."
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    private func mountFolder(_ result: Result<[URL], Error>) {
        do {
            guard let url = try result.get().first else { return }
            try store.mountFolder(url)
            statusMessage = "Mounted \(url.lastPathComponent)."
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    private func delete(_ asset: SharedAsset) {
        do {
            try store.deleteAsset(asset)
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    private func exportConfiguration() {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(engine.providerConfigurationArchive())
            configurationDocument = JSONExportDocument(data: data)
            showConfigurationExporter = true
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    private func importConfiguration(_ result: Result<[URL], Error>) {
        do {
            guard let url = try result.get().first else { return }
            let scoped = url.startAccessingSecurityScopedResource()
            defer {
                if scoped { url.stopAccessingSecurityScopedResource() }
            }
            let data = try Data(contentsOf: url)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let before = engine.providerConfigurationArchive()
            let imported = try decoder.decode(ProviderConfigurationArchive.self, from: data)
            try engine.applyProviderConfiguration(imported)
            auditStore.record(
                source: url.lastPathComponent,
                before: before,
                after: engine.providerConfigurationArchive()
            )
            iCloudSync.pushConfiguration(engine.providerConfigurationArchive())
            statusMessage = "Imported provider settings. Secrets remain unchanged."
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    private func revertConfiguration(_ entry: ConfigurationAuditEntry) {
        do {
            try engine.applyProviderConfiguration(entry.before)
            auditStore.remove(entry.id)
            statusMessage = "Reverted settings imported from \(entry.source)."
            Haptics.success()
        } catch {
            statusMessage = error.localizedDescription
            Haptics.error()
        }
    }
}

private struct SharedAssetSection: View {
    let assets: [SharedAsset]
    let onImport: () -> Void
    let onPreview: (SharedAsset) -> Void
    let onDelete: (SharedAsset) -> Void

    var body: some View {
        Section {
            Button(action: onImport) {
                Label("Import Shared Files", systemImage: "square.and.arrow.down")
            }
            if assets.isEmpty {
                ContentUnavailableView(
                    "No Shared Files",
                    systemImage: "folder",
                    description: Text("Imported files persist across conversations.")
                )
            } else {
                ForEach(assets) { asset in
                    Button {
                        onPreview(asset)
                    } label: {
                        HStack {
                            Label(asset.name, systemImage: "doc")
                                .lineLimit(1)
                            Spacer()
                            Text(
                                ByteCountFormatter.string(
                                    fromByteCount: asset.byteCount,
                                    countStyle: .file
                                )
                            )
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        }
                    }
                    .swipeActions {
                        Button(role: .destructive) {
                            onDelete(asset)
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                    }
                }
            }
        } header: {
            Text("Shared Files")
        } footer: {
            Text("Files are copied into a persistent Website Commander folder and can be previewed before attaching or staging.")
        }
    }
}

private struct MountedFoldersSection: View {
    let folders: [MountedFolder]
    let onMount: () -> Void
    let onUnmount: (UUID) -> Void

    var body: some View {
        Section {
            Button(action: onMount) {
                Label("Mount External Folder", systemImage: "folder.badge.plus")
            }
            ForEach(folders) { folder in
                HStack {
                    Label(folder.displayName, systemImage: "externaldrive")
                    Spacer()
                    Button("Unmount", role: .destructive) {
                        onUnmount(folder.id)
                    }
                    .font(.caption)
                }
            }
        } header: {
            Text("External Folders")
        } footer: {
            Text("Folder access is stored as a security-scoped bookmark. Website Commander never uploads folder contents automatically.")
        }
    }
}

private struct ProviderPortabilitySection: View {
    let statusMessage: String?
    let auditEntries: [ConfigurationAuditEntry]
    let onExport: () -> Void
    let onImport: () -> Void
    let onRevert: (ConfigurationAuditEntry) -> Void

    var body: some View {
        Section {
            Button(action: onExport) {
                Label("Export Provider Configuration", systemImage: "square.and.arrow.up")
            }
            Button(action: onImport) {
                Label("Import Provider Configuration", systemImage: "square.and.arrow.down")
            }
            ForEach(auditEntries.prefix(3)) { entry in
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Imported \(entry.source)")
                            .font(.subheadline)
                            .lineLimit(1)
                        Text(entry.createdAt, style: .relative)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Revert") { onRevert(entry) }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                }
            }
            if let statusMessage {
                Text(statusMessage)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("Provider Portability")
        } footer: {
            Text("Exports include provider, model, routing, and behavior settings. API keys, OAuth tokens, and GitHub credentials are technically excluded.")
        }
    }
}

struct JSONExportDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }
    var data: Data

    init(data: Data = Data()) {
        self.data = data
    }

    init(configuration: ReadConfiguration) throws {
        data = configuration.file.regularFileContents ?? Data()
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}

struct ResourcePreviewView: View {
    @Environment(\.dismiss) private var dismiss
    let asset: SharedAsset

    var body: some View {
        NavigationStack {
            ResourcePreviewContent(url: asset.url)
                .navigationTitle(asset.name)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("Done") { dismiss() }
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        ShareLink(item: asset.url)
                    }
                }
        }
    }
}

private struct ResourcePreviewContent: View {
    let url: URL

    var body: some View {
        let ext = url.pathExtension.lowercased()
        if ["png", "jpg", "jpeg", "gif", "webp"].contains(ext),
           let data = try? Data(contentsOf: url),
           let image = UIImage(data: data) {
            ScrollView([.horizontal, .vertical]) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .padding()
            }
        } else if ["html", "htm"].contains(ext) {
            LocalHTMLPreview(url: url)
        } else if let text = try? String(contentsOf: url, encoding: .utf8) {
            ScrollView {
                if ["md", "markdown"].contains(ext) {
                    Text(.init(text))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding()
                } else {
                    Text(text)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding()
                }
            }
        } else {
            ContentUnavailableView(
                "Preview Unavailable",
                systemImage: "doc.questionmark",
                description: Text("Use Share to open this file in a compatible app.")
            )
        }
    }
}

private struct LocalHTMLPreview: UIViewRepresentable {
    let url: URL

    func makeUIView(context: Context) -> WKWebView {
        WKWebView()
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        webView.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
    }
}
