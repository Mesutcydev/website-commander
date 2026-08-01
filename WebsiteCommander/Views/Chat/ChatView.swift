import SwiftUI
import UniformTypeIdentifiers
import AppKit

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
    @State private var draft = ""
    @State private var draftWorkspaceID: UUID?
    @State private var reviewingChange: PendingChange?
    @State private var showConversations = false
    @State private var attachments: [Attachment] = []
    @State private var showAttachmentPicker = false
    @State private var attachmentError: String?
    @FocusState private var composerFocused: Bool
    /// Focus chrome (indigo border + halo) only after an intentional edit
    /// gesture. AppKit can make the field first responder on window activation;
    /// without this gate the idle empty state would wear a permanent blue ring.
    @State private var composerFocusChrome = false
    @State private var isNearTranscriptBottom = true
    @State private var hasUnseenActivity = false
    @State private var transcriptViewportHeight: CGFloat = 0

    /// True when the composer should show its focused border treatment.
    private var composerShowsFocus: Bool { composerFocused && composerFocusChrome }

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
            restoreDraft()
            if let prompt = engine.prefilledPrompt {
                draft = prompt
                engine.prefilledPrompt = nil
            }
            let hasDraft = !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            // Resume an in-progress draft with focus chrome; otherwise keep the
            // empty state quiet even if the field becomes first responder.
            if hasDraft {
                composerFocusChrome = true
                if !embedded { composerFocused = true }
            } else {
                composerFocusChrome = false
                DispatchQueue.main.async { composerFocused = false }
            }
        }
        .onChange(of: composerFocused) { _, focused in
            if !focused { composerFocusChrome = false }
        }
        .onChange(of: draft) { _, newValue in
            guard draftWorkspaceID == currentDraftWorkspaceID else { return }
            UserDefaults.standard.set(newValue, forKey: draftStorageKey(for: draftWorkspaceID))
        }
        .onChange(of: settings.activeWorkspaceID) { _, _ in
            restoreDraft()
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
        .onReceive(NotificationCenter.default.publisher(for: .requestAgentSend)) { _ in
            sendIfPossible()
        }
        .onReceive(NotificationCenter.default.publisher(for: .requestAgentStop)) { _ in
            engine.cancelGeneration()
        }
        .onReceive(NotificationCenter.default.publisher(for: .requestApproveAll)) { _ in
            guard !engine.pendingChanges.isEmpty else { return }
            Task { await engine.approveAll() }
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
            if engine.canContinue || engine.lastError != nil {
                recoveryBar
            }
            if let note = engine.lastCommitNote {
                commitBanner(note)
            }
            if let warning = engine.lastDeploymentWarning {
                deploymentWarningBanner(warning)
            }
            Rectangle()
                .fill(Theme.divider)
                .frame(height: 1)
            composer(metrics: metrics)
        }
    }

    private var recoveryBar: some View {
        HStack(spacing: Theme.Space.s) {
            Image(systemName: engine.canContinue ? "pause.circle.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(engine.canContinue ? Theme.warning : Theme.danger)
            Text(engine.canContinue
                 ? (engine.lastStopReason ?? "Work paused")
                 : (engine.lastError ?? "The last request failed."))
                .font(.caption)
                .foregroundStyle(Theme.secondaryText)
                .lineLimit(2)
            Spacer()
            if engine.canContinue {
                Button("Continue") { engine.continueRun() }
                    .buttonStyle(.primarySoftCompact)
            } else if engine.lastApprovalError == nil {
                Button("Retry") { retryLastPrompt() }
                    .buttonStyle(.primarySoftCompact)
            } else if let change = engine.pendingChanges.first {
                Button("Review change") { reviewingChange = change }
                    .buttonStyle(.primarySoftCompact)
            }
            Button {
                engine.dismissRecovery()
            } label: {
                Label("Dismiss recovery message", systemImage: "xmark")
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.plain)
        }
        .padding(.horizontal, Theme.Space.m)
        .padding(.vertical, Theme.Space.s)
        .background(engine.canContinue ? Theme.amberSoft : Theme.destructiveSoft)
    }

    private func commitBanner(_ note: String) -> some View {
        HStack(spacing: Theme.Space.s) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(Theme.success)
            Text(note)
                .font(Theme.ui(12))
                .foregroundStyle(Theme.secondaryText)
                .lineLimit(2)
            Spacer()
            if let workspace = settings.activeWorkspace,
               let url = SiteWorkspace.normalizedLiveURL(workspace.configuredLiveURL) {
                Button("Open Live") { NSWorkspace.shared.open(url) }
                    .buttonStyle(.primarySoftCompact)
            }
            Button {
                engine.lastCommitNote = nil
                engine.lastDeploymentWarning = nil
            } label: {
                Label("Dismiss deployment status", systemImage: "xmark")
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.plain)
        }
        .padding(.horizontal, Theme.Space.m)
        .padding(.vertical, Theme.Space.s)
        .background(Theme.greenSoft)
    }

    private func deploymentWarningBanner(_ warning: String) -> some View {
        HStack(spacing: Theme.Space.s) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(Theme.warning)
            VStack(alignment: .leading, spacing: 2) {
                Text("Change committed, but deployment needs attention")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Theme.textPrimary)
                Text(warning)
                    .font(.caption2)
                    .foregroundStyle(Theme.secondaryText)
                    .lineLimit(2)
            }
            Spacer()
            Button {
                engine.lastDeploymentWarning = nil
            } label: {
                Label("Dismiss deployment warning", systemImage: "xmark")
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.plain)
        }
        .padding(.horizontal, Theme.Space.m)
        .padding(.vertical, Theme.Space.s)
        .background(Theme.amberSoft)
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
                // Defer state writes off the layout/constraint pass. Updating
                // @State during preference delivery (which runs while AppKit is
                // inside updateConstraints) trips
                // `_postWindowNeedsUpdateConstraints` and crashes the app mid
                // stream — which relaunches into an empty Agent idle surface.
                DispatchQueue.main.async {
                    isNearTranscriptBottom = bottom <= transcriptViewportHeight + 96 || bottom.isZero
                    if isNearTranscriptBottom { hasUnseenActivity = false }
                }
            }
            .onPreferenceChange(TranscriptViewportKey.self) { height in
                DispatchQueue.main.async { transcriptViewportHeight = height }
            }
            .onPreferenceChange(HeadingBottomKey.self) { top in
                DispatchQueue.main.async { onScrolledUnder?(top < -2) }
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
        HStack(alignment: .center, spacing: Theme.Space.l - 2) {
            BrandIllustration(size: metrics.isNarrow ? 48 : 56)

            VStack(alignment: .leading, spacing: 5) {
                Text("What would you like to improve?")
                    .font(Theme.ui(metrics.isNarrow ? 17 : 21, .bold))
                    .tracking(Theme.Typography.titleTracking)
                    .foregroundStyle(Theme.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                Text("Describe the outcome in plain language. The agent will inspect your repository, stage focused edits, and show Approve / Decline controls.")
                    .font(Theme.ui(13.5))
                    .foregroundStyle(Theme.secondaryText)
                    .lineSpacing(3)
                    .frame(maxWidth: 660, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: Theme.Space.m)

            // Real project context only — nothing synthesized.
            if !metrics.isNarrow, let workspace = settings.activeWorkspace {
                VStack(alignment: .trailing, spacing: 5) {
                    Badge(text: workspace.techStack.rawValue,
                          systemImage: workspace.techStack.icon,
                          tint: Theme.tertiaryText,
                          surface: Theme.secondarySurface)
                    Badge(text: workspace.deployment.rawValue,
                          systemImage: "arrow.up.forward.square",
                          tint: Theme.tertiaryText,
                          surface: Theme.secondarySurface)
                }
                .fixedSize()
            }
        }
        .frame(minHeight: metrics.isNarrow ? 72 : 88, alignment: .center)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func smartTasksSection(metrics: AgentWorkspaceMetrics) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.m - 2) {
            HStack(spacing: 6) {
                Image(systemName: "sparkles")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Theme.violet)
                Text("Suggested improvements")
                    .font(Theme.ui(12, .semibold))
                    .foregroundStyle(Theme.secondaryText)
                Spacer(minLength: Theme.Space.s)
                Text("Click to start")
                    .font(Theme.ui(11))
                    .foregroundStyle(Theme.tertiaryText)
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
                    SmartTaskCard(
                        template: template,
                        metrics: metrics,
                        recommended: isRecommended(template)
                    ) {
                        engine.send(contextualPrompt(for: template))
                    }
                }
            }
        }
    }

    struct AgentTemplate: Identifiable {
        let title: String
        let subtitle: String
        let icon: String
        /// The category's semantic accent. Only the icon tile and the hover
        /// detail use it — the card itself stays neutral.
        let accent: Theme.Accent
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
            subtitle: "Improve loading speed, layout stability, and responsiveness.",
            icon: "gauge.with.dots.needle.67percent",
            accent: .amber,
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
            subtitle: "Review WCAG 2.2, keyboard access, focus, and motion.",
            icon: "accessibility",
            accent: .rose,
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
            subtitle: "Find exploitable risks and outdated dependencies.",
            icon: "checkmark.shield",
            accent: .green,
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
            subtitle: "Introduce tokens, layers, and reusable layout primitives.",
            icon: "paintbrush.pointed",
            accent: .violet,
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
            subtitle: "Add safe caching, prefetching, and resilient navigation states.",
            icon: "bolt.horizontal.circle",
            accent: .primary,
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
            subtitle: "Improve metadata, structured data, previews, and discovery.",
            icon: "magnifyingglass.circle",
            accent: .violet,
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
            subtitle: "Repair reflow, touch targets, and adaptive navigation.",
            icon: "rectangle.on.rectangle.angled",
            accent: .cyan,
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
            subtitle: "Clarify the primary journey and remove unnecessary friction.",
            icon: "point.topleft.down.to.point.bottomright.curvepath",
            accent: .rose,
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
            subtitle: "Add focused tests and safer pull-request checks.",
            icon: "checkmark.seal",
            accent: .green,
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
            subtitle: "Modernize formats, sizing, loading, and alternative text.",
            icon: "photo.on.rectangle.angled",
            accent: .cyan,
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
            subtitle: "Reduce tracking and make consent behavior transparent.",
            icon: "hand.raised",
            accent: .amber,
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
            subtitle: "Improve clarity, structure, scannability, and trust.",
            icon: "text.redaction",
            accent: .neutral,
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
            subtitle: "Handle weak connections, failed requests, and recovery.",
            icon: "wifi.exclamationmark",
            accent: .teal,
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
            promptHeader
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

            HStack(alignment: .bottom, spacing: Theme.Space.s) {
                HStack(alignment: .bottom, spacing: Theme.Space.s) {
                    ComposerAttachmentButton {
                        showAttachmentPicker = true
                    }
                    .disabled(engine.state.isActive || attachments.count >= Attachment.maximumCount)

                    TextField("Describe a change, issue, or goal…", text: $draft, axis: .vertical)
                        .textFieldStyle(.plain)
                        .font(Theme.ui(13.5))
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(1...6)
                        .focused($composerFocused)
                        .onSubmit { sendIfPossible() }
                        .padding(.vertical, 3)
                        .onChange(of: draft) { _, newValue in
                            if !newValue.isEmpty { composerFocusChrome = true }
                        }
                }
                .padding(.horizontal, Theme.Space.m + 2)
                .padding(.vertical, 7)
                .frame(minHeight: 40)
                .background(Theme.elevatedSurface,
                            in: RoundedRectangle(cornerRadius: Theme.Radius.composer, style: .continuous))
                .activityBorder(active: engine.state.isActive, focused: composerShowsFocus)
                .cardElevation(raised: composerShowsFocus)
                .animation(Motion.smooth, value: composerShowsFocus)
                .onTapGesture {
                    composerFocusChrome = true
                    composerFocused = true
                }

                if engine.isRunActive {
                    Button {
                        engine.cancelGeneration()
                    } label: {
                        Label("Stop agent", systemImage: "stop.fill")
                            .font(.system(size: 12, weight: .bold))
                    }
                    .labelStyle(.iconOnly)
                    .buttonStyle(ComposerActionStyle(kind: .stop))
                    .help("Stop agent (⌘.)")
                } else {
                    Button {
                        sendIfPossible()
                    } label: {
                        Label("Send message", systemImage: "arrow.up")
                            .font(.system(size: 14, weight: .semibold))
                    }
                    .labelStyle(.iconOnly)
                    .buttonStyle(ComposerActionStyle(kind: canSend ? .send : .idle))
                    .disabled(!canSend)
                    .animation(Motion.smooth, value: canSend)
                    .help("Send message (⌘↩)")
                }
            }
            composerFooter
        }
        .padding(.horizontal, metrics.paddingX)
        .padding(.vertical, 10)
        .workspaceColumn(metrics)
    }

    private var canSend: Bool {
        (!draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !attachments.isEmpty)
            && !engine.isRunActive
    }

    private var promptHeader: some View {
        HStack(spacing: Theme.Space.s) {
            Label("Agent prompt", systemImage: "sparkles")
                .font(Theme.ui(10.5, .semibold))
                .foregroundStyle(Theme.textPrimary)
            Spacer()
            Label(settings.autoCommit ? "Auto-commit on" : "Review before commit",
                  systemImage: settings.autoCommit ? "bolt.fill" : "checkmark.shield.fill")
                .font(Theme.ui(10.5, .medium))
                .foregroundStyle(settings.autoCommit ? Theme.warning : Theme.success)
            Text("⌘↩")
                .font(.system(.caption2, design: .monospaced).weight(.semibold))
                .foregroundStyle(Theme.tertiaryText)
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(Theme.secondarySurface, in: Capsule())
        }
        .accessibilityElement(children: .combine)
    }

    private var composerFooter: some View {
        HStack(spacing: 5) {
            if let workspace = settings.activeWorkspace {
                Text(workspace.name)
                Text("·")
                Text(workspace.gitBranch)
            }
            if engine.sessionCostUSD > 0 {
                Text("·")
                Text("\(AgentCostFormatter.string(engine.sessionCostUSD)) session")
                if engine.lastTurnCostUSD > 0 {
                    Text("·")
                    Text("\(AgentCostFormatter.string(engine.lastTurnCostUSD)) turn")
                }
            }
            Spacer()
        }
        .font(Theme.ui(10.5))
        .foregroundStyle(Theme.tertiaryText)
        .accessibilityElement(children: .combine)
    }

    private func sendIfPossible() {
        guard canSend else { return }
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "Review the attached file\(attachments.count == 1 ? "" : "s")."
            : draft
        let outgoingAttachments = attachments
        UserDefaults.standard.removeObject(forKey: draftStorageKey(for: draftWorkspaceID))
        draft = ""
        attachments = []
        attachmentError = nil
        engine.send(text, attachments: outgoingAttachments)
    }

    private var currentDraftWorkspaceID: UUID? {
        settings.activeWorkspace?.id
    }

    private func draftStorageKey(for workspaceID: UUID?) -> String {
        "agent.composerDraft.\(workspaceID?.uuidString ?? "unassigned")"
    }

    private func restoreDraft() {
        let workspaceID = currentDraftWorkspaceID
        draftWorkspaceID = workspaceID
        draft = UserDefaults.standard.string(forKey: draftStorageKey(for: workspaceID)) ?? ""
    }

    private func attachmentChip(_ attachment: Attachment) -> some View {
        HStack(spacing: 6) {
            Image(systemName: attachment.isImage ? "photo" : "doc.text")
                .foregroundStyle(Theme.secondaryText)
            VStack(alignment: .leading, spacing: 1) {
                Text(attachment.filename)
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                Text(attachment.byteLabel)
                    .font(.caption2)
                    .foregroundStyle(Theme.tertiaryText)
            }
            Button {
                attachments.removeAll { $0.id == attachment.id }
            } label: {
                Label("Remove \(attachment.filename)", systemImage: "xmark")
                    .foregroundStyle(Theme.secondaryText)
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.plain)
        }
        .font(.callout)
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(Theme.elevatedSurface, in: RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous)
            .strokeBorder(Theme.borderSubtle))
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
            composerFocusChrome = true
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

