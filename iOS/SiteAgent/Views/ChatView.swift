import SwiftUI
import PhotosUI
import UniformTypeIdentifiers
import UIKit

/// Reports the chat transcript's bottom anchor offset (within the scroll
/// coordinate space) so the view can tell when the user is parked near the
/// bottom and auto-follow streaming without fighting manual scroll-back.
private struct BottomAnchorOffsetKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

struct ChatView: View {
    /// `.page` owns transcript/navigation. `.accessory` supplies the complete
    /// composer to the root overlay, keeping it outside the page hierarchy.
    enum Role { case page, accessory }

    @EnvironmentObject var engine: AgentEngine
    @Binding var tab: AppTab
    var role: Role = .page
    @ObservedObject var iap = IAPManager.shared
    @ObservedObject private var composerModel = ChatComposerModel.shared
    // SceneStorage so a half-typed message survives backgrounding and app kills.
    @SceneStorage("chat.draft") private var draft = ""
    private var attachments: [Attachment] {
        get { composerModel.attachments }
        nonmutating set { composerModel.attachments = newValue }
    }
    @State private var photoItems: [PhotosPickerItem] = []
    @State private var showAttachMenu = false
    @State private var showPhotoPicker = false
    @State private var showFileImporter = false
    @State private var showClipboard = false
    @State private var showImageStudio = false
    @State private var showHistory = false
    @State private var showSettings = false
    @State private var showConnectWizard = false
    @State private var showAddSite = false
    @State private var showModelPicker = false
    @State private var showPaywall = false
    @State private var paywallContext: PaywallContext = .general
    @State private var showNewChatConfirm = false
    @State private var reviewingStagedChange: PendingChange?
    /// User intent for transcript auto-follow. Content growth alone must never
    /// turn this off; only an actual drag toward older messages does.
    @State private var isNearBottom = true
    @State private var scrollFollowTask: Task<Void, Never>?
    @FocusState private var inputFocused: Bool
    @Environment(\.colorScheme) var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.rootChatComposerHeight) private var rootChatComposerHeight
    
    private var oledDark: Bool {
        engine.oledMode && colorScheme == .dark
    }

    private var secondaryBG: Color {
        oledDark ? Color(white: 0.05) : Color(.secondarySystemBackground)
    }

    private var proposedPlan: String? {
        // Plan extraction splits and scans the whole assistant response. Defer it
        // until streaming finishes instead of repeating that work for every chunk.
        guard !engine.state.isActive else { return nil }
        return engine.transcript.last(where: { $0.role == .assistant })?.text.extractedPlan
    }

    /// iOS 26+ uses the root-owned composer layer. Older systems embed the same
    /// controls with a safe-area inset while leaving the tab bar untouched.
    private var embedsComposer: Bool {
        if #available(iOS 26.0, *) { return false }
        return true
    }

    var body: some View {
        switch role {
        case .accessory:
            accessoryBody
        case .page:
            pageBody
        }
    }

    /// Complete root-layer composer, including its own outer glass plate.
    @ViewBuilder
    private var accessoryBody: some View {
        inputBar
        .frame(maxWidth: .infinity)
        .animation(Theme.spring, value: engine.pendingChanges.count)
        .environment(\.secondarySurface, secondaryBG)
        .sheet(isPresented: $showClipboard) {
            ClipboardManagerSheet(
                onInsertText: insertClipboardText,
                onAttachImage: attachClipboardImage
            )
        }
        .sheet(isPresented: $showPaywall) {
            ProPaywall(context: paywallContext)
        }
        .sheet(isPresented: $showSettings) {
            SettingsView().environmentObject(engine)
        }
        .sheet(isPresented: $showModelPicker) {
            ChatModelPickerSheet { provider, model in
                select(provider: provider, model: model)
            }
            .environmentObject(engine)
        }
        .onChange(of: engine.prefilledPrompt, initial: true) { _, p in
            if let p, !p.isEmpty {
                draft = p
                inputFocused = true
                engine.prefilledPrompt = nil
            }
        }
        .onChange(of: engine.prefilledAttachments) { _, newValue in
            guard !newValue.isEmpty else { return }
            composerModel.attachments = newValue
            engine.prefilledAttachments = []
        }
    }

    private var pageBody: some View {
        NavigationStack {
            transcript
                .modifier(ChatPageComposerClearance(
                    enabled: !embedsComposer,
                    height: rootChatComposerHeight
                ))
                .modifier(ChatEmbeddedComposerModifier(
                    enabled: embedsComposer,
                    accent: engine.accent,
                    skin: engine.skin
                ) {
                    inputBar
                })
            .background(CommandDeckBackground())
            .glassScrollEdge()
            .environment(\.secondarySurface, secondaryBG)
            .navigationBarTitleDisplayMode(.inline)
            .animation(Theme.spring, value: engine.pendingChanges.count)
            .toolbar {
                if #available(iOS 26.0, *) {
                    ToolbarItem(placement: .topBarLeading) {
                        connectionButton
                    }
                    .sharedBackgroundVisibility(.hidden)
                } else {
                    ToolbarItem(placement: .topBarLeading) {
                        connectionButton
                    }
                }
                ToolbarItem(placement: .principal) {
                    chatTitle
                }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button { Haptics.tap(); showHistory = true } label: {
                        Image(systemName: "clock.arrow.circlepath")
                    }
                    .accessibilityLabel("Chat history")
                    .disabled(engine.commitInFlight)

                    Button {
                        // No transcript yet → nothing to lose, skip the prompt.
                        if engine.transcript.isEmpty {
                            withAnimation(Theme.spring) { engine.resetConversation() }
                        } else {
                            Haptics.tap()
                            showNewChatConfirm = true
                        }
                    } label: {
                        Image(systemName: "square.and.pencil")
                    }
                    .accessibilityLabel("New chat")
                    .keyboardShortcut("n", modifiers: .command)
                    .disabled(engine.state.isActive || engine.commitInFlight)
                }
            }
            .confirmationDialog("Start a new chat?", isPresented: $showNewChatConfirm, titleVisibility: .visible) {
                Button("New Chat", role: .destructive) {
                    withAnimation(Theme.spring) { engine.resetConversation() }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Your current conversation is saved to History.")
            }
            .sheet(isPresented: $showHistory) {
                ConversationHistorySheet().environmentObject(engine)
            }
            .sheet(isPresented: $showSettings) {
                SettingsView().environmentObject(engine)
            }
            .sheet(isPresented: $showModelPicker) {
                ChatModelPickerSheet { provider, model in
                    select(provider: provider, model: model)
                }
                .environmentObject(engine)
            }
            .sheet(isPresented: $showClipboard) {
                ClipboardManagerSheet(
                    onInsertText: insertClipboardText,
                    onAttachImage: attachClipboardImage
                )
            }
            .sheet(isPresented: $showPaywall) {
                ProPaywall(context: paywallContext)
            }
            .sheet(isPresented: $showAddSite) {
                AddWorkspaceSheet().environmentObject(engine)
            }
            .sheet(isPresented: $showConnectWizard) {
                ConnectWebsiteWizardView().environmentObject(engine)
            }
            .onChange(of: engine.requestedConnectWizard) { _, requested in
                guard requested else { return }
                engine.requestedConnectWizard = false
                showConnectWizard = true
            }
            .sheet(item: $reviewingStagedChange) { change in
                DiffSheet(change: change)
            }
            .alert("Something went wrong", isPresented: Binding(
                get: { MainActor.assumeIsolated {
                    engine.lastError != nil && engine.reviewIssueMessage == nil
                } },
                set: { show in MainActor.assumeIsolated { if !show { engine.lastError = nil } } }
            )) {
                if let err = engine.lastError, (err.contains("did not invoke") || err.contains("timed out") || err.contains("blocked") || err.contains("requires") || err.contains("failed") || err.contains("Failed due to")) {
                    if let op = engine.activeOperationState, op.editingToolSucceeded {
                        Button("Dismiss", role: .cancel) { engine.lastError = nil }
                        Button("View changes") {
                            if let firstFile = op.changedFiles.first,
                               let pending = engine.pendingChanges.first(where: { $0.path == firstFile }) {
                                reviewingStagedChange = pending
                            } else {
                                engine.openPreview()
                            }
                        }
                        if op.verificationSucceeded {
                            Button("Verify again") {
                                engine.verifyChangesAgain()
                            }
                            Button("Open preview") {
                                engine.openPreview()
                            }
                        } else {
                            Button("Verify changes") {
                                engine.verifyChangesAgain()
                            }
                        }
                    } else if engine.state == .timedOut || err.localizedCaseInsensitiveContains("run timed out") {
                        Button("Retry run") {
                            engine.retryNormal()
                        }
                        Button("View technical details") {
                            if let currentErr = engine.lastError {
                                engine.lastError = "State: \(engine.state.rawValue)\nProvider: \(engine.activeProviderID)\nModel: \(engine.selectedModel)\nReason: \(currentErr)"
                            }
                        }
                        Button("Cancel", role: .cancel) { engine.lastError = nil }
                    } else {
                        Button("Retry using targeted patch") {
                            engine.retryWithPatch()
                        }
                        Button("Retry edit") {
                            engine.retryNormal()
                        }
                        Button("View technical details") {
                            if let currentErr = engine.lastError {
                                engine.lastError = "State: \(engine.state.rawValue)\nProvider: \(engine.activeProviderID)\nModel: \(engine.selectedModel)\nReason: \(currentErr)"
                            }
                        }
                        Button("Cancel", role: .cancel) { engine.lastError = nil }
                    }
                } else {
                    Button("OK", role: .cancel) { engine.lastError = nil }
                }
            } message: {
                Text(engine.lastError ?? "")
            }
            .task(id: "\(engine.activeProviderID)#\(engine.secretsRevision)") {
                await engine.refreshActiveProviderModels()
            }
            // Prefilled by the preview inspector's "Ask AI" buttons — user reviews
            // before sending (no surprise spend).
            .onChange(of: engine.prefilledPrompt) { _, newValue in
                guard let newValue, !newValue.isEmpty else { return }
                draft = newValue
                inputFocused = true
                engine.prefilledPrompt = nil
            }
            // Safety net: if a prompt was staged while Chat wasn't the active tab,
            // pick it up when Chat appears (so the inspector's element context is
            // never lost).
            .onAppear {
                if let p = engine.prefilledPrompt, !p.isEmpty {
                    draft = p
                    inputFocused = true
                    engine.prefilledPrompt = nil
                }
            }
            // A screenshot handed off from "Create Site" (build from a picture).
            // Staged into the composer so the user reviews before sending.
            .onChange(of: engine.prefilledAttachments) { _, newValue in
                guard !newValue.isEmpty else { return }
                attachments = newValue
                engine.prefilledAttachments = []
            }
            // Peak-intent upsell: just after a free user's first successful ship.
            // Delayed so the diff sheet's success beat + dismissal finish first.
            .onChange(of: engine.showFirstShipUpsell) { _, show in
                guard show else { return }
                engine.showFirstShipUpsell = false
                Task {
                    try? await Task.sleep(nanoseconds: 1_200_000_000)
                    paywallContext = .firstShip
                    showPaywall = true
                }
            }
        }
    }

    /// Running estimated spend for this conversation, with a warning tint as it
    /// nears the cap. Hidden for free/local providers (cost stays 0).
    private var sessionCostChip: some View {
        let cap = engine.spendCapUSD
        let near = cap > 0 && engine.sessionCostUSD >= cap * 0.9
        return HStack(spacing: 6) {
            Image(systemName: near ? "exclamationmark.triangle.fill" : "dollarsign.circle")
            Text(String(format: "Session ~$%.4f", engine.sessionCostUSD))
                .monospacedDigit()
                .contentTransition(.numericText(value: engine.sessionCostUSD))
            if cap > 0 {
                Text("· cap $\(Int(cap))").foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .animation(reduceMotion ? nil : Theme.snappy, value: engine.sessionCostUSD)
        .font(.caption2.weight(.medium))
        .foregroundStyle(near ? .orange : .secondary)
        .padding(.horizontal, 10).padding(.vertical, 5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background((near ? Color.orange : Color.secondary).opacity(0.1),
                    in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .accessibilityLabel(String(format: "Session cost %.2f dollars", engine.sessionCostUSD))
    }

    /// Thin progress bar tracking spend toward the configured cap. Only shown
    /// when a cap is set, beneath the cost chip. Clamped to 0...1.
    private var spendCapProgress: some View {
        let cap = engine.spendCapUSD
        let fraction = cap > 0 ? min(max(engine.sessionCostUSD / cap, 0), 1) : 0
        return ProgressView(value: fraction)
            .progressViewStyle(.linear)
            .tint(fraction >= 0.9 ? .orange : Theme.brand)
            .animation(reduceMotion ? nil : Theme.snappy, value: engine.sessionCostUSD)
            .accessibilityHidden(true)
    }

    private var connectionButton: some View {
        Button {
            Haptics.tap()
            showSettings = true
        } label: {
            // Bare glyph — no Circle fill, no frame plate. System glass chip is
            // suppressed via `.sharedBackgroundVisibility(.hidden)` on the
            // ToolbarItem so only the ! / checkmark shows.
            Group {
                if engine.state.isActive && !engine.isWaitingForConnection {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: connectionIcon)
                        .font(.body.weight(.semibold))
                        .foregroundStyle(connectionColor)
                        .contentTransition(.symbolEffect(.replace))
                        .symbolEffect(.bounce, value: engine.isReady)
                        .symbolEffect(.pulse, isActive: engine.isWaitingForConnection)
                }
            }
        }
        .buttonStyle(.borderless)
        .accessibilityLabel(connectionLabel)
        .accessibilityHint("Opens connection settings")
    }

    private var connectionIcon: String {
        if engine.isWaitingForConnection { return "wifi.exclamationmark" }
        return engine.isReady ? "checkmark" : "exclamationmark"
    }

    private var connectionColor: Color {
        if engine.isWaitingForConnection { return .orange }
        return engine.isReady ? .green : .orange
    }

    private var connectionLabel: String {
        if engine.isWaitingForConnection { return "Reconnecting" }
        if engine.state.isActive { return "Agent working" }
        if engine.state == .awaitingUserApproval { return "Waiting for approval" }
        return engine.isReady ? "Connected" : "Setup required"
    }

    /// Header title — site name + branch/state, mirroring the design's
    /// "aurora.studio / main · editing" header.
    private var chatTitle: some View {
        VStack(spacing: 1) {
            Text(engine.activeWorkspace?.name ?? "Agent")
                .font(.headline)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            Text(branchStatusLine)
                .font(.mono(10, .medium))
                .foregroundStyle(Theme.t3)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .contentTransition(.opacity)
        }
        .frame(maxWidth: dynamicTypeSize.isAccessibilitySize ? 320 : 220)
        .animation(reduceMotion ? nil : Theme.snappy, value: engine.state)
        .accessibilityElement(children: .combine)
    }

    private var branchStatusLine: String {
        let raw = engine.activeWorkspace?.gitBranch ?? ""
        let branch = raw.isEmpty ? "main" : raw
        let state: String
        if engine.state.isActive { state = "working" }
        else if engine.state == .awaitingUserApproval { state = "review" }
        else { state = engine.isReady ? "ready" : "setup" }
        return "\(branch) · \(state)"
    }

    /// Separate status row under the transcript — hidden once the in-progress
    /// assistant bubble is showing streamed text, so we don't stack two live
    /// rows and jump the layout on the first token.
    private var showWorkingRow: Bool {
        guard engine.state.isActive else { return false }
        if engine.state == .receivingModel,
           let last = engine.transcript.last,
           last.role == .assistant,
           !last.text.isEmpty {
            return false
        }
        return true
    }

    /// Coalesce rapid token updates into at most one scroll per display frame.
    /// Debouncing here is incorrect: a fast stream continually cancels the pending
    /// scroll, leaving the transcript stranded until the model pauses.
    private func followTranscriptBottom(with proxy: ScrollViewProxy, animated: Bool) {
        guard isNearBottom, scrollFollowTask == nil else { return }
        scrollFollowTask = Task { @MainActor in
            defer { scrollFollowTask = nil }
            try? await Task.sleep(for: .milliseconds(animated ? 32 : 16))
            guard !Task.isCancelled, isNearBottom else { return }
            if animated {
                withAnimation(Theme.spring) {
                    proxy.scrollTo("bottom", anchor: .bottom)
                }
            } else {
                var transaction = Transaction()
                transaction.disablesAnimations = true
                withTransaction(transaction) {
                    proxy.scrollTo("bottom", anchor: .bottom)
                }
            }
        }
    }

    /// Compact model picker shown in the composer — the design's "• Sonnet" chip.
    private var composerModelChip: some View {
        Button {
            Haptics.tap()
            showModelPicker = true
        } label: {
            HStack(spacing: 5) {
                if engine.isRefreshingModels {
                    ProgressView().controlSize(.mini)
                } else {
                    Circle()
                        .fill(engine.smartRoutingEnabled ? Theme.brand : Theme.ok)
                        .frame(width: 6, height: 6)
                }
                Text(engine.smartRoutingEnabled ? "Auto-Route" : engine.selectedModel)
                    .font(.mono(11, .medium))
                    .foregroundStyle(Theme.t2)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
                    .contentTransition(.opacity)
                if !engine.smartRoutingEnabled {
                    ModelCapabilityBadges(capabilities: engine.activeModelCapabilities, size: 14)
                }
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(Theme.t3)
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(Theme.chip, in: Capsule())
            .overlay(Capsule().strokeBorder(Theme.separator, lineWidth: 1))
            .contentShape(Capsule())
            .animation(reduceMotion ? nil : Theme.snappy, value: engine.selectedModel)
        }
        .buttonStyle(.plain)
        .disabled(engine.state.isActive)
        .accessibilityLabel("Select AI model")
        .accessibilityValue(engine.smartRoutingEnabled ? "Auto-Route" : engine.selectedModel)
    }

    private func select(provider: LLMProvider, model: String) {
        if !iap.isPro && AgentEngine.proOnlyProviderIDs.contains(provider.id) {
            paywallContext = .premiumModel
            showPaywall = true
            return
        }
        Haptics.tap()
        engine.smartRoutingEnabled = false
        engine.activeProviderID = provider.id
        engine.selectedModel = model
        Task { await engine.refreshActiveProviderModels() }
    }

    private var transcript: some View {
        GeometryReader { viewport in
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        if !engine.isReady {
                            SetupCard(onOpenSettings: {
                                showSettings = true
                            }, onStartDemo: {
                                engine.startGuidedDemo()
                            }, onConnectSite: { showAddSite = true },
                               onConnectWizard: { showConnectWizard = true })
                            .padding(.horizontal, AppSize.screenHorizontalPadding)
                        }
                        if engine.transcript.isEmpty && engine.isReady { emptyState }

                        if let plan = proposedPlan {
                            VStack(alignment: .leading, spacing: 8) {
                                Label("Proposed Agent Plan", systemImage: "checklist")
                                    .font(.subheadline.weight(.bold))
                                    .foregroundStyle(Theme.brandGradient)
                                Text(plan)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            .padding(12)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .cardSurface(cornerRadius: Theme.cornerSmall)
                            .padding(.horizontal)
                            .transition(.move(edge: .top).combined(with: .opacity))
                        }

                        ForEach(engine.transcript) { message in
                            MessageBubble(
                                message: message,
                                isLiveStreaming: message.id == engine.transcript.last?.id
                                    && message.role == .assistant
                                    && engine.state.isActive
                                    && (engine.state == .requestingModel || engine.state == .receivingModel),
                                accent: engine.accent,
                                skin: engine.skin,
                                onResend: { text, attachments in
                                    engine.send(text, attachments: attachments)
                                },
                                onEdit: { text in
                                    engine.prefilledPrompt = text
                                }
                            )
                            .equatable()
                            .id(message.id)
                            .transition(.asymmetric(
                                insertion: .move(edge: .bottom).combined(with: .opacity),
                                removal: .opacity))
                        }
                        if showWorkingRow {
                            HStack(spacing: 10) {
                                TypingIndicator()
                                // After ~8s on one status, append a live elapsed
                                // counter. Longer model waits also explain whether
                                // the provider is active or currently silent, and
                                // remind the user that the composer can redirect it.
                                TimelineView(.periodic(from: .now, by: 1)) { context in
                                    let elapsed = Int(context.date.timeIntervalSince(engine.statusChangedAt))
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(elapsed >= 8 ? "\(engine.statusMessage) · \(elapsed)s" : engine.statusMessage)
                                            .foregroundStyle(.secondary)
                                            .font(.footnote.weight(.medium))
                                            .animation(nil, value: engine.statusMessage)
                                        switch engine.longWaitState(now: context.date) {
                                        case .active:
                                            Text("Still active — send a new instruction to redirect, or tap Stop.")
                                                .foregroundStyle(Theme.t2)
                                                .font(.caption2)
                                        case .waitingForProvider:
                                            Text("Waiting for the provider — you can keep waiting, redirect, or tap Stop.")
                                                .foregroundStyle(.orange)
                                                .font(.caption2)
                                        case .none:
                                            EmptyView()
                                        }
                                    }
                                    .fixedSize(horizontal: false, vertical: true)
                                }
                                if engine.pendingInterventionCount > 0 {
                                    Text("\(engine.pendingInterventionCount) queued")
                                        .font(.caption2.weight(.semibold))
                                        .foregroundStyle(Theme.t2)
                                        .padding(.horizontal, 8).padding(.vertical, 3)
                                        .background(Theme.chip, in: Capsule())
                                        .accessibilityLabel("\(engine.pendingInterventionCount) message\(engine.pendingInterventionCount == 1 ? "" : "s") queued, will be handled after the current step")
                                }
                            }
                            .padding(.horizontal)
                            .id("working")
                            .transition(.opacity)
                        }
                        if !engine.pendingChanges.isEmpty,
                           engine.pendingApproval == nil,
                           !engine.state.isActive {
                            PendingChangesBar()
                                .id("pendingChanges")
                                .transition(.move(edge: .bottom).combined(with: .opacity))
                        }
                        if engine.state == .awaitingUserApproval, let approval = engine.pendingApproval {
                            if engine.approvalReady {
                                ApprovalCard(approval: approval)
                                    .padding(.horizontal)
                                    .id("approval")
                                    .transition(.move(edge: .bottom).combined(with: .opacity))
                            } else {
                                ApprovalPreparingRow()
                                    .padding(.horizontal)
                                    .id("approval")
                            }
                        }

                        // Stable, zero-height scroll target. Auto-scroll aims here
                        // instead of at the last message bubble, whose height grows
                        // as tokens stream — animating a scroll to a moving target was
                        // what made the view jump up / flash blank, then re-settle.
                        Color.clear
                            .frame(height: 1)
                            .id("bottom")
                            .background(
                                GeometryReader { geo in
                                    Color.clear.preference(
                                        key: BottomAnchorOffsetKey.self,
                                        value: geo.frame(in: .named("chatScroll")).minY)
                                }
                            )
                    }
                    .padding(.vertical)
                    .animation(Theme.spring, value: engine.transcript.count)
                    // Cap the conversation to a readable measure on iPad/Mac instead of
                    // running text across the whole window.
                    .readableWidth(760)
                }
                .coordinateSpace(name: "chatScroll")
                .scrollDismissesKeyboard(.interactively)
                .scrollContentBackground(.hidden)
                .glassScrollEdge()
                // A downward finger drag reveals older messages. That explicit user
                // gesture pauses auto-follow; AI-driven layout growth does not.
                .simultaneousGesture(
                    DragGesture(minimumDistance: 8)
                        .onChanged { value in
                            guard isNearBottom, value.translation.height > 8 else { return }
                            isNearBottom = false
                            scrollFollowTask?.cancel()
                        }
                )
                // Re-enable following once the user returns to the latest message.
                // Never set this false from geometry: the bottom anchor also moves
                // when streamed text grows, which is not a user scroll.
                .onPreferenceChange(BottomAnchorOffsetKey.self) { minY in
                    let near = minY <= viewport.size.height + 140
                    if near {
                        isNearBottom = true
                    }
                }
                // Sending a message returns the user to the live edge. Incoming
                // assistant/system messages only follow when the transcript is
                // already pinned, so they never yank someone away from history.
                .onChange(of: engine.transcript.last?.id) { _, id in
                    guard id != nil else { return }
                    if engine.transcript.last?.role == .user {
                        isNearBottom = true
                    }
                    followTranscriptBottom(with: proxy, animated: true)
                }
                // Staged changes now live in the transcript instead of the
                // bottom accessory. Reveal them when they first appear—or when
                // Chat opens with changes already staged—so they never remain
                // underneath the independently layered composer.
                .onChange(of: engine.pendingChanges.count, initial: true) { _, count in
                    guard count > 0,
                          engine.pendingApproval == nil,
                          !engine.state.isActive else { return }
                    Task { @MainActor in
                        try? await Task.sleep(for: .milliseconds(64))
                        withAnimation(Theme.spring) {
                            proxy.scrollTo("pendingChanges", anchor: .bottom)
                        }
                    }
                }
                // Follow streaming token growth — but only when already near the
                // bottom, and without animation so the view stays pinned to the
                // growing content instead of animating toward a stale anchor.
                .onChange(of: engine.transcript.last?.text) { _, _ in
                    guard isNearBottom else { return }
                    followTranscriptBottom(with: proxy, animated: false)
                }
                .onChange(of: engine.state) { oldState, newState in
                    // Leaving the approval card behind: approving removes it, and its
                    // removal transition collapses the transcript's height. An animated
                    // scroll here would chase that moving target and flash the view blank
                    // before re-settling (same anti-pattern as the streaming fix above).
                    // Pin to the settled bottom without animation instead.
                    if oldState == .awaitingUserApproval {
                        if newState.isActive { proxy.scrollTo("bottom", anchor: .bottom) }
                        return
                    }
                    switch newState {
                    case .preparing, .requestingModel:
                        followTranscriptBottom(with: proxy, animated: true)
                    case .awaitingUserApproval:
                        withAnimation(Theme.spring) { proxy.scrollTo("approval", anchor: .bottom) }
                    default:
                        break
                    }
                }
            }
        }
    }

    struct CommandTemplate: Identifiable {
        let id: String
        let title: String
        let subtitle: String
        let icon: String
        let prompt: String
    }

    /// Prefill the composer with a template/suggestion prompt (no send) — the
    /// shared, paywall-gated behavior used by Starter Tasks and Try Asking.
    private func prefill(_ prompt: String) {
        Haptics.tap()
        if iap.canRunAgentLoop {
            withAnimation(Theme.snappy) { draft = prompt }
            inputFocused = true
        } else {
            paywallContext = .wall
            showPaywall = true
        }
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 22) {
            agentReadyCard

            // Hero copy — keeps the existing strings.
            VStack(alignment: .leading, spacing: 8) {
                Text("Manage your site by chatting")
                    .font(.display(24, .bold, relativeTo: .title2))
                Text("Describe a change in plain language — the agent edits the repo and deploys it. I'll keep you updated every step of the way.")
                    .font(.subheadline)
                    .foregroundStyle(Theme.t2)
                    .fixedSize(horizontal: false, vertical: true)
            }

            // Starter Tasks — 2-column grid built from the static templates.
            VStack(alignment: .leading, spacing: 12) {
                SectionHeader("Starter Tasks")
                Text("Choose a focused workflow. Website Commander inspects the site first, explains the highest-impact findings, and stages only the changes you approve.")
                    .font(.caption)
                    .foregroundStyle(Theme.t2)
                    .fixedSize(horizontal: false, vertical: true)
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
                    ForEach(Self.templates) { template in
                        Button {
                            prefill(template.prompt)
                        } label: {
                            starterCard(template)
                        }
                        .buttonStyle(.pressable)
                        .accessibilityLabel("Starter task: \(template.title.localized)")
                        .accessibilityHint(template.subtitle.localized)
                    }
                }
            }

            // Try Asking — full-width suggestion rows.
            VStack(alignment: .leading, spacing: 10) {
                SectionHeader("Try Asking")
                VStack(spacing: 10) {
                    ForEach(Self.tryAskingPrompts, id: \.self) { prompt in
                        Button {
                            prefill(prompt)
                        } label: {
                            tryAskingRow(prompt)
                        }
                        .buttonStyle(.pressable)
                        .accessibilityLabel("Try asking: \(prompt)")
                    }
                }
            }
        }
        .padding()
    }

    /// "Agent Ready" hero card — status + Model / Provider / Workspace columns.
    private var agentReadyCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "sparkles")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(CC.accent)
                    .frame(width: 44, height: 44)
                    .background(CC.accentDim, in: RoundedRectangle(cornerRadius: Theme.cornerSmall, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: Theme.cornerSmall, style: .continuous)
                        .strokeBorder(CC.strokeGreen, lineWidth: 1))
                // The unshrinkable status pill sits beside the title only when it
                // fits; at larger text sizes it drops below so "Agent Ready" never
                // truncates to "Agent Re…".
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .top, spacing: 6) {
                        agentReadyHeadline
                        Spacer(minLength: 6)
                        agentReadyStatusPill
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        agentReadyHeadline
                        agentReadyStatusPill
                    }
                }
            }

            Divider().overlay(Theme.separator)

            HStack(alignment: .top, spacing: 12) {
                LabeledStat(
                    icon: "cube",
                    label: "Model",
                    value: engine.smartRoutingEnabled ? "Auto-Route" : engine.selectedModel
                )
                LabeledStat(
                    icon: "cloud",
                    label: "Provider",
                    value: engine.activeProvider.displayName,
                    verified: engine.hasProviderKey
                )
                LabeledStat(
                    icon: "arrow.triangle.branch",
                    label: "Workspace",
                    value: engine.activeWorkspace?.slug ?? "—",
                    verified: engine.pendingChanges.isEmpty
                )
            }
        }
        .padding(18)
        .commandCard(glow: true)
    }

    private var agentReadyHeadline: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("Agent Ready")
                .font(.headline.weight(.bold))
                .foregroundStyle(CC.text)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            Text("I'm ready to help you manage your site.")
                .font(.caption)
                .foregroundStyle(CC.textSub)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var agentReadyStatusPill: some View {
        compactAgentStatusPill(
            text: engine.isReady ? "All systems operational" : "Setup required",
            tint: engine.isReady ? CC.accent : Theme.warn
        )
    }

    private func compactAgentStatusPill(text: String, tint: Color) -> some View {
        HStack(spacing: 5) {
            Circle().fill(tint).frame(width: 6, height: 6)
            Text(text)
                .font(.mono(10, .semibold))
                .lineLimit(1)
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(tint.opacity(0.14), in: Capsule())
        .fixedSize()
        .accessibilityElement(children: .combine)
    }

    private func starterCard(_ template: CommandTemplate) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top) {
                Image(systemName: template.icon)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Theme.brandGradient)
                    .frame(width: 32, height: 32)
                    .background(Theme.brandSoft, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .strokeBorder(Theme.glassBorder, lineWidth: 1))
                Spacer(minLength: 0)
                Image(systemName: "arrow.up.right")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(Theme.brand)
                    .frame(width: 20, height: 20)
                    .background(Circle().fill(Theme.brand.opacity(0.12)))
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(template.title.localized)
                    .font(.ui(14, .semibold))
                    .foregroundStyle(Theme.t1)
                    .lineLimit(1).minimumScaleFactor(0.8)
                Text(template.subtitle.localized)
                    .font(.caption2)
                    .foregroundStyle(Theme.t2)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 92, alignment: .topLeading)
        .padding(12)
        .commandCard()
    }

    private func tryAskingRow(_ prompt: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "message.fill")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Theme.brand)
                .frame(width: 30, height: 30)
                .background(Theme.brandSoft, in: Circle())
            Text(prompt)
                .font(.subheadline)
                .foregroundStyle(Theme.t1)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
            Image(systemName: "arrow.right")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(Theme.t2)
                .frame(width: 26, height: 26)
                .background(Theme.chip, in: Circle())
                .overlay(Circle().strokeBorder(Theme.separator, lineWidth: 1))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .commandCard()
    }

    static let templates = [
        CommandTemplate(
            id: "conversion", title: "Improve Conversion",
            subtitle: "Clarify value, trust, and calls to action",
            icon: "chart.line.uptrend.xyaxis",
            prompt: "Audit the homepage for conversion opportunities. Inspect the value proposition, visual hierarchy, primary call to action, trust signals, navigation, and mobile experience. Use only verified facts already present in the repository—do not invent testimonials, customers, awards, or metrics. Rank the highest-impact improvements, then stage a focused first pass while preserving the site's brand."
        ),
        CommandTemplate(
            id: "web-vitals", title: "Speed Up the Site",
            subtitle: "Target LCP, INP, and layout stability",
            icon: "gauge.with.dots.needle.67percent",
            prompt: "Run a performance-focused code audit for Core Web Vitals: Largest Contentful Paint (LCP), Interaction to Next Paint (INP), and Cumulative Layout Shift (CLS). Inspect the likely LCP resource, render-blocking assets, JavaScript long tasks, image dimensions and formats, font loading, third-party scripts, caching, and lazy loading. Separate measured evidence from code-based inference, rank findings by likely user impact, and stage only safe high-confidence fixes."
        ),
        CommandTemplate(
            id: "search", title: "Modern SEO Audit",
            subtitle: "Improve discovery without keyword stuffing",
            icon: "magnifyingglass",
            prompt: "Audit the site using current technical SEO practices. Review crawlability, robots.txt, sitemap and canonical URLs; unique descriptive titles and snippets; heading and internal-link structure; image alt text; Open Graph metadata; descriptive URLs; and stale or duplicated content. Identify the pages with the clearest opportunity, explain why each change helps users and search engines, and stage accurate fixes without keyword stuffing or unsupported claims."
        ),
        CommandTemplate(
            id: "accessibility", title: "Accessibility Pass",
            subtitle: "Check WCAG 2.2 AA essentials",
            icon: "accessibility",
            prompt: "Run a WCAG 2.2 AA accessibility pass. Inspect semantic landmarks and heading order, keyboard access and visible focus, accessible names and form labels, alt text, contrast, reflow and text resizing, target sizes, reduced motion, status and error messages, and authentication or drag interactions if present. Report issues with file references and severity, then stage the highest-impact fixes without changing the site's visual identity unnecessarily."
        ),
        CommandTemplate(
            id: "responsive", title: "Polish Every Screen",
            subtitle: "Fix responsive layout and touch UX",
            icon: "rectangle.on.rectangle.angled",
            prompt: "Audit the site from small phones through tablets and wide desktops. Check content reflow, horizontal overflow, navigation, touch targets, readable line lengths, fluid type and spacing, media sizing, safe areas, hover-only interactions, and orientation changes. Prioritize problems that block content or actions, then stage responsive fixes using the existing design system."
        ),
        CommandTemplate(
            id: "structured-data", title: "Add Rich Results",
            subtitle: "Use accurate JSON-LD structured data",
            icon: "curlybraces.square",
            prompt: "Inspect the site's real content and recommend only the structured data types that genuinely apply. Add or correct maintainable JSON-LD with complete, accurate required properties; do not fabricate ratings, prices, authors, business details, FAQs, or other facts. Check that the markup matches visible page content and explain how to validate it before deployment."
        ),
        CommandTemplate(
            id: "forms", title: "Upgrade Forms",
            subtitle: "Make forms clearer, faster, and safer",
            icon: "rectangle.and.pencil.and.ellipsis",
            prompt: "Audit every form and improve completion UX. Check labels, input types, autocomplete, keyboard behavior, inline validation, helpful error recovery, loading and success states, duplicate submission prevention, accessibility, privacy copy, and spam resistance. Preserve the existing backend contract and styling, call out any server-side work required, and stage the safest client-side improvements first."
        ),
        CommandTemplate(
            id: "security", title: "Harden the Website",
            subtitle: "Review secrets, dependencies, and headers",
            icon: "lock.shield",
            prompt: "Perform a defensive website security review. Look for exposed secrets, unsafe HTML injection, insecure external links, risky dependency usage, overly broad CORS, missing or conflicting security headers, mixed content, and sensitive data in client code or logs. Account for the current hosting platform, avoid breaking required integrations, never print secret values, and present findings by severity before staging targeted fixes."
        ),
        CommandTemplate(
            id: "deployment", title: "Check Deployment Health",
            subtitle: "Diagnose build, runtime, and release risks",
            icon: "shippingbox.and.arrow.backward",
            prompt: "Inspect the repository and connected deployment configuration for release risks. Review build scripts, environment-variable expectations without exposing values, redirects and routes, asset paths, runtime compatibility, caching rules, CI configuration, and recent available logs or status. Diagnose evidence first, distinguish warnings from blockers, and stage the smallest fix for confirmed issues."
        ),
        CommandTemplate(
            id: "content-refresh", title: "Refresh Site Content",
            subtitle: "Find stale, unclear, or inconsistent copy",
            icon: "text.badge.checkmark",
            prompt: "Audit the site's content for freshness, clarity, consistency, and useful information scent. Find outdated dates, broken or vague calls to action, duplicated copy, inconsistent product names, unsupported claims, dead links, and pages that lack a clear next step. Suggest a prioritized content plan and stage improvements using only facts verified in the repository; mark anything that needs owner input instead of guessing."
        )
    ]

    /// "Try Asking" suggestion prompts — prefill-only, paywall-gated.
    static let tryAskingPrompts = [
        "Find the three highest-impact homepage improvements and explain the evidence before editing",
        "Check every internal and external link, then fix confirmed broken destinations",
        "Create polished loading, empty, error, offline, and 404 states that match the current design",
        "Optimize images and fonts without visible quality loss or layout shifts",
        "Improve the mobile navigation for keyboard, touch, and screen-reader users",
        "Review analytics and cookie code for unnecessary tracking and unclear consent",
        "Turn repeated colors, spacing, typography, and buttons into a consistent design system",
        "Inspect the live-site configuration and repository for anything that could fail on the next deploy"
    ]

    private var inputBar: some View {
        VStack(spacing: 8) {
            if engine.sessionCostUSD > 0 {
                sessionCostChip
                if engine.spendCapUSD > 0 {
                    spendCapProgress
                }
            }
            if let lockMessage {
                lockBanner(lockMessage)
            } else if engine.usingOnDevice && !iap.isPro && iap.onDeviceTrialStart > 0 {
                trialBanner(daysLeft: iap.onDeviceTrialDaysRemaining)
            } else if showFreeSessionsChip {
                freeSessionsChip
            }
            if engine.isWaitingForConnection {
                HStack(spacing: 6) {
                    Image(systemName: "wifi.exclamationmark")
                    Text("Connection lost — retrying automatically. Nothing is discarded.")
                    Spacer(minLength: 0)
                }
                .font(.caption.weight(.medium))
                .foregroundStyle(Theme.warn)
                .padding(.horizontal, 10).padding(.vertical, 7)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.warn.opacity(0.14), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
            if visionWarning {
                HStack(spacing: 6) {
                    Image(systemName: "eye.slash.fill")
                    Text("\(engine.activeProvider.displayName) can't view images — switch to a vision-capable model like Claude or Copilot in Settings.")
                    Spacer(minLength: 0)
                }
                .font(.caption.weight(.medium))
                .foregroundStyle(Theme.warn)
                .padding(.horizontal, 10).padding(.vertical, 7)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.warn.opacity(0.14), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
            if let notice = engine.contextCompactionNotice {
                ContextCompactionBanner(message: notice)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
            if !attachments.isEmpty {
                attachmentStrip
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
            composerControls
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        // Status and entitlement banners deliberately remain outside the
        // composer plate so they never refract into its controls.
        .animation(Theme.snappy, value: attachments.count)
        .animation(Theme.snappy, value: engine.isWaitingForConnection)
        .confirmationDialog("Add to chat", isPresented: $showAttachMenu, titleVisibility: .visible) {
            Button("Clipboard") { showClipboard = true }
            Button("Photo Library") { showPhotoPicker = true }
            Button("Choose File") { showFileImporter = true }
            Button("Create or Edit Image") { showImageStudio = true }
            Button("Cancel", role: .cancel) {}
        }
        .photosPicker(isPresented: $showPhotoPicker, selection: $photoItems,
                      maxSelectionCount: 5, matching: .images)
        .onChange(of: photoItems) { _, items in
            guard !items.isEmpty else { return }
            Task { await loadPhotos(items) }
        }
        .fileImporter(isPresented: $showFileImporter,
                      allowedContentTypes: [.item], allowsMultipleSelection: true) { handleFileImport($0) }
        .sheet(isPresented: $showImageStudio) {
            ImageStudioView { attachment in
                withAnimation(Theme.snappy) { attachments.append(attachment) }
            }
        }
    }

    /// The whole chat composer is one independent plate. The field receives a
    /// second inner layer, while banners above remain visually separate.
    private var composerControls: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                composerModelChip
                if inputFocused {
                    dismissKeyboardButton
                        .transition(.opacity.combined(with: .scale(scale: 0.96)))
                }
                Spacer(minLength: 0)
            }
            HStack(alignment: .bottom, spacing: 10) {
                attachButton
                TextField(placeholderText, text: $draft, axis: .vertical)
                    .lineLimit(1...5)
                    .focused($inputFocused)
                    .disabled(!engine.isReady)
                    .padding(.horizontal, 14).padding(.vertical, 10)
                    .modifier(ChatComposerFieldSurface(focused: inputFocused))
                    .animation(Theme.snappy, value: inputFocused)
                if engine.state.isActive { stopButton }
                else if engine.state == .awaitingUserApproval { cancelApprovalButton }
                sendButton
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .modifier(ChatComposerOuterSurface(
            skin: engine.skin,
            classicFill: secondaryBG
        ))
    }

    private var attachButton: some View {
        Button { Haptics.tap(); showAttachMenu = true } label: {
            Image(systemName: "plus")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(Theme.brand)
                .frame(width: 38, height: 38)
                .modifier(ChatComposerIconSurface())
                .frame(width: 44, height: 44)   // 44pt hit target
                .contentShape(Circle())
        }
        .buttonStyle(.pressable)
        .disabled(!engine.isReady)
        .accessibilityLabel("Add attachment")
    }

    private var dismissKeyboardButton: some View {
        Button {
            inputFocused = false
        } label: {
            Image(systemName: "keyboard.chevron.compact.down")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Theme.t2)
                .frame(width: 34, height: 28)
                .background(Theme.chip, in: Capsule())
                .overlay(Capsule().strokeBorder(Theme.separator, lineWidth: 1))
                .contentShape(Capsule())
        }
        .buttonStyle(.pressable)
        .accessibilityLabel("Dismiss keyboard")
    }

    private var attachmentStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(attachments) { att in
                    AttachmentChip(attachment: att) {
                        withAnimation(Theme.snappy) { attachments.removeAll { $0.id == att.id } }
                    }
                }
            }
            .padding(.horizontal, 2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var canSend: Bool {
        let hasContent = !draft.trimmingCharacters(in: .whitespaces).isEmpty || !attachments.isEmpty
        // Allow sending during active run (intervention) or approval (approval response)
        return hasContent && engine.isReady && usageGateOK && !engine.commitInFlight
    }

    /// Provider-aware usage gate: on-device uses the 3-day trial / Pro check,
    /// remote providers use the monthly free-session meter.
    private var usageGateOK: Bool {
        if engine.state.isActive { return true }
        if engine.state == .awaitingUserApproval { return true }
        if !iap.isPro && engine.isCurrentProviderProOnly { return false }
        return engine.usingOnDevice ? iap.canUseOnDevice : iap.canRunAgentLoop
    }

    private var placeholderText: String {
        if engine.commitInFlight {
            return "Committing approved changes…"
        }
        if !usageGateOK {
            if !iap.isPro && engine.isCurrentProviderProOnly {
                return "Switch to GitHub Copilot or unlock Super"
            }
            return engine.usingOnDevice ? "On-device trial ended — Unlock Super" : "Super required for more agent sessions"
        }
        if engine.state.isActive {
            return engine.isWaitingForConnection
                ? "Add a message while reconnecting…"
                : "Interrupt with a new instruction…"
        }
        if engine.state == .awaitingUserApproval {
            return "Type \"proceed\" to approve, or a new instruction…"
        }
        return engine.isReady ? "Tell the agent what to change…" : "Add your keys in Settings to start"
    }

    /// The red "locked" banner message, if the current provider is gated off.
    private var lockMessage: String? {
        if engine.state.isActive { return nil }
        if engine.state == .awaitingUserApproval { return nil }
        if !iap.isPro && engine.isCurrentProviderProOnly {
            return "\(engine.activeProvider.displayName) requires Super. Switch to GitHub Copilot or unlock Super."
        }
        if engine.usingOnDevice {
            return iap.canUseOnDevice ? nil : "On-device free trial ended. Unlock Super to keep running local models."
        }
        if iap.canRunAgentLoop { return nil }
        // Frame the wall as temporary: it resets on a known date, so it reads as
        // "come back / upgrade" rather than a permanent dead end.
        let resets = iap.freeSessionsResetDate.formatted(.dateTime.month().day())
        return "Free limit reached — resets \(resets). Unlock Super for unlimited sessions."
    }

    private func lockBanner(_ message: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "lock.fill")
            Text(message)
            Spacer(minLength: 6)
            VStack(alignment: .trailing, spacing: 3) {
                Button("Unlock Super") { Haptics.tap(); paywallContext = .wall; showPaywall = true }
                    .font(.caption.weight(.bold))
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .background(Theme.actionGradient, in: Capsule())
                    .foregroundStyle(.white)
                // Returning/already-paid users self-serve here instead of being
                // pushed to buy again.
                Button("Already Super? Restore") {
                    Haptics.tap()
                    Task { await iap.restorePurchases() }
                }
                .font(.caption2.weight(.semibold))
                .foregroundStyle(Theme.brand)
            }
        }
        .font(.caption.weight(.medium))
        .foregroundStyle(.red)
        .padding(.horizontal, 10).padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.red.opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .transition(.opacity.combined(with: .move(edge: .bottom)))
    }

    /// Shown when `ContextBudgeter` trims older turns to fit the model's
    /// context window, so a long conversation's history loss is visible
    /// instead of silent.
    struct ContextCompactionBanner: View {
        let message: String

        var body: some View {
            Label {
                Text(message)
                    .fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: "rectangle.compress.vertical")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 10).padding(.vertical, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .accessibilityLabel("Context compacted")
            .accessibilityValue(message)
        }
    }

    /// Show the free-session meter only for free users actually spending the
    /// monthly remote allowance (not on-device, not a pro-only-locked provider,
    /// and only once setup is done so it isn't noise pre-onboarding).
    private var showFreeSessionsChip: Bool {
        !iap.isPro && engine.isReady && !engine.usingOnDevice
            && !engine.isCurrentProviderProOnly && lockMessage == nil
    }

    /// "N of 8 free sessions left" — makes the finite allowance visible while the
    /// user is working, instead of only at the wall. Turns amber and pre-sells
    /// Super when 1–2 remain.
    private var freeSessionsChip: some View {
        let remaining = iap.freeSessionsRemaining
        let low = remaining <= 2
        return Button {
            Haptics.tap(); paywallContext = .wall; showPaywall = true
        } label: {
            HStack(spacing: 6) {
                Image(systemName: low ? "exclamationmark.triangle.fill" : "bolt.horizontal.circle")
                    .contentTransition(.symbolEffect(.replace))
                Text(low
                     ? "Only \(remaining) free session\(remaining == 1 ? "" : "s") left — go unlimited with Super"
                     : "\(remaining) of \(IAPManager.freeSessionLimit) free sessions left this month")
                    .contentTransition(.opacity)
                Spacer(minLength: 0)
            }
            .font(.caption2.weight(.medium))
            .foregroundStyle(low ? .orange : .secondary)
            .padding(.horizontal, 10).padding(.vertical, 5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background((low ? Color.orange : Color.secondary).opacity(0.1),
                        in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .animation(reduceMotion ? nil : Theme.snappy, value: remaining)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(remaining) free sessions left this month. Tap to upgrade to Super.")
    }

    private func trialBanner(daysLeft: Int) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "bolt.fill")
            Text("On-device free trial — \(daysLeft) day\(daysLeft == 1 ? "" : "s") left.")
            Spacer()
            Button("Get Super") { Haptics.tap(); paywallContext = .onDevice; showPaywall = true }
                .font(.caption.weight(.bold))
        }
        .font(.caption.weight(.medium))
        .foregroundStyle(Theme.brand)
        .padding(.horizontal, 10).padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.brand.opacity(0.10), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .transition(.opacity.combined(with: .move(edge: .bottom)))
    }

    /// Shown when the user attaches an image but the active model is text-only.
    private var visionWarning: Bool {
        attachments.contains(where: \.isImage) && !engine.activeModelCapabilities.supportsImageInput
    }

    private var stopButton: some View {
        Button {
            Haptics.tap()
            engine.stop()
        } label: {
            Image(systemName: "stop.fill")
                .font(.system(size: 16, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 38, height: 38)
                .background(Color.red)
                .clipShape(Circle())
                .shadow(color: Color.red.opacity(0.45), radius: 8, y: 3)
                .frame(width: 44, height: 44)   // 44pt hit target
                .contentShape(Circle())
        }
        .keyboardShortcut(".", modifiers: .command)   // ⌘. cancels (iPad/Mac)
        .accessibilityLabel("Stop generating")
    }

    private var cancelApprovalButton: some View {
        Button {
            Haptics.tap()
            engine.cancelApproval()
        } label: {
            Image(systemName: "xmark")
                .font(.system(size: 16, weight: .bold))
                .foregroundStyle(.orange)
                .frame(width: 38, height: 38)
                .background(Color.orange.opacity(0.15))
                .clipShape(Circle())
                .frame(width: 44, height: 44)
                .contentShape(Circle())
        }
        .accessibilityLabel("Cancel approval")
    }

    private var sendButton: some View {
        Button {
            let isActive = engine.state.isActive
            Haptics.tap()
            // send() is synchronous; clear the composer only once the message is
            // accepted, so a gate rejection (paywall, meter) can't destroy the draft.
            if engine.send(draft, attachments: attachments) {
                withAnimation(Theme.snappy) { draft = ""; attachments = [] }
                inputFocused = isActive
            }
        } label: {
            Image(systemName: "arrow.up")
                .font(.system(size: 18, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 38, height: 38)
                .background {
                    if canSend {
                        Circle().fill(Theme.actionGradient)
                    } else {
                        Circle().fill(Color(.tertiarySystemFill))
                    }
                }
                .shadow(color: canSend ? Theme.brand.opacity(0.45) : .clear, radius: 8, y: 3)
                .scaleEffect(canSend ? 1 : 0.9)
                .animation(Theme.snappy, value: canSend)
                .frame(width: 44, height: 44)   // 44pt hit target
                .contentShape(Circle())
        }
        .disabled(!canSend)
        .keyboardShortcut(.return, modifiers: .command)   // ⌘↩ sends (iPad/Mac)
        .accessibilityLabel(engine.state.isActive ? "Interrupt with message" : (engine.state == .awaitingUserApproval ? "Approve or send message" : "Send message"))
    }

    // MARK: - Attachment loading

    private func loadPhotos(_ items: [PhotosPickerItem]) async {
        for item in items {
            guard let data = try? await item.loadTransferable(type: Data.self) else { continue }
            if data.count > AgentEngine.maxAttachmentBytes {
                engine.lastError = "Photo is too large (max 12 MB)."
                continue
            }
            let type = item.supportedContentTypes.first
            let ext = type?.preferredFilenameExtension ?? "jpg"
            let mime = type?.preferredMIMEType ?? "image/jpeg"
            guard Self.isAllowedAttachmentMIME(mime, filename: "x.\(ext)") else {
                engine.lastError = "Unsupported photo type."
                continue
            }
            let name = "image-\(attachments.count + 1).\(ext)"
            withAnimation(Theme.snappy) {
                attachments.append(Attachment(filename: name, mimeType: mime, data: data))
            }
        }
        photoItems = []
        Haptics.tap()
    }

    private func handleFileImport(_ result: Result<[URL], Error>) {
        guard case .success(let urls) = result else { return }
        for url in urls {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            guard let data = try? Data(contentsOf: url) else { continue }
            if data.count > AgentEngine.maxAttachmentBytes {
                engine.lastError = "“\(url.lastPathComponent)” is too large (max 12 MB)."
                continue
            }
            let mime = UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
            guard Self.isAllowedAttachmentMIME(mime, filename: url.lastPathComponent) else {
                engine.lastError = "Unsupported file type for “\(url.lastPathComponent)”."
                continue
            }
            withAnimation(Theme.snappy) {
                attachments.append(Attachment(filename: url.lastPathComponent, mimeType: mime, data: data))
            }
        }
        Haptics.tap()
    }

    /// Allow common web/image/text assets; reject archives/executables/video.
    private static func isAllowedAttachmentMIME(_ mime: String, filename: String) -> Bool {
        let lower = mime.lowercased()
        let ext = (filename as NSString).pathExtension.lowercased()
        let blockedExt: Set<String> = [
            "exe", "dll", "bat", "cmd", "sh", "ps1", "jar", "apk", "dmg", "pkg",
            "zip", "rar", "7z", "tar", "gz", "bz2", "xz",
            "mp4", "mov", "avi", "mkv", "webm", "mp3", "wav", "flac"
        ]
        if blockedExt.contains(ext) { return false }
        if lower.hasPrefix("image/") { return true }
        if lower.hasPrefix("text/") { return true }
        let allowed: Set<String> = [
            "application/json", "application/javascript", "application/xml",
            "application/pdf", "application/octet-stream",
            "font/woff", "font/woff2", "font/ttf", "font/otf"
        ]
        if allowed.contains(lower) { return true }
        let allowedExt: Set<String> = [
            "html", "htm", "css", "js", "mjs", "json", "svg", "txt", "md", "xml",
            "png", "jpg", "jpeg", "gif", "webp", "avif", "bmp", "ico",
            "woff", "woff2", "ttf", "otf", "pdf", "csv"
        ]
        return allowedExt.contains(ext)
    }

    private func insertClipboardText(_ text: String) {
        let separator = draft.isEmpty || draft.hasSuffix("\n") ? "" : "\n"
        draft += separator + text
        inputFocused = true
        Haptics.tap()
    }

    private func attachClipboardImage(_ image: UIImage) {
        guard let data = image.pngData() else { return }
        if data.count > AgentEngine.maxAttachmentBytes {
            engine.lastError = "Clipboard image is too large (max 12 MB)."
            return
        }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let filename = "clipboard-\(formatter.string(from: Date())).png"
        attachments.append(Attachment(filename: filename, mimeType: "image/png", data: data))
        Haptics.tap()
    }
}

struct ModelCapabilityBadges: View {
    let capabilities: ModelCapabilities
    var size: CGFloat = 16

    private var labels: [String] {
        var values: [String] = []
        if capabilities.supportsImageInput { values.append("vision") }
        if capabilities.supportsTools { values.append("tools") }
        if capabilities.supportsReasoningSummary { values.append("reasoning summary") }
        return values
    }

    var body: some View {
        HStack(spacing: 3) {
            if capabilities.supportsImageInput {
                badge("eye.fill", tint: Theme.brand)
            }
            if capabilities.supportsTools {
                badge("wrench.and.screwdriver.fill", tint: Theme.ok)
            }
            if capabilities.supportsReasoningSummary {
                badge("brain.head.profile", tint: Theme.warn)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(labels.isEmpty ? "No extra model capabilities" : "Model supports \(labels.joined(separator: ", "))")
    }

    private func badge(_ systemImage: String, tint: Color) -> some View {
        Image(systemName: systemImage)
            .font(.system(size: max(9, size * 0.58), weight: .semibold))
            .foregroundStyle(tint)
            .frame(width: size, height: size)
            .background(tint.opacity(0.13), in: Circle())
    }
}

// MARK: - Clipboard

struct ClipboardSnippet: Identifiable, Codable, Equatable {
    let id: UUID
    var text: String
    var date: Date

    init(id: UUID = UUID(), text: String, date: Date = Date()) {
        self.id = id
        self.text = text
        self.date = date
    }
}

@MainActor
final class ClipboardManager: ObservableObject {
    static let shared = ClipboardManager()

    @Published private(set) var snippets: [ClipboardSnippet] = []
    @Published private(set) var currentText: String?
    @Published private(set) var currentImage: UIImage?

    private let storageKey = "siteAgent.clipboardSnippets"
    private let maximumSnippets = 20
    private let maximumStoredCharacters = 20_000
    private init() {
        // Migrate away from UserDefaults persistence (unencrypted). Keep in-memory
        // only for the session — secrets copied into the clipboard must not land
        // in the preferences plist.
        UserDefaults.standard.removeObject(forKey: storageKey)
        snippets = []
    }

    /// Reads the system pasteboard only after the user explicitly opens the
    /// clipboard sheet, avoiding surprise privacy prompts.
    func refreshFromSystem() {
        currentText = UIPasteboard.general.string
        currentImage = UIPasteboard.general.image
    }

    func remember(_ text: String) {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        // Never retain high-entropy / secret-shaped clipboard content.
        if SecretRedactor.looksLikeSecret(text) { return }
        let stored = String(SecretRedactor.redact(text).prefix(maximumStoredCharacters))
        snippets.removeAll { $0.text == stored }
        snippets.insert(ClipboardSnippet(text: stored), at: 0)
        if snippets.count > maximumSnippets {
            snippets.removeLast(snippets.count - maximumSnippets)
        }
        // Session-only: do not write to UserDefaults / disk.
    }

    func copy(_ text: String) {
        // Redact secret-shaped substrings before they hit the system pasteboard.
        let safe = SecretRedactor.redact(text)
        UIPasteboard.general.string = safe
        currentText = safe
        currentImage = nil
        remember(safe)
    }

    func remove(_ id: UUID) {
        snippets.removeAll { $0.id == id }
        persist()
    }

    func clear() {
        snippets.removeAll()
        persist()
    }

    private func persist() {
        // Intentionally no-op: clipboard history is session-only (see init/remember).
        UserDefaults.standard.removeObject(forKey: storageKey)
    }
}

struct ClipboardManagerSheet: View {
    @StateObject private var manager = ClipboardManager.shared
    @Environment(\.dismiss) private var dismiss
    let onInsertText: (String) -> Void
    let onAttachImage: (UIImage) -> Void

    var body: some View {
        NavigationStack {
            List {
                Section("Current Clipboard") {
                    if let text = manager.currentText, !text.isEmpty {
                        Button {
                            manager.remember(text)
                            onInsertText(text)
                            dismiss()
                        } label: {
                            Label {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("Insert clipboard text").font(.body.weight(.semibold))
                                    Text(text).font(.caption).foregroundStyle(.secondary).lineLimit(3)
                                }
                            } icon: {
                                Image(systemName: "doc.on.clipboard")
                            }
                        }
                    }

                    if let image = manager.currentImage {
                        Button {
                            onAttachImage(image)
                            dismiss()
                        } label: {
                            HStack(spacing: 12) {
                                Image(uiImage: image)
                                    .resizable()
                                    .scaledToFill()
                                    .frame(width: 48, height: 48)
                                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                                Label("Attach clipboard image", systemImage: "photo.badge.plus")
                            }
                        }
                    }

                    if manager.currentText == nil && manager.currentImage == nil {
                        ContentUnavailableView(
                            "Clipboard is empty",
                            systemImage: "clipboard",
                            description: Text("Copy text or an image, then refresh.")
                        )
                    }

                    Button {
                        manager.refreshFromSystem()
                    } label: {
                        Label("Refresh clipboard", systemImage: "arrow.clockwise")
                    }
                }

                Section {
                    if manager.snippets.isEmpty {
                        Text("Text inserted or copied from chat will appear here.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(manager.snippets) { snippet in
                            Button {
                                onInsertText(snippet.text)
                                dismiss()
                            } label: {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(snippet.text)
                                        .foregroundStyle(.primary)
                                        .lineLimit(3)
                                    Text(snippet.date, style: .relative)
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .swipeActions {
                                Button(role: .destructive) {
                                    manager.remove(snippet.id)
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                                Button {
                                    manager.copy(snippet.text)
                                    Haptics.tap()
                                } label: {
                                    Label("Copy", systemImage: "doc.on.doc")
                                }
                                .tint(Theme.brand)
                            }
                        }
                    }
                } header: {
                    Text("Recent Text")
                } footer: {
                    Text("Stored only on this device. Images are attached directly and are not kept in history.")
                }
            }
            .navigationTitle("Clipboard")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Close") { dismiss() }
                }
                if !manager.snippets.isEmpty {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Clear", role: .destructive) { manager.clear() }
                    }
                }
            }
            .onAppear {
                manager.refreshFromSystem()
            }
        }
    }
}

// MARK: - Attachment views

/// A removable chip shown in the input bar for a pending attachment.
struct AttachmentChip: View {
    let attachment: Attachment
    var onRemove: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            thumbnail
            Text(attachment.filename)
                .font(.caption.weight(.medium)).lineLimit(1)
                .frame(maxWidth: 110)
            Button(action: onRemove) {
                Image(systemName: "xmark.circle.fill")
                    .font(.body).foregroundStyle(.secondary)
            }
        }
        .padding(5).padding(.trailing, 4)
        .background(Color(.secondarySystemBackground), in: Capsule())
        .overlay(Capsule().strokeBorder(Color.primary.opacity(0.06), lineWidth: 1))
    }

    @ViewBuilder private var thumbnail: some View {
        if attachment.isImage, let ui = UIImage(data: attachment.data) {
            Image(uiImage: ui).resizable().scaledToFill()
                .frame(width: 28, height: 28)
                .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                .accessibilityLabel("Image attachment, \(attachment.filename)")
        } else {
            Image(systemName: "doc.fill")
                .foregroundStyle(Theme.brandGradient)
                .frame(width: 28, height: 28)
        }
    }
}

