import SwiftUI
import UniformTypeIdentifiers

/// The agent workspace pane. It has two modes, both laid out on the shared
/// `AgentWorkspaceMetrics` grid so the transcript and the docked composer align
/// edge-to-edge:
///
/// - **Idle** — a full-width command center: a compact horizontal intro row
///   then a responsive Smart Tasks grid.
/// - **Active** — a conversation-and-execution workspace: the primary timeline
///   plus, on wide windows with real activity, a contextual execution rail.
///
/// Visual-first, keyboard-friendly, and animated through the shared `Motion`
/// system so the agent's presence reads clearly (thinking / streaming / running
/// a tool) without being noisy.
struct ChatView: View {

    var embedded = false
    var showsBrowser = false
    /// Width of the pane the chat occupies, measured by the workspace shell.
    /// Passed in rather than measured here: a `GeometryReader` nested inside
    /// the shell's own one deadlocks SwiftUI's layout during window restoration,
    /// because the scroll preferences it feeds back drive the outer reader.
    var paneWidth: CGFloat = 0
    var onToggleBrowser: (() -> Void)?
    /// Embedded chats render their controls in the parent's unified command
    /// bar; standalone chats keep them in the window toolbar.
    var showsToolbarControls = true
    /// Narrow windows collapse the toolbar controls to compact variants.
    var toolbarCompact = false
    /// Reports when transcript content scrolls beneath the toolbar so the
    /// command bar can raise its separator.
    var onScrolledUnder: ((Bool) -> Void)?
    @EnvironmentObject var engine: AgentEngine
    @EnvironmentObject var settings: SettingsStore
    @SceneStorage("agent.composerDraft") private var draft = ""
    @State private var reviewingChange: PendingChange?
    @State private var showConversations = false
    @State private var attachments: [Attachment] = []
    @State private var showAttachmentPicker = false
    @State private var attachmentError: String?
    @FocusState private var composerFocused: Bool
    @State private var isNearTranscriptBottom = true
    @State private var hasUnseenActivity = false
    @State private var transcriptViewportHeight: CGFloat = 0

