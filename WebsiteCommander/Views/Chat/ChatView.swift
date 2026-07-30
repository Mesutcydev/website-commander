import SwiftUI

/// The agent conversation: a transcript of bubbles and tool events, a pending
/// changes approval bar, and a composer. Visual-first, keyboard-friendly, and
/// animated through the shared `Motion` system so the agent's presence reads
/// clearly (thinking / streaming / running a tool) without being noisy.
struct ChatView: View {

    @EnvironmentObject var engine: AgentEngine
    @EnvironmentObject var settings: SettingsStore
    @State private var draft = ""
    @State private var reviewingChange: PendingChange?
    @State private var showConversations = false
    @FocusState private var composerFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            transcript
            if !engine.pendingChanges.isEmpty {
                PendingChangesBar(reviewingChange: $reviewingChange)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
            Divider()
            composer
        }
        .animation(Motion.smooth, value: engine.pendingChanges.isEmpty)
        .navigationTitle("Agent")
        .toolbar { chatToolbar }
        .onAppear {
            composerFocused = true
            if let prompt = engine.prefilledPrompt {
                draft = prompt
                engine.prefilledPrompt = nil
            }
        }
        .onChange(of: engine.prefilledPrompt) { _, newValue in
            if let newValue { draft = newValue; engine.prefilledPrompt = nil }
        }
        .sheet(item: $reviewingChange) { change in
            DiffApprovalView(change: change)
        }
        .sheet(isPresented: $showConversations) {
            ConversationsSheet()
        }
    }

    // MARK: Toolbar

    @ToolbarContentBuilder
    private var chatToolbar: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            AgentStatusPill()
        }
        ToolbarItemGroup(placement: .primaryAction) {
            Button {
                showConversations = true
            } label: {
                Label("Saved", systemImage: "tray.full.fill")
            }
            Button {
                engine.newChat()
            } label: {
                Label("New Chat", systemImage: "plus.message")
            }
        }
    }

    // MARK: Transcript

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: Theme.Space.m) {
                    if engine.transcript.isEmpty {
                        chatEmptyState
                    }
                    ForEach(engine.transcript) { message in
                        MessageBubble(message: message)
                            .id(message.id)
                    }
                    if engine.state == .streaming && !engine.liveAssistantText.isEmpty {
                        MessageBubble(message: ChatMessage(role: .assistant, text: engine.liveAssistantText),
                                      streaming: true)
                            .id("streaming")
                    } else if engine.state.isActive {
                        TypingIndicator()
                            .transition(.opacity.combined(with: .scale(scale: 0.9)))
                    }
                }
                .padding(Theme.Space.l)
                .frame(maxWidth: 820, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .center)
            }
            .onChange(of: engine.transcript.count) { _, _ in
                if let last = engine.transcript.last {
                    withAnimation(Motion.smooth) { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }
            .onChange(of: engine.liveAssistantText) { _, _ in
                withAnimation(Motion.smooth) { proxy.scrollTo("streaming", anchor: .bottom) }
            }
        }
    }

    private var chatEmptyState: some View {
        VStack(spacing: Theme.Space.l) {
            BrandIllustration(size: 120)
            Text("What should we change today?")
                .font(.title2.weight(.semibold))
            Text("Describe it in plain English — the agent reads your repo and proposes edits for your approval.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, Theme.Space.xl)
        .wcAppear()
    }

    // MARK: Composer

    private var composer: some View {
        HStack(alignment: .bottom, spacing: Theme.Space.m) {
            HStack(alignment: .bottom, spacing: Theme.Space.s) {
                TextField("Describe a change…", text: $draft, axis: .vertical)
                    .textFieldStyle(.plain)
                    .lineLimit(1...6)
                    .focused($composerFocused)
                    .onSubmit { sendIfPossible() }
            }
            .padding(.horizontal, Theme.Space.m)
            .padding(.vertical, Theme.Space.s)
            .background(Theme.cardFill, in: RoundedRectangle(cornerRadius: Theme.Radius.medium))
            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.medium).strokeBorder(Theme.hairline))

            Button {
                sendIfPossible()
            } label: {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 30))
                    .foregroundStyle(canSend ? AnyShapeStyle(Theme.brandGradient) : AnyShapeStyle(Color.secondary.opacity(0.4)))
                    .symbolEffect(.bounce, value: engine.transcript.count)
            }
            .buttonStyle(.plain)
            .disabled(!canSend)
            .animation(Motion.bouncy, value: canSend)
            .keyboardShortcut(.return, modifiers: [])
        }
        .padding(Theme.Space.l)
        .frame(maxWidth: 820)
        .frame(maxWidth: .infinity)
    }

    private var canSend: Bool {
        !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !engine.state.isActive
    }

    private func sendIfPossible() {
        guard canSend else { return }
        let text = draft
        draft = ""
        engine.send(text)
    }
}

