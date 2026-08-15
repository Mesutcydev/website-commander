import SwiftUI

struct UserGuideView: View {
    @EnvironmentObject var engine: AgentEngine
    @Environment(\.colorScheme) var colorScheme
    @Environment(\.dismiss) private var dismiss

    private var oledDark: Bool {
        engine.oledMode && colorScheme == .dark
    }

    private var pageBackground: Color {
        oledDark ? .black : Color(.systemGroupedBackground)
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                headerSection
                workflowSection
                setupSection
                chatSection
                reviewSection
                deploySection
                previewSection
                costsSection
                securitySection
            }
            .padding(.horizontal, 20)
            .padding(.top, 12)
            .padding(.bottom, 32)
        }
        .background(pageBackground.ignoresSafeArea())
        .navigationTitle("User Guide")
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: - Header
    private var headerSection: some View {
        HStack(spacing: 16) {
            ZStack {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Theme.brandGradient)
                    .frame(width: 56, height: 56)

                Image(systemName: "book.pages.fill")
                    .font(.system(size: 24, weight: .bold))
                    .foregroundStyle(.white)
            }
            .shadow(color: Theme.brand.opacity(0.3), radius: 8, y: 4)

            VStack(alignment: .leading, spacing: 4) {
                Text("Using Website Commander")
                    .font(.title2.weight(.black))
                Text("Learn the simple steps to edit and publish your websites.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
        }
        .padding(.vertical, 8)
    }

    // MARK: - Step 1: Big Picture
    private var workflowSection: some View {
        GuideCard(title: "The Big Picture", icon: "sparkles", color: .yellow) {
            VStack(spacing: 16) {
                Text("Website Commander acts as your co-developer. You chat, check the work, and deploy changes in real-time.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)

                HStack(spacing: 8) {
                    WorkflowStepBlock(title: "1. Ask in Chat", icon: "message.fill", color: .blue)
                    Image(systemName: "chevron.right")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.tertiary)
                    WorkflowStepBlock(title: "2. Review Diffs", icon: "doc.text.magnifyingglass", color: .orange)
                    Image(systemName: "chevron.right")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.tertiary)
                    WorkflowStepBlock(title: "3. Publish Live", icon: "paperplane.fill", color: .green)
                }
            }
        }
    }

    // MARK: - Step 2: Connection
    private var setupSection: some View {
        GuideCard(title: "1. Getting Connected", icon: "link", color: .blue) {
            VStack(alignment: .leading, spacing: 14) {
                Text("Open Settings (⚙️) from the Dashboard and connect your site assets:")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                VStack(spacing: 12) {
                    SetupRow(step: "A", title: "Add Your Website Workspace", desc: "Choose your tech stack (Next.js, Astro, Vanilla HTML, etc.) and repository details.", icon: "folder.badge.plus")
                    SetupRow(step: "B", title: "Securely Sign In with GitHub", desc: "Link your account so the agent has write-access to save coding files.", icon: "person.badge.key.fill")
                    SetupRow(step: "C", title: "Choose Your AI Provider", desc: "Sign in to GitHub Copilot on the free tier, or unlock Super for API-key providers and smart routing.", icon: "key.fill")
                }
            }
        }
    }

    // MARK: - Step 3: Chat
    private var chatSection: some View {
        GuideCard(title: "2. Instructing the Agent", icon: "message.and.waveform.fill", color: .purple) {
            VStack(alignment: .leading, spacing: 14) {
                Text("Chat naturally. Tap any template to fill command shortcuts:")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                VStack(alignment: .leading, spacing: 10) {
                    PromptBadge(text: "“Update the hero heading to say 'Hello World'”")
                    PromptBadge(text: "“Optimize our homepage meta tags for SEO”")
                    PromptBadge(text: "“Add a new photography page layout”")
                }

                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: "plus.circle.fill")
                        .foregroundStyle(Theme.brand)
                        .font(.title3)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Need visuals?")
                            .font(.subheadline.weight(.semibold))
                        Text("Tap + in the chatbar to upload mockups or images directly into the developer prompt.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.top, 4)
            }
        }
    }

    // MARK: - Step 4: Diff Review
    private var reviewSection: some View {
        GuideCard(title: "3. Review & Approve", icon: "doc.text.fill", color: .orange) {
            VStack(alignment: .leading, spacing: 14) {
                Text(" Website Commander shows staged file edits so you are always in control before code is committed.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                // Simulating line changes visually
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        Text("-")
                            .foregroundStyle(.red)
                            .font(.system(.subheadline, design: .monospaced).weight(.bold))
                        Text("let welcome = \"Welcome to My Website\"")
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(Color.red.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))

                    HStack(spacing: 8) {
                        Text("+")
                            .foregroundStyle(.green)
                            .font(.system(.subheadline, design: .monospaced).weight(.bold))
                        Text("let welcome = \"Welcome to My Premium Site ✨\"")
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(Color.green.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
                }
                .padding(8)
                .background(Color.primary.opacity(0.03), in: RoundedRectangle(cornerRadius: 10))

                Text("Enter a brief Commit Message explaining the modifications (e.g., 'Update welcome slogan') and tap Approve & Commit to deploy changes live.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Step 4b: Deploy, Verify & Undo
    private var deploySection: some View {
        GuideCard(title: "4. Deploy, Verify & Undo", icon: "paperplane.fill", color: .green) {
            VStack(alignment: .leading, spacing: 14) {
                Text("Approving a change commits it to GitHub — your host rebuilds automatically.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                SetupRow(step: "→", title: "Pick your host once",
                         desc: "Cloudflare Pages, Vercel, Netlify and GitHub Pages redeploy on every push. Cloudflare Workers deploy via a deploy hook — set it in Settings → Deploy Integrations.",
                         icon: "shippingbox.fill")
                SetupRow(step: "✓", title: "Confirm it went live",
                         desc: "Website Commander checks your deployment status and tells you in chat the moment your change is live.",
                         icon: "checkmark.seal.fill")
                SetupRow(step: "↺", title: "Undo in a tap",
                         desc: "Changed your mind? Undo the last commit from the Home dashboard's Recent Activity.",
                         icon: "arrow.uturn.backward")
            }
        }
    }

    // MARK: - Step 5: Preview
    private var previewSection: some View {
        GuideCard(title: "5. Preview & Debug", icon: "eye.fill", color: .green) {
            VStack(alignment: .leading, spacing: 14) {
                Text("Click the Preview tab to see how changes render live across multiple devices:")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                HStack(spacing: 12) {
                    Label("Mobile", systemImage: "iphone").font(.caption.weight(.bold))
                        .padding(.horizontal, 10).padding(.vertical, 6)
                        .background(Color.primary.opacity(0.05), in: Capsule())
                    Label("Tablet", systemImage: "ipad").font(.caption.weight(.bold))
                        .padding(.horizontal, 10).padding(.vertical, 6)
                        .background(Color.primary.opacity(0.05), in: Capsule())
                    Label("Desktop", systemImage: "macbook").font(.caption.weight(.bold))
                        .padding(.horizontal, 10).padding(.vertical, 6)
                        .background(Color.primary.opacity(0.05), in: Capsule())
                }

                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: "ant.circle.fill")
                        .foregroundStyle(Theme.brand)
                        .font(.title3)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Web Inspector (Super)")
                            .font(.subheadline.weight(.semibold))
                        Text("Toggle the bug icon to inspect console warnings, measure DOM layout styles, or check network response logs.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    // MARK: - Plans & Costs
    private var costsSection: some View {
        GuideCard(title: "Plans & Costs", icon: "creditcard.fill", color: .blue) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "gift.fill").foregroundStyle(.green)
                    Text("**Free:** GitHub Copilot, 1 site, and 8 agent runs each month.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Divider()
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "sparkles").foregroundStyle(Theme.brand)
                    Text("**Super:** every AI model, unlimited runs & sites, the live inspector, and smart routing — with a 7-day free trial.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Divider()
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "gauge.with.dots.needle.bottom.50percent").foregroundStyle(.orange)
                    Text("Set a per-session **spend cap** in Settings so cloud usage never surprises you. On-device and Copilot are always $0.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: - Security & Privacy
    private var securitySection: some View {
        GuideCard(title: "Security & Offline Support", icon: "lock.shield.fill", color: .purple) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "lock.fill")
                        .foregroundStyle(.green)
                    Text("Your credentials, authorization tokens, and API keys are saved in iCloud Keychain when available—no server proxies.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Divider()

                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "cpu")
                        .foregroundStyle(.blue)
                    Text("Offline agent runs utilize local 4-bit quantized MLX models (iPhone 15 Pro+), keeping edits entirely private on your device.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}

// MARK: - Card Container
struct GuideCard<Content: View>: View {
    let title: String
    let icon: String
    let color: Color
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(color)
                    .frame(width: 28, height: 28)
                    .background(color.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))

                Text(title)
                    .font(.headline)
                Spacer()
            }

            content
        }
        .padding(18)
        .cardSurface()
    }
}

// MARK: - Helper Views
struct WorkflowStepBlock: View {
    let title: String
    let icon: String
    let color: Color

    var body: some View {
        VStack(spacing: 8) {
            ZStack {
                Circle()
                    .fill(color.opacity(0.12))
                    .frame(width: 38, height: 38)
                Image(systemName: icon)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(color)
            }
            Text(title)
                .font(.caption2.weight(.bold))
                .foregroundStyle(.primary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
    }
}

struct SetupRow: View {
    let step: String
    let title: String
    let desc: String
    let icon: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            ZStack {
                Circle()
                    .fill(Theme.brandGradient)
                    .frame(width: 24, height: 24)
                Text(step)
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.white)
            }
            .padding(.top, 2)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Image(systemName: icon)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(title)
                        .font(.subheadline.weight(.semibold))
                }
                Text(desc)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

struct PromptBadge: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.caption.italic())
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.primary.opacity(0.04), lineWidth: 1))
    }
}