    var body: some View {
        Group {
            if embedded {
                chatContent
            } else {
                chatContent
            }
        }
        .animation(Motion.smooth, value: engine.pendingChanges.isEmpty)
        .onAppear {
            // Moving first responder while the Agent destination and its
            // WKWebView are entering the hierarchy can trigger a second AppKit
            // layout cycle. Standalone chat may autofocus; the split workspace
            // waits for an intentional click.
            if !embedded {
                composerFocused = true
            }
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
        .fileImporter(
            isPresented: $showAttachmentPicker,
            allowedContentTypes: [.image, .plainText, .sourceCode, .json, .xml, .commaSeparatedText],
            allowsMultipleSelection: true,
            onCompletion: importAttachments
        )
        .onChange(of: engine.pendingChanges.count) { oldCount, newCount in
            guard oldCount == 0, newCount > 0, reviewingChange == nil,
                  let first = engine.pendingChanges.first else { return }
            DispatchQueue.main.async { reviewingChange = first }
        }
    }

    /// The workspace shell: a primary column that owns vertical scrolling and
    /// docks the composer, plus an optional execution rail. The rail sits
    /// outside the scroll region so it reads as a full-height surface, and the
    /// composer lives inside the primary column so their gutters align exactly.
    private var workspaceMetrics: AgentWorkspaceMetrics {
        AgentWorkspaceMetrics(width: paneWidth)
    }

    /// The rail is a wide-window affordance *and* only worth showing when the
    /// engine has real activity to put in it. Otherwise the conversation takes
    /// the full width.
    private var showsExecutionRail: Bool {
        workspaceMetrics.allowsRail
            && AgentExecutionRail.hasContent(events: engine.liveToolEvents,
                                             pendingChanges: engine.pendingChanges)
    }

    private var chatContent: some View {
        let metrics = workspaceMetrics
        let showsRail = showsExecutionRail

        return HStack(alignment: .top, spacing: 0) {
            primaryColumn(metrics: metrics, railVisible: showsRail)
                .frame(minWidth: 0, maxWidth: .infinity, maxHeight: .infinity)

            if showsRail {
                AgentExecutionRail(
                    events: engine.liveToolEvents,
                    pendingChanges: engine.pendingChanges,
                    state: engine.state,
                    onReview: { reviewingChange = $0 }
                )
                .frame(width: metrics.railWidth)
                .frame(maxHeight: .infinity)
                .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .animation(Motion.gentle, value: showsRail)
    }

    private func primaryColumn(metrics: AgentWorkspaceMetrics,
                               railVisible: Bool) -> some View {
        VStack(spacing: 0) {
            scrollRegion(metrics: metrics, railVisible: railVisible)
                .frame(minHeight: 0, maxHeight: .infinity)

            if !engine.pendingChanges.isEmpty {
                PendingChangesBar(reviewingChange: $reviewingChange)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
            if let error = engine.lastError {
                errorBar(error)
            }
            Divider()
            composer(metrics: metrics)
        }
    }

    private func errorBar(_ error: String) -> some View {
        HStack(spacing: Theme.Space.s) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(Theme.danger)
            Text(error)
                .font(.caption)
                .foregroundStyle(Theme.secondaryText)
                .lineLimit(2)
            Spacer()
            Button("Retry") { retryLastPrompt() }
                .buttonStyle(.bordered)
            Button {
                engine.lastError = nil
            } label: {
                Label("Dismiss error", systemImage: "xmark")
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.plain)
        }
        .padding(.horizontal, Theme.Space.m)
        .padding(.vertical, Theme.Space.s)
        .background(Theme.danger.opacity(0.10))
    }

    // MARK: Transcript

    private func scrollRegion(metrics: AgentWorkspaceMetrics,
                              railVisible: Bool) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                // Zero-height leaf probe. It reports when content scrolls up
                // under the command bar so the bar can raise its separator.
                // Kept out of the spacing stack below so it costs no height.
                Color.clear
                    .frame(height: 0)
                    .background {
                        GeometryReader { geometry in
                            Color.clear.preference(
                                key: HeadingBottomKey.self,
                                value: geometry.frame(in: .named("transcript")).minY
                            )
                        }
                    }
                LazyVStack(alignment: .leading, spacing: Theme.Space.m) {
                    if engine.transcript.isEmpty {
                        idleCommandCenter(metrics: metrics)
                    }
                    // Inline activity only when the rail isn't carrying it.
                    if !railVisible && !engine.liveToolEvents.isEmpty {
                        LiveToolActivity(events: engine.liveToolEvents)
                            .id("live-tools")
                    }
                    ForEach(engine.transcript) { message in
                        MessageBubble(message: message, metrics: metrics)
                            .id(message.id)
                    }
                    if engine.state.isActive
                        && (!engine.liveAssistantText.isEmpty || !engine.liveReasoningText.isEmpty) {
                        MessageBubble(
                            message: ChatMessage(
                                role: .assistant,
                                text: engine.liveAssistantText,
                                reasoning: engine.liveReasoningText.isEmpty
                                    ? nil : engine.liveReasoningText
                            ),
                            streaming: true,
                            metrics: metrics
                        )
                        .id("streaming")
                    } else if engine.state.isActive {
                        TypingIndicator()
                            .transition(.opacity.combined(with: .scale(scale: 0.9)))
                    }
                    Color.clear.frame(height: 1).id("chat-bottom")
                        .background {
                            GeometryReader { geometry in
                                Color.clear.preference(
                                    key: TranscriptBottomKey.self,
                                    value: geometry.frame(in: .named("transcript")).maxY
                                )
                            }
                        }
                }
                }
                .padding(.horizontal, metrics.paddingX)
                .padding(.top, metrics.paddingTop)
                .padding(.bottom, metrics.paddingBottom)
                .workspaceColumn(metrics)
            }
            .coordinateSpace(name: "transcript")
            .background {
                GeometryReader { geometry in
                    Color.clear.preference(key: TranscriptViewportKey.self, value: geometry.size.height)
                }
            }
            .overlay(alignment: .bottomTrailing) {
                if hasUnseenActivity {
                    Button {
                        withAnimation(Motion.snappy) {
                            proxy.scrollTo("chat-bottom", anchor: .bottom)
                        }
                        hasUnseenActivity = false
                        isNearTranscriptBottom = true
                    } label: {
                        Label("Jump to latest", systemImage: "arrow.down")
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .padding(Theme.Space.m)
                    .help("Show the newest agent activity")
                }
            }
            .onPreferenceChange(TranscriptBottomKey.self) { bottom in
                // The coordinate space is the visible scroll viewport: a
                // bottom within 96pt means following new output is intentional.
                isNearTranscriptBottom = bottom <= transcriptViewportHeight + 96 || bottom.isZero
                if isNearTranscriptBottom { hasUnseenActivity = false }
            }
            .onPreferenceChange(TranscriptViewportKey.self) { transcriptViewportHeight = $0 }
            .onPreferenceChange(HeadingBottomKey.self) { top in
                onScrolledUnder?(top < -2)
            }
            .onChange(of: engine.transcript.count) { _, _ in
                followBottom(proxy)
            }
            .onChange(of: engine.liveAssistantText) { _, _ in
                followBottom(proxy)
            }
            .onChange(of: engine.liveReasoningText) { _, _ in
                followBottom(proxy)
            }
            .onChange(of: engine.liveToolEvents.map { "\($0.id)-\($0.status.rawValue)" }) { _, _ in
                followBottom(proxy)
            }
            .onChange(of: engine.pendingChanges.count) { _, _ in
                followBottom(proxy)
            }
        }
    }

    private func followBottom(_ proxy: ScrollViewProxy) {
        guard isNearTranscriptBottom else {
            hasUnseenActivity = true
            return
        }
        DispatchQueue.main.async { proxy.scrollTo("chat-bottom", anchor: .bottom) }
    }

