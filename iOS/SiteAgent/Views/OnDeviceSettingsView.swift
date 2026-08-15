import SwiftUI

/// Manage on-device models: download, pick the active one, and see trial / Super
/// status. Reachable from Settings on capable hardware (iPhone 15 Pro and up).
struct OnDeviceSettingsView: View {
    @EnvironmentObject var engine: AgentEngine
    @ObservedObject private var iap = IAPManager.shared
    @ObservedObject private var engineState = MLXTextEngine.shared
    @ObservedObject private var manager = OnDeviceModelManager.shared

    @State private var showPaywall = false
    @AppStorage("onDeviceThinkingEnabled") private var thinkingEnabled = true

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                if !OnDeviceCapability.isCapable {
                    unsupportedCard
                } else {
                    statusCard
                    OnDeviceRuntimeStatusSection()
                    activationCard
                    modelsCard
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
        }
        .appBackground(.grouped)
        .navigationTitle("On-Device")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showPaywall) { ProPaywall(context: .onDevice) }
    }

    // MARK: - Unsupported

    private var unsupportedCard: some View {
        SettingsSection {
            VStack(spacing: 10) {
                Image(systemName: "cpu").font(.system(size: 40)).foregroundStyle(.secondary)
                Text("Not available on this device").font(.headline)
                Text("On-device models need the Neural Engine and memory of iPhone 15 Pro or newer.")
                    .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
                Text("Detected: \(OnDeviceCapability.machineIdentifier) · \(OnDeviceCapability.physicalMemoryGB) GB RAM")
                    .font(.caption).foregroundStyle(.tertiary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
        }
    }

    // MARK: - Status (trial / Super / engine)

    private var statusCard: some View {
        SettingsSection("Status", footer: "Everything runs locally — no API key, no internet, nothing leaves your iPhone.") {
            if iap.isPro {
                Label("Super — unlimited on-device use", systemImage: "checkmark.seal.fill")
                    .foregroundStyle(.green)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 11)
            } else if iap.onDeviceTrialActive {
                HStack {
                    Label("Free trial — \(iap.onDeviceTrialDaysRemaining) day\(iap.onDeviceTrialDaysRemaining == 1 ? "" : "s") left",
                          systemImage: "bolt.fill")
                    Spacer()
                    Button("Get Super") { Haptics.tap(); showPaywall = true }
                        .font(.caption.weight(.bold))
                }
                .padding(.vertical, 11)
            } else {
                HStack {
                    Label("Free trial ended", systemImage: "lock.fill").foregroundStyle(.red)
                    Spacer()
                    Button("Unlock Super") { Haptics.tap(); showPaywall = true }
                        .font(.caption.weight(.bold))
                        .padding(.horizontal, 10).padding(.vertical, 5)
                        .background(Theme.actionGradient, in: Capsule())
                        .foregroundStyle(.white)
                }
                .padding(.vertical, 11)
            }

            if case .loading(let status) = engineState.state {
                SettingsDivider()
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(status).font(.footnote).foregroundStyle(.secondary)
                    Spacer()
                }
                .padding(.vertical, 11)
            } else if engineState.isReady, let id = engineState.loadedModelID,
                      let m = OnDeviceModelCatalog.model(id: id) {
                SettingsDivider()
                Label("\(m.displayName) loaded\(engineState.tokensPerSecond > 0 ? String(format: " · %.0f tok/s", engineState.tokensPerSecond) : "")",
                      systemImage: "memorychip")
                    .font(.footnote).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 11)
            }
        }
    }

    // MARK: - Activation

    private var activationCard: some View {
        SettingsSection(footer: "When on, the chat uses your selected local model instead of a cloud provider.") {
            Toggle("Use on-device for the agent", isOn: Binding(
                get: { MainActor.assumeIsolated { engine.usingOnDevice } },
                set: { value in MainActor.assumeIsolated { setOnDevice(value) } }
            ))
            .disabled(manager.downloadedModels().isEmpty)
            .padding(.vertical, 8)

            SettingsDivider()
            Toggle("Thinking for supported models", isOn: $thinkingEnabled)
                .padding(.vertical, 8)
            Text("Uses private reasoning with Qwen3, Qwen3.5, and Bonsai. It can improve multi-step tool decisions but makes replies slower.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.bottom, 8)

            if manager.downloadedModels().isEmpty {
                SettingsDivider()
                Text("Download a model below to enable this.")
                    .font(.caption).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 10)
            }
        }
    }

    // MARK: - Models

    private var modelsCard: some View {
        SettingsSection("Models", footer: "Curated 2-bit and 4-bit MLX models from public Hugging Face repositories. Website Commander keeps an 8K-token working context for reliable memory use. Download over Wi-Fi — sizes are approximate.") {
            OnDeviceModelList()
            SettingsDivider()
            PartialDownloadCacheControl()
        }
    }

    // MARK: - Actions

    private func setOnDevice(_ on: Bool) {
        if on {
            engine.activeProviderID = "ondevice"
            let downloaded = manager.downloadedModels()
            if let current = OnDeviceModelCatalog.model(id: engine.activeModelID),
               downloaded.contains(current) {
                // keep it
            } else if downloaded.contains(OnDeviceModelCatalog.defaultModel) {
                engine.activeModelID = OnDeviceModelCatalog.defaultModel.id
            } else if let first = downloaded.first {
                engine.activeModelID = first.id
            }
        } else {
            engine.activeProviderID = AgentEngine.freeProviderID
            engine.activeModelID = ""
        }
        engine.noteSecretsChanged()
        Haptics.tap()
    }
}

