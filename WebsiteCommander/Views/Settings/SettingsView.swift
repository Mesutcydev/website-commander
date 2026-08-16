import SwiftUI
import AppKit

// MARK: - Window metrics

/// One place owns the Settings window's geometry. Both the width and the
/// page height are fixed: a preferences window is a form, not a canvas, and
/// an even page size means switching tabs never resizes the window under the
/// user's pointer. Pages whose content exceeds the fixed height scroll.
enum SettingsMetrics {
    static let width: CGFloat = 620
    /// Every page is exactly this tall, so tab-to-tab the window chrome stays
    /// put. Chosen to fit the largest page (Provider) without scrolling on a
    /// first run, and to leave short pages (About) breathing room.
    static let pageHeight: CGFloat = 560
    static let tabItemWidth: CGFloat = 84
    static let pageInsets = EdgeInsets(top: Theme.Space.l, leading: Theme.Space.xl,
                                       bottom: Theme.Space.xl, trailing: Theme.Space.xl)
}

// MARK: - Pages

enum SettingsTab: String, CaseIterable, Identifiable {
    case github, provider, behavior, onDevice, about

    var id: String { rawValue }

    var title: String {
        switch self {
        case .github:   return "GitHub"
        case .provider: return "AI Provider"
        case .behavior: return "Behavior"
        case .onDevice: return "On-Device"
        case .about:    return "About"
        }
    }

    /// One glyph per page, all from the same optical weight so the strip reads
    /// as a set. The two AI pages deliberately differ (the provider is a remote
    /// service; on-device is this Mac's own silicon).
    var icon: String {
        switch self {
        case .github:   return "person.badge.key.fill"
        case .provider: return "sparkles"
        case .behavior: return "slider.horizontal.3"
        case .onDevice: return "cpu"
        case .about:    return "info.circle"
        }
    }
}

/// The Settings window: five pages — GitHub auth, AI provider & keys, behavior
/// toggles, on-device inference, and about — sharing one chrome.
struct SettingsView: View {

    @EnvironmentObject var settings: SettingsStore
    @EnvironmentObject var engine: AgentEngine
    @EnvironmentObject var updater: UpdateChecker
    @EnvironmentObject var bridge: LocalBridge
    @EnvironmentObject var cloudSync: CloudSyncService

    @State private var tab: SettingsTab = .github

    var body: some View {
        VStack(spacing: 0) {
            SettingsTabStrip(selection: $tab)
            page
        }
        .frame(width: SettingsMetrics.width)
        .background(Theme.canvas)
        .navigationTitle(LocalizedStringKey(tab.title))
        // Re-publish every object the pages need. macOS Settings hosts its
        // content in a way that has dropped `UpdateChecker` before
        // (EXC_BREAKPOINT in AboutSettingsTab), which relaunches the app onto
        // the homepage.
        .environmentObject(settings)
        .environmentObject(engine)
        .environmentObject(updater)
        .environmentObject(bridge)
        .environmentObject(cloudSync)
        .task {
            // Opening Settings is a user-initiated moment; refreshing the
            // readiness metadata here (rather than at launch) keeps the launch
            // path free of Keychain access-control prompts.
            settings.refreshPairedProviders()
            settings.refreshReadiness()
        }
    }

    @ViewBuilder private var page: some View {
        switch tab {
        case .github:   GitHubSettingsTab()
        case .provider: ProviderSettingsTab()
        case .behavior: BehaviorSettingsTab()
        case .onDevice: OnDeviceSettingsTab()
        case .about:    AboutSettingsTab()
        }
    }
}

// MARK: - Tab strip

/// The page switcher. Every item is the same width with the same glyph size and
/// label weight, the selected one wears the app's soft indigo, and an unselected
/// item stays legible secondary text rather than looking disabled.
private struct SettingsTabStrip: View {
    @Binding var selection: SettingsTab

    var body: some View {
        HStack(spacing: Theme.Space.xs) {
            ForEach(SettingsTab.allCases) { tab in
                Button { selection = tab } label: {
                    VStack(spacing: 5) {
                        Image(systemName: tab.icon)
                            .font(.system(size: 15, weight: .medium))
                            .frame(height: 17)
                        Text(LocalizedStringKey(tab.title))
                            .font(Theme.ui(11, .semibold))
                            .lineLimit(1)
                    }
                }
                .buttonStyle(SettingsTabButtonStyle(isSelected: selection == tab))
                .accessibilityAddTraits(selection == tab ? [.isSelected] : [])
            }
        }
        .padding(.horizontal, Theme.Space.m)
        .padding(.vertical, Theme.Space.s + 2)
        .frame(maxWidth: .infinity)
        .background(Theme.chromeSurface)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Theme.divider).frame(height: 1)
        }
    }
}