    /// The idle state is a full-width command center: one compact horizontal
    /// introduction row, then the Smart Tasks grid across the whole workspace.
    /// Nothing is vertically centered, so content starts right below the bar.
    private func idleCommandCenter(metrics: AgentWorkspaceMetrics) -> some View {
        VStack(alignment: .leading, spacing: metrics.sectionGap) {
            introRow(metrics: metrics)
            smartTasksSection(metrics: metrics)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .wcAppear()
    }

    private func introRow(metrics: AgentWorkspaceMetrics) -> some View {
        HStack(alignment: .center, spacing: Theme.Space.m) {
            BrandIllustration(size: metrics.isNarrow ? 48 : 56)

            VStack(alignment: .leading, spacing: 3) {
                Text("What should we change today?")
                    .font(Theme.ui(metrics.isNarrow ? 16 : 19, .semibold))
                    .tracking(Theme.Typography.titleTracking)
                    .foregroundStyle(Theme.Chrome.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                Text("Describe it in plain English — the agent reads your repo and proposes edits for your approval.")
                    .font(Theme.ui(13))
                    .foregroundStyle(Theme.Chrome.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: metrics.proseWidth, alignment: .leading)

            Spacer(minLength: Theme.Space.m)

            // Real project context only — nothing synthesized.
            if !metrics.isNarrow, let workspace = settings.activeWorkspace {
                VStack(alignment: .trailing, spacing: 5) {
                    Badge(text: workspace.techStack.rawValue,
                          systemImage: workspace.techStack.icon,
                          tint: Theme.Chrome.textSecondary)
                    Badge(text: workspace.deployment.rawValue,
                          systemImage: "arrow.up.forward.square",
                          tint: Theme.Chrome.textSecondary)
                }
                .fixedSize()
            }
        }
        .frame(minHeight: metrics.isNarrow ? 72 : 88, alignment: .center)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func smartTasksSection(metrics: AgentWorkspaceMetrics) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            HStack(spacing: Theme.Space.s) {
                Text("Smart tasks")
                    .font(Theme.ui(10.5, .semibold))
                    .tracking(0.6)
                    .textCase(.uppercase)
                    .foregroundStyle(Theme.Chrome.textMuted)
                Spacer()
                Text("Click to prefill the message")
                    .font(Theme.ui(11))
                    .foregroundStyle(Theme.Chrome.textMuted)
            }

            LazyVGrid(
                columns: Array(
                    repeating: GridItem(.flexible(minimum: 0), spacing: metrics.cardGap),
                    count: metrics.taskColumns
                ),
                alignment: .leading,
                spacing: metrics.cardGap
            ) {
                ForEach(smartTemplates) { template in
                    Button {
                        draft = contextualPrompt(for: template)
                        composerFocused = true
                    } label: {
                        templateCard(
                            template,
                            metrics: metrics,
                            recommended: isRecommended(template)
                        )
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Starter task: \(template.title)")
                    .accessibilityHint("\(template.subtitle). Fills the message field for editing.")
                }
            }
        }
    }

    private func templateCard(_ template: AgentTemplate,
                              metrics: AgentWorkspaceMetrics,
                              recommended: Bool) -> some View {
        let compact = metrics.isNarrow
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: Theme.Space.s) {
                Image(systemName: template.icon)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(recommended ? Theme.Chrome.accent : Theme.Chrome.textSecondary)
                    .frame(width: 26, height: 26)
                    .background(recommended ? Theme.Chrome.accentTint : Theme.raisedFill,
                                in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                Spacer(minLength: 0)
                if recommended {
                    Text("Recommended")
                        .font(Theme.ui(9, .bold))
                        .foregroundStyle(Theme.Chrome.accent)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(Theme.Chrome.accentTint, in: Capsule())
                }
            }
            Text(LocalizedStringKey(template.title))
                .font(Theme.ui(12.5, .semibold))
                .foregroundStyle(Theme.Chrome.textPrimary)
                .lineLimit(1)
            Text(LocalizedStringKey(template.subtitle))
                .font(Theme.ui(11.5))
                .foregroundStyle(Theme.Chrome.textSecondary)
                .lineLimit(compact ? 2 : 3)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .frame(minHeight: metrics.taskCardMinHeight, alignment: .topLeading)
        .padding(Theme.Space.m - 2)
        .background(Theme.raisedFill,
                    in: RoundedRectangle(cornerRadius: Theme.Radius.medium, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: Theme.Radius.medium, style: .continuous)
                .strokeBorder(Theme.hairline)
        }
        .contentShape(Rectangle())
    }

    private struct AgentTemplate: Identifiable {
        let title: String
        let subtitle: String
        let icon: String
        let prompt: String
        var stacks: [TechStack] = []
        var deployments: [DeploymentType] = []
        var id: String { title }
    }

    private var smartTemplates: [AgentTemplate] {
        guard let workspace = settings.activeWorkspace else { return Self.templates }
        return Self.templates.sorted {
            recommendationScore($0, workspace: workspace) > recommendationScore($1, workspace: workspace)
        }
    }

    private func recommendationScore(_ template: AgentTemplate, workspace: SiteWorkspace) -> Int {
        var score = 0
        if template.stacks.contains(workspace.techStack) { score += 2 }
        if template.deployments.contains(workspace.deployment) { score += 1 }
        return score
    }

    private func isRecommended(_ template: AgentTemplate) -> Bool {
        guard let workspace = settings.activeWorkspace else { return false }
        return recommendationScore(template, workspace: workspace) > 0
    }

    private func contextualPrompt(for template: AgentTemplate) -> String {
        guard let workspace = settings.activeWorkspace else { return template.prompt }
        return """
        Project context: \(workspace.techStack.rawValue), deployed with \(workspace.deployment.rawValue).

        \(template.prompt)
        """
    }

    private static let templates: [AgentTemplate] = [
        AgentTemplate(
            title: "Core Web Vitals",
            subtitle: "Improve LCP, INP, CLS, and perceived speed",
            icon: "gauge.with.dots.needle.67percent",
            prompt: """
            Audit and improve real-user performance.
            - Find likely LCP, INP, and CLS problems in the current code
            - Reduce render-blocking work, oversized media, and layout shifts
            - Add safe caching, preloading, or prefetching only where evidence supports it
            - Preserve behavior and accessibility

            Explain the highest-impact findings, apply focused fixes, and note how to measure the result.
            """,
            stacks: [.nextjs, .astro, .sveltekit]
        ),
        AgentTemplate(
            title: "Accessibility Review",
            subtitle: "Fix WCAG 2.2, keyboard, focus, and reflow issues",
            icon: "accessibility",
            prompt: """
            Run a practical WCAG 2.2 accessibility review and fix objective issues.
            - Check semantic structure, labels, names, contrast, and error messaging
            - Verify full keyboard navigation and visible focus
            - Check zoom/reflow, target sizes, reduced motion, and screen-reader announcements
            - Preserve the product's visual character

            List findings by severity, then implement and verify the safe fixes.
            """
        ),
        AgentTemplate(
            title: "Security & Dependencies",
            subtitle: "Prioritize exploitable risks and supply-chain gaps",
            icon: "checkmark.shield",
            prompt: """
            Audit this project for actionable web and supply-chain security risks.
            - Review dependencies and configuration for exposed secrets or unsafe defaults
            - Check untrusted input handling, authentication boundaries, CSP, and security headers
            - Inspect CI workflows for broad permissions and unpinned third-party actions
            - Prioritize by exploitability and impact; avoid noisy speculative findings

            Apply low-risk fixes and clearly flag anything that needs a product decision.
            """
        ),
        AgentTemplate(
            title: "Modern CSS System",
            subtitle: "Adopt tokens, layers, and component-aware layouts",
            icon: "paintbrush.pointed",
            prompt: """
            Modernize the CSS architecture without redesigning the site.
            - Consolidate repeated values into design tokens
            - Use cascade layers to make precedence explicit where they reduce conflicts
            - Replace brittle viewport-only layouts with container queries where appropriate
            - Use modern color and sizing functions with sensible fallbacks

            Make incremental changes, remove obsolete overrides, and verify responsive behavior.
            """,
            stacks: [.vanillaHTML, .hugo, .jekyll, .eleventy, .custom]
        ),
        AgentTemplate(
            title: "Instant Navigation",
            subtitle: "Add safe caching, prefetching, and resilient states",
            icon: "bolt.horizontal.circle",
            prompt: """
            Make navigation feel instant and resilient.
            - Trace repeated data and asset requests across common navigation paths
            - Add framework-native caching, prefetching, and stale-while-revalidate behavior where safe
            - Add useful loading, empty, offline, and retry states
            - Avoid stale private data, request storms, and unnecessary JavaScript

            Implement the highest-value improvements and document cache invalidation behavior.
            """,
            stacks: [.nextjs, .astro, .sveltekit],
            deployments: [.vercel, .netlify, .cloudflarePages]
        ),
        AgentTemplate(
            title: "Search & Sharing",
            subtitle: "Upgrade metadata, structured data, and discovery",
            icon: "magnifyingglass.circle",
            prompt: """
            Improve search-engine and social discovery using current standards.
            - Audit titles, descriptions, canonical URLs, robots directives, and sitemap coverage
            - Fix heading and internal-link structure
            - Add accurate schema.org JSON-LD for the site's real content
            - Validate Open Graph and X card metadata, including image dimensions

            Avoid keyword stuffing and invented claims. Apply fixes and summarize validation steps.
            """
        ),
        AgentTemplate(
            title: "Responsive UX",
            subtitle: "Repair reflow, touch targets, and adaptive navigation",
            icon: "rectangle.on.rectangle.angled",
            prompt: """
            Test and improve responsive behavior from narrow phones through wide desktops.
            - Find horizontal overflow, clipped content, unsafe fixed dimensions, and awkward breakpoints
            - Fix touch targets, fluid typography, media sizing, and adaptive navigation
            - Test 200% zoom and long localized text
            - Respect safe areas and input methods

            Describe each reproduced issue, fix it, and verify representative widths.
            """
        ),
        AgentTemplate(
            title: "Conversion Flow",
            subtitle: "Clarify the primary journey and reduce friction",
            icon: "point.topleft.down.to.point.bottomright.curvepath",
            prompt: """
            Review the site's primary conversion journey.
            - Identify the main user goal and unclear or competing calls to action
            - Improve information hierarchy, trust cues, form friction, and completion feedback
            - Add accessible validation and recovery states
            - Keep claims factual and avoid dark patterns

            Propose the smallest high-confidence changes, then implement them consistently.
            """
        ),
        AgentTemplate(
            title: "Quality Pipeline",
            subtitle: "Add focused tests and safer pull-request checks",
            icon: "checkmark.seal",
            prompt: """
            Strengthen the project's quality pipeline.
            - Identify critical paths currently lacking automated coverage
            - Add focused unit, integration, or end-to-end tests using the existing stack
            - Add fast pull-request checks for formatting, types, tests, accessibility, and builds
            - Use least-privilege CI permissions and pin third-party actions appropriately

            Keep CI fast, deterministic, and easy to debug.
            """
        ),
        AgentTemplate(
            title: "Image Delivery",
            subtitle: "Modernize formats, sizing, loading, and alt text",
            icon: "photo.on.rectangle.angled",
            prompt: """
            Audit and modernize image delivery.
            - Find oversized, poorly compressed, or incorrectly dimensioned assets
            - Add responsive sources and modern formats supported by the current stack
            - Prioritize the likely LCP image; lazy-load only below-the-fold media
            - Fix missing dimensions and meaningful alternative text

            Apply improvements without visible quality loss and report expected byte savings.
            """,
            stacks: [.nextjs, .astro, .sveltekit, .hugo]
        ),
        AgentTemplate(
            title: "Privacy & Analytics",
            subtitle: "Reduce tracking and make consent behavior honest",
            icon: "hand.raised",
            prompt: """
            Audit analytics, embeds, cookies, and client-side data collection.
            - Inventory what loads, what data it sends, and when it activates
            - Remove redundant trackers and minimize collected data
            - Ensure consent controls match actual behavior and remain keyboard accessible
            - Update user-facing disclosure only to reflect verified implementation

            Apply technical fixes first and clearly identify any legal or policy decisions for review.
            """
        ),
        AgentTemplate(
            title: "Content Refresh",
            subtitle: "Improve clarity, scannability, and trust",
            icon: "text.redaction",
            prompt: """
            Refresh the site's core copy without changing its meaning or inventing facts.
            - Tighten headings and opening paragraphs
            - Make benefits, proof, and next steps easier to scan
            - Remove stale language, repetition, and vague claims
            - Preserve brand voice and localization structure

            Show the key copy decisions, then update the relevant pages consistently.
            """
        ),
        AgentTemplate(
            title: "Offline Resilience",
            subtitle: "Handle weak networks, failures, and recovery",
            icon: "wifi.exclamationmark",
            prompt: """
            Improve resilience under slow, intermittent, or offline network conditions.
            - Find requests that fail silently or leave the interface stuck
            - Add timeouts, cancellation, retry, and clear recovery states
            - Cache only safe public assets or data with an explicit invalidation plan
            - Prevent duplicate submissions and preserve user input

            Implement focused improvements and test representative failure paths.
            """,
            deployments: [.cloudflarePages, .vercel, .netlify]
        )
    ]

    // MARK: Composer

    private func composer(metrics: AgentWorkspaceMetrics) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            if !attachments.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: Theme.Space.s) {
                        ForEach(attachments) { attachment in
                            attachmentChip(attachment)
                        }
                    }
                }
            }