// MARK: - Composer controls

/// The composer's attachment affordance: neutral at rest, violet while hovered
/// or focused, with a visible focus ring of its own.
private struct ComposerAttachmentButton: View {
    let action: () -> Void

    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Label("Attach files", systemImage: "paperclip")
                .labelStyle(.iconOnly)
                .font(.system(size: 14, weight: .medium))
                .frame(width: 30, height: 30)
        }
        .buttonStyle(AttachmentStyle(isHovering: isHovering && isEnabled))
        .onHover { hovering in
            withAnimation(Theme.Chrome.Timing.hover) { isHovering = hovering }
        }
        .help("Attach images or text files")
    }

    private struct AttachmentStyle: ButtonStyle {
        let isHovering: Bool

        func makeBody(configuration: Configuration) -> some View {
            Surface(configuration: configuration, isHovering: isHovering)
        }

        private struct Surface: View {
            let configuration: Configuration
            let isHovering: Bool

            @Environment(\.isEnabled) private var isEnabled
            @Environment(\.isFocused) private var isFocused

            private var shape: RoundedRectangle {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
            }

            var body: some View {
                configuration.label
                    .foregroundStyle(active ? Theme.violet : Theme.tertiaryText)
                    .background(shape.fill(active ? Theme.violetSoft : Color.clear))
                    .overlay {
                        shape.inset(by: -2)
                            .strokeBorder(Theme.focusRing.opacity(isFocused ? 0.9 : 0), lineWidth: 2)
                    }
                    .contentShape(shape)
                    .opacity(isEnabled ? 1 : 0.45)
            }

            private var active: Bool {
                isEnabled && (isHovering || configuration.isPressed || isFocused)
            }
        }
    }
}