private struct SettingsTabButtonStyle: ButtonStyle {
    let isSelected: Bool

    func makeBody(configuration: Configuration) -> some View {
        Surface(configuration: configuration, isSelected: isSelected)
    }

    private struct Surface: View {
        let configuration: Configuration
        let isSelected: Bool

        @Environment(\.isFocused) private var isFocused
        @Environment(\.accessibilityReduceMotion) private var reduceMotion
        @State private var isHovering = false

        private let shape = RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous)

        var body: some View {
            configuration.label
                .foregroundStyle(isSelected ? Theme.accent : Theme.secondaryText)
                .frame(width: SettingsMetrics.tabItemWidth)
                .padding(.vertical, Theme.Space.s - 1)
                .background(fill, in: shape)
                .overlay {
                    shape.strokeBorder(isSelected ? Theme.accentBorder : .clear, lineWidth: 1)
                }
                .focusRing(isFocused, cornerRadius: Theme.Radius.small)
                .contentShape(shape)
                .scaleEffect(configuration.isPressed && !reduceMotion ? 0.97 : 1)
                .animation(Theme.Chrome.Timing.press, value: configuration.isPressed)
                .animation(Theme.Chrome.Timing.selection, value: isSelected)
                .animation(Theme.Chrome.Timing.hover, value: isHovering)
                .onHover { isHovering = $0 }
        }

        private var fill: Color {
            if isSelected { return Theme.accentSoft }
            if configuration.isPressed { return Theme.Chrome.controlPressed }
            return isHovering ? Theme.Chrome.controlFill : .clear
        }
    }
}

// MARK: - Page scaffold

/// A settings page: one top-aligned content column inside a fixed-height
/// scroll region. The height is owned by `SettingsMetrics.pageHeight`, so the
/// window never resizes when the user moves between tabs — every page is the
/// same size and only the content changes. Pages taller than the fixed height
/// scroll; shorter pages simply leave breathing room at the bottom.
struct SettingsPage<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: Theme.Space.l) {
                content
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(SettingsMetrics.pageInsets)
        }
        .scrollBounceBehavior(.basedOnSize)
        .frame(height: SettingsMetrics.pageHeight)
    }
}

/// A titled group: a section heading with an optional count badge, one card of
/// rows, and optional explanatory text underneath the card.
struct SettingsSection<Content: View>: View {
    let title: String
    var count: Int? = nil
    var footnote: String? = nil
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            SectionHeader(title: title) {
                if let count { Badge(text: "\(count)") }
            }
            VStack(alignment: .leading, spacing: Theme.Space.m) {
                content
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .commandCard()
            if let footnote {
                Text(LocalizedStringKey(footnote))
                    .font(Theme.ui(11))
                    .foregroundStyle(Theme.tertiaryText)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 2)
            }
        }
    }
}

/// The hairline between rows inside a section card.
struct SettingsRowDivider: View {
    var body: some View {
        Rectangle().fill(Theme.divider).frame(height: 1)
    }
}

/// A switch row: title, optional explanation, and the control on the trailing
/// edge so a column of them aligns.
struct SettingsToggleRow: View {
    let title: String
    var detail: String? = nil
    @Binding var isOn: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: Theme.Space.m) {
                Text(LocalizedStringKey(title))
                    .font(Theme.ui(13))
                    .foregroundStyle(Theme.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: Theme.Space.m)
                Toggle("", isOn: $isOn)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .accessibilityLabel(LocalizedStringKey(title))
            }
            if let detail {
                Text(LocalizedStringKey(detail))
                    .font(Theme.ui(11))
                    .foregroundStyle(Theme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// A single line of state ("Signed in to iCloud", "Listening on 127.0.0.1…").
/// The glyph carries the same tint as the text so the line reads as one object.
/// `verbatim` is for runtime values and error messages, which must not be run
/// through the string catalog.
struct SettingsStatusLine: View {
    private let content: Text
    let systemImage: String
    var tint: Color = Theme.secondaryText

    init(_ text: String, systemImage: String, tint: Color = Theme.secondaryText) {
        self.content = Text(LocalizedStringKey(text))
        self.systemImage = systemImage
        self.tint = tint
    }

    init(verbatim text: String, systemImage: String, tint: Color = Theme.secondaryText) {
        self.content = Text(verbatim: text)
        self.systemImage = systemImage
        self.tint = tint
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: systemImage)
                .font(.system(size: 11, weight: .semibold))
            content
                .font(Theme.ui(11, .semibold))
                .fixedSize(horizontal: false, vertical: true)
        }
        .foregroundStyle(tint)
    }
}

