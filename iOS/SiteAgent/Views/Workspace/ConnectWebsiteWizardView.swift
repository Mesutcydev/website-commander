import SwiftUI

/// Four-step first-run / connect flow:
/// GitHub → Choose website → Connect deployment → Choose AI.
struct ConnectWebsiteWizardView: View {
    @EnvironmentObject var engine: AgentEngine
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ObservedObject private var coordinator = ConnectWebsiteWizardCoordinator.shared

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                WizardProgressHeader(step: coordinator.step)
                Divider()
                ScrollView {
                    Group {
                        switch coordinator.step {
                        case .github:
                            WizardGitHubStep(coordinator: coordinator) {
                                Task {
                                    await coordinator.refreshGitHub(engine: engine)
                                    withAnimation(reduceMotion ? nil : Theme.snappy) {
                                        coordinator.step = .website
                                    }
                                }
                            }
                        case .website:
                            WizardRepositoryStep(coordinator: coordinator)
                        case .deployment:
                            WizardDeploymentStep(coordinator: coordinator)
                        case .assistant:
                            WizardAssistantStep(coordinator: coordinator)
                        }
                    }
                    .padding(20)
                    .readableWidth(560)
                }
                .scrollDismissesKeyboard(.interactively)
            }
            .safeAreaInset(edge: .bottom) {
                footerBar
                    .background(.bar)
            }
            .commandBackground()
            .navigationTitle("Connect Website")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
            .onAppear {
                coordinator.prepareOnAppear(engine: engine)
            }
            .onChange(of: coordinator.didFinish) { _, finished in
                if finished {
                    dismiss()
                    // Prefer Command Center / Sites over leaving user in Settings.
                    engine.requestedTab = .home
                }
            }
        }
    }

    private var footerBar: some View {
        HStack(spacing: 12) {
            if coordinator.step != .github {
                Button("Back") {
                    Haptics.tap()
                    let previous = ConnectWebsiteWizardCoordinator.Step(rawValue: max(0, coordinator.step.rawValue - 1)) ?? .github
                    withAnimation(reduceMotion ? nil : Theme.snappy) {
                        coordinator.step = previous
                    }
                }
                .frame(minHeight: 44)
            }
            Spacer()
            switch coordinator.step {
            case .github, .website:
                EmptyView()
            case .deployment:
                Button("Set up later") {
                    Haptics.tap()
                    coordinator.continueFromDeployment(skip: true)
                }
                .frame(minHeight: 44)
                SettingsButton("Continue", systemImage: "arrow.right", kind: .primary) {
                    coordinator.continueFromDeployment(skip: false)
                }
                .frame(width: 160)
                .frame(minHeight: 44)
            case .assistant:
                SettingsButton(
                    "Finish",
                    systemImage: "checkmark",
                    kind: .primary,
                    loading: coordinator.isWorking
                ) {
                    _ = coordinator.finish(engine: engine)
                }
                .frame(width: 160)
                .frame(minHeight: 44)
                .disabled(coordinator.isWorking || coordinator.selectedRepository == nil)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }
}
