import SwiftUI

struct CustomViewportSheet: View {
    @Binding var width: Double
    @Binding var height: Double
    @Binding var userAgent: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section("Viewport") {
                    HStack {
                        Text("Width")
                        Spacer()
                        TextField("430", value: $width, format: .number)
                            .keyboardType(.numberPad)
                            .multilineTextAlignment(.trailing)
                            .frame(width: 100)
                    }
                    HStack {
                        Text("Height")
                        Spacer()
                        TextField("932", value: $height, format: .number)
                            .keyboardType(.numberPad)
                            .multilineTextAlignment(.trailing)
                            .frame(width: 100)
                    }
                }

                Section {
                    TextField("Use desktop default", text: $userAgent, axis: .vertical)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .lineLimit(3...6)
                } header: {
                    Text("User agent override")
                } footer: {
                    Text("Leave blank to use the system desktop user agent. Website Commander warns visually by showing “Custom UA” above the preview whenever an override is active.")
                }
            }
            .navigationTitle("Custom Viewport")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        width = min(max(width, 240), 2560)
                        height = min(max(height, 320), 2560)
                        dismiss()
                    }
                }
            }
        }
    }
}