            if let attachmentError {
                Label(attachmentError, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(Theme.danger)
            }

            HStack(alignment: .bottom, spacing: Theme.Space.m) {
                HStack(alignment: .bottom, spacing: Theme.Space.s) {
                    Button {
                        showAttachmentPicker = true
                    } label: {
                        Label("Attach files", systemImage: "paperclip")
                    }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.plain)
                    .frame(width: 32, height: 32)
                    .contentShape(Rectangle())
                    .disabled(engine.state.isActive || attachments.count >= Attachment.maximumCount)
                    .help("Attach images or text files")

                    TextField("Describe a change…", text: $draft, axis: .vertical)
                        .textFieldStyle(.plain)
                        .font(.body)
                        .lineLimit(1...6)
                        .focused($composerFocused)
                        .onSubmit { sendIfPossible() }
                }
                .padding(.horizontal, Theme.Space.m)
                .padding(.vertical, 10)
                .background(Theme.raisedFill, in: RoundedRectangle(cornerRadius: Theme.Radius.medium))
                .overlay {
                    RoundedRectangle(cornerRadius: Theme.Radius.medium)
                        .strokeBorder(composerFocused ? Theme.focusRing : Theme.strongBorder,
                                      lineWidth: composerFocused ? 2 : 1)
                }

                if engine.state.isActive {
                    Button {
                        engine.cancelGeneration()
                    } label: {
                        Label("Stop agent", systemImage: "stop.circle.fill")
                            .font(.system(size: 30))
                    }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.plain)
                    .foregroundStyle(Theme.warning)
                    .keyboardShortcut(".", modifiers: .command)
                    .help("Stop agent (⌘.)")
                } else {
                    Button {
                        sendIfPossible()
                    } label: {
                        Label("Send message", systemImage: "arrow.up.circle.fill")
                            .font(.system(size: 30))
                            .foregroundStyle(canSend
                                ? AnyShapeStyle(Theme.brandGradient)
                                : AnyShapeStyle(Theme.tertiaryText))
                            .symbolEffect(.bounce, value: engine.transcript.count)
                    }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.plain)
                    .disabled(!canSend)
                    .animation(Motion.bouncy, value: canSend)
                    .keyboardShortcut(.return, modifiers: [])
                    .help("Send message")
                }
            }
        }
        .padding(.horizontal, metrics.paddingX)
        .padding(.vertical, 14)
        .workspaceColumn(metrics)
    }

    private var canSend: Bool {
        (!draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !attachments.isEmpty)
            && !engine.state.isActive
    }

    private func sendIfPossible() {
        guard canSend else { return }
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "Review the attached file\(attachments.count == 1 ? "" : "s")."
            : draft
        let outgoingAttachments = attachments
        draft = ""
        attachments = []
        attachmentError = nil
        engine.send(text, attachments: outgoingAttachments)
    }

    private func attachmentChip(_ attachment: Attachment) -> some View {
        HStack(spacing: 6) {
            Image(systemName: attachment.isImage ? "photo" : "doc.text")
                .foregroundStyle(Theme.accent)
            VStack(alignment: .leading, spacing: 1) {
                Text(attachment.filename).lineLimit(1)
                Text(attachment.byteLabel)
                    .font(.caption2)
                    .foregroundStyle(Theme.secondaryText)
            }
            Button {
                attachments.removeAll { $0.id == attachment.id }
            } label: {
                Label("Remove \(attachment.filename)", systemImage: "xmark")
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.plain)
        }
        .font(.callout)
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(Theme.raisedFill, in: RoundedRectangle(cornerRadius: Theme.Radius.small))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.small).strokeBorder(Theme.strongBorder))
        .frame(maxWidth: 260)
    }

    private func importAttachments(_ result: Result<[URL], Error>) {
        do {
            for url in try result.get() {
                guard attachments.count < Attachment.maximumCount else {
                    throw AttachmentImportError.tooMany
                }
                let accessing = url.startAccessingSecurityScopedResource()
                defer { if accessing { url.stopAccessingSecurityScopedResource() } }
                let values = try url.resourceValues(forKeys: [.contentTypeKey, .fileSizeKey])
                let type = values.contentType
                let isImage = type?.conforms(to: .image) == true
                let isText = type?.conforms(to: .text) == true
                    || type?.conforms(to: .sourceCode) == true
                    || type?.conforms(to: .json) == true
                guard isImage || isText else {
                    throw AttachmentImportError.unsupported(url.lastPathComponent)
                }
                let size = values.fileSize ?? 0
                let maximum = isImage ? Attachment.maximumImageBytes : Attachment.maximumTextBytes
                guard size <= maximum else {
                    throw AttachmentImportError.tooLarge(url.lastPathComponent)
                }
                let data = try Data(contentsOf: url, options: .mappedIfSafe)
                attachments.append(Attachment(
                    filename: url.lastPathComponent,
                    mimeType: type?.preferredMIMEType ?? (isImage ? "image/png" : "text/plain"),
                    data: data
                ))
            }
            attachmentError = nil
            composerFocused = true
        } catch {
            attachmentError = error.localizedDescription
        }
    }

    private func retryLastPrompt() {
        guard let text = engine.transcript.last(where: { $0.role == .user })?.text else {
            engine.lastError = nil
            return
        }
        engine.lastError = nil
        draft = text
        sendIfPossible()
    }
}