/// An attachment rendered under a user message in the transcript.
struct UserAttachmentView: View {
    let attachment: Attachment
    @EnvironmentObject var engine: AgentEngine
    @Environment(\.secondarySurface) private var secondaryBG

    var body: some View {
        if attachment.isImage, let ui = UIImage(data: attachment.data) {
            Image(uiImage: ui).resizable().scaledToFill()
                .frame(maxWidth: 220, maxHeight: 220)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1))
                .accessibilityLabel("Image attachment, \(attachment.filename)")
        } else {
            HStack(spacing: 8) {
                Image(systemName: "doc.fill").foregroundStyle(Theme.brandGradient)
                VStack(alignment: .leading, spacing: 1) {
                    Text(attachment.filename).font(.caption.weight(.medium)).lineLimit(1)
                    Text(ByteCountFormatter.string(fromByteCount: Int64(attachment.byteCount), countStyle: .file))
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
            .padding(10)
            .background(secondaryBG, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
    }
}

// MARK: - Setup card

struct SetupCard: View {
    @EnvironmentObject var engine: AgentEngine
    let onOpenSettings: () -> Void
    var onStartDemo: (() -> Void)? = nil
    /// Deep-link for the "connect a website" step → Connect wizard (preferred)
    /// or AddWorkspaceSheet. Falls back to Workspace settings.
    var onConnectSite: (() -> Void)? = nil
    /// Opens the 4-step Connect Website wizard when available.
    var onConnectWizard: (() -> Void)? = nil

    var body: some View {
        // Full-screen first-run layout: content lives directly on the backdrop
        // (no enclosing box) — a hero header, each todo as its own floating row,
        // and big actions.
        VStack(alignment: .leading, spacing: 24) {
            SetupCardHeader()
            SetupTodoList(items: engine.setupTodoItems, onSelect: handle)
            SetupCardActions(
                onPrimary: {
                    if engine.setupTodoItems.contains(where: { $0.kind == .site }),
                       let onConnectWizard {
                        onConnectWizard()
                    } else {
                        onOpenSettings()
                    }
                },
                primaryTitle: engine.setupTodoItems.contains(where: { $0.kind == .site })
                    ? "Connect Website"
                    : "Open Workspace",
                primarySystemImage: engine.setupTodoItems.contains(where: { $0.kind == .site })
                    ? "sparkles"
                    : "gearshape.fill",
                onOpenSettings: onOpenSettings,
                onStartDemo: onStartDemo
            )
        }
        .padding(.vertical, 16)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func handle(_ item: AgentEngine.SetupTodoItem) {
        Haptics.tap()
        switch item.kind {
        case .site:
            if let onConnectWizard {
                onConnectWizard()
            } else {
                (onConnectSite ?? onOpenSettings)()
            }
        case .ai:
            if engine.activeWorkspace == nil, let onConnectWizard {
                engine.requestedWizardStep = .assistant
                onConnectWizard()
            } else {
                engine.openWorkspace(.assistant)
                onOpenSettings()
            }
        case .token:
            if let onConnectWizard {
                engine.requestedWizardStep = .github
                onConnectWizard()
            } else {
                engine.openWorkspace(.github)
                onOpenSettings()
            }
        }
    }
}

private struct SetupCardHeader: View {
    var body: some View {
        // Screen-scale hero, not a widget header.
        VStack(alignment: .leading, spacing: 14) {
            Group {
                if Theme.isGlass {
                    Image(systemName: "wand.and.stars")
                        .font(.system(size: 26, weight: .semibold))
                        .foregroundStyle(Theme.brand)
                        .frame(width: 60, height: 60)
                        .glassSurface(.icon, cornerRadius: 18, accentReflection: Theme.brand)
                } else {
                    Image(systemName: "wand.and.stars")
                        .font(.system(size: 26, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 60, height: 60)
                        .background(Theme.brandGradient, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                        .shadow(color: Theme.brand.opacity(0.35), radius: 16, y: 8)
                }
            }
            .accessibilityHidden(true)
            Text("Finish setup")
                .font(.display(32, .heavy, relativeTo: .largeTitle))
                .foregroundStyle(CC.text)
            Text("Connect the missing pieces and Website Commander can edit, preview, and deploy.")
                .font(.ui(16))
                .foregroundStyle(CC.textSub)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct SetupTodoList: View {
    let items: [AgentEngine.SetupTodoItem]
    let onSelect: (AgentEngine.SetupTodoItem) -> Void

    var body: some View {
        // Each todo floats on its own row surface (glass under Clear Glass,
        // flat cell on classic) instead of a divided list inside one box.
        VStack(spacing: 10) {
            ForEach(items.indices, id: \.self) { index in
                let item = items[index]
                Button {
                    onSelect(item)
                } label: {
                    SetupTodoRow(item: item)
                        .padding(.horizontal, 14)
                        .commandCard(cornerRadius: 18)
                }
                .buttonStyle(.pressable)
            }
        }
        .accessibilityElement(children: .contain)
    }
}

private struct SetupTodoRow: View {
    let item: AgentEngine.SetupTodoItem

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Theme.brand)
                .frame(width: 30, height: 30)
                .modifier(SetupTodoIconSurface())
                .accessibilityHidden(true)
            Text(item.label.localized)
                .font(.ui(15, .semibold))
                .foregroundStyle(CC.text)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
                .layoutPriority(1)
            Spacer(minLength: 8)
            Image(systemName: "chevron.right")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(CC.textSub)
                .accessibilityHidden(true)
        }
        .padding(.vertical, 15)
        .contentShape(Rectangle())
    }

    private var icon: String {
        switch item.kind {
        case .site: return "globe"
        case .ai: return "sparkles"
        case .token: return "key.fill"
        }
    }
}

private struct SetupCardActions: View {
    let onPrimary: () -> Void
    let primaryTitle: String
    let primarySystemImage: String
    let onOpenSettings: () -> Void
    let onStartDemo: (() -> Void)?

    var body: some View {
        ViewThatFits {
            HStack(spacing: 10) { buttons }
            VStack(spacing: 10) { buttons }
        }
    }

    @ViewBuilder private var buttons: some View {
        Button {
            Haptics.tap()
            onPrimary()
        } label: {
            Label(primaryTitle, systemImage: primarySystemImage)
                .font(.ui(15, .bold))
                .frame(maxWidth: .infinity)
                .frame(height: 52)
        }
        .modifier(SetupPrimaryButtonSurface())

        if primaryTitle != "Open Workspace" {
            Button {
                Haptics.tap()
                onOpenSettings()
            } label: {
                Label("Open Workspace", systemImage: "gearshape.fill")
                    .font(.ui(15, .bold))
                    .frame(maxWidth: .infinity)
                    .frame(height: 52)
            }
            .modifier(SetupSecondaryButtonSurface())
        }

        if let onStartDemo {
            Button {
                Haptics.tap()
                onStartDemo()
            } label: {
                Label("Try Guided Demo", systemImage: "play.circle.fill")
                    .font(.ui(15, .bold))
                    .frame(maxWidth: .infinity)
                    .frame(height: 52)
            }
            .modifier(SetupSecondaryButtonSurface())
        }
    }
}

private struct SetupTodoIconSurface: ViewModifier {
    @ViewBuilder
    func body(content: Content) -> some View {
        if Theme.isGlass {
            content.glassSurface(.icon, cornerRadius: 15, accentReflection: nil)
        } else {
            content.background(Theme.brand.opacity(0.13), in: Circle())
        }
    }
}

private struct SetupPrimaryButtonSurface: ViewModifier {
    @ViewBuilder
    func body(content: Content) -> some View {
        if Theme.isGlass {
            content.glassSurface(.button, cornerRadius: 16, accentReflection: nil)
        } else {
            content
                .foregroundStyle(.white)
                .background(Theme.actionGradient, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .shadow(color: Theme.brand.opacity(0.25), radius: 12, y: 6)
        }
    }
}

private struct SetupSecondaryButtonSurface: ViewModifier {
    @ViewBuilder
    func body(content: Content) -> some View {
        if Theme.isGlass {
            content.glassSurface(.button, cornerRadius: 16, accentReflection: nil)
        } else {
            content
                .background(Theme.brand.opacity(0.12), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(Theme.brand.opacity(0.22), lineWidth: 1))
        }
    }
}

struct StatusDot: View {
    let ready: Bool
    var working: Bool = false
    var body: some View {
        HStack(spacing: 6) {
            PulsingDot(color: ready ? .green : .orange, active: working || !ready)
            Text(working ? "Working" : (ready ? "Connected" : "Setup"))
                .font(.caption.weight(.medium)).foregroundStyle(.secondary)
                .contentTransition(.opacity)
        }
        .fixedSize()
        .animation(Theme.snappy, value: working)
    }
}

// MARK: - Messages

struct MessageBubble: View, Equatable {
    let message: ChatMessage
    var isLiveStreaming = false
    let accent: Theme.Accent
    let skin: AppSkin
    let onResend: (String, [Attachment]) -> Void
    let onEdit: (String) -> Void
    @State private var showCopied = false

    static func == (lhs: MessageBubble, rhs: MessageBubble) -> Bool {
        lhs.message == rhs.message
            && lhs.isLiveStreaming == rhs.isLiveStreaming
            && lhs.accent == rhs.accent
            && lhs.skin == rhs.skin
    }

    private var accessibilityDescription: String {
        // Avoid rebuilding an accessibility label containing the entire growing
        // response on every streamed update. The complete text becomes available
        // to VoiceOver as soon as the turn finishes.
        if isLiveStreaming { return "Agent, responding" }
        let roleLabel: String
        switch message.role {
        case .user: roleLabel = "User"
        case .assistant: roleLabel = "Agent"
        case .system: roleLabel = "System"
        case .tool: roleLabel = "Tool"
        }
        var pieces: [String] = []
        if !message.text.isEmpty { pieces.append(message.text) }
        if message.text.isEmpty, !message.toolEvents.isEmpty {
            pieces.append(message.toolEvents.map(\.summary).joined(separator: ", "))
        }
        let body = pieces.joined(separator: ", ")
        return body.isEmpty ? roleLabel : "\(roleLabel), \(body)"
    }

    var body: some View {
        Group {
            switch message.role {
            case .user:
                HStack {
                    Spacer(minLength: 40)
                    VStack(alignment: .trailing, spacing: 6) {
                        ForEach(message.attachments) { att in
                            UserAttachmentView(attachment: att)
                        }
                        if !message.text.isEmpty {
                            Text(message.text)
                                .padding(.horizontal, 14).padding(.vertical, 10)
                                .background(Theme.messageGradient,
                                            in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                                .foregroundStyle(.white)
                                .shadow(color: Theme.brand.opacity(0.3), radius: 6, y: 3)
                        }
                    }
                }
                .padding(.horizontal)
            case .system:
                // A success line ("✅ …") earns a green checkmark + one-shot
                // bounce — the moment a change ships. Failure/warning lines keep
                // their emoji and stay plain. symbolEffect self-suppresses under
                // Reduce Motion.
                let isSuccess = message.text.hasPrefix("✅")
                HStack(spacing: 6) {
                    if isSuccess {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(Theme.ok)
                            .symbolEffect(.bounce, options: .nonRepeating, value: message.id)
                    }
                    Text(isSuccess
                         ? String(message.text.dropFirst()).trimmingCharacters(in: .whitespaces)
                         : message.text)
                        .font(.footnote)
                        .foregroundStyle(isSuccess ? .primary : .secondary)
                }
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.horizontal)
            // An empty assistant message is appended at run start and streams in
            // later — don't show a bare "AGENT" header until there's content (the
            // separate typing indicator already signals work).
            case .assistant where message.text.isEmpty && message.toolEvents.isEmpty:
                EmptyView()
            default:
                VStack(alignment: .leading, spacing: 8) {
                    // Agent identity — the design's avatar + "AGENT" eyebrow.
                    HStack(spacing: 7) {
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .fill(Theme.brandGradient)
                            .frame(width: 24, height: 24)
                            .overlay(
                                Image(systemName: "sparkle")
                                    .font(.system(size: 12, weight: .bold))
                                    .foregroundStyle(.white))
                        Text("AGENT")
                            .font(.mono(11, .semibold)).kerning(1.4)
                            .foregroundStyle(Theme.t3)
                    }
                    if !message.toolEvents.isEmpty {
                        // Inline pills, scrolling horizontally if they overflow.
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 6) {
                                ForEach(message.toolEvents) { ToolEventRow(event: $0) }
                            }
                        }
                    }
                    if !message.text.isEmpty {
                        // Plain text on the backdrop — no bubble — like the design.
                        // Block markdown is deferred until the turn finishes so fenced
                        // code / headings don't re-parse (and re-layout) every token.
                        MarkdownMessage(text: message.text, streaming: isLiveStreaming)
                            .textSelection(.enabled)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.trailing, 24)
                .padding(.horizontal)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityDescription)
        .overlay {
            if showCopied {
                Label("Copied", systemImage: "checkmark")
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .background(.regularMaterial, in: Capsule())
                    .transition(.opacity.combined(with: .scale(scale: 0.9)))
                    .accessibilityHidden(true)   // copy already announced via button
            }
        }
        .contextMenu {
            if !message.text.isEmpty {
                Button {
                    ClipboardManager.shared.copy(message.text)
                    Haptics.tap()
                    withAnimation(Theme.snappy) { showCopied = true }
                    Task {
                        try? await Task.sleep(for: .seconds(1.2))
                        withAnimation(Theme.snappy) { showCopied = false }
                    }
                } label: {
                    Label("Copy and save", systemImage: "doc.on.doc")
                }
            }
            if message.role == .user {
                Button {
                    Haptics.tap()
                    onResend(message.text, message.attachments)
                } label: {
                    Label("Resend", systemImage: "arrow.up.circle")
                }
                if !message.text.isEmpty {
                    // Reuses the prefilledPrompt pipeline ChatView already
                    // watches — the text lands in the composer, focused.
                    Button {
                        Haptics.tap()
                        onEdit(message.text)
                    } label: {
                        Label("Edit in composer", systemImage: "pencil")
                    }
                }
            }
        }
    }
}

struct ToolEventRow: View {
    let event: ToolEvent

    var body: some View {
        HStack(spacing: 6) {
            icon
            Text(event.summary).font(.mono(11)).foregroundStyle(Theme.t2).lineLimit(1)
        }
        .padding(.vertical, 6).padding(.horizontal, 10)
        .background(Theme.chip, in: Capsule())
        .overlay(Capsule().strokeBorder(Theme.glassBorder, lineWidth: 1))
        .fixedSize()
    }

    @ViewBuilder private var icon: some View {
        switch event.status {
        case .running: ProgressView().controlSize(.mini)
        case .success: Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.ok).font(.footnote)
        case .failure: Image(systemName: "xmark.circle.fill").foregroundStyle(Theme.danger).font(.footnote)
        }
    }
}

extension String {
    /// Render inline markdown (bold, code, links) while preserving newlines;
    /// falls back to plain text if parsing fails.
    var asMarkdown: AttributedString {
        (try? AttributedString(
            markdown: self,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
        ?? AttributedString(self)
    }
}

/// Lightweight block markdown renderer for assistant messages: fenced code
/// blocks, ATX headings, and bullet list items, with inline markdown for the
/// rest. SwiftUI's AttributedString markdown is inline-only, so headings, lists,
/// and code blocks otherwise render as run-on raw text.
struct MarkdownMessage: View {
    let text: String
    var streaming = false

    private enum Block { case paragraph(String), heading(Int, String), bullet(String), code(String) }

    var body: some View {
        Group {
            if streaming {
                // Inline Markdown parsing allocates and scans the full cumulative
                // response. Stream verbatim text, then render Markdown once when
                // the response is complete.
                Text(verbatim: text)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                blockBody
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var blockBody: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                switch block {
                case .code(let code):
                    ScrollView(.horizontal, showsIndicators: false) {
                        Text(code).font(.system(.caption, design: .monospaced))
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.primary.opacity(0.06),
                                in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                case .heading(let level, let content):
                    Text(content.asMarkdown)
                        .font(level <= 1 ? .title3.weight(.bold)
                              : (level == 2 ? .headline : .subheadline.weight(.semibold)))
                        .fixedSize(horizontal: false, vertical: true)
                case .bullet(let content):
                    HStack(alignment: .top, spacing: 8) {
                        Text("•").foregroundStyle(.secondary)
                        Text(content.asMarkdown).fixedSize(horizontal: false, vertical: true)
                    }
                case .paragraph(let content):
                    Text(content.asMarkdown).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private var blocks: [Block] {
        var result: [Block] = []
        var para: [String] = []
        func flush() {
            let joined = para.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if !joined.isEmpty { result.append(.paragraph(joined)) }
            para.removeAll()
        }
        let lines = text.components(separatedBy: "\n")
        var i = 0
        while i < lines.count {
            let raw = lines[i]
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") {                 // fenced code block
                flush()
                var code: [String] = []
                i += 1
                while i < lines.count, !lines[i].trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                    code.append(lines[i]); i += 1
                }
                result.append(.code(code.joined(separator: "\n")))
                i += 1                                     // skip the closing fence
                continue
            }
            if trimmed.hasPrefix("#") {                    // ATX heading
                flush()
                let level = trimmed.prefix(while: { $0 == "#" }).count
                let content = trimmed.drop(while: { $0 == "#" }).trimmingCharacters(in: .whitespaces)
                result.append(.heading(level, content))
            } else if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") {
                flush()
                result.append(.bullet(String(trimmed.dropFirst(2))))
            } else {
                para.append(raw)
            }
            i += 1
        }
        flush()
        return result
    }
}

struct ConversationHistorySheet: View {
    @EnvironmentObject var engine: AgentEngine
    @Environment(\.dismiss) private var dismiss
    @StateObject private var store = ConversationStore.shared
    @State private var searchText = ""

    private var filteredConversations: [SavedConversation] {
        let trimmed = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return store.savedConversations }
        return store.savedConversations.filter {
            $0.title.localizedCaseInsensitiveContains(trimmed)
        }
    }

    var body: some View {
        NavigationStack {
            List {
                if let err = store.lastError {
                    Text(err)
                        .font(.footnote)
                        .foregroundStyle(.red)
                        .listRowBackground(Color.clear)
                }
                if store.savedConversations.isEmpty {
                    Text("No saved conversations").foregroundStyle(.secondary)
                } else {
                    ForEach(filteredConversations) { conv in
                        Button {
                            Haptics.tap()
                            engine.loadSavedConversation(conv)
                            dismiss()
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                HStack(spacing: 6) {
                                    if conv.isPinned {
                                        Image(systemName: "pin.fill")
                                            .font(.caption)
                                            .foregroundStyle(Theme.brand)
                                            .accessibilityHidden(true)
                                    }
                                    Text(conv.title)
                                        .font(.subheadline.weight(.semibold))
                                        .foregroundStyle(.primary)
                                        .lineLimit(1)
                                }
                                HStack {
                                    Text("\(conv.transcript.count) message\(conv.transcript.count == 1 ? "" : "s")")
                                    Spacer()
                                    Text(conv.date, style: .date)
                                }
                                .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        .disabled(engine.commitInFlight)
                        .accessibilityValue(conv.isPinned ? "Pinned" : "Not pinned")
                        .contextMenu {
                            Button {
                                Haptics.tap()
                                store.setPinned(!conv.isPinned, for: conv.id)
                            } label: {
                                Label(
                                    conv.isPinned ? "Unpin" : "Pin",
                                    systemImage: conv.isPinned ? "pin.slash" : "pin"
                                )
                            }
                        }
                        .swipeActions(edge: .leading, allowsFullSwipe: true) {
                            Button {
                                Haptics.tap()
                                store.setPinned(!conv.isPinned, for: conv.id)
                            } label: {
                                Label(
                                    conv.isPinned ? "Unpin" : "Pin",
                                    systemImage: conv.isPinned ? "pin.slash" : "pin"
                                )
                            }
                            .tint(Theme.brand)
                        }
                    }
                    .onDelete(perform: delete)
                }
            }
            .searchable(text: $searchText, prompt: "Search conversations")
            .navigationTitle("Chat History")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Close") { dismiss() }
                }
            }
            .onAppear {
                store.loadAll()
            }
        }
    }

    private func delete(at offsets: IndexSet) {
        for index in offsets {
            let conv = filteredConversations[index]
            store.delete(conv.id)
        }
    }
}

extension String {
    var extractedPlan: String? {
        let lines = self.components(separatedBy: "\n")
        var planLines: [String] = []
        var isParsingPlan = false
        
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.lowercased().hasPrefix("plan:") || trimmed.lowercased().hasPrefix("proposed plan:") || trimmed.lowercased().hasPrefix("## plan") {
                isParsingPlan = true
                continue
            }
            if isParsingPlan {
                if trimmed.isEmpty { continue }
                // Stop if we hit another Markdown header or a non-bullet/numbered item
                if trimmed.hasPrefix("#") {
                    break
                }
                if trimmed.first?.isNumber == true || trimmed.hasPrefix("-") || trimmed.hasPrefix("*") || trimmed.hasPrefix("•") {
                    planLines.append(line)
                } else if planLines.count > 0 {
                    break
                }
            }
        }
        return planLines.isEmpty ? nil : planLines.joined(separator: "\n")
    }
}

// MARK: - Approval Card (Phase 7)

/// Short handoff state shown after the model requests approval but before its
/// run task has fully unwound. Keeping this non-actionable closes the race where
/// `finishRun` and the user's commit used to mutate the same state concurrently.
private struct ApprovalPreparingRow: View {
    var body: some View {
        HStack(spacing: 10) {
            ProgressView().controlSize(.small)
            VStack(alignment: .leading, spacing: 2) {
                Text("Preparing review…")
                    .font(.subheadline.weight(.semibold))
                Text("Your staged files will be ready in a moment.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .background(Theme.cardFill,
                    in: RoundedRectangle(cornerRadius: Theme.corner, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.corner, style: .continuous)
                .strokeBorder(Theme.separator, lineWidth: 1)
        )
    }
}

private struct ApprovalFilesList: View {
    let changes: [PendingChange]
    let onReview: (PendingChange) -> Void

    var body: some View {
        VStack(spacing: 6) {
            ForEach(changes) { change in
                Button { onReview(change) } label: {
                    HStack(spacing: 9) {
                        Image(systemName: change.category.icon)
                            .foregroundStyle(change.isDeletion ? Color.red : Theme.brand)
                        Text(change.path)
                            .font(.callout.weight(.medium))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                        Spacer(minLength: 8)
                        Text("Review")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        Image(systemName: "chevron.right")
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(.tertiary)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 9)
                    .background(Theme.cardFill,
                                in: RoundedRectangle(cornerRadius: Theme.cornerSmall, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: Theme.cornerSmall, style: .continuous)
                            .strokeBorder(Theme.separator, lineWidth: 1)
                    )
                }
                .buttonStyle(.pressable)
            }
        }
    }
}

/// Card displayed when the agent is awaiting user approval for proposed changes.
struct ApprovalCard: View {
    let approval: PendingApproval
    @EnvironmentObject var engine: AgentEngine
    @Environment(\.secondarySurface) private var secondaryBG
    @State private var isApproving = false
    @State private var hasActed = false
    @State private var reviewing: PendingChange?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "checkmark.shield.fill")
                    .foregroundStyle(Theme.brand)
                    .font(.title3)
                Text(approval.title)
                    .font(.headline.weight(.semibold))
                Spacer()
                if approval.isExpired {
                    Label("Expired", systemImage: "clock.badge.exclamationmark")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.orange)
                }
            }

            Text(approval.summary)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if let issue = engine.reviewIssueMessage {
                ReviewIssueBanner(message: issue)
            }

            if !engine.pendingChanges.isEmpty {
                ApprovalFilesList(changes: engine.pendingChanges) { change in
                    Haptics.tap()
                    reviewing = change
                }
            }

            Divider()

            HStack(spacing: 12) {
                // Apply Changes button
                Button {
                    guard !hasActed else { return }
                    hasActed = true
                    isApproving = true
                    Haptics.tap()
                    Task {
                        let result = await engine.approveAction(approvalID: approval.id)
                        isApproving = false
                        if !result.isAccepted { hasActed = false }
                    }
                } label: {
                    HStack(spacing: 6) {
                        if isApproving {
                            ProgressView().tint(.white).controlSize(.small)
                        } else {
                            Image(systemName: "checkmark.circle.fill")
                        }
                        Text(isApproving ? "Committing…" : "Approve & Commit")
                    }
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(Theme.actionGradient, in: RoundedRectangle(cornerRadius: Theme.cornerSmall, style: .continuous))
                }
                .disabled(hasActed || approval.isExpired || !engine.approvalReady)
                .buttonStyle(.pressable)

                // Cancel button
                Button {
                    guard !hasActed else { return }
                    hasActed = true
                    Haptics.tap()
                    engine.cancelApproval()
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "xmark.circle")
                        Text("Cancel")
                    }
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(secondaryBG, in: RoundedRectangle(cornerRadius: Theme.cornerSmall, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: Theme.cornerSmall, style: .continuous)
                            .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1))
                }
                .disabled(hasActed)
                .buttonStyle(.pressable)
            }
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: Theme.corner, style: .continuous)
                .fill(Color(.systemBackground))
                .shadow(color: Color.primary.opacity(0.08), radius: 12, y: 4)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Theme.corner, style: .continuous)
                .strokeBorder(Theme.brand.opacity(0.3), lineWidth: 1.5)
        )
        .sheet(item: $reviewing) { change in
            DiffSheet(change: change)
        }
    }
}

