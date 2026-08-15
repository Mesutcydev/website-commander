import SwiftUI

struct WizardProgressHeader: View {
    let step: ConnectWebsiteWizardCoordinator.Step

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                ForEach(ConnectWebsiteWizardCoordinator.Step.allCases, id: \.rawValue) { s in
                    Capsule()
                        .fill(s.rawValue <= step.rawValue ? Theme.brand : Theme.separator)
                        .frame(height: 4)
                        .accessibilityHidden(true)
                }
            }
            Text("Step \(step.rawValue + 1) of \(ConnectWebsiteWizardCoordinator.Step.allCases.count) · \(step.title)")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Step \(step.rawValue + 1) of \(ConnectWebsiteWizardCoordinator.Step.allCases.count), \(step.title)")
    }
}