/// Body copy inside a card — an explanation that belongs to the rows above it,
/// optionally led by a glyph. `verbatim` is for values (paths, URLs) that must
/// not be run through the string catalog or auto-linkified.
struct SettingsNote: View {
    private let content: Text
    var systemImage: String? = nil
    var tint: Color = Theme.secondaryText

    init(_ text: String, systemImage: String? = nil) {
        self.content = Text(LocalizedStringKey(text))
        self.systemImage = systemImage
    }

    init(verbatim text: String, tint: Color = Theme.tertiaryText) {
        self.content = Text(verbatim: text)
        self.tint = tint
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            if let systemImage {
                Image(systemName: systemImage)
                    .font(.system(size: 11, weight: .semibold))
            }
            content
                .font(Theme.ui(11))
                .fixedSize(horizontal: false, vertical: true)
        }
        .foregroundStyle(tint)
    }
}

// MARK: - GitHub tab

struct GitHubSettingsTab: View {
    @EnvironmentObject var settings: SettingsStore
    @State private var newLabel = ""
    @State private var newToken = ""
    @State private var status: String?
    @State private var statusOK = false
    @State private var verifying = false
    @FocusState private var focus: Field?

    private enum Field { case label, token }

    private var hasDefault: Bool { settings.hasDefaultGitHubToken }

    private var canVerify: Bool {
        !newToken.trimmingCharacters(in: .whitespaces).isEmpty && !verifying
    }

    var body: some View {
        SettingsPage {
            accountsSection
            addAccountSection
        }
    }

    // MARK: Accounts