private struct ChatModelPickerSheet: View {
    @EnvironmentObject private var engine: AgentEngine
    @Environment(\.dismiss) private var dismiss
    @State private var searchText = ""
    @State private var expandedProviderIDs: Set<String> = []

    let onSelect: (LLMProvider, String) -> Void

    private var hasMatches: Bool {
        engine.availableProviders.contains { !matchingModels(for: $0).isEmpty }
    }

    var body: some View {
        NavigationStack {
            List {
                if engine.smartRoutingEnabled && searchText.isEmpty {
                    Section("Routing") {
                        Button {
                            engine.smartRoutingEnabled = false
                            Haptics.tap()
                        } label: {
                            Label("Use a specific model", systemImage: "slider.horizontal.3")
                        }
                    }
                }

                if searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Section("Providers") {
                        ForEach(engine.availableProviders, id: \.id) { provider in
                            providerDisclosure(provider)
                        }
                    }
                } else {
                    ForEach(engine.availableProviders, id: \.id) { provider in
                        let models = matchingModels(for: provider)
                        if !models.isEmpty {
                            modelSection(provider: provider, models: models)
                        }
                    }
                }

                if !hasMatches {
                    ContentUnavailableView.search(text: searchText)
                        .listRowBackground(Color.clear)
                }
            }
            .navigationTitle("Choose Model")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(
                text: $searchText,
                placement: .navigationBarDrawer(displayMode: .always),
                prompt: "Search models or providers"
            )
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        Task { await engine.refreshAllProviderModels(force: true) }
                    } label: {
                        if engine.isRefreshingModels {
                            ProgressView()
                        } else {
                            Image(systemName: "arrow.clockwise")
                        }
                    }
                    .disabled(engine.isRefreshingModels)
                    .accessibilityLabel("Refresh all provider models")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .onAppear {
            expandedProviderIDs.insert(engine.activeProviderID)
        }
    }

    private func matchingModels(for provider: LLMProvider) -> [String] {
        let models = engine.availableModels(for: provider)
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return models }
        if provider.displayName.localizedStandardContains(query) {
            return models
        }
        return models.filter { $0.localizedStandardContains(query) }
    }

    private func modelSection(provider: LLMProvider, models: [String]) -> some View {
        Section {
            ForEach(models, id: \.self) { model in
                Button {
                    onSelect(provider, model)
                    dismiss()
                } label: {
                    HStack(spacing: 10) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(model)
                                .foregroundStyle(.primary)
                                .lineLimit(2)
                            if isSelected(provider: provider, model: model) {
                                Text("Current model")
                                    .font(.caption)
                                    .foregroundStyle(Theme.ok)
                            }
                        }
                        Spacer(minLength: 8)
                        ModelCapabilityBadges(
                            capabilities: engine.capabilities(for: provider, model: model),
                            size: 15
                        )
                        if isSelected(provider: provider, model: model) {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(Theme.ok)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        } header: {
            Label(
                provider.displayName,
                systemImage: provider.id == engine.activeProviderID
                    ? "checkmark.circle.fill"
                    : "circle"
            )
        }
    }

    private func providerDisclosure(_ provider: LLMProvider) -> some View {
        let models = engine.availableModels(for: provider)
        return DisclosureGroup(
            isExpanded: Binding(
                get: { expandedProviderIDs.contains(provider.id) },
                set: { isExpanded in
                    if isExpanded {
                        expandedProviderIDs.insert(provider.id)
                    } else {
                        expandedProviderIDs.remove(provider.id)
                    }
                }
            )
        ) {
            ForEach(models, id: \.self) { model in
                Button {
                    onSelect(provider, model)
                    dismiss()
                } label: {
                    HStack(spacing: 10) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(model)
                                .foregroundStyle(.primary)
                                .lineLimit(2)
                            if isSelected(provider: provider, model: model) {
                                Text("Current model")
                                    .font(.caption)
                                    .foregroundStyle(Theme.ok)
                            }
                        }
                        Spacer(minLength: 8)
                        ModelCapabilityBadges(
                            capabilities: engine.capabilities(for: provider, model: model),
                            size: 15
                        )
                        if isSelected(provider: provider, model: model) {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(Theme.ok)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.leading, 8)
            }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: provider.id == engine.activeProviderID
                    ? "checkmark.circle.fill"
                    : "circle")
                    .foregroundStyle(provider.id == engine.activeProviderID ? Theme.ok : .secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(provider.displayName)
                        .foregroundStyle(.primary)
                    Text("\(models.count) models")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func isSelected(provider: LLMProvider, model: String) -> Bool {
        provider.id == engine.activeProviderID && model == engine.selectedModel
    }
}

/// Reserves page space for the root-owned composer. The composer is not a child
/// of this view on iOS 26, but transcript content must still stop above it.
private struct ChatPageComposerClearance: ViewModifier {
    let enabled: Bool
    let height: CGFloat

    @ViewBuilder
    func body(content: Content) -> some View {
        if enabled {
            content.safeAreaPadding(.bottom, max(112, height))
        } else {
            content
        }
    }
}

// MARK: - Composer chrome helpers

/// A self-contained surface for the complete model/attachment/input/send unit.
/// In Clear Glass, a local neutral backing sits behind the native glass so the
/// transcript cannot refract through the controls. Classic remains the same
/// flat filled surface and never acquires glass styling.
private struct ChatComposerOuterSurface: ViewModifier {
    let skin: AppSkin
    let classicFill: Color
    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: 30, style: .continuous)

        if skin == .clearGlass {
            content
                .glassSurface(.composer, cornerRadius: 30)
                // This backing is deliberately applied outside the glass
                // modifier, making it the plate's immediate backdrop. The
                // native glass remains unchanged while dense page text can no
                // longer show through or create mirrored-looking collisions.
                .background(
                    Color(.systemBackground)
                        .opacity(colorScheme == .dark ? 0.82 : 0.88),
                    in: shape
                )
                .overlay(shape.strokeBorder(Color.primary.opacity(0.10), lineWidth: 0.75))
        } else {
            content
                .background(classicFill, in: shape)
                .overlay(shape.strokeBorder(Theme.separator, lineWidth: 0.5))
        }
    }
}

/// Pins the composer above the system tab bar. iOS 26 renders the surrounding
/// plate as untinted, interactive Clear Liquid Glass.
private struct ChatEmbeddedComposerModifier<Bar: View>: ViewModifier {
    let enabled: Bool
    let accent: Theme.Accent
    let skin: AppSkin
    @ViewBuilder let bar: () -> Bar

    private var themeIdentity: String {
        "\(accent.rawValue)-\(skin.rawValue)"
    }

    @ViewBuilder
    func body(content: Content) -> some View {
        if enabled {
            content.safeAreaInset(edge: .bottom, spacing: 0) {
                bar()
                    // The inset owns a builder closure, so make theme state an
                    // explicit identity input. This rebuilds only the composer
                    // chrome when Appearance changes; the transcript, draft,
                    // focus state, geometry and tab-bar separation stay intact.
                    .id(themeIdentity)
                    // Clear the optical expansion of both floating materials;
                    // the composer must never visually merge with the tab bar.
                    .padding(.bottom, 22)
            }
        } else {
            content
        }
    }
}

/// Composer icon surface, rendered as native Clear Glass on iOS 26+.
private struct ChatComposerIconSurface: ViewModifier {
    @Environment(\.secondarySurface) private var secondaryBG

    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content.glassSurface(.icon, cornerRadius: 19)
        } else {
            content
                .background(secondaryBG, in: Circle())
                .overlay(Circle().strokeBorder(Color.primary.opacity(0.06), lineWidth: 1))
        }
    }
}

/// Independent text-entry plate inside the outer composer surface.
private struct ChatComposerFieldSurface: ViewModifier {
    var focused: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            // A dedicated inner plate prevents wallpaper and transcript text
            // from competing with the draft and placeholder.
            content
                .glassSurface(.composerField, cornerRadius: 20)
                // Give Clear Glass a neutral local backdrop to refract. Without
                // this layer the field inherits the selected ambient hue and
                // visually merges with the composer beneath it.
                .background(
                    Color(.secondarySystemBackground).opacity(0.78),
                    in: RoundedRectangle(cornerRadius: 20, style: .continuous)
                )
        } else {
            content.glassSurface(
                .button,
                cornerRadius: 20,
                accentReflection: focused ? Theme.brand : nil
            )
        }
    }
}

private extension ToolbarContent {
    /// iOS 26 wraps bar items in a Liquid Glass chip. Hide it for icon-only
    /// controls (Chat setup "!") so we don't get circle-inside-circle.
    @ToolbarContentBuilder
    func hideSharedBackgroundIfAvailable() -> some ToolbarContent {
        if #available(iOS 26.0, *) {
            sharedBackgroundVisibility(.hidden)
        } else {
            self
        }
    }
}