// MARK: - Message bubble

struct MessageBubble: View {
    let message: ChatMessage
    var streaming: Bool = false

    @EnvironmentObject var settings: SettingsStore

    private var isUser: Bool { message.role == .user }

    private var assistantProviderID: String {
        settings.preferOnDevice ? "ondevice" : settings.providerID
    }

    var body: some View {
        HStack(alignment: .top, spacing: Theme.Space.s) {
            if !isUser {
                ProviderAvatar(size: 28, providerID: assistantProviderID)
            }
            VStack(alignment: .leading, spacing: Theme.Space.s) {
                if !message.toolEvents.isEmpty {
                    toolEvents
                }
                if !message.text.isEmpty {
                    HStack(alignment: .center, spacing: 4) {
                        Text(message.text)
                            .font(.callout)
                            .textSelection(.enabled)
                        if streaming { StreamingCaret() }
                    }
                    .padding(.horizontal, Theme.Space.m)
                    .padding(.vertical, Theme.Space.s + 2)
                    .background(background, in: bubbleShape)
                    .foregroundStyle(isUser ? .white : .primary)
                }
            }
            if isUser { Spacer(minLength: 60) } else { Spacer(minLength: 40) }
        }
        .wcAppear()
    }

    private var background: AnyShapeStyle {
        isUser ? AnyShapeStyle(Theme.brandGradient) : AnyShapeStyle(Theme.cardFill)
    }

    private var bubbleShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: Theme.Radius.medium, style: .continuous)
    }

    private var toolEvents: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(message.toolEvents.enumerated()), id: \.element.id) { idx, event in
                HStack(spacing: 6) {
                    toolIcon(event.status)
                    Text(event.summary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background(Color.primary.opacity(0.05), in: Capsule())
                .animation(Motion.snappy, value: event.status)
                .wcAppear(delay: Double(idx) * 0.03)
            }
        }
    }

    @ViewBuilder
    private func toolIcon(_ status: ToolEvent.Status) -> some View {
        switch status {
        case .running: ProgressView().controlSize(.mini)
        case .success: Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.success).font(.caption2)
        case .failure: Image(systemName: "xmark.circle.fill").foregroundStyle(Theme.danger).font(.caption2)
        }
    }
}

// MARK: - Typing indicator

struct TypingIndicator: View {
    @EnvironmentObject var settings: SettingsStore
    @State private var phase = 0.0

    private var providerID: String {
        settings.preferOnDevice ? "ondevice" : settings.providerID
    }

    var body: some View {
        HStack(spacing: 6) {
            ProviderAvatar(size: 28, providerID: providerID, active: true, state: .thinking)
            HStack(spacing: 4) {
                ForEach(0..<3) { i in
                    Circle().fill(Color.secondary)
                        .frame(width: 6, height: 6)
                        .opacity(0.4 + 0.6 * abs(sin(phase + Double(i) * 0.6)))
                }
            }
            .padding(.horizontal, Theme.Space.m).padding(.vertical, Theme.Space.s + 2)
            .background(Theme.cardFill, in: RoundedRectangle(cornerRadius: Theme.Radius.medium))
        }
        .wcAppear()
        .onAppear {
            withAnimation(.linear(duration: 1.2).repeatForever(autoreverses: false)) { phase = .pi }
        }
    }
}

// MARK: - Pending changes bar

struct PendingChangesBar: View {
    @EnvironmentObject var engine: AgentEngine
    @Binding var reviewingChange: PendingChange?

    var body: some View {
        HStack(spacing: Theme.Space.m) {
            Image(systemName: "tray.full.fill")
                .foregroundStyle(Theme.warning)
                .symbolEffect(.bounce, value: engine.pendingChanges.count)
            Text("\(engine.pendingChanges.count) change\(engine.pendingChanges.count == 1 ? "" : "s") ready to review")
                .font(.callout.weight(.medium))
                .contentTransition(.numericText())
            Spacer()
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(Array(engine.pendingChanges.enumerated()), id: \.element.id) { idx, change in
                        Button { reviewingChange = change } label: {
                            HStack(spacing: 4) {
                                Image(systemName: change.category.icon).font(.caption2)
                                Text(change.path).font(.caption).lineLimit(1)
                            }
                            .padding(.horizontal, 8).padding(.vertical, 4)
                            .background(Theme.accent.opacity(0.12), in: Capsule())
                        }
                        .buttonStyle(.plain)
                        .wcAppear(delay: Double(idx) * 0.03)
                    }
                }
            }
            .frame(maxWidth: 360)
            Button("Approve All") { Task { await engine.approveAll() } }
                .buttonStyle(.primary)
        }
        .padding(.horizontal, Theme.Space.l)
        .padding(.vertical, Theme.Space.m)
        .background(Theme.warning.opacity(0.08))
    }
}