    private var accountsSection: some View {
        SettingsSection(
            title: "Accounts",
            count: settings.accountOptions.count,
            footnote: "Each site uses one account. Add as many as you need — e.g. one for work, one for personal repos. Tokens are stored only in the macOS Keychain."
        ) {
            if rows.isEmpty {
                SettingsNote("No GitHub accounts yet. Add one below to connect your sites.")
            } else {
                ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                    if index > 0 { SettingsRowDivider() }
                    accountRow(row)
                }
            }
        }
    }

    /// The account list, flattened so the default token and the named accounts
    /// render through one row treatment.
    private var rows: [AccountRow] {
        var result: [AccountRow] = []
        if hasDefault {
            result.append(AccountRow(
                id: "default",
                title: "Default account",
                subtitle: "Used by sites with no specific account",
                statusLabel: "Stored token is valid",
                tint: Theme.accent,
                removeLabel: "Clear",
                remove: {
                    settings.setGitHubToken("")
                    status = "Default token removed."
                    statusOK = true
                }))
        }
        for account in settings.githubAccounts {
            let hasToken = settings.hasGitHubToken(forCredential: account.id)
            result.append(AccountRow(
                id: account.id.uuidString,
                title: account.displayName,
                subtitle: hasToken ? "Personal access token stored" : "Token missing",
                statusLabel: hasToken ? "Stored token is valid" : "No token stored for this account",
                tint: hasToken ? Theme.success : Theme.warning,
                removeLabel: "Remove",
                remove: {
                    settings.removeGitHubAccount(account.id)
                    status = "Removed \(account.displayName)."
                    statusOK = true
                }))
        }
        return result
    }

    private struct AccountRow: Identifiable {
        let id: String
        let title: String
        let subtitle: String
        /// What the status dot means, for anyone who can't read the colour.
        let statusLabel: String
        let tint: Color
        let removeLabel: String
        let remove: () -> Void
    }

    private func accountRow(_ row: AccountRow) -> some View {
        HStack(spacing: Theme.Space.m) {
            IconTile(systemImage: "person.crop.circle.fill", accent: .neutral, size: 32)
            VStack(alignment: .leading, spacing: 2) {
                // A GitHub login is a value, not copy: never localised.
                Text(verbatim: row.title)
                    .font(Theme.ui(13, .semibold))
                    .foregroundStyle(Theme.textPrimary)
                Text(LocalizedStringKey(row.subtitle))
                    .font(Theme.ui(11))
                    .foregroundStyle(Theme.secondaryText)
            }
            Spacer(minLength: Theme.Space.m)
            StatusDot(color: row.tint, label: row.statusLabel)
            Button(LocalizedStringKey(row.removeLabel), action: row.remove)
                .buttonStyle(.destructiveText)
                .accessibilityLabel("\(row.removeLabel) \(row.title)")
        }
    }

    // MARK: Add account

    private var addAccountSection: some View {
        SettingsSection(title: "Add Account") {
            FormRow(label: "Label",
                    help: HelpButton(title: "Account label",
                                     message: "A name you'll recognise in the account picker — e.g. Work or Personal. Leave it blank and the GitHub username the token belongs to is used instead.")) {
                TextField("e.g. Work", text: $newLabel)
                    .focused($focus, equals: .label)
                    .fieldChrome(focused: focus == .label)
            }
            FormRow(label: "Personal access token",
                    footnote: "ghp_… or github_pat_…") {
                SecureField("Paste your token", text: $newToken)
                    .focused($focus, equals: .token)
                    .fieldChrome(focused: focus == .token)
            }
            SettingsRowDivider()
            HStack(spacing: Theme.Space.s) {
                Button {
                    Task { await verifyAndAdd() }
                } label: {
                    Label("Verify & Add", systemImage: "person.badge.plus")
                        // The label keeps its width while verifying, so the
                        // button doesn't collapse to a spinner and back.
                        .opacity(verifying ? 0 : 1)
                        .overlay { if verifying { ProgressView().controlSize(.small) } }
                }
                .buttonStyle(.primary)
                .disabled(!canVerify)
                HelpButton(title: "Creating a GitHub token",
                           message: "Generate a classic Personal Access Token with the `repo` scope so the agent can read and write your repositories. We verify it (and fetch your username) before storing it in the Keychain.",
                           links: [("github.com/settings/tokens", "https://github.com/settings/tokens")])
                Spacer(minLength: 0)
            }
            if let status {
                SettingsStatusLine(verbatim: status,
                                   systemImage: statusOK ? "checkmark.circle.fill" : "xmark.circle.fill",
                                   tint: statusOK ? Theme.success : Theme.danger)
            }
        }
    }

    private func verifyAndAdd() async {
        verifying = true
        status = nil
        defer { verifying = false }
        let trimmed = newToken.trimmingCharacters(in: .whitespaces)
        do {
            let info = try await GitHubClient(token: trimmed).accountInfo()
            let label = newLabel.trimmingCharacters(in: .whitespaces).isEmpty ? info.login : newLabel.trimmingCharacters(in: .whitespaces)
            settings.addGitHubAccount(label: label, token: trimmed, login: info.login)
            newToken = ""
            newLabel = ""
            switch scopeVerdict(info.scopes) {
            case .full:
                status = "Added \(info.login) — full repo access."
                statusOK = true
            case .unknown:
                status = "Added \(info.login). Scopes not readable (fine-grained token?) — write access will be confirmed per site."
                statusOK = true
            case .noPush:
                status = "Added \(info.login), but this token can't push (no `repo` scope). The agent won't be able to commit — add a token with `repo`."
                statusOK = false
            }
        } catch {
            status = error.localizedDescription
            statusOK = false
        }
    }

    private enum ScopeVerdict { case full, unknown, noPush }
    private func scopeVerdict(_ scopes: [String]) -> ScopeVerdict {
        if scopes.isEmpty { return .unknown }            // fine-grained PAT
        return scopes.contains("repo") ? .full : .noPush  // classic PAT
    }
}

// MARK: - Provider tab

struct ProviderSettingsTab: View {
    @EnvironmentObject var settings: SettingsStore
    @State private var key = ""
    @FocusState private var focus: Field?

    private enum Field { case baseURL, customModel, apiKey }

    private var info: ProviderInfo? { ProviderRegistry.info(for: settings.providerID) }

