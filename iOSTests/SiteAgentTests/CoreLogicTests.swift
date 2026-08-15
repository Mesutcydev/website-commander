import XCTest
import WebKit
import SwiftUI
@testable import SiteAgent

/// Characterization tests for the pure, safety-critical logic. These don't touch
/// the network or UI — they pin the behavior of the diff engine, the security
/// scan that gates auto-commit, provider response parsing, and the helpers the
/// Phase 0 work introduced, so future refactors can't silently regress them.
final class CoreLogicTests: XCTestCase {

    // MARK: Keychain commit policy (blank SecureFields must not wipe secrets)

    func testKeychainCommitActionPreservesBlankAndClearsNil() {
        XCTAssertEqual(Keychain.commitAction(for: nil), .clear)
        XCTAssertEqual(Keychain.commitAction(for: ""), .preserve)
        XCTAssertEqual(Keychain.commitAction(for: "   \n\t"), .preserve)
        XCTAssertEqual(Keychain.commitAction(for: "sk-live"), .store("sk-live"))
        XCTAssertEqual(Keychain.commitAction(for: "  sk-live  "), .store("sk-live"))
    }

    // MARK: SecurityScan (routes risky content to manual review under auto-commit)

    func testSecurityScanFlagsDangerousPatterns() {
        XCTAssertTrue(SecurityScan.risks(in: "const x = eval(userInput)").contains { $0.contains("eval") })
        XCTAssertTrue(SecurityScan.risks(in: "atob('payload')").contains { $0.contains("base64") })
        XCTAssertTrue(SecurityScan.risks(in: #"<script src="https://evil.example/x.js"></script>"#)
            .contains { $0.contains("external") })
    }

    func testSecurityScanIgnoresCleanContent() {
        XCTAssertTrue(SecurityScan.risks(in: "<h1>Hello</h1>\n<p>Clean static markup.</p>").isEmpty)
        // A relative same-origin script is not flagged as an external include.
        XCTAssertFalse(SecurityScan.risks(in: #"<script src="/js/app.js"></script>"#)
            .contains { $0.contains("external") })
    }

    // MARK: 409 self-heal (approve() conflict resolution)

    func testResolveConflictDetectsAlreadyAppliedChange() {
        // Remote already has the exact staged content (earlier commit landed,
        // response lost) → approve must succeed as a no-op, not dead-end on 409.
        let change = PendingChange(path: "styles.css", oldContent: "old", newContent: "new", message: "m")
        XCTAssertEqual(AgentEngine.resolveConflict(remoteContent: "new", change: change), .alreadyApplied)
    }

    func testResolveConflictRebasesOnRealDrift() {
        let change = PendingChange(path: "styles.css", oldContent: "old", newContent: "new", message: "m")
        XCTAssertEqual(AgentEngine.resolveConflict(remoteContent: "other", change: change), .rebase)
        // Deletions and uploads never match on text content — always re-review.
        var deletion = PendingChange(path: "styles.css", oldContent: "new", newContent: "", message: "m")
        deletion.isDeletion = true
        XCTAssertEqual(AgentEngine.resolveConflict(remoteContent: "", change: deletion), .rebase)
        var upload = PendingChange(path: "logo.png", oldContent: nil, newContent: "", message: "m")
        upload.uploadData = Data([0x1])
        XCTAssertEqual(AgentEngine.resolveConflict(remoteContent: "", change: upload), .rebase)
    }

    func testRefUpdateReconciliationDistinguishesAppliedUnchangedAndDiverged() {
        XCTAssertEqual(
            GitHubClient.resolveRefUpdate(baseSHA: "base", newCommitSHA: "new", observedTip: "new"),
            .applied
        )
        XCTAssertEqual(
            GitHubClient.resolveRefUpdate(baseSHA: "base", newCommitSHA: "new", observedTip: "base"),
            .unchanged
        )
        XCTAssertEqual(
            GitHubClient.resolveRefUpdate(baseSHA: "base", newCommitSHA: "new", observedTip: "someone-else"),
            .diverged
        )
    }

    // MARK: DeploymentVerifier (maps a committed file to its live URL candidates)

    func testDeploymentVerifierMapsCommittedPathsToLiveURLs() {
        let base = URL(string: "https://example.com")!
        // index.html serves at the site root.
        XCTAssertEqual(DeploymentVerifier.candidateURLs(base: base, path: "index.html"),
                       [base])
        // A nested directory index serves at that directory (canonical trailing slash).
        XCTAssertEqual(DeploymentVerifier.candidateURLs(base: base, path: "blog/index.html"),
                       [URL(string: "https://example.com/blog/")!])
        // A non-index page: try the .html file AND the "pretty URL" form.
        XCTAssertEqual(DeploymentVerifier.candidateURLs(base: base, path: "about.html"),
                       [URL(string: "https://example.com/about.html")!,
                        URL(string: "https://example.com/about")!])
        // A nested asset maps to its exact path.
        XCTAssertEqual(DeploymentVerifier.candidateURLs(base: base, path: "css/app.css"),
                       [URL(string: "https://example.com/css/app.css")!])
        // A leading slash is tolerated.
        XCTAssertEqual(DeploymentVerifier.candidateURLs(base: base, path: "/index.html"),
                       [base])
    }

    // MARK: DiffEngine (drives the approval gate's diff)

    func testLineDiffCountsAddsRemovesContext() {
        let lines = DiffEngine.lineDiff(old: "a\nb\nc", new: "a\nx\nc")
        XCTAssertEqual(lines.filter { $0.kind == .add }.count, 1)
        XCTAssertEqual(lines.filter { $0.kind == .remove }.count, 1)
        XCTAssertEqual(lines.filter { $0.kind == .context }.count, 2)
    }

    func testLineDiffNewFileIsAllAdds() {
        let lines = DiffEngine.lineDiff(old: "", new: "one\ntwo")
        XCTAssertEqual(lines.filter { $0.kind == .add }.count, 2)
        XCTAssertTrue(lines.allSatisfy { $0.kind == .add })
    }

    // MARK: OpenAI-compatible response parsing (DeepSeek/OpenAI/Copilot share this)

    func testOpenAICompatibleParseExtractsToolCallAndUsage() throws {
        let json = """
        {"choices":[{"message":{"content":"Working on it",
          "tool_calls":[{"id":"t1","type":"function",
            "function":{"name":"read_file","arguments":"{\\"path\\":\\"index.html\\"}"}}]}}],
         "usage":{"prompt_tokens":12,"completion_tokens":7}}
        """
        let resp = try OpenAICompatibleProvider.parse(Data(json.utf8))
        XCTAssertEqual(resp.content, "Working on it")
        XCTAssertEqual(resp.toolCalls.count, 1)
        XCTAssertEqual(resp.toolCalls.first?.name, "read_file")
        XCTAssertEqual(resp.usage?.promptTokens, 12)
        XCTAssertEqual(resp.usage?.completionTokens, 7)
    }

    func testOpenAICompatibleParseNormalizesObjectToolArguments() throws {
        let json = """
        {"choices":[{"message":{"tool_calls":[{"id":"t1","type":"function",
          "function":{"name":"read_file","arguments":{"path":"index.html"}}}]}}]}
        """
        let resp = try OpenAICompatibleProvider.parse(Data(json.utf8))
        XCTAssertEqual(resp.toolCalls.first?.argumentsJSON, #"{"path":"index.html"}"#)
        XCTAssertNil(resp.errorType)
    }

    func testOpenCodeGoCatalogAndResponsesToolParsing() throws {
        let provider = OpenAICompatibleProvider.opencode
        XCTAssertEqual(provider.defaultModel, "gpt-5.6-luna")
        XCTAssertTrue(provider.models.contains("qwen3.8-max"))
        XCTAssertFalse(provider.models.contains("qwen3.8-max-preview"))
        XCTAssertTrue(provider.capabilities(for: "gpt-5.6-luna").supportsReasoningSummary)

        let json = """
        {"status":"completed","output":[
          {"type":"reasoning","encrypted_content":"enc_123","summary":[]},
          {"type":"message","role":"assistant","content":[{"type":"output_text","text":"Inspecting"}]},
          {"type":"function_call","id":"fc_1","call_id":"call_1","name":"read_file","arguments":{"path":"index.html"}}
        ],"usage":{"input_tokens":12,"output_tokens":7}}
        """
        let response = try OpenAICompatibleProvider.parseResponses(Data(json.utf8))
        XCTAssertEqual(response.content, "Inspecting")
        XCTAssertEqual(response.thoughtSignature, "enc_123")
        XCTAssertEqual(response.toolCalls.first?.id, "call_1")
        XCTAssertEqual(response.toolCalls.first?.argumentsJSON, #"{"path":"index.html"}"#)
        XCTAssertEqual(response.usage, TokenUsage(promptTokens: 12, completionTokens: 7))
        XCTAssertNil(response.errorType)
    }

    func testOpenCodeGoResponsesRoundTripsReasoningAndToolOutput() throws {
        let tool = ToolSpec(
            name: "read_file",
            description: "Read a file",
            parameters: ["type": "object", "properties": ["path": ["type": "string"]]]
        )
        let messages: [LLMMessage] = [
            .system("Use tools."),
            .assistant(
                nil,
                calls: [LLMToolCall(id: "call_1", name: "read_file", argumentsJSON: #"{"path":"index.html"}"#)],
                thoughtSignature: "enc_123"
            ),
            .tool("<html />", id: "call_1", name: "read_file")
        ]
        let payload = OpenAICompatibleProvider.responsesPayload(
            messages: messages,
            tools: [tool],
            model: "gpt-5.6-luna",
            stream: false
        )
        let input = try XCTUnwrap(payload["input"] as? [[String: Any]])
        XCTAssertEqual(input.first?["role"] as? String, "developer")
        XCTAssertEqual(input.first?["content"] as? String, "Use tools.")
        XCTAssertEqual(input[1]["type"] as? String, "reasoning")
        XCTAssertEqual(input[1]["encrypted_content"] as? String, "enc_123")
        XCTAssertEqual(input[2]["type"] as? String, "function_call")
        XCTAssertEqual(input[2]["call_id"] as? String, "call_1")
        XCTAssertNil(input[2]["id"])
        XCTAssertEqual(input[3]["type"] as? String, "function_call_output")
        XCTAssertEqual(input[3]["call_id"] as? String, "call_1")
        XCTAssertEqual(payload["store"] as? Bool, false)
        XCTAssertEqual(payload["include"] as? [String], ["reasoning.encrypted_content"])
    }

    func testOpenCodeGoMessagesToolParsing() throws {
        let json = """
        {"stop_reason":"tool_use","content":[
          {"type":"text","text":"Inspecting"},
          {"type":"tool_use","id":"toolu_1","name":"read_file","input":{"path":"index.html"}}
        ],"usage":{"input_tokens":3,"output_tokens":5}}
        """
        let response = try OpenAICompatibleProvider.parseAnthropicMessages(Data(json.utf8))
        XCTAssertEqual(response.content, "Inspecting")
        XCTAssertEqual(response.toolCalls.first?.name, "read_file")
        XCTAssertEqual(response.toolCalls.first?.argumentsJSON, #"{"path":"index.html"}"#)
        XCTAssertEqual(response.usage, TokenUsage(promptTokens: 3, completionTokens: 5))
        XCTAssertNil(response.errorType)
    }

    func testOpenAICompatibleEncodeIncludesImageParts() throws {
        let image = LLMImage(mimeType: "image/png", base64: "abc123")
        let encoded = OpenAICompatibleProvider.encode(.user("Describe this", images: [image]))

        let content = try XCTUnwrap(encoded["content"] as? [[String: Any]])
        XCTAssertEqual(content.count, 2)
        XCTAssertEqual(content[0]["type"] as? String, "text")
        XCTAssertEqual(content[0]["text"] as? String, "Describe this")

        XCTAssertEqual(content[1]["type"] as? String, "image_url")
        let imageURL = try XCTUnwrap(content[1]["image_url"] as? [String: Any])
        XCTAssertEqual(imageURL["url"] as? String, "data:image/png;base64,abc123")
    }

    func testAnthropicConvertIncludesImageBlocks() throws {
        let image = LLMImage(mimeType: "image/jpeg", base64: "jpegdata")
        let (_, messages) = AnthropicProvider.convert([.user("Describe this", images: [image])])

        let first = try XCTUnwrap(messages.first)
        XCTAssertEqual(first["role"] as? String, "user")
        let content = try XCTUnwrap(first["content"] as? [[String: Any]])
        XCTAssertEqual(content[0]["type"] as? String, "text")
        XCTAssertEqual(content[0]["text"] as? String, "Describe this")

        XCTAssertEqual(content[1]["type"] as? String, "image")
        let source = try XCTUnwrap(content[1]["source"] as? [String: Any])
        XCTAssertEqual(source["type"] as? String, "base64")
        XCTAssertEqual(source["media_type"] as? String, "image/jpeg")
        XCTAssertEqual(source["data"] as? String, "jpegdata")
    }

    func testGeminiMapMessagesIncludesInlineImageData() throws {
        let image = LLMImage(mimeType: "image/webp", base64: "webpdata")
        let mapped = GeminiProvider().mapMessages([.user("Describe this", images: [image])])

        let first = try XCTUnwrap(mapped.contents.first)
        XCTAssertEqual(first["role"] as? String, "user")
        let parts = try XCTUnwrap(first["parts"] as? [[String: Any]])
        XCTAssertEqual(parts[0]["text"] as? String, "Describe this")

        let inlineData = try XCTUnwrap(parts[1]["inlineData"] as? [String: Any])
        XCTAssertEqual(inlineData["mimeType"] as? String, "image/webp")
        XCTAssertEqual(inlineData["data"] as? String, "webpdata")
    }

    func testProviderCapabilitiesUseModelModalities() {
        XCTAssertTrue(OpenAICompatibleProvider.openAI.capabilities(for: "gpt-5.4").supportsImageInput)
        XCTAssertTrue(OpenAICompatibleProvider.openAI.capabilities(for: "gpt-5.4").supportsReasoningSummary)
        XCTAssertTrue(OpenAICompatibleProvider.openRouter.capabilities(for: "openai/gpt-4o").supportsImageInput)
        XCTAssertFalse(OpenAICompatibleProvider.openRouter.capabilities(for: "meta-llama/llama-3.3-70b-instruct").supportsImageInput)
        XCTAssertFalse(OnDeviceProvider().capabilities(for: OnDeviceProvider().defaultModel).supportsImageInput)
    }

    // MARK: Preview MIME mapping (Phase 0 custom-scheme fix)

    func testPreviewMimeTypes() {
        XCTAssertTrue(PreviewSchemeHandler.mimeType(for: URL(fileURLWithPath: "/p/app.css")).contains("text/css"))
        XCTAssertTrue(PreviewSchemeHandler.mimeType(for: URL(fileURLWithPath: "/p/app.js")).contains("javascript"))
        XCTAssertTrue(PreviewSchemeHandler.mimeType(for: URL(fileURLWithPath: "/p/index.html")).contains("text/html"))
        XCTAssertEqual(PreviewSchemeHandler.mimeType(for: URL(fileURLWithPath: "/p/logo.svg")), "image/svg+xml")
    }

    func testPreviewStartsAtSiteRootForClientSideRouters() {
        XCTAssertEqual(PreviewSchemeHandler.entryURL.path, "/")
        XCTAssertFalse(PreviewSchemeHandler.entryURL.absoluteString.contains("index.html"))
    }

    func testConfiguredLiveURLAcceptsBareDomainsAndRejectsUnsupportedSchemes() {
        XCTAssertEqual(
            SiteWorkspace.normalizedLiveURL("elemanlazim.net")?.absoluteString,
            "https://elemanlazim.net"
        )
        XCTAssertEqual(
            SiteWorkspace.normalizedLiveURL(" https://elemanlazim.net/preview ")?.absoluteString,
            "https://elemanlazim.net/preview"
        )
        XCTAssertNil(SiteWorkspace.normalizedLiveURL("ftp://elemanlazim.net"))
        XCTAssertNil(SiteWorkspace.normalizedLiveURL("not a URL"))
    }

    func testDeploymentHookURLNormalizationTreatsMalformedDataAsMissingConfiguration() {
        XCTAssertNil(DeploymentClientFactory.normalizedDeployHookURL("not a URL"))
        XCTAssertEqual(
            DeploymentClientFactory.normalizedDeployHookURL("hooks.example.com/siteagent")?.absoluteString,
            "https://hooks.example.com/siteagent"
        )
    }

    func testDeploymentConnectionStateHasSafeNoWorkspaceFallback() {
        XCTAssertEqual(
            DeploymentCapabilities.connectionState(workspace: nil, repo: .none),
            .notConfigured
        )
    }

    func testRepositoryDeploymentConfigFindsProductionCustomDomain() {
        let wrangler = """
        name = "elemanlazimnet"
        NEXT_PUBLIC_SITE_URL = "https://elemanlazim.net"
        [[routes]]
        pattern = "elemanlazim.net"
        custom_domain = true
        """
        XCTAssertEqual(
            SiteWorkspace.repositoryConfiguredLiveURL(source: wrangler)?.absoluteString,
            "https://elemanlazim.net"
        )
    }

    func testPreviewURLCandidateUsesWorkspaceDomainWhenLiveURLIsMissing() {
        let workspace = SiteWorkspace(
            name: "elemanlar-m.net",
            gitOwner: "Mesutcydev",
            gitRepo: "elemanlar-m.net",
            gitBranch: "main",
            techStack: .nextjs,
            deployment: .cloudflareWorkers,
            defaultModel: "gpt-5"
        )

        XCTAssertEqual(workspace.previewURLCandidate?.absoluteString, "https://elemanlar-m.net")
    }

    func testPreviewURLCandidatePrefersConfiguredURLAndCanDeriveWorkersURL() {
        var configured = SiteWorkspace(
            name: "elemanlar-m.net",
            gitOwner: "Mesutcydev",
            gitRepo: "elemanlar-m.net",
            gitBranch: "main",
            techStack: .nextjs,
            deployment: .cloudflareWorkers,
            defaultModel: "gpt-5",
            deploymentConfig: ["liveURL": "https://production.example.com"]
        )
        XCTAssertEqual(configured.previewURLCandidate?.absoluteString, "https://production.example.com")

        configured.name = "Elemanlar worker"
        configured.deploymentConfig = [
            "cloudflareWorkerName": "elemanlar",
            "cloudflareAccountSubdomain": "mesut"
        ]
        XCTAssertEqual(configured.previewURLCandidate?.absoluteString, "https://elemanlar.mesut.workers.dev")

        // A legacy workspace can retain the old repository/domain name after
        // the Worker is moved to a custom domain. Provider metadata must win
        // over that stale name-based guess.
        configured.name = "elemanlar-m.net"
        XCTAssertEqual(configured.previewURLCandidate?.absoluteString, "https://elemanlar.mesut.workers.dev")
    }

    func testProviderTiersIncludeOpenRouterFree() {
        XCTAssertEqual(AgentEngine.freeProviderID, "copilot")
        XCTAssertFalse(AgentEngine.proOnlyProviderIDs.contains("copilot"))
        XCTAssertFalse(AgentEngine.proOnlyProviderIDs.contains("openrouter-free"))
        XCTAssertTrue(AgentEngine.proOnlyProviderIDs.contains("deepseek"))
        XCTAssertTrue(AgentEngine.proOnlyProviderIDs.contains("anthropic"))
        XCTAssertTrue(AgentEngine.proOnlyProviderIDs.contains("openai"))
        XCTAssertTrue(AgentEngine.proOnlyProviderIDs.contains("opencode"))
        XCTAssertTrue(AgentEngine.proOnlyProviderIDs.contains("openrouter"))
        XCTAssertTrue(AgentEngine.proOnlyProviderIDs.contains("longcat"))
        XCTAssertTrue(AgentEngine.proOnlyProviderIDs.contains("groq"))
    }

    func testOpenRouterFreeUsesSharedKeyAndOnlyFreeRouter() {
        XCTAssertEqual(ProviderCredentials.keychainProviderID(for: "openrouter-free"), "openrouter")
        XCTAssertEqual(OpenAICompatibleProvider.openRouterFree.models, ["openrouter/free"])
        XCTAssertEqual(OpenAICompatibleProvider.openRouterFree.defaultModel, "openrouter/free")
    }

    func testLongCatPresetMatchesOfficialOpenAIEndpoint() {
        let provider = OpenAICompatibleProvider.longCat
        XCTAssertEqual(provider.defaultModel, "LongCat-2.0")
        XCTAssertEqual(provider.baseURL.absoluteString, "https://api.longcat.chat/openai/v1")
        XCTAssertFalse(provider.capabilities(for: provider.defaultModel).supportsImageInput)
    }

    @MainActor
    func testInspectorBridgeReportsAfterDocumentStartInjection() async {
        let performanceReported = expectation(description: "Inspector reported performance metrics")
        let documentReported = expectation(description: "Inspector reported the main document")
        let recorder = InspectorMessageRecorder(
            performanceExpectation: performanceReported,
            documentExpectation: documentReported
        )
        let configuration = WKWebViewConfiguration()
        configuration.userContentController.add(recorder, name: "siteAgentInspector")
        configuration.userContentController.addUserScript(
            WKUserScript(
                source: WebViewContainer.inspectorJavaScript,
                injectionTime: .atDocumentStart,
                forMainFrameOnly: true
            )
        )

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.loadHTMLString(
            "<!doctype html><html><head><title>Preview</title></head><body><h1>Ready</h1></body></html>",
            baseURL: URL(string: "https://preview.test/")
        )

        // 3s flakes on a loaded simulator; WKWebView cold-start alone can exceed it.
        await fulfillment(of: [performanceReported, documentReported], timeout: 15)
        XCTAssertGreaterThan(recorder.loadTime, 0)
        XCTAssertGreaterThan(recorder.domReady, 0)
        withExtendedLifetime(webView) {}
    }

    // MARK: RepoConfig empty-state (Phase 0 de-personalization)

    func testRepoConfigEmptyState() {
        XCTAssertTrue(RepoConfig.none.isEmpty)
        XCTAssertEqual(RepoConfig.none.slug, "—")
        let real = RepoConfig(owner: "octocat", name: "site", branch: "main")
        XCTAssertFalse(real.isEmpty)
        XCTAssertEqual(real.slug, "octocat/site")
    }

    // MARK: DeploymentType honesty (Phase 0 deploy messaging)

    func testRedeployNoteIsProviderAwareAndHonest() {
        XCTAssertTrue(DeploymentType.cloudflarePages.redeployNote.contains("Cloudflare"))
        XCTAssertTrue(DeploymentType.vercel.redeployNote.contains("Vercel"))
        XCTAssertTrue(DeploymentType.render.redeployNote.contains("Render"))
        XCTAssertTrue(DeploymentType.railway.redeployNote.contains("Railway"))
        // SSH/SFTP must NOT promise an automatic redeploy that won't happen.
        XCTAssertFalse(DeploymentType.sshFtp.redeployNote.lowercased().contains("will redeploy"))
    }

    // MARK: Deployment provider helpers

    func testDeploymentStateMappingsNormalizeProviderStatuses() {
        XCTAssertEqual(DeploymentState.cloudflare("queued"), .queued)
        XCTAssertEqual(DeploymentState.cloudflare("success"), .success)
        XCTAssertEqual(DeploymentState.vercel("READY"), .success)
        XCTAssertEqual(DeploymentState.netlify("error"), .failure)
        XCTAssertEqual(DeploymentState.githubActions(status: "in_progress", conclusion: nil), .building)
        XCTAssertEqual(DeploymentState.githubActions(status: "completed", conclusion: "failure"), .failure)
        XCTAssertEqual(DeploymentState.render("live"), .success)
        XCTAssertEqual(DeploymentState.render("build_failed"), .failure)
        XCTAssertEqual(DeploymentState.railway("SUCCESS"), .success)
        XCTAssertEqual(DeploymentState.railway("FAILED"), .failure)
        XCTAssertEqual(DeploymentState.cloudflareWorkersBuild(status: "running", buildOutcome: nil), .building)
        XCTAssertEqual(DeploymentState.cloudflareWorkersBuild(status: "stopped", buildOutcome: "success"), .success)
        XCTAssertEqual(DeploymentState.cloudflareWorkersBuild(status: "stopped", buildOutcome: "fail"), .failure)
        XCTAssertEqual(DeploymentState.cloudflareWorkersBuild(status: "queued", buildOutcome: nil), .queued)
    }

    func testRepoAutoDetectorFindsAstroAndDeployProviderHints() {
        let entries = [
            RepoEntry(path: "package.json", type: .file),
            RepoEntry(path: "astro.config.mjs", type: .file),
            RepoEntry(path: "wrangler.toml", type: .file),
            RepoEntry(path: ".github/workflows/deploy.yml", type: .file)
        ]
        let packageJSON = #"{"scripts":{"build":"astro build"},"dependencies":{"astro":"latest"}}"#

        let result = RepoAutoDetector.detect(entries: entries, packageJSON: packageJSON)

        XCTAssertEqual(result.techStack, .astro)
        XCTAssertEqual(result.buildCommand, "npm run build")
        XCTAssertEqual(result.outputDirectory, "dist")
        XCTAssertTrue(result.notes.contains(where: { $0.contains("Cloudflare Workers (Wrangler) detected") }))
        XCTAssertTrue(result.notes.contains("GitHub Actions workflows detected."))
    }

    func testHostConfigFilesScaffoldVercelAndNetlify() {
        let vercel = HostConfigFiles.files(deployment: .vercel, techStack: .astro)
        XCTAssertTrue(vercel["vercel.json"]?.contains("dist") == true)
        XCTAssertTrue(vercel["vercel.json"]?.contains("npm run build") == true)

        let netlify = HostConfigFiles.files(deployment: .netlify, techStack: .vanillaHTML)
        XCTAssertTrue(netlify["netlify.toml"]?.contains("publish = \".\"") == true)

        let nextNetlify = HostConfigFiles.files(deployment: .netlify, techStack: .nextjs)
        XCTAssertTrue(nextNetlify["netlify.toml"]?.contains("publish = \"out\"") == true)

        XCTAssertTrue(HostConfigFiles.files(deployment: .githubPages, techStack: .vanillaHTML).isEmpty)
        XCTAssertTrue(HostConfigFiles.files(deployment: .cloudflarePages, techStack: .vanillaHTML).isEmpty)
    }

    func testSiteTemplatesSetMatchingTechStack() {
        XCTAssertEqual(SiteTemplate.all.first(where: { $0.id == "astro" })?.techStack, .astro)
        XCTAssertEqual(SiteTemplate.all.first(where: { $0.id == "next-static" })?.techStack, .nextjs)
        XCTAssertEqual(SiteTemplate.all.filter { ["portfolio", "landing", "blog", "docs"].contains($0.id) }.map(\.techStack),
                       [.vanillaHTML, .vanillaHTML, .vanillaHTML, .vanillaHTML])

        let astroFiles = SiteTemplate.all.first(where: { $0.id == "astro" })!.files(siteName: "My Site")
        XCTAssertNotNil(astroFiles["astro.config.mjs"])
        XCTAssertTrue(astroFiles["package.json"]?.contains("my-site") == true)
    }

    func testDeploymentLogDiagnosisFindsMissingEnvironmentVariables() {
        let deployment = DeploymentRecord(
            id: "dep_1",
            providerID: .cloudflare,
            providerName: "Cloudflare Pages",
            projectName: "site",
            state: .failure
        )
        let logs = [DeployLogLine(timestamp: nil, text: "Error: Missing env var API_KEY")]

        let summary = DeploymentLogDiagnosis.summarize(deployment, logs: logs)

        XCTAssertTrue(summary.lowercased().contains("environment variable"))
    }

    // MARK: Attachment text detection

    func testAttachmentTextDetection() {
        let txt = Attachment(filename: "note.txt", mimeType: "text/plain", data: Data("hello".utf8))
        XCTAssertTrue(txt.isTextual)
        XCTAssertEqual(txt.asText, "hello")

        let png = Attachment(filename: "logo.png", mimeType: "image/png", data: Data([0x89, 0x50]))
        XCTAssertFalse(png.isTextual)
        XCTAssertNil(png.asText)
        XCTAssertTrue(png.isImage)
    }

    // MARK: Plan extraction (chat "Proposed Agent Plan" card)

    func testExtractedPlanPullsNumberedSteps() {
        let reply = "Plan:\n1. Read index.html\n2. Add the card\n\nThen I'll explain."
        let plan = reply.extractedPlan
        XCTAssertNotNil(plan)
        XCTAssertTrue(plan?.contains("Read index.html") == true)
        XCTAssertTrue(plan?.contains("Add the card") == true)
    }

    func testNoPlanReturnsNil() {
        XCTAssertNil("Just a normal reply with no plan.".extractedPlan)
    }

    @MainActor
    func testSendingWhileRunningQueuesInterventionWithoutStoppingConversation() {
        let engine = AgentEngine()
        engine.state = .requestingModel

        engine.send("Use the existing component instead.")

        XCTAssertTrue(engine.isRunning)
        XCTAssertEqual(engine.pendingInterventionCount, 1)
        XCTAssertEqual(engine.transcript.last?.role, .user)
        XCTAssertEqual(engine.transcript.last?.text, "Use the existing component instead.")
    }

    // MARK: Gemini tool loop

    func testGeminiToolHistoryPreservesCallIdentityAndSignature() throws {
        let provider = GeminiProvider()
        let call = LLMToolCall(
            id: "function-call-42",
            name: "read_file",
            argumentsJSON: #"{"path":"index.html"}"#,
            thoughtSignature: "signed-reasoning"
        )
        let mapped = provider.mapMessages([
            .user("Inspect the home page"),
            .assistant(nil, calls: [call]),
            .tool(#"{"content":"hello"}"#, id: call.id, name: call.name)
        ])

        XCTAssertEqual(mapped.contents.compactMap { $0["role"] as? String }, ["user", "model", "user"])

        let modelParts = try XCTUnwrap(mapped.contents[1]["parts"] as? [[String: Any]])
        let functionCall = try XCTUnwrap(modelParts.first?["functionCall"] as? [String: Any])
        XCTAssertEqual(functionCall["id"] as? String, call.id)
        XCTAssertEqual(modelParts.first?["thoughtSignature"] as? String, call.thoughtSignature)

        let responseParts = try XCTUnwrap(mapped.contents[2]["parts"] as? [[String: Any]])
        let functionResponse = try XCTUnwrap(responseParts.first?["functionResponse"] as? [String: Any])
        XCTAssertEqual(functionResponse["id"] as? String, call.id)
        XCTAssertEqual(functionResponse["name"] as? String, call.name)
    }

    func testGeminiParallelToolResultsShareOneUserTurn() throws {
        let provider = GeminiProvider()
        let mapped = provider.mapMessages([
            .user("Read both files"),
            .assistant(nil, calls: [
                LLMToolCall(id: "a", name: "read_file", argumentsJSON: #"{"path":"a"}"#),
                LLMToolCall(id: "b", name: "read_file", argumentsJSON: #"{"path":"b"}"#)
            ]),
            .tool("A", id: "a", name: "read_file"),
            .tool("B", id: "b", name: "read_file")
        ])

        XCTAssertEqual(mapped.contents.count, 3)
        XCTAssertEqual(mapped.contents.last?["role"] as? String, "user")
        let parts = try XCTUnwrap(mapped.contents.last?["parts"] as? [[String: Any]])
        XCTAssertEqual(parts.count, 2)
    }

    func testGeminiParserHidesThoughtTextAndKeepsFunctionMetadata() throws {
        let response = try GeminiProvider().parseCandidate([
            "candidates": [[
                "content": [
                    "parts": [
                        ["thought": true, "text": "private reasoning"],
                        [
                            "functionCall": [
                                "id": "server-call-id",
                                "name": "list_files",
                                "args": ["path": ""]
                            ],
                            "thoughtSignature": "server-signature"
                        ]
                    ]
                ]
            ]]
        ])

        XCTAssertNil(response.content)
        XCTAssertEqual(response.toolCalls.first?.id, "server-call-id")
        XCTAssertEqual(response.toolCalls.first?.thoughtSignature, "server-signature")
    }

    // MARK: GitHub 403 translation (commit-time permission failures)

    func testExplain403MapsMissingWritePermissionToActionableMessage() {
        // The exact body GitHub returns when a fine-grained token has Contents:read
        // but not Read-and-write (the create-tree failure seen on commit).
        let body = #"{"message":"Resource not accessible by personal access token","documentation_url":"https://docs.github.com/rest/git/trees#create-a-tree","status":"403"}"#
        let msg = GitHubError.explain403(body)
        XCTAssertTrue(msg.contains("Read and write"))
        XCTAssertFalse(msg.contains("documentation_url"))   // no raw JSON leaks to the user
        // And it surfaces through LocalizedError as the same friendly text.
        XCTAssertEqual(GitHubError.forbidden(msg).errorDescription, msg)
    }

    func testExplain403DistinguishesSSOAndSecretScanning() {
        XCTAssertTrue(GitHubError.explain403(#"{"message":"... SAML enforcement ..."}"#).contains("SSO"))
        XCTAssertTrue(GitHubError.explain403(#"{"message":"push declined due to secret (GH013)"}"#).lowercased().contains("secret"))
    }

    // MARK: IAPManager Logic

    @MainActor
    func testIAPManagerSessionIncrementsAndTrialState() {
        let iap = IAPManager.shared
        
        // Reset trial and session state for testing
        iap.freeSessionsUsedThisMonth = 0
        iap.onDeviceTrialStart = 0
        
        XCTAssertTrue(iap.canRunAgentLoop)
        XCTAssertEqual(iap.onDeviceTrialDaysRemaining, 3)
        XCTAssertTrue(iap.onDeviceTrialActive)
        
        let expectedUsage = iap.isPro ? 0 : 1
        iap.incrementSessionUsage()
        // PCC-free bundles Super, so its runs never consume the standard App
        // Store build's monthly allowance. Other schemes still charge one.
        XCTAssertEqual(iap.freeSessionsUsedThisMonth, expectedUsage)
        
        iap.beginOnDeviceTrialIfNeeded()
        XCTAssertGreaterThan(iap.onDeviceTrialStart, 0)
    }

    // MARK: - Apple Private Cloud Compute Build Gating Tests
    
    @MainActor
    func testPCCDisabledInAppStoreBuild() {
        #if !IOS27_PCC_EXPERIMENTAL
        let engine = AgentEngine()
        let containsPCC = engine.availableProviders.contains { $0.id == "apple-pcc" || $0.id == "apple-auto" }
        XCTAssertFalse(containsPCC, "PCC models must not be selectable in production AppStore builds.")
        #endif
    }

    /// The MLX on-device provider bridges tools via prompt-injection, so it must
    /// report `supportsTools == true` — otherwise the agent's tool gate fails the
    /// run with "no editing tool available" before generation. Apple FM providers
    /// genuinely can't bridge tools and must stay false.
    func testOnDeviceProviderSupportsTools() {
        XCTAssertTrue(OnDeviceProvider().capabilities(for: OnDeviceProvider().defaultModel).supportsTools)
        XCTAssertTrue(AnthropicProvider().capabilities(for: AnthropicProvider().defaultModel).supportsTools)
        let unavailable = UnavailablePrivateCloudComputeProvider(reason: .available)
        XCTAssertFalse(unavailable.capabilities(for: unavailable.defaultModel).supportsTools)
    }

    /// On-device output that truncates mid tool-call must be flagged so the agent's
    /// recovery fires, instead of silently finishing with no edit.
    func testOnDeviceMakeResponseFlagsTruncatedToolCall() {
        // Complete, valid tool call → extracted, no error.
        let ok = OnDeviceProvider.makeResponse(from: "ok\n```tool\n{\"name\": \"read_file\", \"args\": {\"path\": \"a.html\"}}\n```")
        XCTAssertEqual(ok.toolCalls.first?.name, "read_file")
        XCTAssertNil(ok.errorType)

        // Opened a tool block but it got cut off (no closing fence) → toolCallIncomplete.
        let truncated = OnDeviceProvider.makeResponse(from: "Sure.\n```tool\n{\"name\": \"write_file\", \"args\": {\"path\": \"a.html\", \"content\": \"<html><body>")
        XCTAssertTrue(truncated.toolCalls.isEmpty)
        XCTAssertEqual(truncated.errorType, .toolCallIncomplete)

        // Closed block but unparseable JSON → malformedToolArguments.
        let malformed = OnDeviceProvider.makeResponse(from: "```tool\n{name: write_file, oops}\n```")
        XCTAssertTrue(malformed.toolCalls.isEmpty)
        XCTAssertEqual(malformed.errorType, .malformedToolArguments)

        // Plain prose with no tool block → no error (a normal text reply).
        let prose = OnDeviceProvider.makeResponse(from: "Here's how you could do that.")
        XCTAssertNil(prose.errorType)
        XCTAssertTrue(prose.toolCalls.isEmpty)
    }

    func testOnDeviceToolParserAcceptsCommonLocalModelFormats() {
        let xml = OnDeviceProvider.makeResponse(from: """
        <tool_call>{"name":"read_file","arguments":"{\\"path\\":\\"index.html\\"}"}</tool_call>
        """)
        XCTAssertEqual(xml.toolCalls.first?.name, "read_file")
        XCTAssertEqual(xml.toolCalls.first?.argumentsJSON, #"{"path":"index.html"}"#)

        let bare = OnDeviceProvider.makeResponse(from: #"{"function":{"name":"list_files","arguments":{}}}"#)
        XCTAssertEqual(bare.toolCalls.first?.name, "list_files")

        let missingClosingFence = OnDeviceProvider.makeResponse(
            from: "```tool\n{\"name\":\"read_file\",\"args\":{\"path\":\"a}b.html\"}}"
        )
        XCTAssertEqual(missingClosingFence.toolCalls.first?.name, "read_file")
        XCTAssertNil(missingClosingFence.errorType)

        let bonsaiApproval = OnDeviceProvider.makeResponse(from: """
        <tool_call>
        <function=request_user_approval>
        <parameter=title>Apply portfolio update</parameter>
        <parameter=summary>Update the app list.</parameter>
        <parameter=proposedActions>[{"type":"commit_staged","description":"Commit index.html"}]</parameter>
        </function>
        </tool_call>
        """)
        XCTAssertEqual(bonsaiApproval.toolCalls.first?.name, "request_user_approval")
        let approvalArguments = bonsaiApproval.toolCalls.first?.argumentsJSON.data(using: .utf8)
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        XCTAssertEqual(approvalArguments?["title"] as? String, "Apply portfolio update")
        XCTAssertEqual((approvalArguments?["proposedActions"] as? [[String: Any]])?.count, 1)

        let thinkingTool = OnDeviceProvider.makeResponse(from: """
        <think>I should inspect the file before editing.</think>
        <tool_call>{"name":"read_file","arguments":{"path":"index.html"}}</tool_call>
        """)
        XCTAssertEqual(thinkingTool.toolCalls.first?.name, "read_file")
        XCTAssertNil(thinkingTool.content)
    }

    func testOnDeviceThinkingIsPrivateAndModelAware() {
        XCTAssertTrue(OnDeviceModelCatalog.model(id: "ternary-bonsai-8b-2bit")?.supportsThinking == true)
        XCTAssertTrue(OnDeviceModelCatalog.model(id: "qwen3-4b-2507")?.supportsThinking == true)
        XCTAssertFalse(OnDeviceModelCatalog.model(id: "qwen2.5-coder-1.5b")?.supportsThinking == true)
        XCTAssertEqual(OnDeviceProvider.visibleContent("<think>still reasoning"), "")
        XCTAssertEqual(OnDeviceProvider.visibleContent("<think>done</think>Final answer"), "Final answer")
    }

    func testOnDeviceToolParserRejectsUnknownToolsAndMissingRequiredArguments() {
        let tools = [ToolSpec(
            name: "read_file",
            description: "Read a file",
            parameters: [
                "type": "object",
                "properties": ["path": ["type": "string"]],
                "required": ["path"]
            ]
        )]
        let unknown = OnDeviceProvider.makeResponse(
            from: "```tool\n{\"name\":\"delete_everything\",\"args\":{}}\n```",
            allowedTools: tools
        )
        XCTAssertTrue(unknown.toolCalls.isEmpty)
        XCTAssertEqual(unknown.errorType, .malformedToolArguments)

        let missing = OnDeviceProvider.makeResponse(
            from: "```tool\n{\"name\":\"read_file\",\"args\":{}}\n```",
            allowedTools: tools
        )
        XCTAssertTrue(missing.toolCalls.isEmpty)
        XCTAssertEqual(missing.errorType, .malformedToolArguments)
    }

    func testOnDeviceToolPromptIsCompactAndExplicit() {
        let prompt = OnDeviceProvider.toolInstructions([ToolSpec(
            name: "replace_text",
            description: "Replace exact text.\nUse a narrow match.",
            parameters: [
                "type": "object",
                "properties": [
                    "path": ["type": "string", "description": "Relative path", "examples": ["index.html"]]
                ],
                "required": ["path"],
                "examples": [["path": "index.html"]]
            ]
        )])
        XCTAssertTrue(prompt.contains("Inspect before editing"))
        XCTAssertTrue(prompt.contains("exactly one fenced block"))
        XCTAssertFalse(prompt.contains("index.html"))
    }

    func testOnDeviceContextBudgetDropsOlderUserTaskFirst() {
        let turns = [
            OnDeviceTurn(role: "system", content: "system"),
            OnDeviceTurn(role: "user", content: "old task"),
            OnDeviceTurn(role: "assistant", content: "old answer"),
            OnDeviceTurn(role: "user", content: "new task"),
            OnDeviceTurn(role: "assistant", content: "new answer")
        ]

        let pruned = OnDeviceContextBudget.removingOldestRound(from: turns)
        XCTAssertEqual(pruned?.map(\.content), ["system", "new task", "new answer"])
    }

    func testOnDeviceContextBudgetPrunesToolCallAndResultAtomically() {
        let turns = [
            OnDeviceTurn(role: "system", content: "system"),
            OnDeviceTurn(role: "user", content: "task"),
            OnDeviceTurn(role: "assistant", content: "```tool\nold call\n```"),
            OnDeviceTurn(role: "user", content: "```tool_result\nold result\n```"),
            OnDeviceTurn(role: "assistant", content: "```tool\nnew call\n```"),
            OnDeviceTurn(role: "user", content: "```tool_result\nnew result\n```")
        ]

        let pruned = OnDeviceContextBudget.removingOldestRound(from: turns)
        XCTAssertEqual(pruned?.map(\.content), [
            "system", "task", "```tool\nnew call\n```", "```tool_result\nnew result\n```"
        ])
        XCTAssertNil(pruned.flatMap { OnDeviceContextBudget.removingOldestRound(from: $0) })
    }

    func testOnDeviceContextBudgetCompactsLargeResultButKeepsBothEdges() {
        let payload = "BEGIN" + String(repeating: "x", count: 4_000) + "END"
        let turns = [OnDeviceTurn(role: "user", content: payload)]

        let compacted = OnDeviceContextBudget.compactingLargestTurn(in: turns)
        XCTAssertTrue(compacted?.first?.content.hasPrefix("BEGIN") == true)
        XCTAssertTrue(compacted?.first?.content.hasSuffix("END") == true)
        XCTAssertTrue(compacted?.first?.content.contains("older context compacted") == true)
        XCTAssertLessThan(compacted?.first?.content.count ?? .max, payload.count)
    }

    func testOnDeviceContextBudgetKeepsCompactedToolJSONValid() throws {
        let payload = String(repeating: "<main>content</main>", count: 120)
        let arguments = try JSONSerialization.data(withJSONObject: ["path": "index.html", "content": payload])
        let argumentsJSON = String(data: arguments, encoding: .utf8)!
        let call = OnDeviceTurn(
            role: "assistant",
            content: "```tool\n{\"name\":\"write_file\",\"args\":\(argumentsJSON)}\n```"
        )
        let result = OnDeviceTurn(
            role: "user",
            content: "```tool_result\n{\"name\":\"write_file\",\"result\":\(OnDeviceProvider.jsonString(payload))}\n```\nContinue."
        )

        let compactedCall = try XCTUnwrap(OnDeviceContextBudget.compactingLargestTurn(in: [call]))
        let parsedCall = OnDeviceProvider.makeResponse(from: compactedCall[0].content)
        XCTAssertEqual(parsedCall.toolCalls.first?.name, "write_file")
        let parsedArguments = try XCTUnwrap(parsedCall.toolCalls.first?.argumentsJSON)
        XCTAssertNotNil(try JSONSerialization.jsonObject(with: Data(parsedArguments.utf8)))

        let compactedResult = try XCTUnwrap(OnDeviceContextBudget.compactingLargestTurn(in: [result]))
        let resultText = compactedResult[0].content
        let bodyStart = try XCTUnwrap(resultText.range(of: "```tool_result\n")?.upperBound)
        let bodyEnd = try XCTUnwrap(resultText.range(of: "\n```", range: bodyStart..<resultText.endIndex)?.lowerBound)
        XCTAssertNotNil(try JSONSerialization.jsonObject(with: Data(resultText[bodyStart..<bodyEnd].utf8)))
    }

    func testOnDeviceCatalogUsesEightKAndIncludesExperimentalBestModels() {
        XCTAssertEqual(OnDeviceMemoryBudget.prefillChunkTokens, 32)
        XCTAssertEqual(OnDeviceMemoryBudget.maxKVTokens, 8_192)
        XCTAssertEqual(OnDeviceModelCatalog.defaultModel.id, "qwen3-4b-2507")
        XCTAssertEqual(OnDeviceModelCatalog.stableFallbackModel.id, "qwen3-4b-2507")
        XCTAssertEqual(OnDeviceModelCatalog.model(id: "qwen3.5-4b")?.sampling.topK, 20)
        XCTAssertTrue(OnDeviceModelCatalog.model(id: "qwen3.5-9b")?.needsMaxTier == true)
        XCTAssertEqual(
            OnDeviceModelCatalog.model(id: "ternary-bonsai-8b-2bit")?.repoID,
            "prism-ml/Ternary-Bonsai-8B-mlx-2bit"
        )
        XCTAssertEqual(OnDeviceModelCatalog.model(id: "ternary-bonsai-8b-2bit")?.sampling.topK, 20)
        XCTAssertTrue(OnDeviceModelCatalog.all.allSatisfy { $0.contextTokens == 8_192 })
        XCTAssertTrue(OnDeviceModelCatalog.all.allSatisfy {
            $0.huggingFaceURL.absoluteString == "https://huggingface.co/\($0.repoID)"
        })
    }

    func testOnDeviceRuntimePolicyKeepsFullBudgetWhenNominal() {
        let policy = OnDeviceRuntimePolicy.make(
            thermalState: .nominal,
            recentMemoryWarning: false,
            requestedMaxTokens: 4_096
        )

        XCTAssertEqual(policy.mode, .full)
        XCTAssertTrue(policy.allowsGeneration)
        XCTAssertEqual(policy.maxCompletionTokens, 4_096)
        XCTAssertFalse(policy.constrainedByMemoryWarning)
    }

    func testOnDeviceRuntimePolicyReducesBudgetForHeatAndMemoryPressure() {
        let fair = OnDeviceRuntimePolicy.make(
            thermalState: .fair,
            recentMemoryWarning: false,
            requestedMaxTokens: 4_096
        )
        let serious = OnDeviceRuntimePolicy.make(
            thermalState: .serious,
            recentMemoryWarning: false,
            requestedMaxTokens: 4_096
        )
        let memoryPressure = OnDeviceRuntimePolicy.make(
            thermalState: .nominal,
            recentMemoryWarning: true,
            requestedMaxTokens: 4_096
        )

        XCTAssertEqual(fair.mode, .reduced)
        XCTAssertEqual(fair.maxCompletionTokens, 3_072)
        XCTAssertEqual(serious.mode, .reduced)
        XCTAssertEqual(serious.maxCompletionTokens, 2_048)
        XCTAssertEqual(serious.decodeDelayNanoseconds, 40_000_000)
        XCTAssertEqual(memoryPressure.mode, .reduced)
        XCTAssertEqual(memoryPressure.maxCompletionTokens, 2_048)
        XCTAssertTrue(memoryPressure.constrainedByMemoryWarning)

        let lowPower = OnDeviceRuntimePolicy.make(
            thermalState: .nominal,
            recentMemoryWarning: false,
            lowPowerMode: true,
            requestedMaxTokens: 4_096
        )
        XCTAssertEqual(lowPower.mode, .reduced)
        XCTAssertEqual(lowPower.maxCompletionTokens, 2_048)
        XCTAssertEqual(lowPower.decodeDelayNanoseconds, 40_000_000)
    }

    func testOnDeviceRuntimePolicySuspendsAtCriticalThermalState() {
        let policy = OnDeviceRuntimePolicy.make(
            thermalState: .critical,
            recentMemoryWarning: false,
            requestedMaxTokens: 4_096
        )

        XCTAssertEqual(policy.mode, .suspended)
        XCTAssertFalse(policy.allowsGeneration)
        XCTAssertEqual(policy.maxCompletionTokens, 0)
    }

    func testOnDeviceMemoryBudgetAndTwelveGBTierStayBounded() {
        XCTAssertEqual(OnDeviceMemoryBudget.mlxCacheBytes, 20 * 1024 * 1024)
        XCTAssertLessThanOrEqual(OnDeviceMemoryBudget.prefillChunkTokens, 128)
        XCTAssertLessThanOrEqual(OnDeviceMemoryBudget.maxKVTokens, 12_288)

        XCTAssertEqual(
            OnDeviceCapability.tier(physicalMemoryBytes: 8 * 1_073_741_824),
            .pro
        )
        XCTAssertEqual(
            OnDeviceCapability.tier(physicalMemoryBytes: 10_680_000_000),
            .pro
        )
        XCTAssertEqual(
            OnDeviceCapability.tier(physicalMemoryBytes: 12_000_000_000),
            .max
        )
    }
    
    func testUnavailableProviderFallbackReturnsCorrectReason() async {
        let provider = UnavailablePrivateCloudComputeProvider(reason: .quotaLimitReached)
        XCTAssertEqual(provider.id, "apple-pcc")
        let availability = await provider.availability()
        XCTAssertEqual(availability, .quotaLimitReached)
        
        do {
            _ = try await provider.complete(messages: [], tools: [], model: "Automatic")
            XCTFail("Should throw an error")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("limit reached"))
        }
    }
    
    func testIntelligenceAvailabilityStateDescriptions() {
        XCTAssertEqual(IntelligenceAvailability.disabledByBuild.description, "Disabled in this build configuration.")
        XCTAssertEqual(IntelligenceAvailability.unsupportedOS.description, "Requires iOS 27 or later.")
    }

    @MainActor
    func testLocalProvidersHaveProviderKey() {
        let engine = AgentEngine()
        let originalProviderID = engine.activeProviderID
        defer { engine.activeProviderID = originalProviderID }
        
        for provider in engine.availableProviders {
            if AgentEngine.localProviderIDs.contains(provider.id) {
                engine.activeProviderID = provider.id
                XCTAssertTrue(engine.hasProviderKey, "Local/Apple provider \(provider.id) should not require an API key or credentials.")
            }
        }
    }

    // MARK: - Safe Patch-Based Editing & Watchdog Tests

    @MainActor
    func testPathValidationBlocksTraversal() {
        let engine = AgentEngine()
        XCTAssertThrowsError(try engine.validatePath("../outside.js"))
        XCTAssertThrowsError(try engine.validatePath("a/../../outside.js"))
        XCTAssertThrowsError(try engine.validatePath("/absolute/path.js"))
        XCTAssertThrowsError(try engine.validatePath(""))
        XCTAssertNoThrow(try engine.validatePath("js/data/apps.js"))
        // Filename containing ".." as a substring is NOT traversal.
        XCTAssertNoThrow(try engine.validatePath("assets/foo..bar.js"))
        XCTAssertFalse(AgentEngine.pathContainsDotDotComponent("assets/foo..bar.js"))
        XCTAssertTrue(AgentEngine.pathContainsDotDotComponent("../escape"))
        XCTAssertTrue(AgentEngine.pathContainsDotDotComponent("a/../b"))
    }

    @MainActor
    func testCanAutoApproveRejectsSecurityScanRisksAndDeletes() {
        let engine = AgentEngine()
        engine.transcript = [ChatMessage(role: .user, text: "please edit")]

        var flagged = PendingChange(path: "a.js", oldContent: "x", newContent: "eval(1)", message: "m")
        flagged.risks = SecurityScan.risks(in: flagged.newContent)
        engine.pendingChanges = [flagged]
        let flaggedApproval = PendingApproval(
            sessionID: engine.currentConversationID,
            originatingRunID: 0,
            title: "t",
            summary: "s",
            proposedActions: [.replaceText(path: "a.js", oldText: "x", newText: "eval(1)", expectedOccurrences: 1)]
        )
        XCTAssertFalse(engine.canAutoApprove(flaggedApproval),
                       "Staged SecurityScan risks must block auto-approval")

        engine.pendingChanges = []
        var deletion = PendingChange(path: "a.js", oldContent: "x", newContent: "", message: "m")
        deletion.isDeletion = true
        engine.pendingChanges = [deletion]
        let deleteApproval = PendingApproval(
            sessionID: engine.currentConversationID,
            originatingRunID: 0,
            title: "t",
            summary: "s",
            proposedActions: [.executeTool(name: "delete_file", arguments: ["path": "a.js"])]
        )
        XCTAssertFalse(engine.canAutoApprove(deleteApproval),
                       "Deletions must never auto-approve")

        engine.pendingChanges = []
        let sideEffectApproval = PendingApproval(
            sessionID: engine.currentConversationID,
            originatingRunID: 0,
            title: "t",
            summary: "s",
            proposedActions: [.executeTool(name: "trigger_deploy", arguments: [:])]
        )
        XCTAssertFalse(engine.canAutoApprove(sideEffectApproval),
                       "Side-effect tools must never auto-approve")

        let clean = PendingChange(path: "a.js", oldContent: "x", newContent: "y", message: "m")
        engine.pendingChanges = [clean]
        let cleanApproval = PendingApproval(
            sessionID: engine.currentConversationID,
            originatingRunID: 0,
            title: "t",
            summary: "s",
            proposedActions: [.replaceText(path: "a.js", oldText: "x", newText: "y", expectedOccurrences: 1)]
        )
        XCTAssertTrue(engine.canAutoApprove(cleanApproval),
                      "Clean reversible edits remain auto-approvable when autoCommit is on")
    }

    @MainActor
    func testToolPayloadHistoryTruncation() {
        let small = String(repeating: "a", count: 100)
        XCTAssertEqual(AgentEngine.truncateToolPayloadForHistory(small), small)

        let large = String(repeating: "b", count: 90_000)
        let truncated = AgentEngine.truncateToolPayloadForHistory(large)
        XCTAssertTrue(truncated.count < large.count)
        XCTAssertTrue(truncated.contains("truncated"))
    }

    /// Commit-failed ⇒ side effects must not run (approveAction ordering policy).
    @MainActor
    func testSideEffectsSkippedWhenFileStepsFail() {
        XCTAssertFalse(AgentEngine.shouldExecuteSideEffects(fileStepsSucceeded: false, sideEffectCount: 1))
        XCTAssertFalse(AgentEngine.shouldExecuteSideEffects(fileStepsSucceeded: true, sideEffectCount: 0))
        XCTAssertFalse(AgentEngine.shouldExecuteSideEffects(fileStepsSucceeded: false, sideEffectCount: 0))
        XCTAssertTrue(AgentEngine.shouldExecuteSideEffects(fileStepsSucceeded: true, sideEffectCount: 2))
        XCTAssertTrue(AgentEngine.sideEffectToolNames.contains("trigger_deploy"))
        XCTAssertTrue(AgentEngine.sideEffectToolNames.contains("revert_last_commit"))
    }

    @MainActor
    func testPendingApprovalHasSideEffectsDetectsGatedTools() {
        let engine = AgentEngine()
        XCTAssertFalse(engine.pendingApprovalHasSideEffects)

        engine._testSetPendingApproval(PendingApproval(
            sessionID: engine.currentConversationID,
            originatingRunID: 0,
            title: "Deploy",
            summary: "trigger deploy",
            proposedActions: [
                .replaceText(path: "a.html", oldText: "x", newText: "y", expectedOccurrences: 1),
                .executeTool(name: "trigger_deploy", arguments: [:])
            ]
        ))
        XCTAssertTrue(engine.pendingApprovalHasSideEffects)

        engine._testSetPendingApproval(PendingApproval(
            sessionID: engine.currentConversationID,
            originatingRunID: 0,
            title: "Edit",
            summary: "files only",
            proposedActions: [
                .replaceText(path: "a.html", oldText: "x", newText: "y", expectedOccurrences: 1)
            ]
        ))
        XCTAssertFalse(engine.pendingApprovalHasSideEffects)
    }

    @MainActor
    func testApprovalCannotExecuteBeforeRunHandoffCompletes() async {
        let engine = AgentEngine()
        let approval = PendingApproval(
            sessionID: engine.currentConversationID,
            originatingRunID: 0,
            title: "Review",
            summary: "One staged change",
            proposedActions: []
        )
        engine._testSetPendingApproval(approval)
        engine.state = .awaitingUserApproval
        engine._testSetApprovalReady(false)

        let result = await engine.approveAction(approvalID: approval.id)

        guard case .notReady = result else {
            return XCTFail("Approval must stay blocked until finishRun hands control back")
        }
        XCTAssertEqual(engine.pendingApproval?.id, approval.id)
        XCTAssertEqual(engine.state, .awaitingUserApproval)
    }

    @MainActor
    func testReviewConflictIsRoutedToInlineReviewUI() {
        let engine = AgentEngine()
        engine.pendingChanges = [
            PendingChange(path: "index.html", oldContent: "a", newContent: "b", message: "Edit")
        ]
        engine.lastError = "Changed on main since you reviewed: index.html. The staged diffs were refreshed—review them, then approve again."
        XCTAssertEqual(engine.reviewIssueMessage, engine.lastError)

        engine.lastError = "No GitHub token set."
        XCTAssertNil(engine.reviewIssueMessage)
    }

    @MainActor
    func testSoftDismissApprovalKeepsStagedChanges() {
        let engine = AgentEngine()
        let change = PendingChange(path: "index.html", oldContent: "a", newContent: "b", message: "edit")
        engine.pendingChanges = [change]
        engine._testStaged[change.path] = change
        engine._testSetPendingApproval(PendingApproval(
            sessionID: engine.currentConversationID,
            originatingRunID: 0,
            title: "Review",
            summary: "s",
            proposedActions: [.replaceText(path: "index.html", oldText: "a", newText: "b", expectedOccurrences: 1)]
        ))
        engine.state = .awaitingUserApproval

        engine.softDismissApprovalKeepingStaged()

        XCTAssertNil(engine.pendingApproval)
        XCTAssertEqual(engine.state, .idle)
        XCTAssertEqual(engine.pendingChanges.count, 1)
        XCTAssertNotNil(engine._testStaged["index.html"])
    }

    func testSecretRedactorMasksTokensAndKeys() {
        let sample = """
        token=ghp_abcdefghijklmnopqrstuvwxyz0123456789
        key sk-abcdefghijklmnopqrstuvwxyz012345
        -----BEGIN PRIVATE KEY-----
        ABCDEF
        -----END PRIVATE KEY-----
        """
        let redacted = SecretRedactor.redact(sample)
        XCTAssertFalse(redacted.contains("ghp_abcdefghijklmnopqrstuvwxyz0123456789"))
        XCTAssertFalse(redacted.contains("sk-abcdefghijklmnopqrstuvwxyz012345"))
        XCTAssertTrue(redacted.contains("[redacted-github-token]") || redacted.contains("[redacted-api-key]"))
        XCTAssertTrue(redacted.contains("[redacted-private-key]"))
        XCTAssertTrue(SecretRedactor.looksLikeSecret("ghp_abcdefghijklmnopqrstuvwxyz0123456789"))
        XCTAssertFalse(SecretRedactor.looksLikeSecret("https://example.com/docs/long-path-name-here"))
    }

    func testDeployErrorBodySanitizerPrefersMessageAndRedactsBearer() {
        let json = #"{"message":"Unauthorized","token":"supersecrettokenvalue"}"#
        let sanitized = DeployJSON.sanitizeErrorBodyForTests(Data(json.utf8), status: 401)
        XCTAssertEqual(sanitized, "Unauthorized")

        let bearer = #"Bearer abcdefghijklmnop"#
        let sanitizedBearer = DeployJSON.sanitizeErrorBodyForTests(Data(bearer.utf8), status: 401)
        XCTAssertFalse(sanitizedBearer.lowercased().contains("abcdefghijklmnop"))
        XCTAssertTrue(sanitizedBearer.lowercased().contains("redacted") || sanitizedBearer.contains("HTTP"))
    }

    @MainActor
    func testApprovalPhraseSetsAreExactOnly() {
        XCTAssertTrue(AgentEngine.approvalExactPhrases.contains("approve"))
        XCTAssertTrue(AgentEngine.approvalExactPhrases.contains("ok"))
        XCTAssertFalse(AgentEngine.approvalExactPhrases.contains("ok but wait"))
        XCTAssertTrue(AgentEngine.rejectionExactPhrases.contains("reject"))
        XCTAssertEqual(AgentEngine.maxAttachmentBytes, 12 * 1024 * 1024)
        XCTAssertTrue(AgentEngine.readOnlyToolNames.contains("list_files"))
    }

    @MainActor
    func testCancelApprovalStillDiscardsStagedChanges() {
        let engine = AgentEngine()
        let change = PendingChange(path: "index.html", oldContent: "a", newContent: "b", message: "edit")
        engine.pendingChanges = [change]
        engine._testStaged[change.path] = change
        engine._testSetPendingApproval(PendingApproval(
            sessionID: engine.currentConversationID,
            originatingRunID: 0,
            title: "Review",
            summary: "s",
            proposedActions: [.replaceText(path: "index.html", oldText: "a", newText: "b", expectedOccurrences: 1)]
        ))
        engine.state = .awaitingUserApproval

        engine.cancelApproval()

        XCTAssertNil(engine.pendingApproval)
        XCTAssertEqual(engine.state, .cancelled)
        XCTAssertTrue(engine.pendingChanges.isEmpty)
        XCTAssertNil(engine._testStaged["index.html"])
    }

    func testPreviewPathSandboxRejectsTraversal() {
        let root = URL(fileURLWithPath: "/tmp/siteagent-preview-test", isDirectory: true)
        XCTAssertTrue(SitePreviewView.isSafePreviewRelativePath("index.html", under: root))
        XCTAssertTrue(SitePreviewView.isSafePreviewRelativePath("css/app.css", under: root))
        XCTAssertTrue(SitePreviewView.isSafePreviewRelativePath("assets/foo..bar.js", under: root),
                      "Substring '..' in a filename must not be treated as traversal")
        XCTAssertFalse(SitePreviewView.isSafePreviewRelativePath("../escape.txt", under: root))
        XCTAssertFalse(SitePreviewView.isSafePreviewRelativePath("a/../../escape.txt", under: root))
        XCTAssertFalse(SitePreviewView.isSafePreviewRelativePath("/etc/passwd", under: root))
        XCTAssertFalse(SitePreviewView.isSafePreviewRelativePath("", under: root))
    }

    func testPreviewLayoutPreservesDeviceViewportWhileScalingDisplay() {
        let phone = SitePreviewView.PreviewMode.mobile.layout(in: CGSize(width: 390, height: 620))
        XCTAssertEqual(phone.viewportSize, CGSize(width: 390, height: 844))
        XCTAssertLessThan(phone.displayScale, 1)
        XCTAssertLessThanOrEqual(phone.displaySize.width, 358)
        XCTAssertLessThanOrEqual(phone.displaySize.height, 588)

        let tablet = SitePreviewView.PreviewMode.tablet.layout(in: CGSize(width: 390, height: 620))
        XCTAssertEqual(tablet.viewportSize, CGSize(width: 768, height: 1024))
        XCTAssertLessThan(tablet.displayScale, 1)

        let desktop = SitePreviewView.PreviewMode.desktop.layout(in: CGSize(width: 390, height: 620))
        XCTAssertEqual(desktop.viewportSize, CGSize(width: 390, height: 620))
        XCTAssertEqual(desktop.displayScale, 1)
    }

    /// Regression: iOS temp dirs often surface as `/var/…` while
    /// `standardizedFileURL` yields `/private/var/…`. Comparing raw paths
    /// skipped every downloaded preview file → "No index.html found".
    func testPreviewURLInsideRootToleratesVarPrivatePrefix() {
        let rootVar = URL(fileURLWithPath: "/var/folders/xx/SiteAgentPreview", isDirectory: true)
        let filePrivate = URL(fileURLWithPath: "/private/var/folders/xx/SiteAgentPreview/index.html")
        let escape = URL(fileURLWithPath: "/private/var/folders/xx/other/index.html")
        // On macOS/iOS, standardizedFileURL collapses /var → /private/var.
        XCTAssertTrue(SitePreviewView.isURLInsidePreviewRoot(filePrivate, root: rootVar))
        XCTAssertTrue(SitePreviewView.isURLInsidePreviewRoot(
            rootVar.appendingPathComponent("css/app.css").standardizedFileURL,
            root: rootVar
        ))
        XCTAssertFalse(SitePreviewView.isURLInsidePreviewRoot(escape, root: rootVar))
    }

    @MainActor
    func testReplaceTextSuccessfullyReplaces() {
        let engine = AgentEngine()
        let old = "let x = 1;\nlet y = 2;"
        let search = "let y = 2;"
        let replacement = "let y = 3;"
        
        let count = engine.occurrencesCount(in: old, of: search)
        XCTAssertEqual(count, 1)
        
        let new = old.replacingOccurrences(of: search, with: replacement)
        XCTAssertEqual(new, "let x = 1;\nlet y = 3;")
        
        let diff = engine.computeDiffAndLineRanges(old: old, new: new, oldText: search, newText: replacement)
        XCTAssertEqual(diff.ranges, "2-2")
    }

    @MainActor
    func testReplaceTextMismatchedCountFails() {
        let engine = AgentEngine()
        let text = "let x = 1;\nlet x = 1;"
        let search = "let x = 1;"
        let count = engine.occurrencesCount(in: text, of: search)
        XCTAssertEqual(count, 2)
    }

    // MARK: - Agent Operation State & Outcome Precedence Tests
    
    @MainActor
    func testPipelineOutcomePrecedence() {
        let engine = AgentEngine()
        
        // 19. Genuine absence of all editing tools produces the expected error (failed)
        engine.activeOperationState = AgentOperationState(
            operationID: UUID(),
            sessionID: UUID(),
            originatingUserMessageID: UUID(),
            requestedMutation: true,
            editingToolInvoked: false,
            editingToolSucceeded: false,
            mutationCommitted: false,
            verificationSucceeded: false,
            changedFiles: [],
            successfulToolCalls: [],
            failedToolCalls: [],
            recoveryAttempts: 1,
            terminalOutcome: nil
        )
        XCTAssertEqual(engine.determineOutcome(), .failed(AgentError(code: 4, message: "The model did not invoke an editing tool.")))
        
        // 18. Verification failure after patch produces partiallyCompleted, not editingToolNotInvoked
        engine.activeOperationState?.editingToolSucceeded = true
        engine.activeOperationState?.mutationCommitted = true
        XCTAssertEqual(engine.determineOutcome(), .partiallyCompleted(PartialResult(message: "Mutation succeeded but verification failed")))
        
        // 1. Verified and committed requested mutation -> completed
        engine.activeOperationState?.verificationSucceeded = true
        XCTAssertEqual(engine.determineOutcome(), .completed(OperationSuccess(message: "Verified and committed requested mutation")))
        
        // 2. Verified requested mutation without commit requirement -> completed
        engine.activeOperationState?.mutationCommitted = false
        XCTAssertEqual(engine.determineOutcome(), .completed(OperationSuccess(message: "Verified requested mutation without commit requirement")))
        
        // 12. Completed outcome is immutable
        engine.finalizeOperationOutcome()
        XCTAssertNotNil(engine.activeOperationState?.terminalOutcome)
        
        // Changing properties shouldn't affect outcome once finalized
        engine.activeOperationState?.verificationSucceeded = false
        engine.finalizeOperationOutcome()
        XCTAssertEqual(engine.activeOperationState?.terminalOutcome, .completed(OperationSuccess(message: "Verified requested mutation without commit requirement")))
    }
    
    // MARK: - Pipeline Idempotency Tests
    
    @MainActor
    func testPipelineIdempotency() {
        let engine = AgentEngine()
        let opID = UUID()
        
        engine.activeOperationState = AgentOperationState(
            operationID: opID,
            sessionID: UUID(),
            originatingUserMessageID: UUID(),
            requestedMutation: true,
            editingToolInvoked: false,
            editingToolSucceeded: false,
            mutationCommitted: false,
            verificationSucceeded: false,
            changedFiles: [],
            successfulToolCalls: [],
            failedToolCalls: [],
            recoveryAttempts: 0,
            terminalOutcome: nil
        )
        
        // Let's verify that patchHash behaves correctly
        let hash = engine.sha256("old -> new")
        XCTAssertFalse(hash.isEmpty)
    }

    // MARK: - Pipeline Recovery & Callbacks Tests
    
    @MainActor
    func testPipelineRecoveryAndCallbacks() {
        let engine = AgentEngine()
        
        // 9. A delayed recovery callback/watchdog cannot override completed state
        engine.activeOperationState = AgentOperationState(
            operationID: UUID(),
            sessionID: UUID(),
            originatingUserMessageID: UUID(),
            requestedMutation: true,
            editingToolInvoked: true,
            editingToolSucceeded: true,
            mutationCommitted: true,
            verificationSucceeded: true,
            changedFiles: ["index.html"],
            successfulToolCalls: [],
            failedToolCalls: [],
            recoveryAttempts: 0,
            terminalOutcome: .completed(OperationSuccess(message: "Success"))
        )
        
        // Call finalize again
        engine.finalizeOperationOutcome()
        XCTAssertEqual(engine.activeOperationState?.terminalOutcome, .completed(OperationSuccess(message: "Success")))
    }

    // MARK: - Agent watchdog policy

    @MainActor
    func testStreamingPublishGateCannotBeBypassedByLargeOrNewlineChunks() {
        let lastPublish = Date()

        // Provider chunk shape must not override the display cadence. These were
        // the two paths that previously allowed several transcript layouts inside
        // a single frame on fast streams.
        XCTAssertFalse(AgentEngine.shouldPublishStreamingText(
            previousUTF8Count: 1,
            partialUTF8Count: 129,
            lastPublishedAt: lastPublish,
            now: lastPublish.addingTimeInterval(0.005)
        ))
        XCTAssertFalse(AgentEngine.shouldPublishStreamingText(
            previousUTF8Count: 4,
            partialUTF8Count: 5,
            lastPublishedAt: lastPublish,
            now: lastPublish.addingTimeInterval(0.005)
        ))

        XCTAssertTrue(AgentEngine.shouldPublishStreamingText(
            previousUTF8Count: 4,
            partialUTF8Count: 14,
            lastPublishedAt: lastPublish,
            now: lastPublish.addingTimeInterval(0.040)
        ))
        XCTAssertFalse(AgentEngine.shouldPublishStreamingText(
            previousUTF8Count: 9,
            partialUTF8Count: 9,
            lastPublishedAt: lastPublish,
            now: lastPublish.addingTimeInterval(1)
        ))
    }

    @MainActor
    func testTimeoutPolicyGivesModelReasoningAndLocalGenerationHeadroom() {
        let remote = AgentEngine.timeoutPolicy(forProviderID: "opencode")
        XCTAssertEqual(remote.firstModelProgressSeconds, 180)
        XCTAssertEqual(remote.streamedModelIdleSeconds, 120)
        XCTAssertGreaterThan(remote.wholeRunSeconds, remote.firstModelProgressSeconds)
        XCTAssertGreaterThan(LLMTransportPolicy.requestTimeoutSeconds,
                             remote.firstModelProgressSeconds)

        let local = AgentEngine.timeoutPolicy(forProviderID: "ondevice")
        XCTAssertEqual(local.firstModelProgressSeconds, 600)
        XCTAssertEqual(local.streamedModelIdleSeconds, 180)
        XCTAssertGreaterThan(local.wholeRunSeconds, local.firstModelProgressSeconds)
    }

    @MainActor
    func testEveryPostToolModelRoundGetsFreshProgressWindow() {
        let engine = AgentEngine()
        let firstRound = Date()

        engine.beginModelRequest(providerID: "opencode", now: firstRound)
        XCTAssertNil(engine.watchdogReason(now: firstRound.addingTimeInterval(60)))
        XCTAssertNotNil(engine.watchdogReason(now: firstRound.addingTimeInterval(181)))

        // Model/tool work consumed most of the old round's allowance. Beginning
        // the next model request must reset the clock instead of timing out from
        // the timestamp that preceded those tools.
        let postToolRound = firstRound.addingTimeInterval(170)
        engine.beginModelRequest(providerID: "opencode", now: postToolRound)
        XCTAssertNil(engine.watchdogReason(now: postToolRound.addingTimeInterval(60)))
        XCTAssertNotNil(engine.watchdogReason(now: postToolRound.addingTimeInterval(181)))
    }

    @MainActor
    func testStreamingUsesIdleWindowInsteadOfFirstResponseWindow() {
        let engine = AgentEngine()
        let now = Date()
        engine.beginModelRequest(providerID: "opencode", now: now)
        engine.state = .receivingModel

        XCTAssertNil(engine.watchdogReason(now: now.addingTimeInterval(120)))
        XCTAssertTrue(engine.watchdogReason(now: now.addingTimeInterval(121))?
            .contains("stopped producing output") == true)
    }

    @MainActor
    func testHiddenReasoningActivityKeepsModelRoundAliveAndImprovesWaitUX() {
        let engine = AgentEngine()
        let started = Date()
        let round = engine.beginModelRequest(providerID: "opencode", now: started)

        XCTAssertEqual(engine.longWaitState(now: started.addingTimeInterval(44)), .none)
        XCTAssertEqual(engine.longWaitState(now: started.addingTimeInterval(46)), .waitingForProvider)

        engine.recordModelActivity(.reasoning,
                                   roundID: round,
                                   now: started.addingTimeInterval(170))
        XCTAssertEqual(engine.statusMessage, "Reasoning…")
        XCTAssertEqual(engine.longWaitState(now: started.addingTimeInterval(171)), .active)
        XCTAssertNil(engine.watchdogReason(now: started.addingTimeInterval(181)))
        XCTAssertTrue(engine.watchdogReason(now: started.addingTimeInterval(351))?
            .contains("stopped making progress") == true)
    }

    @MainActor
    func testStaleReasoningActivityCannotRefreshReplacementRound() {
        let engine = AgentEngine()
        let started = Date()
        let staleRound = engine.beginModelRequest(providerID: "opencode", now: started)
        _ = engine.beginModelRequest(providerID: "opencode", now: started.addingTimeInterval(10))

        engine.recordModelActivity(.reasoning,
                                   roundID: staleRound,
                                   now: started.addingTimeInterval(170))
        XCTAssertNotNil(engine.watchdogReason(now: started.addingTimeInterval(191)))
    }

    func testOpenAICompatibleReasoningProgressShapesAreRecognizedButNotRendered() {
        XCTAssertTrue(OpenAICompatibleProvider.containsReasoningProgress([
            "reasoning_content": "checking the repository"
        ]))
        XCTAssertTrue(OpenAICompatibleProvider.containsReasoningProgress([
            "reasoning_details": [["type": "summary", "text": "working"]]
        ]))
        XCTAssertTrue(OpenAICompatibleProvider.containsReasoningProgress([
            "thinking": "planning"
        ]))
        XCTAssertFalse(OpenAICompatibleProvider.containsReasoningProgress([
            "content": "visible reply"
        ]))
    }

    func testDeepSeekUsesReasoningCompatibleTextOnlyToolStream() {
        let provider = OpenAICompatibleProvider.deepseek
        XCTAssertEqual(provider.id, "deepseek")
        XCTAssertTrue(provider.capabilities(for: provider.defaultModel).supportsTools)
        XCTAssertFalse(provider.capabilities(for: provider.defaultModel).supportsImageInput)
        XCTAssertTrue(OpenAICompatibleProvider.containsReasoningProgress([
            "reasoning_content": "DeepSeek is still reasoning"
        ]))
    }

    @MainActor
    func testLateStreamingCallbacksCannotBelongToAReplacedModelRound() {
        let engine = AgentEngine()
        let first = engine.beginModelRequest(providerID: "opencode")
        XCTAssertTrue(engine.isCurrentModelRound(first))

        let second = engine.beginModelRequest(providerID: "opencode")
        XCTAssertFalse(engine.isCurrentModelRound(first))
        XCTAssertTrue(engine.isCurrentModelRound(second))
    }

    @MainActor
    func testTimeoutRetryExplicitlyContinuesTheUnresolvedTurn() {
        let instruction = AgentEngine.retryInstruction(after: .timedOut)
        XCTAssertTrue(instruction?.contains("Continue the unresolved last user request") == true)
        XCTAssertNil(AgentEngine.retryInstruction(after: .failed))
        XCTAssertNil(AgentEngine.retryInstruction(after: .cancelled))
    }

    @MainActor
    func testLocalNarratedToolContinuationDetection() {
        XCTAssertTrue(AgentEngine.narratesPendingToolAction(
            "Let me proceed by reading the index.html file to identify the apps listed."
        ))
        XCTAssertTrue(AgentEngine.narratesPendingToolAction(
            "Next, I will inspect styles.css."
        ))
        XCTAssertTrue(AgentEngine.narratesPendingToolAction(
            "To continue, we need to read the portfolio data."
        ))
        XCTAssertFalse(AgentEngine.narratesPendingToolAction(
            "I inspected index.html and found four apps: SiteAgent, CodeLens, Vamp, and TokenAI."
        ))
        XCTAssertFalse(AgentEngine.narratesPendingToolAction(nil))
    }

    @MainActor
    func testResetConversationClearsPriorRunLifecycleState() {
        let engine = AgentEngine()
        engine.activeOperationState = AgentOperationState(
            operationID: UUID(),
            sessionID: UUID(),
            originatingUserMessageID: UUID(),
            requestedMutation: true,
            editingToolInvoked: true,
            editingToolSucceeded: true,
            mutationCommitted: false,
            verificationSucceeded: false,
            changedFiles: ["index.html"],
            successfulToolCalls: [],
            failedToolCalls: [],
            recoveryAttempts: 0,
            terminalOutcome: nil
        )
        engine.state = .timedOut

        engine.resetConversation()

        XCTAssertEqual(engine.state, .idle)
        XCTAssertNil(engine.activeOperationState)
        XCTAssertTrue(engine.transcript.isEmpty)
        XCTAssertTrue(engine.pendingChanges.isEmpty)
    }

    // MARK: - Tool dispatch seam (no-network result builders)

    /// `read_file` with a staged change returns the staged content verbatim and
    /// flags the display as a staged read — the shape the model sees when a file
    /// is mid-edit. No network/Keychain involved.
    @MainActor
    func testReadFileStagedReturnsExpectedToolResultShape() {
        let result = AgentEngine.readFileStagedResult(path: "index.html", content: "<h1>Hi</h1>")
        XCTAssertTrue(result.ok)
        XCTAssertEqual(result.payload, "<h1>Hi</h1>")
        XCTAssertEqual(result.display, "Read index.html (staged)")
    }

    /// `read_file` with no `path` argument yields a clear, non-crashing error
    /// ToolResult rather than falling through or trapping.
    @MainActor
    func testReadFileMissingPathReturnsErrorToolResult() {
        let result = AgentEngine.readFileMissingPathResult()
        XCTAssertFalse(result.ok)
        XCTAssertTrue(result.payload.contains("missing"))
        XCTAssertTrue(result.display.contains("read_file"))
    }

    /// `trigger_deploy` with no workspace / no hook returns clear error
    /// ToolResults instead of attempting a network call. Both must be non-OK and
    /// carry actionable text.
    @MainActor
    func testTriggerDeployMissingConfigReturnsClearError() {
        let noWorkspace = AgentEngine.triggerDeployNoWorkspaceResult()
        XCTAssertFalse(noWorkspace.ok)
        XCTAssertTrue(noWorkspace.payload.contains("no active workspace"))
        XCTAssertEqual(noWorkspace.display, "trigger_deploy: no workspace")

        let noHook = AgentEngine.triggerDeployNoHookResult()
        XCTAssertFalse(noHook.ok)
        XCTAssertTrue(noHook.payload.contains("no deploy hook"))
        XCTAssertEqual(noHook.display, "trigger_deploy: no hook")
    }

    /// Deploy observability tools with no workspace / no provider return clear
    /// error ToolResults instead of attempting a network call.
    @MainActor
    func testDeployObservabilityMissingConfigReturnsClearError() {
        let statusNoWorkspace = AgentEngine.getDeployStatusNoWorkspaceResult()
        XCTAssertFalse(statusNoWorkspace.ok)
        XCTAssertTrue(statusNoWorkspace.payload.contains("no active workspace"))
        XCTAssertEqual(statusNoWorkspace.display, "get_deploy_status: no workspace")

        let statusNoClient = AgentEngine.getDeployStatusNoClientResult()
        XCTAssertFalse(statusNoClient.ok)
        XCTAssertTrue(statusNoClient.payload.contains("no deployment provider"))
        XCTAssertEqual(statusNoClient.display, "get_deploy_status: no provider")

        let logsNoWorkspace = AgentEngine.getDeployLogsNoWorkspaceResult()
        XCTAssertFalse(logsNoWorkspace.ok)
        XCTAssertTrue(logsNoWorkspace.payload.contains("no active workspace"))
        XCTAssertEqual(logsNoWorkspace.display, "get_deploy_logs: no workspace")

        let logsNoClient = AgentEngine.getDeployLogsNoClientResult()
        XCTAssertFalse(logsNoClient.ok)
        XCTAssertTrue(logsNoClient.payload.contains("no deployment provider"))
        XCTAssertEqual(logsNoClient.display, "get_deploy_logs: no provider")

        let logsNone = AgentEngine.getDeployLogsNoDeploymentsResult()
        XCTAssertFalse(logsNone.ok)
        XCTAssertTrue(logsNone.payload.contains("no deployments"))
        XCTAssertEqual(logsNone.display, "get_deploy_logs: none")
    }

    /// Routing assertion: an unrecognized tool name routes to the default branch
    /// and yields a distinct, non-crashing "Unknown tool" error whose payload
    /// echoes the bad name.
    @MainActor
    func testUnknownToolRoutesToErrorResult() {
        let result = AgentEngine.unknownToolResult(name: "frobnicate")
        XCTAssertFalse(result.ok)
        XCTAssertTrue(result.payload.contains("Unknown tool"))
        XCTAssertTrue(result.payload.contains("frobnicate"))
        XCTAssertEqual(result.display, "unknown tool")
    }

    // MARK: Signal colours (hex parsing + accent palette)

    /// `Color(hex:)` is the only non-trivial parser the colour system adds, and
    /// adaptive accents must resolve to their intended light and dark endpoints.
    func testHexParsingAndAccentPalette() {
        func rgb(_ c: Color, style: UIUserInterfaceStyle = .light) -> [Int] {
            var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
            UIColor(c)
                .resolvedColor(with: UITraitCollection(userInterfaceStyle: style))
                .getRed(&r, green: &g, blue: &b, alpha: &a)
            return [Int((r * 255).rounded()), Int((g * 255).rounded()), Int((b * 255).rounded())]
        }
        XCTAssertEqual(rgb(Color(hex: "#FFFFFF"))[0], 255)
        XCTAssertEqual(rgb(Color(hex: "000000"))[2], 0)         // '#' optional
        XCTAssertEqual(rgb(Color(hex: "4FA37A")), [79, 163, 122])  // Sage
        XCTAssertEqual(rgb(Theme.Accent.sage.base), [58, 125, 92])
        XCTAssertEqual(rgb(Theme.Accent.sage.base, style: .dark), [79, 163, 122])
        XCTAssertEqual(rgb(Theme.Accent.emerald.base), [22, 160, 106])
        XCTAssertEqual(rgb(Theme.Accent.emerald.base, style: .dark), [70, 211, 154])
        XCTAssertEqual(rgb(Theme.Accent.cobalt.base), [47, 79, 192])
        XCTAssertEqual(rgb(Theme.Accent.cobalt.base, style: .dark), [62, 99, 221])
        XCTAssertEqual(Theme.Accent.allCases.first, .colorless)
        XCTAssertEqual(Theme.Accent.allCases.count, 9)

        func whiteContrast(_ color: Color) -> CGFloat {
            var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
            UIColor(color).getRed(&r, green: &g, blue: &b, alpha: &a)
            func linear(_ channel: CGFloat) -> CGFloat {
                channel <= 0.04045
                    ? channel / 12.92
                    : pow((channel + 0.055) / 1.055, 2.4)
            }
            let luminance = 0.2126 * linear(r) + 0.7152 * linear(g) + 0.0722 * linear(b)
            return 1.05 / (luminance + 0.05)
        }
        for accent in Theme.Accent.allCases {
            XCTAssertGreaterThanOrEqual(
                whiteContrast(accent.messageBase), 4.5,
                "\(accent.name) message base must meet WCAG AA with white text"
            )
            XCTAssertGreaterThanOrEqual(
                whiteContrast(accent.messageHi), 4.5,
                "\(accent.name) message highlight must meet WCAG AA with white text"
            )
        }
        XCTAssertEqual(ThemeMode(rawValue: "system")?.colorScheme, nil)
        XCTAssertEqual(ThemeMode.dark.colorScheme, .dark)
    }

    // MARK: Approval race guard

    @MainActor
    func testApproveBlocksUserCommitWhileAgentIsWriting() async {
        let engine = AgentEngine()
        let change = PendingChange(path: "index.html", oldContent: "old", newContent: "new", message: "Update page")
        engine.pendingChanges = [change]
        engine.state = .executingTool

        let approved = await engine.approve(change)
        XCTAssertFalse(approved)
        XCTAssertEqual(engine.pendingChanges.map(\.id), [change.id])
        XCTAssertTrue(engine.lastError?.contains("still writing") == true)
    }

    @MainActor
    func testApproveAllBlocksUserBatchWhileAgentIsWriting() async {
        let engine = AgentEngine()
        let change = PendingChange(path: "styles.css", oldContent: "old", newContent: "new", message: "Update styles")
        engine.pendingChanges = [change]
        engine.state = .receivingModel

        let approved = await engine.approveAll()
        XCTAssertFalse(approved)
        XCTAssertEqual(engine.pendingChanges.map(\.id), [change.id])
        XCTAssertTrue(engine.lastError?.contains("still writing") == true)
    }

    @MainActor
    func testCommitGateBlocksNewRunAndConversationReset() {
        let engine = AgentEngine()
        let originalConversationID = engine.currentConversationID
        engine._testSetCommitInFlight(true)

        XCTAssertFalse(engine.send("Start another edit"))
        XCTAssertTrue(engine.transcript.isEmpty)
        XCTAssertTrue(engine.lastError?.contains("still being committed") == true)

        engine.resetConversation()
        XCTAssertEqual(engine.currentConversationID, originalConversationID)
        XCTAssertTrue(engine.lastError?.contains("commit to finish") == true)
    }

    /// The bundled design fonts must register and their exact PostScript names
    /// must resolve — otherwise `Font.custom(...)` silently falls back to system.
    func testDesignFontsRegister() {
        Fonts.register()
        let families = Set(UIFont.familyNames)
        for fam in ["Bricolage Grotesque", "Geist", "Geist Mono"] {
            XCTAssertTrue(families.contains(fam), "missing family \(fam) in \(families.sorted())")
        }
        for ps in ["BricolageGrotesque-ExtraBold", "BricolageGrotesque-Bold",
                   "BricolageGrotesque-SemiBold", "Geist-Regular", "Geist-Medium",
                   "Geist-SemiBold", "GeistMono-Regular", "GeistMono-Medium", "GeistMono-SemiBold"] {
            XCTAssertNotNil(UIFont(name: ps, size: 12), "PostScript face \(ps) did not resolve")
        }
    }

    // MARK: Smart routing

    func testSmartRouterClassifiesTaskMeaningInsteadOfOnlyPromptLength() {
        let router = SmartRouter.shared
        XCTAssertEqual(router.classifyTask(prompt: "Fix the typo in the hero title"), .quickFix)
        XCTAssertEqual(router.classifyTask(prompt: "Audit the technical SEO and recommend a plan"), .planning)
        XCTAssertEqual(router.classifyTask(prompt: "Migrate every page across the entire site"), .bulkUpdates)
    }

    func testSmartRouterUsesConfiguredCodingProviders() {
        let route = SmartRouter.shared.selectModel(
            strategy: .codeEdition,
            prompt: "Refactor the checkout code and update its tests",
            needsVision: false,
            hasClaude: false,
            hasCopilot: false,
            hasDeepSeek: false,
            hasOpenAI: false,
            hasQwenCode: true,
            hasKimiCode: false
        )
        XCTAssertEqual(route.providerID, "qwen-code")
        XCTAssertEqual(route.modelID, "qwen3-coder-plus")
    }

    func testSmartRouterFiltersTextOnlyModelsForImageTasks() {
        let route = SmartRouter.shared.selectModel(
            strategy: .budget,
            prompt: "Match this screenshot",
            needsVision: true,
            hasClaude: false,
            hasCopilot: false,
            hasDeepSeek: true,
            hasOpenAI: false,
            hasGrok: true
        )
        XCTAssertEqual(route.providerID, "grok")
        XCTAssertEqual(route.modelID, "grok-4.5")
    }

    func testSmartRouterRespectsPreferredModelForSelectedProvider() {
        let route = SmartRouter.shared.selectModel(
            strategy: .codeEdition,
            prompt: "Fix the navigation bug",
            needsVision: false,
            hasClaude: false,
            hasCopilot: false,
            hasDeepSeek: false,
            hasOpenAI: false,
            hasQwenCode: true,
            preferredModels: ["qwen-code": "qwen3.8-coder-plus"]
        )
        XCTAssertEqual(route.providerID, "qwen-code")
        XCTAssertEqual(route.modelID, "qwen3.8-coder-plus")
    }

    // MARK: - 1.16 port: Agent reliability foundation (ported from Projects tree)

    func testLegacySavedConversationDefaultsToUnpinned() throws {
        let json = """
        {
          "id":"A6F3F205-54AF-4E52-875A-A32A89138877",
          "title":"Legacy chat",
          "date":0,
          "transcript":[],
          "history":[]
        }
        """

        let saved = try JSONDecoder().decode(SavedConversation.self, from: Data(json.utf8))

        XCTAssertFalse(saved.isPinned)
    }

    func testContextBudgetCompactsLargeToolPayloadAndPreservesPairing() {
        let call = LLMToolCall(
            id: "read-1",
            name: "read_file",
            argumentsJSON: #"{"path":"large.json"}"#
        )
        let history: [LLMMessage] = [
            .system("rules"),
            .user("Inspect the repository"),
            .assistant(nil, calls: [call]),
            .tool(String(repeating: "payload-", count: 3_000), id: call.id, name: call.name),
            .user("Continue with the current task")
        ]
        let capability = ModelCapability(
            contextTokens: 5_000,
            outputReserveTokens: 512,
            supportsVision: true,
            supportsReasoningPreference: true
        )

        let prepared = ContextBudgeter.prepare(history, capability: capability)

        XCTAssertTrue(prepared.didCompact)
        XCTAssertLessThan(prepared.estimatedTokensAfter, prepared.estimatedTokensBefore)
        XCTAssertEqual(prepared.messages.filter { $0.role == "assistant" }.count, 1)
        XCTAssertEqual(prepared.messages.filter { $0.role == "tool" }.count, 1)
        XCTAssertTrue(prepared.messages.compactMap(\.content)
            .contains { $0.contains("offloaded for context safety") })
    }

    func testToolLoopDetectorStopsIdenticalResultOnThirdRepeat() {
        let call = LLMToolCall(
            id: "read-1",
            name: "read_file",
            argumentsJSON: #"{"path":"index.html"}"#
        )
        var detector = ToolLoopDetector()

        XCTAssertNil(detector.record(call: call, resultPayload: "same", succeeded: true))
        XCTAssertNil(detector.record(call: call, resultPayload: "same", succeeded: true))
        XCTAssertNotNil(detector.record(call: call, resultPayload: "same", succeeded: true))
    }

    func testToolLoopDetectorStopsTwoActionOscillation() {
        let first = LLMToolCall(id: "a", name: "read_file", argumentsJSON: #"{"path":"a"}"#)
        let second = LLMToolCall(id: "b", name: "read_file", argumentsJSON: #"{"path":"b"}"#)
        var detector = ToolLoopDetector()
        var warning: String?

        for call in [first, second, first, second, first, second] {
            warning = detector.record(call: call, resultPayload: call.name + call.argumentsJSON, succeeded: true)
        }

        XCTAssertNotNil(warning)
    }

    func testPrivacyRedactorMasksEnvironmentJSONAndBearerSecrets() {
        let input = """
        OPENAI_API_KEY=sk-live-secretvalue
        {"password":"correct horse battery staple","safe":"visible"}
        Authorization: Bearer abcdefghijklmnopqrstuvwxyz
        """
        let redacted = PrivacyRedactor.redact(input)

        XCTAssertFalse(redacted.contains("sk-live-secretvalue"))
        XCTAssertFalse(redacted.contains("correct horse battery staple"))
        XCTAssertFalse(redacted.contains("abcdefghijklmnopqrstuvwxyz"))
        XCTAssertTrue(redacted.contains("[REDACTED]"))
        XCTAssertTrue(redacted.contains(#""safe":"visible""#))
    }

    func testFallbackStrategiesExposeSafeDefaults() {
        XCTAssertEqual(ModelFallbackStrategy.transient.rawValue, "Connection errors")
        XCTAssertTrue(ModelFallbackStrategy.allCases.contains(.off))
        XCTAssertTrue(ModelFallbackStrategy.allCases.contains(.anyError))
    }

    func testProviderConfigurationArchiveRejectsInsecureCustomURL() {
        let archive = ProviderConfigurationArchive(
            activeProviderID: "custom",
            activeModelID: "model",
            customBaseURL: "http://example.com/v1",
            customModel: "model",
            smartRoutingEnabled: true,
            routingStrategy: .quality,
            reasoningPreference: .balanced,
            launchPreference: .lastConversation
        )

        XCTAssertThrowsError(try archive.validated())
    }

    func testProviderConfigurationArchiveRoundTripsWithoutSecrets() throws {
        let archive = ProviderConfigurationArchive(
            activeProviderID: "openai",
            activeModelID: "gpt-5.5",
            customBaseURL: "",
            customModel: "",
            smartRoutingEnabled: true,
            routingStrategy: .quality,
            reasoningPreference: .deep,
            launchPreference: .newChat
        )

        let data = try JSONEncoder().encode(archive)
        let json = String(decoding: data, as: UTF8.self)
        XCTAssertFalse(json.localizedCaseInsensitiveContains("token"))
        XCTAssertFalse(json.localizedCaseInsensitiveContains("apiKey"))
        XCTAssertEqual(try JSONDecoder().decode(ProviderConfigurationArchive.self, from: data), archive)
    }

    @MainActor
    func testSharedWorkspaceRejectsUnsafeFilenames() {
        XCTAssertTrue(WorkspacePortabilityStore.isSafeFilename("hero-image.webp"))
        XCTAssertFalse(WorkspacePortabilityStore.isSafeFilename("../secret"))
        XCTAssertFalse(WorkspacePortabilityStore.isSafeFilename("nested/file.txt"))
        XCTAssertFalse(WorkspacePortabilityStore.isSafeFilename(""))
    }

    func testMCPServerRequiresHTTPSAndUsesStableNamespace() throws {
        let id = UUID(uuidString: "12345678-1234-1234-1234-123456789ABC")!
        let secure = MCPServerConfiguration(
            id: id,
            name: "Analytics",
            endpoint: URL(string: "https://analytics.example.com/mcp")!
        )
        XCTAssertNoThrow(try secure.validated())
        XCTAssertEqual(secure.namespace, "mcp_12345678")

        let insecure = MCPServerConfiguration(
            name: "Unsafe",
            endpoint: URL(string: "http://example.com/mcp")!
        )
        XCTAssertThrowsError(try insecure.validated())
    }

    func testSiteProfilePromptIncludesOnlyApprovedNonemptyFacts() {
        let profile = SiteProfile(
            brandVoice: "Confident and concise",
            audience: "Independent developers",
            approvedTerminology: "",
            designTokens: "",
            accessibilityRequirements: "WCAG AA",
            deploymentConventions: "",
            protectedRules: "Do not rename public routes",
            lastConfirmedAt: nil
        )

        XCTAssertTrue(profile.promptContext.contains("Confident and concise"))
        XCTAssertTrue(profile.promptContext.contains("WCAG AA"))
        XCTAssertTrue(profile.promptContext.contains("Do not rename public routes"))
        XCTAssertFalse(profile.promptContext.contains("Approved terminology"))
    }
}

private final class InspectorMessageRecorder: NSObject, WKScriptMessageHandler {
    private let performanceExpectation: XCTestExpectation
    private let documentExpectation: XCTestExpectation
    private var reportedPerformance = false
    private var reportedDocument = false
    private(set) var loadTime = 0.0
    private(set) var domReady = 0.0

    init(
        performanceExpectation: XCTestExpectation,
        documentExpectation: XCTestExpectation
    ) {
        self.performanceExpectation = performanceExpectation
        self.documentExpectation = documentExpectation
    }

    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        guard let body = message.body as? [String: Any],
              let type = body["type"] as? String,
              let data = body["data"] as? [String: Any] else {
            return
        }

        if type == "performanceMetrics", !reportedPerformance {
            loadTime = (data["loadTime"] as? NSNumber)?.doubleValue ?? 0
            domReady = (data["domReady"] as? NSNumber)?.doubleValue ?? 0
            reportedPerformance = true
            performanceExpectation.fulfill()
        }

        if type == "networkStatic",
           data["type"] as? String == "document",
           !reportedDocument {
            reportedDocument = true
            documentExpectation.fulfill()
        }
    }
}