// MARK: - Runtime status

private struct OnDeviceRuntimeStatusSection: View {
    @ObservedObject private var monitor = OnDeviceRuntimeMonitor.shared

    private var policy: OnDeviceRuntimePolicy { monitor.currentPolicy() }

    var body: some View {
        SettingsSection(
            "Runtime Guardrails",
            footer: "Website Commander automatically reduces local generation when iOS reports heat or memory pressure."
        ) {
            OnDeviceRuntimeMetricRow(
                title: "Thermal state",
                value: thermalLabel,
                systemImage: "thermometer",
                tint: thermalTint
            )
            SettingsDivider()
            OnDeviceRuntimeMetricRow(
                title: "Memory tier",
                value: memoryTierLabel,
                systemImage: "memorychip",
                tint: Theme.brand
            )
            SettingsDivider()
            OnDeviceRuntimeMetricRow(
                title: "Generation budget",
                value: generationBudgetLabel,
                systemImage: "speedometer",
                tint: policyTint
            )
            if monitor.memoryWarningCount > 0 {
                SettingsDivider()
                OnDeviceRuntimeMetricRow(
                    title: "Memory warnings",
                    value: memoryWarningLabel,
                    systemImage: "exclamationmark.triangle",
                    tint: Theme.warn
                )
            }
            if policy.mode != .full {
                SettingsDivider()
                SettingsBanner(message: policyNotice, ok: false, errorTint: policyTint)
            }
        }
    }

    private var thermalLabel: String {
        switch monitor.thermalState {
        case .nominal: return "Nominal".localized
        case .fair: return "Fair".localized
        case .serious: return "Serious".localized
        case .critical: return "Critical".localized
        @unknown default: return "Elevated".localized
        }
    }

    private var thermalTint: Color {
        switch monitor.thermalState {
        case .nominal: return Theme.ok
        case .fair: return Theme.info
        case .serious: return Theme.warn
        case .critical: return Theme.danger
        @unknown default: return Theme.warn
        }
    }

    private var memoryTierLabel: String {
        let tier = OnDeviceCapability.tier == .max ? "Max tier".localized : "Pro tier".localized
        return String(format: "%lld GB RAM · %@".localized, Int64(OnDeviceCapability.physicalMemoryGB), tier)
    }

    private var generationBudgetLabel: String {
        guard policy.allowsGeneration else { return "Paused".localized }
        if policy.maxCompletionTokens >= OnDeviceRuntimePolicy.standardMaxCompletionTokens {
            return "Full".localized
        }
        return String(format: "%lld tokens".localized, Int64(policy.maxCompletionTokens))
    }

    private var memoryWarningLabel: String {
        monitor.hasRecentMemoryWarning() ? "Recent memory pressure".localized : "Past memory pressure".localized
    }

    private var policyTint: Color {
        guard policy.allowsGeneration else { return Theme.danger }
        return policy.mode == .full ? Theme.ok : Theme.warn
    }