    private var onDeviceAvailable: Bool {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) { return OnDeviceProvider.isAvailable }
        #endif
        return false
    }

    private var onDeviceStatus: String {
        onDeviceAvailable ? "Apple Intelligence is available on this Mac."
                          : "Apple Intelligence isn't available (requires macOS 26 + Apple Intelligence)."
    }

    var body: some View {
        SettingsPage {
            SettingsSection(title: "Provider") {
                // Flexible columns, not `.adaptive`: the settings window has a
                // fixed width, and adaptive chips would sit at their minimum
                // size with dead space trailing every row.
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(minimum: 0),
                                                            spacing: Theme.Space.s),
                                         count: 3),
                          alignment: .leading,
                          spacing: Theme.Space.s) {
                    ForEach(ProviderRegistry.catalog) { provider in
                        ProviderChip(provider: provider, isSelected: provider.id == settings.providerID) {
                            settings.providerID = provider.id
                            settings.model = ""
                            key = settings.apiKey(for: provider.id) ?? ""
                        }
                    }
                }
            }

            if settings.providerID == "custom" {
                SettingsSection(title: "Custom Endpoint") {
                    FormRow(label: "Base URL") {
                        TextField("https://…/v1", text: $settings.customBaseURL)
                            .focused($focus, equals: .baseURL)
                            .fieldChrome(focused: focus == .baseURL)
                    }
                    FormRow(label: "Model name") {
                        TextField("", text: $settings.customModel)
                            .focused($focus, equals: .customModel)
                            .fieldChrome(focused: focus == .customModel)
                    }
                }
            }

            SettingsSection(title: "Model") {
                FormRow(label: "Model") {
                    Picker("", selection: $settings.model) {
                        Text("Default (\(defaultModelLabel))").tag("")
                        ForEach(modelList, id: \.self) { model in
                            Text(info?.modelLabel(model) ?? model).tag(model)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .font(Theme.ui(13))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityLabel("Model")
                }
            }

            if showsEffortSection {
                SettingsSection(
                    title: "Effort",
                    footnote: "Only models that support a reasoning control honor this. Lower effort answers faster and cheaper; higher effort thinks longer before replying."
                ) {
                    FormRow(label: "Reasoning effort",
                            footnote: settings.reasoningEffort.summary) {
                        WCInlineSegmentedControl(
                            selection: $settings.reasoningEffort,
                            items: Array(ReasoningEffort.allCases),
                            accessibilityLabel: "Reasoning effort"
                        ) { effort in
                            Text(effort.label)
                        }
                    }
                }
            }

            if settings.providerID == "ondevice" {
                SettingsSection(title: "On-Device AI") {
                    SettingsStatusLine(onDeviceStatus,
                                       systemImage: onDeviceAvailable ? "checkmark.circle.fill" : "exclamationmark.triangle.fill",
                                       tint: onDeviceAvailable ? Theme.success : Theme.warning)
                    SettingsNote("Runs fully offline using Apple Intelligence. No API key required.")
                }
            } else {
                SettingsSection(title: "API Key",
                                footnote: "Stored only in the macOS Keychain. Direct API calls — no proxy servers.") {
                    FormRow(label: info?.keyLabel ?? "API Key") {
                        SecureField("", text: $key)
                            .focused($focus, equals: .apiKey)
                            .fieldChrome(focused: focus == .apiKey)
                            .onAppear { key = settings.apiKey(for: settings.providerID) ?? "" }
                            .onChange(of: settings.providerID) { _, newID in
                                // Keep the field in sync when the provider is
                                // changed from the top-bar model control while
                                // this window is open, so "Save Key" cannot
                                // write one provider's key under another id.
                                key = settings.apiKey(for: newID) ?? ""
                            }
                    }
                    SettingsRowDivider()
                    HStack(spacing: Theme.Space.m) {
                        Button("Save Key") {
                            settings.setAPIKey(key.trimmingCharacters(in: .whitespaces), for: settings.providerID)
                        }
                        .buttonStyle(.primaryCompact)
                        if let url = info?.keySourceURL, !url.isEmpty {
                            Link(destination: URL(string: url)!) {
                                HStack(spacing: 4) {
                                    Text("Get a key")
                                    Image(systemName: "arrow.up.right").font(.system(size: 9, weight: .bold))
                                }
                                .font(Theme.ui(12, .semibold))
                                .foregroundStyle(Theme.accent)
                            }
                        }
                        Spacer(minLength: 0)
                    }
                }
            }

            SettingsSection(title: "Smart Routing") {
                SettingsToggleRow(title: "Auto-route to the best model",
                                  isOn: $settings.smartRouting)
                if settings.smartRouting {
                    SettingsRowDivider()
                    FormRow(label: "Strategy", footnote: settings.routingStrategy.detail) {
                        WCInlineSegmentedControl(
                            selection: $settings.routingStrategy,
                            items: Array(RoutingStrategy.allCases),
                            accessibilityLabel: "Strategy"
                        ) { strategy in
                            Text(strategy.rawValue)
                        }
                    }
                }
            }
        }
    }

    private var modelList: [String] {
        if settings.providerID == "custom" {
            return settings.customModel.isEmpty ? [] : [settings.customModel]
        }
        return info?.models ?? []
    }

    private var defaultModelLabel: String {
        guard let info else { return "auto" }
        return info.modelLabel(info.defaultModel)
    }

    /// The model the effort choice applies to: explicit selection, else the
    /// provider default (custom endpoints keep their typed model ID).
    private var effortEligibleModel: String {
        if settings.model.isEmpty {
            return settings.providerID == "custom" ? settings.customModel
                : (info?.defaultModel ?? "")
        }
        return settings.model
    }

    private var showsEffortSection: Bool {
        ReasoningEffortSupport.supports(providerID: settings.providerID,
                                        model: effortEligibleModel)
    }
}

