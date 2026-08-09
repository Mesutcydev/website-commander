import SwiftUI
import AppKit

/// Experimental public-X-to-blog workflow. The screen deliberately stops at
/// preparation: repository inspection, article generation, media staging, and
/// approval all remain visible in the existing Agent review surface.
struct BlogView: View {
    @EnvironmentObject private var engine: AgentEngine
    @Environment(\.destination) private var destination

    @State private var sourceURL = ""
    @State private var draft: XPostImportDraft?
    @State private var isFetching = false
    @State private var rightsConfirmed = false
    @State private var errorMessage: String?

    private var importer: XPostImporter {
        XPostImporter(assetStore: engine.blogImportAssetStore)
    }

    var body: some View {
        GeometryReader { proxy in
            VStack(spacing: 0) {
                header
                ScrollView {
                    VStack(alignment: .leading, spacing: Theme.Space.xl) {
                        sourceComposer
                        if let draft {
                            draftWorkspace(draft, width: proxy.size.width)
                        } else {
                            EmptyStateView(
                                systemImage: "link",
                                title: "Bring a public X post into your blog",
                                message: "Paste an x.com or twitter.com post URL to inspect its public embed, then prepare a repository-native article.",
                                useBrandArt: false
                            )
                            .frame(minHeight: 300)
                        }
                    }
                    .padding(.horizontal, AgentWorkspaceMetrics.gutter(for: proxy.size.width))
                    .padding(.vertical, Theme.Space.xl)
                    .frame(maxWidth: 1360, alignment: .leading)
                    .frame(maxWidth: .infinity)
                }
            }
        }
        .background { GlassWorkspaceBackground() }
    }