    private var policyNotice: String {
        if !policy.allowsGeneration {
            return "Local generation is paused until iOS reports a safer thermal state.".localized
        }
        if policy.constrainedByMemoryWarning {
            return "Memory pressure was detected. Website Commander released idle model buffers and is using shorter replies.".localized
        }
        return "Power saving is active. Local replies are shorter until the device cools down.".localized
    }
}

private struct OnDeviceRuntimeMetricRow: View {
    let title: String
    let value: String
    let systemImage: String
    let tint: Color

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: systemImage)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(tint)
                .frame(width: 28, height: 28)
                .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            Text(title.localized)
                .font(.subheadline)
            Spacer(minLength: 12)
            Text(value)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.trailing)
        }
        .padding(.vertical, 11)
    }
}

// MARK: - Reusable model list

/// The list of on-device models with inline download / select / delete. Shared
/// by the dedicated On-Device screen and the provider picker in Settings, so a
/// user can download an undownloaded model right where they pick it — no need to
/// hunt down a separate menu. Renders rows only (no section wrapper) so it drops
/// into either a SettingsSection.
struct OnDeviceModelList: View {
    @EnvironmentObject var engine: AgentEngine
    @ObservedObject private var manager = OnDeviceModelManager.shared
    @ObservedObject private var engineState = MLXTextEngine.shared

    @State private var errorText: String?
    @State private var pendingDeletion: OnDeviceModel?

    var body: some View {
        ForEach(Array(OnDeviceModelCatalog.all.enumerated()), id: \.element.id) { index, model in
            if index > 0 { SettingsDivider() }
            modelRow(model)
        }
        .alert("Download failed", isPresented: Binding(
            get: { errorText != nil },
            set: { if !$0 { errorText = nil } }
        )) {
            Button("OK", role: .cancel) { errorText = nil }
        } message: { Text(errorText ?? "") }
        .confirmationDialog(
            "Delete downloaded model?",
            isPresented: Binding(
                get: { pendingDeletion != nil },
                set: { if !$0 { pendingDeletion = nil } }
            ),
            presenting: pendingDeletion
        ) { model in
            Button("Delete \(model.displayName)", role: .destructive) { delete(model) }
            Button("Cancel", role: .cancel) { pendingDeletion = nil }
        } message: { model in
            Text("This removes \(model.displayName) from this device. You can download it again later.")
        }
    }

