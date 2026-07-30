import SwiftUI

// MARK: - On-Device tab

/// Honest on-device panel. There is no downloadable catalog here: Apple's
/// Foundation Models is a single, fixed system model that is either present
/// (macOS 26 + Apple Intelligence enabled) or not. We surface that truth and a
/// single "prefer on-device" switch — never a fake model list.
struct OnDeviceSettingsTab: View {
    @EnvironmentObject var settings: SettingsStore

    private var available: Bool {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) { return OnDeviceProvider.isAvailable }
        #endif
        return false
    }

    private var reason: String {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            return available
                ? "Apple Intelligence is active on this Mac. On-device inference is ready."
                : "macOS 26 is present but Apple Intelligence isn't enabled. Turn it on in System Settings → Apple Intelligence & Siri."
        } else {
            return "On-device inference needs macOS 26 (or later) with Apple Intelligence."
        }
        #else
        return "This build wasn't compiled with the Foundation Models framework."
        #endif
    }

    var body: some View {
        Form {
            Section {
                Label {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(available ? "Available" : "Unavailable")
                            .font(.body.weight(.semibold))
                        Text(reason).font(.caption).foregroundStyle(.secondary)
                    }
                } icon: {
                    Image(systemName: available ? "checkmark.seal.fill" : "xmark.seal.fill")
                        .foregroundStyle(available ? Theme.success : Theme.warning)
                }
            }
            Section {
                Toggle("Prefer on-device when available", isOn: $settings.preferOnDevice)
                    .disabled(!available)
                Text("When on, the agent runs entirely on this Mac — no network, no API key, no usage cost. Your cloud provider is used again the moment you switch this off.")
                    .font(.caption).foregroundStyle(.secondary)
            } header: {
                Text("Routing")
            }
            Section {
                Label("On-device models are text-only. The agent's live-page screenshot falls back to a text snapshot when running on-device.",
                      systemImage: "eye.slash")
                    .font(.caption).foregroundStyle(.secondary)
                Label("There is no model to download or pick: Foundation Models is a single system model managed by macOS.",
                      systemImage: "info.circle")
                    .font(.caption).foregroundStyle(.secondary)
            } header: {
                Text("Good to know")
            }
        }
        .formStyle(.grouped)
        .padding(Theme.Space.l)
    }
}