/// A selectable visual provider chip.
private struct ProviderChip: View {
    let provider: ProviderInfo
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: Theme.Space.s) {
                Group {
                    if let mark = BrandMarkID.from(providerID: provider.id) {
                        BrandMark(id: mark)
                            .fill(isSelected ? Theme.textInverse : Theme.textPrimary)
                    } else {
                        Image(systemName: provider.icon)
                            .font(.system(size: 13, weight: .medium))
                    }
                }
                .frame(width: 16, height: 16)
                Text(provider.displayName)
                    .font(Theme.ui(12, .semibold))
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
        }
        .buttonStyle(ProviderChipStyle(isSelected: isSelected))
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }
}

private struct ProviderChipStyle: ButtonStyle {
    let isSelected: Bool

    func makeBody(configuration: Configuration) -> some View {
        Surface(configuration: configuration, isSelected: isSelected)
    }

    private struct Surface: View {
        let configuration: Configuration
        let isSelected: Bool

        @Environment(\.isFocused) private var isFocused
        @Environment(\.accessibilityReduceMotion) private var reduceMotion
        @State private var isHovering = false

        private let shape = RoundedRectangle(cornerRadius: Theme.Radius.medium, style: .continuous)

        var body: some View {
            configuration.label
                .foregroundStyle(isSelected ? Theme.textInverse : Theme.textPrimary)
                .padding(.horizontal, Theme.Space.m)
                .padding(.vertical, Theme.Space.s)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(fill, in: shape)
                .overlay {
                    shape.strokeBorder(isSelected ? .clear : Theme.borderSubtle, lineWidth: 1)
                }
                .focusRing(isFocused, cornerRadius: Theme.Radius.medium)
                .contentShape(shape)
                .scaleEffect(configuration.isPressed && !reduceMotion ? 0.98 : 1)
                .animation(Theme.Chrome.Timing.press, value: configuration.isPressed)
                .animation(Theme.Chrome.Timing.selection, value: isSelected)
                .animation(Theme.Chrome.Timing.hover, value: isHovering)
                .onHover { isHovering = $0 }
        }

        private var fill: Color {
            if isSelected {
                if configuration.isPressed { return Theme.accentPressed }
                return isHovering ? Theme.accentHover : Theme.accent
            }
            if configuration.isPressed { return Theme.Chrome.controlPressed }
            return isHovering ? Theme.tertiarySurface : Theme.secondarySurface
        }
    }
}

// MARK: - Behavior tab

struct BehaviorSettingsTab: View {
    @EnvironmentObject var settings: SettingsStore
    @EnvironmentObject var cloudSync: CloudSyncService
    @EnvironmentObject var bridge: LocalBridge
    @FocusState private var portFocused: Bool

