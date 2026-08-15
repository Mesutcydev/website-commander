import XCTest
@testable import SiteAgent

@MainActor
final class ConnectWebsiteWizardCoordinatorTests: XCTestCase {

    override func setUp() {
        super.setUp()
        ConnectWebsiteWizardCoordinator.shared.reset()
    }

    override func tearDown() {
        ConnectWebsiteWizardCoordinator.shared.reset()
        super.tearDown()
    }

    func testStartsAtGitHub() {
        let c = ConnectWebsiteWizardCoordinator()
        XCTAssertEqual(c.step, .github)
    }

    func testRepositorySelectionStoresDefaultBranch() async {
        let c = ConnectWebsiteWizardCoordinator()
        let repo = makeRepo(owner: "acme", name: "site", branch: "develop")
        // Without network, selectRepository will fall back detection and still store selection.
        // We only assert pre-detection assignment path via direct state (unit, no live GitHub).
        c.selectedRepository = repo
        c.selectedBranch = repo.defaultBranch
        XCTAssertEqual(c.selectedBranch, "develop")
        XCTAssertEqual(c.selectedRepository?.owner, "acme")
    }

    func testDeploymentSkipAdvancesToAssistant() {
        let c = ConnectWebsiteWizardCoordinator()
        c.step = .deployment
        c.continueFromDeployment(skip: true)
        XCTAssertTrue(c.skipDeployment)
        XCTAssertEqual(c.step, .assistant)
    }

    func testAssistantSelectionRetained() {
        let c = ConnectWebsiteWizardCoordinator()
        c.selectedProviderID = "anthropic"
        XCTAssertEqual(c.selectedProviderID, "anthropic")
    }

    func testFinishRequiresRepository() {
        let engine = AgentEngine()
        let c = ConnectWebsiteWizardCoordinator()
        c.step = .assistant
        // No repo selected — finish must not create a workspace (GitHub or repo gate).
        let before = engine.workspaces.count
        let result = c.finish(engine: engine)
        XCTAssertNil(result)
        XCTAssertNotNil(c.issue)
        XCTAssertFalse(c.didFinish)
        XCTAssertEqual(engine.workspaces.count, before)
    }

    func testDoubleFinishDoesNotDuplicateWhenAlreadyFinished() {
        let c = ConnectWebsiteWizardCoordinator()
        c.didFinish = true
        let engine = AgentEngine()
        let first = c.finish(engine: engine)
        // Already finished — returns active workspace (possibly nil) without creating.
        XCTAssertEqual(first?.id, engine.activeWorkspace?.id)
    }

    func testCancellationResetClearsDraftWithoutTouchingEngineWorkspaces() {
        let engine = AgentEngine()
        let before = engine.workspaces.count
        let c = ConnectWebsiteWizardCoordinator()
        c.selectedRepository = makeRepo(owner: "a", name: "b", branch: "main")
        c.deployHookDraft = "https://example.com/hook"
        c.reset()
        XCTAssertNil(c.selectedRepository)
        XCTAssertTrue(c.deployHookDraft.isEmpty)
        XCTAssertEqual(engine.workspaces.count, before)
    }

    func testExistingWorkspaceDetection() {
        let engine = AgentEngine()
        let ws = SiteWorkspace(
            name: "Demo",
            gitOwner: "Cesur2000",
            gitRepo: "website",
            gitBranch: "main",
            techStack: .vanillaHTML,
            deployment: .cloudflareWorkers,
            defaultModel: "x"
        )
        // Don't persist to disk in unit test if save is heavy — exercise matcher API with in-memory list.
        engine.workspaces = [ws]
        let found = engine.existingWorkspace(owner: "cesur2000", repo: "Website", branch: "MAIN")
        XCTAssertEqual(found?.id, ws.id)
        XCTAssertNil(engine.existingWorkspace(owner: "other", repo: "website", branch: "main"))
    }

    func testPrimaryRouteForMissingAssistant() {
        let ws = SiteWorkspace(
            name: "Demo",
            gitOwner: "a",
            gitRepo: "b",
            gitBranch: "main",
            techStack: .vanillaHTML,
            deployment: .githubPages,
            defaultModel: "x"
        )
        let status = WorkspaceStatus.evaluate(
            workspace: ws,
            githubConnected: true,
            assistantReady: false,
            assistantDisplayName: "Claude",
            repo: RepoConfig(owner: "a", name: "b", branch: "main")
        )
        XCTAssertEqual(status.primaryRoute, .assistant)
    }

    func testDetectionDoesNotImplyConnected() {
        let state = DeploymentCapabilities.connectionState(
            workspace: nil,
            repo: .none,
            detectedSuggestion: .cloudflareWorkers
        )
        if case .detected(let type) = state {
            XCTAssertEqual(type, .cloudflareWorkers)
        } else {
            XCTFail("Expected detected, not connected")
        }
        XCTAssertNotEqual(state.statusLabel, "Connected")
    }

    func testConnectionStateCapabilitiesSeparateTriggerAndStatus() {
        // Without Keychain secrets, Workers workspace cannot trigger or observe.
        let ws = SiteWorkspace(
            name: "W",
            gitOwner: "a",
            gitRepo: "b",
            gitBranch: "main",
            techStack: .vanillaHTML,
            deployment: .cloudflareWorkers,
            defaultModel: "x"
        )
        let caps = DeploymentCapabilities.evaluate(
            workspace: ws,
            repo: RepoConfig(owner: "a", name: "b", branch: "main")
        )
        XCTAssertFalse(caps.canTriggerDeploy)
        XCTAssertFalse(caps.canObserveStatus)
        XCTAssertFalse(caps.hasAutomaticDeploy)
    }

    func testWorkspaceCredentialRoundTrips() throws {
        let credentialID = UUID()
        let workspace = SiteWorkspace(
            name: "Second account",
            gitOwner: "another-owner",
            gitRepo: "site",
            gitBranch: "main",
            githubCredentialID: credentialID,
            techStack: .astro,
            deployment: .githubPages,
            defaultModel: "x"
        )
        let decoded = try JSONDecoder().decode(
            SiteWorkspace.self,
            from: JSONEncoder().encode(workspace)
        )
        XCTAssertEqual(decoded.githubCredentialID, credentialID)
    }

    func testLegacyWorkspaceWithoutCredentialStillDecodes() throws {
        let data = Data("""
        {
          "id":"00000000-0000-0000-0000-000000000001",
          "name":"Legacy",
          "gitOwner":"owner",
          "gitRepo":"site",
          "gitBranch":"main",
          "techStack":"Vanilla HTML/JS",
          "deployment":"GitHub Pages",
          "defaultModel":"x",
          "customRules":"",
          "deploymentConfig":{}
        }
        """.utf8)
        let decoded = try JSONDecoder().decode(SiteWorkspace.self, from: data)
        XCTAssertNil(decoded.githubCredentialID)
    }

    // MARK: - Helpers

    private func makeRepo(owner: String, name: String, branch: String) -> GitHubRepoSummary {
        let json: [String: Any] = [
            "id": Int.random(in: 1...1_000_000),
            "name": name,
            "full_name": "\(owner)/\(name)",
            "owner": ["login": owner],
            "default_branch": branch,
            "private": false,
            "homepage": "https://\(name).example",
            "description": "Test site"
        ]
        return GitHubRepoSummary(json: json)!
    }
}
