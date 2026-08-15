import SwiftUI

struct WizardAssistantStep: View {
    @ObservedObject var coordinator: ConnectWebsiteWizardCoordinator
    @EnvironmentObject var engine: AgentEngine

    private var providers: [(id: String, title: String, subtitle: String, oauth: Bool)] {
        var rows: [(id: String, title: String, subtitle: String, oauth: Bool)] = [
            ("copilot", "GitHub Copilot", "Uses your Copilot subscription", true),
            ("anthropic", "Claude", "Sign in with Anthropic", true),
            ("openai", "ChatGPT", "Sign in with OpenAI", true),
            ("gemini", "Gemini", "Configure later in Workspace", false),
        ]
        #if APPLE_FM
        if AppleModels.onDeviceAvailable {
            rows.append(("ondevice", "On-device", AppleModels.onDeviceStatus, false))
        }
        #endif
        return rows
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Choose AI")
                .font(.title2.bold())
            Text("Pick an assistant. Prefer sign-in where available — API keys stay under Advanced.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(spacing: 0) {
                ForEach(Array(providers.enumerated()), id: \.element.id) { index, item in
                    if index > 0 { Divider() }
                    let locked = !IAPManager.shared.isPro && AgentEngine.proOnlyProviderIDs.contains(item.id)
                    Button {
                        Haptics.tap()
                        guard !locked else { return }
                        coordinator.selectedProviderID = item.id
                        engine.activeProviderID = item.id
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.title)
                                    .font(.headline)
                                    .foregroundStyle(Theme.t1)
                                Text(item.subtitle)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            if locked {
                                Image(systemName: "lock.fill").foregroundStyle(.yellow)
                            } else if coordinator.selectedProviderID == item.id {
                                Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.brand)
                            }
                        }
                        .padding(.vertical, 12)
                        .contentShape(Rectangle())
                        .frame(minHeight: 44)
                    }
                    .buttonStyle(.plain)
                    .disabled(locked)
                    .accessibilityAddTraits(coordinator.selectedProviderID == item.id ? .isSelected : [])
                }
            }
            .padding(.horizontal, 14)
            .commandCard()

            if coordinator.selectedProviderID == "copilot" || coordinator.selectedProviderID == "anthropic" || coordinator.selectedProviderID == "openai" {
                Text("Complete sign-in from Workspace → Assistant after finishing if you aren’t already connected.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if case .message(let text) = coordinator.issue {
                Text(text).font(.footnote).foregroundStyle(.red)
            } else if case .duplicateWorkspace = coordinator.issue {
                VStack(alignment: .leading, spacing: 10) {
                    Text(coordinator.issue?.text ?? "")
                        .font(.footnote.weight(.semibold))
                    SettingsButton("Open Existing Workspace", systemImage: "arrow.right.circle", kind: .primary) {
                        coordinator.openExistingDuplicate(engine: engine)
                    }
                }
            }

            let models = engine.availableModels(for: engine.activeProvider)
            if !models.isEmpty, coordinator.selectedProviderID == engine.activeProviderID {
                DisclosureGroup("Model") {
                    Picker("Model", selection: Binding(
                        get: { engine.selectedModel },
                        set: { engine.selectedModel = $0 }
                    )) {
                        ForEach(models, id: \.self) { model in
                            Text(model).tag(model)
                        }
                    }
                    .pickerStyle(.inline)
                }
                .font(.subheadline.weight(.semibold))
            }
        }
    }
}
