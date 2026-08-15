import SwiftUI
import PhotosUI
import UniformTypeIdentifiers

/// Add a file to the repo in `directory`: a new text file, a photo from the
/// library, or any imported file. Commits directly (this is a manual action).
struct AddFileSheet: View {
    let repo: RepoConfig
    let directory: String          // "" for repo root
    var onDone: () -> Void

    @Environment(\.dismiss) private var dismiss

    enum Kind: String, CaseIterable, Identifiable {
        case text = "Text file", photo = "Photo", file = "File"
        var id: String { rawValue }
        var icon: String {
            switch self {
            case .text: return "doc.text"
            case .photo: return "photo"
            case .file: return "folder"
            }
        }
    }

    @State private var kind: Kind = .text
    @State private var filename = ""
    @State private var textContent = ""
    @State private var payload: Data?          // for photo/file
    @State private var photoItem: PhotosPickerItem?
    @State private var showFileImporter = false
    @State private var commitMessage = ""
    @State private var uploading = false
    @State private var error: String?

    private var targetPath: String { directory.isEmpty ? filename : "\(directory)/\(filename)" }

    /// Reject path separators / `..` components in the filename so a mistyped
    /// name cannot commit outside the chosen directory. `foo..bar.js` is OK.
    private var isFilenameSafe: Bool {
        let name = filename.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return false }
        if name.contains("/") || name.contains("\\") { return false }
        if AgentEngine.pathContainsDotDotComponent(name) { return false }
        return true
    }

    private var canCommit: Bool {
        guard isFilenameSafe, !uploading else { return false }
        switch kind {
        case .text: return true
        case .photo, .file: return payload != nil
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Type", selection: $kind) {
                        ForEach(Kind.allCases) { k in
                            Label(k.rawValue, systemImage: k.icon).tag(k)
                        }
                    }
                    .pickerStyle(.segmented)
                }

                Section("Destination") {
                    LabeledContent("Folder", value: directory.isEmpty ? "/ (root)" : "/\(directory)")
                    TextField("File name (e.g. logo.png)", text: $filename)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }

                switch kind {
                case .text:
                    Section("Contents") {
                        TextEditor(text: $textContent)
                            .frame(minHeight: 160)
                            .font(.system(.body, design: .monospaced))
                    }
                case .photo:
                    Section("Image") { photoPicker }
                case .file:
                    Section("File") { fileImporterRow }
                }

                Section("Commit message") {
                    TextField("Add \(filename.isEmpty ? "file" : filename)", text: $commitMessage)
                }

                if let error {
                    Section { Text(error).foregroundStyle(.red) }
                }
            }
            .appListRowBackground()
            .appBackground(.grouped)
            .navigationTitle("Add File")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        Task { await commit() }
                    } label: {
                        if uploading { ProgressView() } else { Text("Add").bold() }
                    }
                    .disabled(!canCommit)
                }
            }
            .fileImporter(isPresented: $showFileImporter,
                          allowedContentTypes: [.item],
                          allowsMultipleSelection: false) { handleImport($0) }
        }
    }

    // MARK: - Pickers

    private var photoPicker: some View {
        VStack(alignment: .leading, spacing: 10) {
            PhotosPicker(selection: $photoItem, matching: .images) {
                Label(payload == nil ? "Choose Photo" : "Change Photo", systemImage: "photo.on.rectangle")
            }
            if let payload, let ui = UIImage(data: payload) {
                Image(uiImage: ui)
                    .resizable().scaledToFit()
                    .frame(maxHeight: 160)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                Text(ByteCountFormatter.string(fromByteCount: Int64(payload.count), countStyle: .file))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .onChange(of: photoItem) { _, item in
            Task {
                if let data = try? await item?.loadTransferable(type: Data.self) {
                    payload = data
                    if filename.isEmpty { filename = "image.png" }
                }
            }
        }
    }

    private var fileImporterRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                showFileImporter = true
            } label: {
                Label(payload == nil ? "Choose File" : "Change File", systemImage: "folder")
            }
            if let payload {
                Text("\(ByteCountFormatter.string(fromByteCount: Int64(payload.count), countStyle: .file)) selected")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func handleImport(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            do {
                payload = try Data(contentsOf: url)
                if filename.isEmpty { filename = url.lastPathComponent }
            } catch {
                self.error = error.localizedDescription
            }
        case .failure(let err):
            self.error = err.localizedDescription
        }
    }

    // MARK: - Commit

    private func commit() async {
        uploading = true; error = nil
        defer { uploading = false }
        guard isFilenameSafe else {
            error = "Filename cannot contain path separators or '..'."
            return
        }
        let client = GitHubClient(repo: repo)
        let message = commitMessage.isEmpty ? "Add \(filename)" : commitMessage
        let sha = await client.fileSHA(path: targetPath)   // overwrite if it already exists
        do {
            switch kind {
            case .text:
                _ = try await client.write(path: targetPath, content: textContent, message: message, sha: sha)
            case .photo, .file:
                guard let payload else { return }
                _ = try await client.upload(path: targetPath, data: payload, message: message, sha: sha)
            }
            Haptics.success()
            onDone()
            dismiss()
        } catch {
            self.error = error.localizedDescription
            Haptics.error()
        }
    }
}