private enum AttachmentImportError: LocalizedError {
    case tooMany
    case tooLarge(String)
    case unsupported(String)

    var errorDescription: String? {
        switch self {
        case .tooMany:
            return String(localized: "You can attach up to 5 files.")
        case .tooLarge(let name):
            return String(localized: "\(name) is too large.")
        case .unsupported(let name):
            return String(localized: "\(name) is not a supported image or text file.")
        }
    }
}

private struct TranscriptBottomKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

private struct TranscriptViewportKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

private struct HeadingBottomKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

// MARK: - Live agent activity

struct LiveToolActivity: View {
    let events: [ToolEvent]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "sparkles")
                    .foregroundStyle(Theme.accent)
                Text("Agent activity")
                    .font(.caption.weight(.semibold))
                Spacer()
                if events.contains(where: { $0.status == .running }) {
                    ProgressView().controlSize(.mini)
                }
            }
            ForEach(ToolActivityGroup.group(events)) { group in
                DisclosureGroup {
                    VStack(alignment: .leading, spacing: 5) {
                        ForEach(group.events) { event in
                            HStack(spacing: 6) {
                                activityIcon(event)
                                Text(event.summary).lineLimit(2)
                            }
                    .font(.callout)
                            .foregroundStyle(event.status == .failure ? Theme.danger : Theme.secondaryText)
                        }
                    }
                    .padding(.leading, 22)
                    .padding(.top, 4)
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: group.icon).foregroundStyle(group.tint)
                        Text(LocalizedStringKey(group.title)).font(.callout.weight(.semibold))
                        Text(group.summary).font(.callout).foregroundStyle(Theme.secondaryText)
                        Spacer()
                        if group.hasRunning { ProgressView().controlSize(.mini) }
                    }
                }
                .disclosureGroupStyle(.automatic)
            }
        }
        .padding(Theme.Space.m)
        .background(Theme.panelFill,
                    in: RoundedRectangle(cornerRadius: Theme.Radius.medium, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: Theme.Radius.medium, style: .continuous)
                .strokeBorder(Theme.hairline)
        }
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private func activityIcon(_ event: ToolEvent) -> some View {
        switch event.status {
        case .running:
            Image(systemName: event.name == "write_file" ? "pencil.line" : "doc.text.magnifyingglass")
                .foregroundStyle(Theme.warning)
        case .success:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.success)
        case .failure:
            Image(systemName: "xmark.circle.fill").foregroundStyle(Theme.danger)
        }
    }

    private func activityTint(_ event: ToolEvent) -> Color {
        switch event.status {
        case .running: return Theme.warning
        case .success: return Theme.success
        case .failure: return Theme.danger
        }
    }
}