/// The composer's trailing action. One footprint, three states: an inert
/// neutral circle while there is nothing to send, a primary circle once there
/// is, and a restrained amber Stop while the agent is running.
private struct ComposerActionStyle: ButtonStyle {
    enum Kind { case idle, send, stop }

    let kind: Kind

    func makeBody(configuration: Configuration) -> some View {
        Surface(configuration: configuration, kind: kind)
    }

    private struct Surface: View {
        let configuration: Configuration
        let kind: Kind

        @Environment(\.isEnabled) private var isEnabled
        @Environment(\.isFocused) private var isFocused
        @Environment(\.accessibilityReduceMotion) private var reduceMotion
        @State private var isHovering = false

        var body: some View {
            configuration.label
                .foregroundStyle(foreground)
                .frame(width: 34, height: 34)
                .background(Circle().fill(fill))
                .overlay {
                    if kind == .stop {
                        Circle().strokeBorder(Theme.warning.opacity(0.28), lineWidth: 1)
                    }
                }
                .overlay {
                    Circle()
                        .inset(by: -3)
                        .strokeBorder(Theme.focusRing.opacity(isFocused ? 0.9 : 0), lineWidth: 2)
                }
                .contentShape(Circle())
                .scaleEffect(configuration.isPressed && !reduceMotion ? 0.97 : 1)
                .animation(Theme.Chrome.Timing.press, value: configuration.isPressed)
                .animation(Theme.Chrome.Timing.hover, value: isHovering)
                .onHover { isHovering = $0 }
        }