    var body: some View {
        SettingsPage {
            SettingsSection(title: "Agent") {
                SettingsToggleRow(
                    title: "Auto-commit (skip the approval step)",
                    detail: "When on, approved edits commit immediately without a diff review. Recommended off.",
                    isOn: $settings.autoCommit)
                SettingsRowDivider()
                FormRow(label: "Spend warning",
                        footnote: "Pauses the run for review; it never discards staged work.") {
                    HStack(spacing: 4) {
                        Text("$")
                            .font(Theme.ui(13))
                            .foregroundStyle(Theme.secondaryText)
                        TextField("", value: $settings.spendWarningUSD,
                                  format: .number.precision(.fractionLength(2)))
                            .frame(width: 70)
                            .textFieldStyle(.roundedBorder)
                            .accessibilityLabel("Per-turn spend warning in dollars")
                    }
                }
            }

            SettingsSection(title: "Appearance") {
                FormRow(label: "Appearance", footnote: appearanceDetail) {
                    WCInlineSegmentedControl(
                        selection: $settings.themeMode,
                        items: Array(ThemeMode.allCases),
                        accessibilityLabel: "Appearance"
                    ) { mode in
                        Label(mode.rawValue, systemImage: mode.icon)
                    }
                }
            }

            SettingsSection(title: "Sounds",
                            footnote: "Short system sounds play when an agent task finishes or needs attention.") {
                SettingsToggleRow(title: "Play notification sounds",
                                  isOn: $settings.notificationSoundsEnabled)
                if settings.notificationSoundsEnabled {
                    SettingsRowDivider()
                    soundPicker(title: "Task completed", selection: $settings.completionSound)
                    SettingsRowDivider()
                    soundPicker(title: "Changes ready", selection: $settings.changesReadySound)
                    SettingsRowDivider()
                    soundPicker(title: "Task failed", selection: $settings.errorSound)
                }
            }

            SettingsSection(title: "iCloud Sync") {
                SettingsToggleRow(title: "Sync workspaces & preferences via iCloud",
                                  isOn: $settings.cloudSyncEnabled)
                    .onChange(of: settings.cloudSyncEnabled) { _, on in
                        if on { cloudSync.push(settings) }
                    }
                SettingsStatusLine(
                    CloudSyncService.isSignedIn
                        ? "Signed in to iCloud. Secrets (API keys, tokens) never sync."
                        : "Not signed in to iCloud — sync is inactive.",
                    systemImage: CloudSyncService.isSignedIn ? "checkmark.circle.fill" : "exclamationmark.triangle.fill",
                    tint: CloudSyncService.isSignedIn ? Theme.success : Theme.warning)
            }

            SettingsSection(title: "Local Agent Bridge",
                            footnote: "Lets Codex, Cursor, opencode, or scripts on this Mac list sites, run the agent, and pull debug briefs over a token-authenticated loopback socket. Off by default; never exposed to the network.") {
                SettingsToggleRow(title: "Allow local agent connections",
                                  isOn: $settings.localBridgeEnabled)
                SettingsRowDivider()
                bridgeState
                FormRow(label: "Port",
                        footnote: settings.localBridgeEnabled ? "Restart the bridge to apply a new port." : nil) {
                    TextField("0 = auto", value: $settings.localBridgePort, format: .number)
                        .focused($portFocused)
                        .fieldChrome(focused: portFocused)
                        .frame(width: 110)
                        .accessibilityLabel("Port")
                }
            }
        }
    }

    private var appearanceDetail: String {
        switch settings.themeMode {
        case .system: return "Follows your Mac appearance automatically."
        case .light:  return "A bright, high-contrast workspace for daylight use."
        default:      return "A low-luminance workspace for dim environments."
        }
    }