struct ToolActivityGroup: Identifiable {
    let id: String
    let title: String
    let icon: String
    let events: [ToolEvent]

    var hasRunning: Bool { events.contains { $0.status == .running } }
    var hasFailure: Bool { events.contains { $0.status == .failure } }
    var tint: Color { hasFailure ? Theme.danger : (hasRunning ? Theme.warning : Theme.success) }
    var summary: String {
        if hasFailure {
            return "\(events.count) operation\(events.count == 1 ? "" : "s") · \(events.filter { $0.status == .failure }.count) failed"
        }
        return "\(events.count) operation\(events.count == 1 ? "" : "s")"
    }

    static func group(_ events: [ToolEvent]) -> [ToolActivityGroup] {
        let order = ["explore", "read", "inspect", "edit", "check", "review"]
        let buckets = Dictionary(grouping: events, by: category)
        return order.compactMap { key in
            guard let values = buckets[key], !values.isEmpty else { return nil }
            let metadata: (String, String)
            switch key {
            case "explore": metadata = ("Exploring project", "folder")
            case "read": metadata = ("Reading files", "doc.text.magnifyingglass")
            case "inspect": metadata = ("Inspecting live site", "safari")
            case "edit": metadata = ("Editing files", "pencil.line")
            case "check": metadata = ("Running checks", "checkmark.circle")
            default: metadata = ("Reviewing changes", "doc.text")
            }
            return ToolActivityGroup(id: key, title: metadata.0, icon: metadata.1, events: values)
        }
    }

