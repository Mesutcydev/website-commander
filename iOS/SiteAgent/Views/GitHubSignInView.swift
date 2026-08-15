import SwiftUI
import UIKit

/// Reusable "Sign in with GitHub" control built on `GitHubAuth`'s OAuth device
/// flow. Drop it anywhere the user might first connect GitHub — Settings, the
/// workspace-connect sheet, onboarding — so a repo-scoped (writable) token is
/// obtained without hand-crafting a Personal Access Token (the #1 way users end
/// up unable to push).
///
/// Self-contained: it owns its device-code + polling state and writes the
/// resulting token to `Keychain.githubToken`, the same slot every other part of
/// the app reads. Renders nothing when sign-in isn't configured in this build
/// and there's no token to report, so hosts can place it unconditionally.
struct GitHubSignInView: View {
    /// `.inline` blends into a Settings/form row; `.card` is a self-contained CTA
    /// for dark surfaces like onboarding.
    enum Style { case inline, card }

    var style: Style = .inline
    /// When false, the control never shows a "connected" status and always offers
    /// the button — used in Settings, where the token field already reflects state.
    var showsStatus: Bool = true
    var credentialID: UUID? = nil
    /// Called after a token is successfully stored, so hosts can refresh.
    var onSignedIn: () -> Void = {}

    private let auth = GitHubAuth.shared
    @State private var device: GitHubAuth.DeviceCode?
    @State private var busy = false
    @State private var errorText: String?
    // "Connected" reflects a *provably writable* token: one obtained via this
    // OAuth device flow (granted `repo` scope). A manually-pasted token of
    // unknown scope is deliberately NOT treated as connected here — claiming so
    // would be the very 403-at-commit surprise this feature exists to prevent.
    // (Manual tokens are validated separately in Settings via the write probe.)
    @State private var oauthConnected = false

    private var showsConnected: Bool { oauthConnected && showsStatus && device == nil }

    init(
        style: Style = .inline,
        showsStatus: Bool = true,
        credentialID: UUID? = nil,
        onSignedIn: @escaping () -> Void = {}
    ) {
        self.style = style
        self.showsStatus = showsStatus
        self.credentialID = credentialID
        self.onSignedIn = onSignedIn
        _oauthConnected = State(initialValue:
            Keychain.get(Keychain.githubTokenSource(credentialID: credentialID)) == "oauth"
            && Keychain.hasGitHubToken(credentialID: credentialID)
        )
    }

    var body: some View {
        // Nothing to show if we can't start a sign-in and have no status to report.
        if auth.isConfigured || (oauthConnected && showsStatus) {
            switch style {
            case .inline:
                content
            case .card:
                content
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16)
                    .commandCard(cornerRadius: 18)
            }
        }
    }

    @ViewBuilder private var content: some View {
        VStack(alignment: .leading, spacing: 10) {
            if showsConnected {
                HStack {
                    Label("GitHub connected", systemImage: "checkmark.seal.fill")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.green)
                    Spacer()
                    Button("Sign out", role: .destructive) {
                        Keychain.set(nil, for: Keychain.githubToken(credentialID: credentialID))
                        Keychain.set(nil, for: Keychain.githubTokenSource(credentialID: credentialID))
                        oauthConnected = false
                        Haptics.tap()
                        onSignedIn()
                    }
                    .font(.footnote.weight(.medium))
                }
            } else if let device {
                deviceCode(device)
            } else if auth.isConfigured {
                trigger
            }
            if let errorText {
                Text(errorText).font(.footnote).foregroundStyle(.red)
            }
        }
        .onAppear {
            oauthConnected =
                Keychain.get(Keychain.githubTokenSource(credentialID: credentialID)) == "oauth"
                && Keychain.hasGitHubToken(credentialID: credentialID)
        }
    }

    @ViewBuilder private var trigger: some View {
        switch style {
        case .inline:
            Button { Task { await start() } } label: {
                HStack {
                    Label("Sign in with GitHub", systemImage: "person.badge.key")
                    if busy { Spacer(); ProgressView().controlSize(.small) }
                }
            }
            .disabled(busy)
        case .card:
            Button { Task { await start() } } label: {
                HStack {
                    Spacer()
                    Label("Sign in with GitHub", systemImage: "person.badge.key")
                    if busy { ProgressView().controlSize(.small) }
                    Spacer()
                }
            }
            .buttonStyle(.borderedProminent)
            .tint(Theme.brand)
            .disabled(busy)
        }
    }

    @ViewBuilder private func deviceCode(_ device: GitHubAuth.DeviceCode) -> some View {
        Text("1. Copy this code").font(.footnote).foregroundStyle(.secondary)
        HStack {
            Text(device.userCode)
                .font(.title3.weight(.bold).monospaced())
                .textSelection(.enabled)
            Spacer()
            Button {
                UIPasteboard.general.string = device.userCode; Haptics.tap()
            } label: { Image(systemName: "doc.on.doc") }
            .accessibilityLabel("Copy code")
        }
        if let verificationURL = URL(string: device.verificationURI) {
            Link(destination: verificationURL) {
                Label("2. Open github.com/login/device", systemImage: "arrow.up.forward.app")
            }
        } else {
            Text("GitHub returned an invalid verification link. Copy the code and open github.com/login/device manually.")
                .font(.footnote)
                .foregroundStyle(.orange)
        }
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text("Waiting for you to authorize…").font(.footnote).foregroundStyle(.secondary)
        }
    }

    private func start() async {
        busy = true; errorText = nil
        defer { busy = false }
        do {
            let d = try await auth.requestDeviceCode()
            UIPasteboard.general.string = d.userCode      // pre-copy for convenience
            device = d
            try await auth.pollForToken(d, credentialID: credentialID)
            device = nil
            oauthConnected = true
            Haptics.success()
            onSignedIn()
        } catch {
            device = nil
            errorText = error.localizedDescription
            Haptics.error()
        }
    }
}
