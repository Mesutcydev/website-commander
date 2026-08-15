import SwiftUI

struct EditFileSheet: View {
    let repo: RepoConfig
    let path: String
    let initialContent: String
    var onSaved: (String) -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var content = ""
    @State private var commitMessage = ""
    @State private var saving = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("Path") {
                    Text(path).font(.subheadline.monospaced()).foregroundStyle(.secondary)
                }

                Section("Contents") {
                    TextEditor(text: $content)
                        .frame(minHeight: 280)
                        .font(.system(.body, design: .monospaced))
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                }

                Section("Commit message") {
                    TextField("Update \((path as NSString).lastPathComponent)", text: $commitMessage)
                }

                if let error {
                    Section {
                        Text(error).foregroundStyle(.red)
                    }
                }
            }
            .appListRowBackground()
            .appBackground(.grouped)
            .navigationTitle("Edit File")
            .navigationBarTitleDisplayMode(.inline)
            .onAppear {
                content = initialContent
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        Task { await save() }
                    } label: {
                        if saving {
                            ProgressView()
                        } else {
                            Text("Save").bold()
                        }
                    }
                    .disabled(content == initialContent || saving)
                }
            }
        }
    }

    private func save() async {
        saving = true; error = nil
        defer { saving = false }
        let client = GitHubClient(repo: repo)
        let message = commitMessage.isEmpty ? "Update \((path as NSString).lastPathComponent)" : commitMessage
        do {
            let sha = try await client.read(path: path).sha
            _ = try await client.write(path: path, content: content, message: message, sha: sha)
            Haptics.success()
            onSaved(content)
            dismiss()
        } catch {
            self.error = error.localizedDescription
            Haptics.error()
        }
    }
}