    private static func category(_ event: ToolEvent) -> String {
        let name = event.name.lowercased()
        if name.contains("list") || name.contains("search") { return "explore" }
        if name.contains("read") { return "read" }
        if name.contains("browser") || name.contains("screenshot") || name.contains("inspect") { return "inspect" }
        if name.contains("write") || name.contains("edit") || name.contains("patch") { return "edit" }
        if name.contains("test") || name.contains("build") || name.contains("run") { return "check" }
        return "review"
    }
}

// MARK: - Reasoning / thinking disclosure

/// Secondary surface for real provider reasoning. While streaming it stays
/// open so tokens are visible as they arrive; completed turns start collapsed.
struct ReasoningDisclosure: View {
    let text: String
    var streaming: Bool = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var expanded = false
    @State private var userCollapsed = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                if streaming {
                    userCollapsed.toggle()
                    if reduceMotion {
                        expanded = !userCollapsed
                    } else {
                        withAnimation(Motion.snappy) { expanded = !userCollapsed }
                    }
                } else if reduceMotion {
                    expanded.toggle()
                } else {
                    withAnimation(Motion.snappy) { expanded.toggle() }
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "brain")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Theme.Chrome.accent)
                        .symbolEffect(.pulse, isActive: streaming && expanded && !reduceMotion)
                    Text(streaming
                         ? String(localized: "Thinking…")
                         : String(localized: "Reasoning"))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Theme.Chrome.textSecondary)
                        .contentTransition(.opacity)
                    if streaming {
                        ProgressView().controlSize(.mini)
                    }
                    Spacer(minLength: 8)
                    Text(streaming
                         ? "\(max(1, text.split { $0.isWhitespace || $0.isNewline }.count)) words"
                         : "")
                        .font(.caption2)
                        .foregroundStyle(Theme.Chrome.textMuted)
                        .opacity(streaming && expanded ? 1 : 0)
                    Image(systemName: "chevron.right")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(Theme.Chrome.textMuted)
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                        .animation(reduceMotion ? nil : Motion.snappy, value: expanded)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(expanded
                                ? String(localized: "Hide reasoning")
                                : String(localized: "Show reasoning"))
            .accessibilityValue(streaming
                                ? String(localized: "Streaming")
                                : String(localized: "Complete"))

            if expanded {
                ScrollView {
                    Text(text)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(Theme.Chrome.textSecondary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: streaming ? 220 : 320)
                .padding(.horizontal, 10)
                .padding(.bottom, 8)
                .transition(reduceMotion
                            ? .opacity
                            : .opacity.combined(with: .move(edge: .top)))
                .accessibilityLabel(String(localized: "Model reasoning"))
            }
        }
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous)
                .fill(Theme.raisedFill)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous)
                .strokeBorder(
                    streaming ? Theme.Chrome.accent.opacity(0.28) : Theme.borderSubtle,
                    lineWidth: 1
                )
        )
        .onAppear { syncExpanded() }
        .onChange(of: streaming) { _, _ in syncExpanded() }
        .onChange(of: text) { _, _ in
            // Keep the live panel open as tokens arrive unless the user hid it.
            if streaming && !userCollapsed && !expanded {
                if reduceMotion { expanded = true }
                else { withAnimation(Motion.snappy) { expanded = true } }
            }
        }
    }

    private func syncExpanded() {
        if streaming {
            let shouldExpand = !userCollapsed
            if reduceMotion { expanded = shouldExpand }
            else { withAnimation(Motion.snappy) { expanded = shouldExpand } }
        } else {
            userCollapsed = false
            // Completed turns stay collapsed so the reply stays primary.
        }
    }
}

