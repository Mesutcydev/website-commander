import SwiftUI
import PhotosUI
import UniformTypeIdentifiers
import UIKit

struct ImageStudioView: View {
    let onAttach: (Attachment) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var mode: ImageCreationMode = .generate
    @State private var prompt = ""
    @State private var filename = "generated-asset.png"
    @State private var altText = ""
    @State private var size: ImageOutputSize = .landscape
    @State private var quality: ImageOutputQuality = .medium
    @State private var sourceItem: PhotosPickerItem?
    @State private var source: Attachment?
    @State private var output: Data?
    @State private var isWorking = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Mode", selection: $mode) {
                        ForEach(ImageCreationMode.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)

                    if mode == .edit {
                        PhotosPicker(selection: $sourceItem, matching: .images) {
                            Label(source == nil ? "Choose source image" : "Replace source image",
                                  systemImage: "photo.badge.plus")
                        }
                        if let source, let image = UIImage(data: source.data) {
                            Image(uiImage: image)
                                .resizable()
                                .scaledToFit()
                                .frame(maxHeight: 180)
                                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        }
                    }
                } header: {
                    Text("Source")
                } footer: {
                    Text("Generation uses GPT Image 2. Edits preserve the selected source with the OpenAI Images Edits API.")
                }

                Section("Instructions") {
                    TextField(
                        mode == .generate
                            ? "Describe the website asset to create"
                            : "Describe how the source should change",
                        text: $prompt,
                        axis: .vertical
                    )
                    .lineLimit(4...10)

                    Picker("Canvas", selection: $size) {
                        ForEach(ImageOutputSize.allCases) {
                            Text("\($0.label) · \($0.rawValue)").tag($0)
                        }
                    }
                    Picker("Quality", selection: $quality) {
                        ForEach(ImageOutputQuality.allCases) {
                            Text($0.rawValue.capitalized).tag($0)
                        }
                    }
                }

                Section("Website metadata") {
                    TextField("Filename", text: $filename)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    TextField("Alt text", text: $altText, axis: .vertical)
                        .lineLimit(2...4)
                }

                if let output, let image = UIImage(data: output) {
                    Section("Result") {
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFit()
                            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        Button {
                            attach(output)
                        } label: {
                            Label("Add to Chat", systemImage: "paperclip")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                    }
                }
            }
            .navigationTitle("Image Studio")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    if isWorking {
                        ProgressView()
                    } else {
                        Button(output == nil ? "Create" : "Recreate") {
                            Task { await createImage() }
                        }
                        .disabled(!canCreate)
                    }
                }
            }
            .onChange(of: sourceItem) { _, item in
                guard let item else { return }
                Task { await loadSource(item) }
            }
            .alert("Image creation failed", isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(errorMessage ?? "")
            }
        }
    }

    private var canCreate: Bool {
        !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && (mode == .generate || source != nil)
            && !isWorking
    }

    private func loadSource(_ item: PhotosPickerItem) async {
        guard let data = try? await item.loadTransferable(type: Data.self) else { return }
        let type = item.supportedContentTypes.first ?? .png
        source = Attachment(
            filename: "source.\(type.preferredFilenameExtension ?? "png")",
            mimeType: type.preferredMIMEType ?? "image/png",
            data: data
        )
    }

    private func createImage() async {
        isWorking = true
        defer { isWorking = false }
        do {
            output = try await OpenAIImageService.create(
                mode: mode,
                prompt: prompt.trimmingCharacters(in: .whitespacesAndNewlines),
                size: size,
                quality: quality,
                source: source
            )
            Haptics.success()
        } catch {
            errorMessage = error.localizedDescription
            Haptics.error()
        }
    }

    private func attach(_ data: Data) {
        let base = filename.trimmingCharacters(in: .whitespacesAndNewlines)
        let safe = base.isEmpty ? "generated-asset.png" : base
        onAttach(Attachment(filename: safe.hasSuffix(".png") ? safe : "\(safe).png",
                            mimeType: "image/png",
                            data: data))
        if !altText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            UIPasteboard.general.string = altText
        }
        Haptics.success()
        dismiss()
    }
}