        private var foreground: Color {
            switch kind {
            case .idle: return Theme.disabledText
            case .send: return Theme.textInverse
            case .stop: return Theme.warning
            }
        }

        private var fill: Color {
            switch kind {
            case .idle:
                return Theme.secondarySurface
            case .send:
                if configuration.isPressed { return Theme.accentPressed }
                return isHovering && isEnabled ? Theme.accentHover : Theme.accent
            case .stop:
                return Theme.warning.opacity(configuration.isPressed ? 0.24
                                             : (isHovering ? 0.18 : 0.12))
            }
        }
    }
}

// MARK: - Smart task card

/// One suggestion in the Smart Tasks grid.
///
/// Every card is the same neutral elevated surface; the category's accent
/// appears only in the icon tile (and, a shade stronger, while hovered). One
/// component owns the card's default, hover, pressed, focused, and recommended
/// states so the grid cannot drift into thirteen variants.
struct SmartTaskCard: View {
    let template: ChatView.AgentTemplate
    let metrics: AgentWorkspaceMetrics
    let recommended: Bool
    let action: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: Theme.Space.s) {
                iconTile
                VStack(alignment: .leading, spacing: 3) {
                    Text(LocalizedStringKey(template.title))
                        .font(Theme.ui(13, .semibold))
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(1)
                    Text(LocalizedStringKey(template.subtitle))
                        .font(Theme.ui(11.5))
                        .foregroundStyle(Theme.secondaryText)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                Spacer(minLength: Theme.Space.xs)
                if recommended { RecommendedBadge() }
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Theme.tertiaryText)
            }
            .padding(.horizontal, Theme.Space.m)
            .padding(.vertical, Theme.Space.s)
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .frame(minHeight: metrics.taskCardMinHeight, alignment: .topLeading)
        }
        .buttonStyle(SmartTaskCardStyle(isHovering: isHovering))
        .onHover { hovering in
            withAnimation(reduceMotion ? nil : Theme.Chrome.Timing.elevation) {
                isHovering = hovering
            }
        }
        .accessibilityLabel("Starter task: \(template.title)")
        .accessibilityHint("\(template.subtitle). Fills the message field for editing.")
    }

    private var iconTile: some View {
        Image(systemName: template.icon)
            .font(.system(size: 12.5, weight: .semibold))
            .foregroundStyle(template.accent.color)
            .frame(width: 28, height: 28)
            .background(
                isHovering ? AnyShapeStyle(template.accent.color.opacity(0.16))
                           : AnyShapeStyle(template.accent.soft),
                in: RoundedRectangle(cornerRadius: 8, style: .continuous)
            )
    }
}