// MARK: - Message bubble

struct MessageBubble: View {
    let message: ChatMessage
    var streaming: Bool = false
    /// The workspace grid. Drives the user-bubble cap and the readable prose
    /// measure so every message aligns to the same column.
    var metrics: AgentWorkspaceMetrics?

    @EnvironmentObject var settings: SettingsStore

    private var isUser: Bool { message.role == .user }

    private var assistantProviderID: String {
        settings.preferOnDevice ? "ondevice" : settings.providerID
    }

    /// User messages hug their content, up to `min(72%, 820)` of the column.
    private var userMaxWidth: CGFloat { metrics?.userBubbleWidth ?? 820 }
    /// Long assistant prose stays at a readable measure; cards, code, diffs,
    /// and tool output below use the full column.
    private var proseMaxWidth: CGFloat { metrics?.proseWidth ?? 720 }

    var body: some View {
        HStack(alignment: .top, spacing: Theme.Space.s) {
            if isUser {
                Spacer(minLength: Theme.Space.l)
                content
                    .frame(maxWidth: userMaxWidth, alignment: .trailing)
            } else {
                ProviderAvatar(size: 28, providerID: assistantProviderID)
                content
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(maxWidth: .infinity, alignment: isUser ? .trailing : .leading)
        .wcAppear()
    }

    private var content: some View {
        VStack(alignment: isUser ? .trailing : .leading, spacing: Theme.Space.s) {
            if !message.toolEvents.isEmpty {
                toolEvents
            }
            if let reasoning = message.reasoning?
                .trimmingCharacters(in: .whitespacesAndNewlines),
               !reasoning.isEmpty {
                ReasoningDisclosure(
                    text: reasoning,
                    streaming: streaming
                )
            }
            if !message.attachments.isEmpty {
                attachmentSummary
            }
            if !message.text.isEmpty {
                HStack(alignment: .center, spacing: 4) {
                    Text(message.text)
                        .font(.callout)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                    if streaming { StreamingCaret() }
                }
                .padding(.horizontal, Theme.Space.m)
                .padding(.vertical, Theme.Space.s + 2)
                .frame(maxWidth: isUser ? nil : proseMaxWidth,
                       alignment: .leading)
                .background(background, in: bubbleShape)
                .foregroundStyle(isUser ? .white : .primary)
            }
        }
    }

    private var background: AnyShapeStyle {
        isUser ? AnyShapeStyle(Theme.brandGradient) : AnyShapeStyle(Theme.cardFill)
    }

    private var bubbleShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: Theme.Radius.medium, style: .continuous)
    }

    private var toolEvents: some View {
        LiveToolActivity(events: message.toolEvents)
    }

    private var attachmentSummary: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(message.attachments) { attachment in
                Label {
                    Text("\(attachment.filename) · \(attachment.byteLabel)")
                        .lineLimit(1)
                } icon: {
                    Image(systemName: attachment.isImage ? "photo" : "doc.text")
                }
                .font(.caption)
                .foregroundStyle(Theme.secondaryText)
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(Theme.raisedFill, in: Capsule())
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