    private var header: some View {
        HStack(spacing: Theme.Space.s) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: Theme.Space.s) {
                    Text("Blog")
                        .font(.system(size: 24, weight: .semibold))
                        .foregroundStyle(Theme.textHeading)
                    Badge(text: "Experimental", systemImage: "flask",
                          tint: Theme.amberText, surface: Theme.amberSoft)
                }
                Text("Turn a public X post into a reviewable, repository-native article.")
                    .font(Theme.ui(11.5))
                    .foregroundStyle(Theme.secondaryText)
            }
            Spacer(minLength: Theme.Space.m)
            if let phase = activePhase {
                HStack(spacing: 6) {
                    if phaseIsActive {
                        ProgressView().controlSize(.mini)
                    } else {
                        Image(systemName: phaseIcon)
                    }
                    Text(phase.label)
                }
                .font(Theme.ui(11.5, .medium))
                .foregroundStyle(phaseColor)
                .padding(.horizontal, 9)
                .frame(height: Theme.Height.badge)
                .background(phaseColor.opacity(0.10),
                            in: RoundedRectangle(cornerRadius: Theme.Radius.badge,
                                                 style: .continuous))
            }
        }
        .padding(.horizontal, 24)
        .padding(.top, 20)
        .padding(.bottom, Theme.Space.m)
        .frame(maxWidth: 1360)
        .frame(maxWidth: .infinity)
    }

    private var sourceComposer: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            HStack(spacing: Theme.Space.s) {
                Image(systemName: "link")
                    .foregroundStyle(Theme.accent)
                TextField("https://x.com/author/status/…", text: $sourceURL)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13, design: .monospaced))
                    .onSubmit { fetchDraft() }
                if !sourceURL.isEmpty {
                    Button {
                        sourceURL = ""
                        draft = nil
                        rightsConfirmed = false
                        errorMessage = nil
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Theme.tertiaryText)
                }
                Button(isFetching ? "Inspecting…" : "Inspect public post") {
                    fetchDraft()
                }
                .buttonStyle(.primarySoftCompact)
                .disabled(isFetching || sourceURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                          || importIsActive)
            }
            .padding(.horizontal, Theme.Space.m)
            .frame(minHeight: 44)
            .background(Theme.standardSurface,
                        in: RoundedRectangle(cornerRadius: Theme.Radius.composer,
                                             style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: Theme.Radius.composer, style: .continuous)
                    .strokeBorder(Theme.borderSubtle)
            }

            HStack(alignment: .top, spacing: Theme.Space.s) {
                Image(systemName: "shield.lefthalf.filled")
                    .foregroundStyle(Theme.secondaryText)
                Text("Only the official public embed is inspected. Source text is treated as untrusted content, and imported bytes stay file-backed until you review the final changes.")
                    .font(Theme.ui(11.5))
                    .foregroundStyle(Theme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                    .font(Theme.ui(11.5, .medium))
                    .foregroundStyle(Theme.danger)
                    .textSelection(.enabled)
            }
            if let engineError = engine.lastError,
               engine.activeBlogImportSessionID != nil,
               errorMessage == nil {
                Label(engineError, systemImage: "exclamationmark.triangle.fill")
                    .font(Theme.ui(11.5, .medium))
                    .foregroundStyle(Theme.danger)
                    .textSelection(.enabled)
            }
        }
    }

    @ViewBuilder
    private func draftWorkspace(_ draft: XPostImportDraft, width: CGFloat) -> some View {
        if width >= 980 {
            HStack(alignment: .top, spacing: Theme.Space.l) {
                sourcePreview(draft)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                preparationPanel(draft)
                    .frame(width: 380, alignment: .topLeading)
            }
        } else {
            VStack(alignment: .leading, spacing: Theme.Space.l) {
                sourcePreview(draft)
                preparationPanel(draft)
            }
        }
    }

    private func sourcePreview(_ draft: XPostImportDraft) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            HStack(alignment: .top, spacing: Theme.Space.s) {
                IconTile(systemImage: "text.quote", accent: .violet, size: 34)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Source preview")
                        .font(Theme.ui(13, .semibold))
                        .foregroundStyle(Theme.textPrimary)
                    HStack(spacing: 6) {
                        Text(authorLabel(for: draft))
                        Text("·")
                        Text(draft.postID)
                            .font(.system(size: 10.5, design: .monospaced))
                    }
                    .font(Theme.ui(11.5))
                    .foregroundStyle(Theme.secondaryText)
                }
                Spacer()
                Button {
                    NSWorkspace.shared.open(draft.canonicalURL)
                } label: {
                    Label("Open source", systemImage: "arrow.up.right")
                }
                .buttonStyle(.primarySoftCompact)
            }

            Text(draft.sourceText)
                .font(.system(size: 15, weight: .regular))
                .foregroundStyle(Theme.textPrimary)
                .lineSpacing(4)
                .textSelection(.enabled)
                .frame(maxWidth: 660, alignment: .leading)

            HStack(spacing: Theme.Space.s) {
                if let date = draft.sourcePublishedAt {
                    Label(date.formatted(date: .abbreviated, time: .omitted),
                          systemImage: "calendar")
                } else {
                    Label("Publication date unavailable", systemImage: "calendar.badge.exclamationmark")
                }
                Label("\(draft.media.count) imported image\(draft.media.count == 1 ? "" : "s")",
                      systemImage: "photo")
                if draft.hasVideo {
                    Label("Video stays linked", systemImage: "video")
                }
            }
            .font(Theme.ui(11.5))
            .foregroundStyle(Theme.secondaryText)

            if !draft.media.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: Theme.Space.s) {
                        ForEach(draft.media) { asset in
                            BlogAssetThumbnail(asset: asset, sessionID: draft.id)
                        }
                    }
                }
            }

            if !draft.warnings.isEmpty {
                VStack(alignment: .leading, spacing: Theme.Space.xs) {
                    ForEach(draft.warnings) { warning in
                        Label(warning.message, systemImage: "info.circle")
                            .font(Theme.ui(11.5))
                            .foregroundStyle(Theme.secondaryText)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.top, Theme.Space.xs)
            }
        }
        .padding(Theme.Space.l)
        .background(Theme.standardSurface,
                    in: RoundedRectangle(cornerRadius: Theme.Radius.large, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: Theme.Radius.large, style: .continuous)
                .strokeBorder(Theme.borderHairline)
        }
    }

    private func preparationPanel(_ draft: XPostImportDraft) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            HStack {
                Text("Prepare article")
                    .font(Theme.ui(13, .semibold))
                    .foregroundStyle(Theme.textPrimary)
                Spacer()
                if engine.pendingChanges.contains(where: { $0.importSessionID == draft.id }) {
                    Badge(text: "\(engine.pendingChanges.filter { $0.importSessionID == draft.id }.count) staged",
                          tint: Theme.teal, surface: Theme.tealSoft)
                }
            }

            Text("The agent will inspect this repository's existing posts first, follow its actual article and media conventions, and stop at the normal review gate.")
                .font(Theme.ui(11.5))
                .foregroundStyle(Theme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)

            Toggle(isOn: $rightsConfirmed) {
                Text("I own this content or have permission to adapt and publish it, including any imported media.")
                    .font(Theme.ui(11.5, .medium))
                    .foregroundStyle(Theme.textPrimary)
            }
            .toggleStyle(.checkbox)
            .disabled(importIsActive)

            Button {
                engine.startBlogImport(draft, rightsConfirmed: rightsConfirmed)
            } label: {
                Label(importIsActive && engine.activeBlogImportSessionID == draft.id ? "Preparing…" : "Prepare blog post",
                      systemImage: "wand.and.stars")
            }
            .buttonStyle(.primary)
            .frame(maxWidth: .infinity)
            .disabled(!rightsConfirmed || importIsActive
                      || engine.isRunActive || !engine.pendingChanges.isEmpty)

            if let phase = activePhase {
                HStack(alignment: .top, spacing: Theme.Space.s) {
                    Image(systemName: phaseIcon)
                        .foregroundStyle(phaseColor)
                    Text(phaseDetail(for: phase))
                        .font(Theme.ui(11.5))
                        .foregroundStyle(Theme.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.top, Theme.Space.xs)
            } else {
                Text("Nothing is committed until you review and approve the generated changes.")
                    .font(Theme.ui(11.5))
                    .foregroundStyle(Theme.tertiaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if engine.pendingChanges.contains(where: { $0.importSessionID == draft.id }) {
                Button("Review staged changes") {
                    destination.wrappedValue = .agent
                }
                .buttonStyle(.primarySoftCompact)
            }
        }
        .padding(Theme.Space.l)
        .background(Theme.standardSurface,
                    in: RoundedRectangle(cornerRadius: Theme.Radius.large, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: Theme.Radius.large, style: .continuous)
                .strokeBorder(Theme.borderHairline)
        }
    }

    private var activePhase: BlogImportRunPhase? {
        guard let draft,
              engine.activeBlogImportSessionID == draft.id else { return nil }
        return engine.blogImportPhase
    }

    private var importIsActive: Bool {
        guard engine.activeBlogImportSessionID != nil else { return false }
        if case .failed = engine.blogImportPhase { return false }
        return true
    }

    private var phaseIsActive: Bool {
        switch activePhase {
        case .inspectingRepository, .conventionDeclared, .staging: return true
        default: return false
        }
    }

    private var phaseIcon: String {
        switch activePhase {
        case .inspectingRepository: return "magnifyingglass"
        case .conventionDeclared: return "checkmark.circle"
        case .staging: return "square.and.arrow.down"
        case .readyForReview: return "checkmark.seal"
        case .failed: return "xmark.octagon"
        case .none: return "circle"
        }
    }

    private var phaseColor: Color {
        switch activePhase {
        case .readyForReview: return Theme.teal
        case .failed: return Theme.danger
        case .conventionDeclared, .staging: return Theme.accent
        default: return Theme.secondaryText
        }
    }

    private func phaseDetail(for phase: BlogImportRunPhase) -> String {
        switch phase {
        case .readyForReview:
            return "The article and any imported media are staged together. Open Agent to inspect the diff before approving."
        case .failed(let reason):
            return reason
        default:
            return phase.label + ". The repository is still untouched."
        }
    }

    private func authorLabel(for draft: XPostImportDraft) -> String {
        if let display = draft.authorDisplayName, !display.isEmpty {
            if let handle = draft.authorHandle, !handle.isEmpty {
                return "\(display) · @\(handle.trimmingCharacters(in: CharacterSet(charactersIn: "@")))"
            }
            return display
        }
        if let handle = draft.authorHandle, !handle.isEmpty {
            return "@\(handle.trimmingCharacters(in: CharacterSet(charactersIn: "@")))"
        }
        return "Public X post"
    }

    private func fetchDraft() {
        guard !isFetching else { return }
        let value = sourceURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        isFetching = true
        errorMessage = nil
        let oldDraft = draft
        draft = nil
        rightsConfirmed = false
        Task { @MainActor in
            if let oldDraft {
                await engine.blogImportAssetStore.cleanup(sessionID: oldDraft.id)
            }
            do {
                draft = try await importer.importPost(from: value)
            } catch {
                errorMessage = error.localizedDescription
            }
            isFetching = false
        }
    }
}

private struct BlogAssetThumbnail: View {
    @EnvironmentObject private var engine: AgentEngine
    let asset: ImportedMediaAssetDescriptor
    let sessionID: UUID
    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                ZStack {
                    Theme.recessedSurface
                    ProgressView().controlSize(.small)
                }
            }
        }
        .frame(width: 92, height: 72)
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous)
                .strokeBorder(Theme.borderSubtle)
        }
        .task(id: asset.id) {
            let reference = BinaryAssetReference(sessionID: sessionID, assetID: asset.id)
            if let data = await engine.blogAssetData(for: reference) {
                image = NSImage(data: data)
            }
        }
        .accessibilityLabel("Imported \(asset.mimeType) \(asset.byteCount) bytes")
    }
}