    @ViewBuilder private var bridgeState: some View {
        if bridge.isRunning, let port = bridge.port {
            VStack(alignment: .leading, spacing: Theme.Space.s) {
                SettingsStatusLine(verbatim: "Listening on 127.0.0.1:\(port) (loopback only)",
                                   systemImage: "lock.shield.fill",
                                   tint: Theme.success)
                HStack(spacing: Theme.Space.s) {
                    FieldHeader(label: "Token file")
                    Text(LocalBridge.tokenFileURL.path)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(Theme.secondaryText)
                        .textSelection(.enabled)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: Theme.Space.s)
                    Button("Copy token") {
                        if let token = LocalBridge.readPublishedToken() {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(token, forType: .string)
                        }
                    }
                    .buttonStyle(.primarySoftCompact)
                }
                SettingsNote("Any program on this Mac that reads the token file can drive the app. Keep it off when not in use.")
            }
        } else if settings.localBridgeEnabled {
            if let error = bridge.lastError {
                SettingsStatusLine(verbatim: error, systemImage: "xmark.octagon.fill", tint: Theme.danger)
            } else {
                SettingsStatusLine("Starting…", systemImage: "hourglass")
            }
        } else {
            SettingsStatusLine("Off — no socket is open.", systemImage: "power")
        }
    }

    private func soundPicker(title: String,
                             selection: Binding<NotificationSound>) -> some View {
        FormRow(label: title) {
            HStack(spacing: Theme.Space.s) {
                Picker("", selection: selection) {
                    ForEach(NotificationSound.allCases) { sound in
                        Text(sound.rawValue).tag(sound)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .font(Theme.ui(13))
                .accessibilityLabel(LocalizedStringKey(title))
                Button {
                    AudioNotificationPlayer.play(selection.wrappedValue)
                } label: {
                    Image(systemName: "speaker.wave.2.fill")
                }
                .buttonStyle(.iconCompact)
                .help("Preview sound")
                .accessibilityLabel("Preview \(selection.wrappedValue.rawValue) sound")
            }
        }
    }
}

// MARK: - About tab

struct AboutSettingsTab: View {
    @EnvironmentObject var settings: SettingsStore
    @EnvironmentObject var updater: UpdateChecker
    @FocusState private var feedFocused: Bool

    var body: some View {
        SettingsPage {
            VStack(spacing: Theme.Space.s) {
                BrandIllustration(size: 64)
                Text("Website Commander")
                    .font(Theme.ui(17, .bold))
                    .foregroundStyle(Theme.textPrimary)
                Text("Version \(UpdateChecker.currentVersion)")
                    .font(Theme.ui(11, .semibold))
                    .foregroundStyle(Theme.secondaryText)
                Text("The open-source, Mac-native website agent. Edit your sites with plain English, review every change, and ship.")
                    .font(Theme.ui(12))
                    .foregroundStyle(Theme.secondaryText)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 380)
            }
            .frame(maxWidth: .infinity)

            SettingsSection(title: "Updates") {
                FormRow(label: "Update feed URL",
                        help: HelpButton(title: "Update feed",
                                         message: "Leave this blank to use the built-in feed at mesut.uk. Override only if you host your own JSON: {\"version\":\"1.1.0\",\"url\":\"…zip\",\"sha256\":\"…\",\"notes\":\"…\"}. The app checks once shortly after launch and whenever you choose Check for Updates — it never polls in the background. Install verifies the ZIP checksum, replaces this app, and relaunches.",
                                         links: [])) {
                    HStack(spacing: Theme.Space.s) {
                        TextField(UpdateChecker.defaultFeedURL, text: $settings.updateFeedURL)
                            .focused($feedFocused)
                            .fieldChrome(focused: feedFocused)
                        Button(updater.checking ? "…" : "Check") {
                            Task { await updater.check(feedURL: settings.updateFeedURL, userInitiated: true) }
                        }
                        .buttonStyle(.primarySoftCompact)
                        .disabled(updater.checking || updater.installing)
                    }
                }
                if settings.updateFeedURL.trimmingCharacters(in: .whitespaces).isEmpty {
                    SettingsNote(verbatim: "Using \(UpdateChecker.defaultFeedURL)")
                }
                updateState
            }
        }
    }

    @ViewBuilder private var updateState: some View {
        if let error = updater.lastError {
            SettingsStatusLine(verbatim: error, systemImage: "xmark.circle.fill", tint: Theme.danger)
        } else if updater.upToDate {
            SettingsStatusLine("You're on the latest version.",
                               systemImage: "checkmark.circle.fill",
                               tint: Theme.success)
        } else if let release = updater.available {
            SettingsRowDivider()
            VStack(alignment: .leading, spacing: Theme.Space.s) {
                SettingsStatusLine(verbatim: "Update \(release.version) is available.",
                                   systemImage: "arrow.down.circle.fill",
                                   tint: Theme.accent)
                if !release.notes.isEmpty {
                    SettingsNote(verbatim: release.notes, tint: Theme.secondaryText)
                }
                HStack(spacing: Theme.Space.s) {
                    if release.sha256.count == 64 && release.url.lowercased().hasSuffix(".zip") {
                        Button(updater.installing ? "Installing…" : "Install & Relaunch") {
                            Task { await updater.installAndRelaunch(release) }
                        }
                        .buttonStyle(.primaryCompact)
                        .disabled(updater.installing)
                    }
                    if let url = URL(string: release.url), !release.url.isEmpty {
                        Button("Download") { NSWorkspace.shared.open(url) }
                            .buttonStyle(.primarySoftCompact)
                    }
                    Spacer(minLength: 0)
                }
                if updater.installing {
                    ProgressView(value: updater.installProgress)
                        .progressViewStyle(.linear)
                }
            }
        }
    }
}