/// The one Recommended treatment: a small amber chip, sized to sit beside a
/// card title without competing with it.
private struct RecommendedBadge: View {
    var body: some View {
        Text("Recommended")
            .font(Theme.ui(10.5, .semibold))
            .foregroundStyle(Theme.amberText)
            .padding(.horizontal, 6)
            .padding(.vertical, 2.5)
            .background(Theme.amberSoft, in: Capsule())
            .overlay(Capsule().strokeBorder(Theme.amberBorder, lineWidth: 1))
    }
}

/// The row's surface: tonal separation at rest, a quiet hover state, and a
/// restrained focus indicator. Suggestions are not elevated cards.
private struct SmartTaskCardStyle: ButtonStyle {
    let isHovering: Bool

    func makeBody(configuration: Configuration) -> some View {
        Surface(configuration: configuration, isHovering: isHovering)
    }

    private struct Surface: View {
        let configuration: Configuration
        let isHovering: Bool

        @Environment(\.isEnabled) private var isEnabled
        @Environment(\.isFocused) private var isFocused
        @Environment(\.accessibilityReduceMotion) private var reduceMotion

        private var shape: RoundedRectangle {
            RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
        }

        var body: some View {
            configuration.label
                .background(configuration.isPressed
                            ? AnyShapeStyle(Theme.surfacePressed)
                            : AnyShapeStyle(isHovering ? Theme.surfaceHover : Theme.standardSurface),
                            in: shape)
                .overlay {
                    shape.inset(by: -3)
                        .strokeBorder(Theme.focusRing.opacity(isFocused ? 0.9 : 0), lineWidth: 2)
                }
                .contentShape(shape)
                .opacity(isEnabled ? 1 : 0.5)
                .animation(reduceMotion ? nil : Theme.Chrome.Timing.press,
                           value: configuration.isPressed)
        }
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
                    .foregroundStyle(Theme.violet)
                Text("Agent activity")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Theme.textPrimary)
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
                .background(Theme.standardPanelGradient,
                            in: RoundedRectangle(cornerRadius: Theme.Radius.medium, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: Theme.Radius.medium, style: .continuous)
                .strokeBorder(Theme.borderSubtle)
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
    @State private var userPinned = false

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
                    userPinned = expanded
                } else {
                    withAnimation(Motion.snappy) { expanded.toggle() }
                    userPinned = expanded
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "brain")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Theme.violet)
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
                .fill(Theme.secondarySurface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous)
                .strokeBorder(
                    streaming ? Theme.violet.opacity(0.28) : Theme.borderSubtle,
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
            if !userPinned {
                if reduceMotion { expanded = false }
                else { withAnimation(Motion.snappy) { expanded = false } }
            }
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
                .foregroundStyle(isUser ? Theme.textInverse : Theme.textPrimary)
            }
        }
    }

    private var background: AnyShapeStyle {
        isUser ? AnyShapeStyle(Theme.accent) : AnyShapeStyle(Theme.cardFill)
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
                .background(Theme.secondarySurface, in: Capsule())
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
    var body: some View {
        HStack(spacing: Theme.Space.s) {
            AgentActivityGlyph(state: .thinking, size: 20)
            Text("Agent is thinking…")
                .font(Theme.ui(12.5, .medium))
                .foregroundStyle(Theme.secondaryText)
        }
        .padding(.horizontal, Theme.Space.m)
        .padding(.vertical, Theme.Space.s)
        .background(Theme.cardFill, in: RoundedRectangle(cornerRadius: Theme.Radius.medium))
        .wcAppear()
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
                .font(Theme.ui(13, .medium))
                .foregroundStyle(Theme.textPrimary)
                .contentTransition(.numericText())
            changeSummary
            Spacer()
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(Array(engine.pendingChanges.enumerated()), id: \.element.id) { idx, change in
                        Button { reviewingChange = change } label: {
                            HStack(spacing: 4) {
                                Image(systemName: change.category.icon).font(.caption2)
                                Text(change.path).font(.caption).lineLimit(1)
                            }
                            .foregroundStyle(Theme.secondaryText)
                            .padding(.horizontal, 8).padding(.vertical, 4)
                            .background(Theme.elevatedSurface, in: Capsule())
                            .overlay(Capsule().strokeBorder(Theme.borderSubtle))
                        }
                        .buttonStyle(.plain)
                        .wcAppear(delay: Double(idx) * 0.03)
                    }
                }
            }
            .frame(maxWidth: 360)
            Button("Decline All") { engine.discardAll() }
                .buttonStyle(.destructiveText)
            Button("Approve All") { Task { await engine.approveAll() } }
                .buttonStyle(.primary)
        }
        .padding(.horizontal, Theme.Space.l)
        .padding(.vertical, Theme.Space.m)
        .background(Theme.amberSoft)
    }

    private var changeSummary: some View {
        let textChanges = engine.pendingChanges.filter { !$0.isBinary }
        let added = textChanges.reduce(0) { $0 + $1.addedLines }
        let removed = textChanges.reduce(0) { $0 + $1.removedLines }
        let binaryChanges = engine.pendingChanges.compactMap { $0.binaryContent }
        let binaryBytes = binaryChanges.reduce(Int64(0)) { $0 + $1.byteCount }
        let risks = engine.pendingChanges.reduce(0) { $0 + $1.risks.count }
        return HStack(spacing: 4) {
            if !textChanges.isEmpty {
                Text("+\(added)").foregroundStyle(Theme.success)
                Text("−\(removed)").foregroundStyle(Theme.danger)
            }
            if !binaryChanges.isEmpty {
                Label("\(binaryChanges.count) asset\(binaryChanges.count == 1 ? "" : "s") · \(ByteCountFormatter.string(fromByteCount: binaryBytes, countStyle: .file))",
                      systemImage: "photo")
                    .foregroundStyle(Theme.teal)
            }
            if risks > 0 {
                Label("\(risks)", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(Theme.warning)
            }
        }
        .font(Theme.ui(10.5, .semibold))
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(Theme.elevatedSurface.opacity(0.75), in: Capsule())
        .accessibilityLabel("\(added) lines added, \(removed) removed, \(binaryChanges.count) binary assets, \(risks) risk findings")
    }
}