    @ViewBuilder
    private func modelRow(_ model: OnDeviceModel) -> some View {
        let downloaded = manager.downloadedIDs.contains(model.id)
        let isDownloading = manager.downloading.contains(model.id)
        let isActive = engine.usingOnDevice && engine.activeModelID == model.id
        let isLoaded = engineState.loadedModelID == model.id

        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(model.displayName).font(.body.weight(.semibold))
                        if model.tags.contains("best") {
                            Text("BEST")
                                .font(.caption2.weight(.bold))
                                .padding(.horizontal, 5).padding(.vertical, 1)
                                .background(Theme.ok.opacity(0.15), in: Capsule())
                                .foregroundStyle(Theme.ok)
                        }
                        if isActive {
                            Text("ACTIVE")
                                .font(.caption2.weight(.bold))
                                .padding(.horizontal, 5).padding(.vertical, 1)
                                .background(Theme.brand.opacity(0.15), in: Capsule())
                                .foregroundStyle(Theme.brand)
                        }
                    }
                    Text(model.subtitle).font(.caption).foregroundStyle(.secondary)
                    Link(destination: model.huggingFaceURL) {
                        Label("Hugging Face", systemImage: "arrow.up.right.square")
                            .font(.caption2.weight(.medium))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Theme.brand)
                    .accessibilityLabel("Open \(model.displayName) on Hugging Face")
                    if model.needsMaxTier && OnDeviceCapability.tier == .pro {
                        Label("Best on 12 GB+ devices", systemImage: "exclamationmark.triangle")
                            .font(.caption2).foregroundStyle(.orange)
                    }
                }
                Spacer()
                control(
                    for: model,
                    downloaded: downloaded,
                    isDownloading: isDownloading,
                    isLoaded: isLoaded
                )
            }
            if isDownloading {
                if let value = manager.progress[model.id] {
                    BrandProgressBar(value: value)
                } else {
                    ProgressView()
                        .progressViewStyle(.linear)
                        .tint(Theme.brand)
                        .accessibilityLabel("Connecting to Hugging Face")
                }
            }
        }
        .padding(.vertical, 11)
        .contextMenu {
            Link(destination: model.huggingFaceURL) {
                Label("View on Hugging Face", systemImage: "arrow.up.right.square")
            }
            if downloaded && !isDownloading {
                Button(role: .destructive) { pendingDeletion = model } label: {
                    Label("Delete model", systemImage: "trash")
                }
            }
        }
    }

    @ViewBuilder
    private func control(
        for model: OnDeviceModel,
        downloaded: Bool,
        isDownloading: Bool,
        isLoaded: Bool
    ) -> some View {
        if isDownloading {
            switch manager.downloadPhase[model.id] {
            case .connecting:
                Text("Connecting…")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
            case .reconnecting(let attempt):
                Text("Reconnecting… \(attempt)/7")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(Theme.warn)
            case .downloading, .none:
                let pct = Int((manager.progress[model.id] ?? 0) * 100)
                Text(pct == 0 ? "Downloading…" : "\(pct)%")
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    .contentTransition(.numericText())
                    .motion(value: pct)   // key on the integer, not the raw fraction
            }
        } else if downloaded {
            if isLoaded {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.brand)
            } else {
                Button("Use") { selectModel(model) }
                    .font(.caption.weight(.bold)).buttonStyle(.borderless)
            }
        } else {
            Button { download(model) } label: {
                Label(ByteCountFormatter.string(fromByteCount: model.approxDownloadBytes, countStyle: .file),
                      systemImage: "arrow.down.circle")
                    .font(.caption.weight(.semibold))
            }
            .buttonStyle(.borderless)
            .disabled(!manager.downloading.isEmpty)
            .opacity(manager.downloading.isEmpty ? 1 : 0.45)
        }
    }

    // MARK: - Actions

    /// Make `model` the active on-device model and warm it in the background.
    private func selectModel(_ model: OnDeviceModel) {
        engine.activeProviderID = "ondevice"
        engine.activeModelID = model.id
        engine.noteSecretsChanged()
        Haptics.tap()
        Task { try? await MLXTextEngine.shared.ensureLoaded(model) }
    }

    private func download(_ model: OnDeviceModel) {
        Haptics.tap()
        Task {
            do { try await manager.download(model) }
            catch { errorText = error.localizedDescription }
        }
    }

    /// Delete a model; if it was the active on-device model, re-point the agent at
    /// another downloaded model (or off on-device) so the next send doesn't fail
    /// with `notDownloaded`.
    private func delete(_ model: OnDeviceModel) {
        if engineState.loadedModelID == model.id { engineState.unload() }
        let wasActive = engine.usingOnDevice && engine.activeModelID == model.id
        manager.delete(model)
        pendingDeletion = nil
        guard wasActive else { return }
        if let next = manager.downloadedModels().first {
            engine.activeModelID = next.id
        } else {
            engine.activeProviderID = AgentEngine.freeProviderID
            engine.activeModelID = ""
        }
        engine.noteSecretsChanged()
    }
}

// MARK: - Partial download cache

private struct PartialDownloadCacheControl: View {
    @ObservedObject private var manager = OnDeviceModelManager.shared

    @State private var showsConfirmation = false
    @State private var resultMessage: String?

    var body: some View {
        Button(role: .destructive) {
            Haptics.tap()
            showsConfirmation = true
        } label: {
            Label("Clear partial downloads", systemImage: "trash")
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.borderless)
        .disabled(!manager.downloading.isEmpty)
        .padding(.vertical, 11)
        .confirmationDialog(
            "Clear partial downloads?",
            isPresented: $showsConfirmation,
            titleVisibility: .visible
        ) {
            Button("Clear partial downloads", role: .destructive) {
                clearPartialDownloads()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes unfinished model files and resumable download data. Completed models will not be deleted.")
        }
        .alert("Partial Downloads", isPresented: Binding(
            get: { resultMessage != nil },
            set: { if !$0 { resultMessage = nil } }
        )) {
            Button("OK", role: .cancel) { resultMessage = nil }
        } message: {
            Text(resultMessage ?? "")
        }
    }

    private func clearPartialDownloads() {
        Task {
            do {
                let bytes = try await manager.clearPartialDownloads()
                if bytes > 0 {
                    let size = ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
                    resultMessage = "Cleared \(size) of partial model downloads."
                } else {
                    resultMessage = "No partial model downloads were found."
                }
            } catch {
                resultMessage = error.localizedDescription
            }
        }
    }
}
