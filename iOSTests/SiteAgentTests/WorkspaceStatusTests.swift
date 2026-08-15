import XCTest
@testable import SiteAgent

final class WorkspaceStatusTests: XCTestCase {

    func testEvaluateEmptyWorkspace() {
        let status = WorkspaceStatus.evaluate(
            workspace: nil,
            githubConnected: false,
            assistantReady: false,
            assistantDisplayName: "Claude",
            repo: .none
        )
        XCTAssertFalse(status.hasWebsite)
        XCTAssertFalse(status.allGreen)
        XCTAssertFalse(status.agentReady)
        XCTAssertEqual(status.websiteDisplayName, "No website")
        XCTAssertTrue(status.statusSummary.lowercased().contains("connect"))
    }

    func testAgentReadyWithoutDeployment() {
        let ws = SiteWorkspace(
            name: "Mesut",
            gitOwner: "Cesur2000",
            gitRepo: "website",
            gitBranch: "main",
            techStack: .vanillaHTML,
            deployment: .cloudflareWorkers,
            defaultModel: "claude",
            deploymentConfig: ["liveURL": "https://mesut.uk"]
        )
        let status = WorkspaceStatus.evaluate(
            workspace: ws,
            githubConnected: true,
            assistantReady: true,
            assistantDisplayName: "Claude Sonnet",
            repo: RepoConfig(owner: "Cesur2000", name: "website", branch: "main")
        )
        XCTAssertTrue(status.hasWebsite)
        XCTAssertTrue(status.agentReady)
        XCTAssertFalse(status.deploymentReady) // no hook/token in test Keychain
        XCTAssertFalse(status.canTriggerDeploy)
        XCTAssertFalse(status.canObserveDeployStatus)
        XCTAssertEqual(status.websiteDisplayName, "mesut.uk")
        XCTAssertTrue(status.connectedPills.contains("GitHub"))
        XCTAssertTrue(status.connectedPills.contains("Claude Sonnet"))
        XCTAssertFalse(status.connectedPills.contains("Cloudflare"))
        XCTAssertEqual(status.primaryRoute, .deployment)
    }

    func testWranglerDetectionIsNotDeploymentReady() {
        let ws = SiteWorkspace(
            name: "Workers Site",
            gitOwner: "a",
            gitRepo: "b",
            gitBranch: "main",
            techStack: .vanillaHTML,
            deployment: .cloudflareWorkers,
            defaultModel: "x",
            deploymentConfig: ["cloudflareWorkerName": "website"]
        )
        // Worker name from wrangler is not a hook / token — must stay not ready.
        XCTAssertFalse(
            WorkspaceStatus.isDeploymentReady(
                workspace: ws,
                repo: RepoConfig(owner: "a", name: "b", branch: "main")
            )
        )
    }

    func testGitHubPagesReadyWithTokenAssumption() {
        // Without a real Keychain token, githubPages is not ready.
        let ws = SiteWorkspace(
            name: "Docs",
            gitOwner: "a",
            gitRepo: "b",
            gitBranch: "main",
            techStack: .jekyll,
            deployment: .githubPages,
            defaultModel: "x"
        )
        XCTAssertFalse(
            WorkspaceStatus.isDeploymentReady(
                workspace: ws,
                repo: RepoConfig(owner: "a", name: "b", branch: "main")
            )
        )
    }

    func testShortHostLabels() {
        XCTAssertEqual(WorkspaceStatus.shortHostLabel(.cloudflareWorkers), "Cloudflare")
        XCTAssertEqual(WorkspaceStatus.shortHostLabel(.vercel), "Vercel")
        XCTAssertEqual(WorkspaceStatus.shortHostLabel(.githubPages), "GitHub Pages")
    }

    // MARK: - Detector → provider

    func testWranglerSuggestsWorkers() {
        let entries = [
            RepoEntry(path: "wrangler.toml", type: .file, sha: nil, size: 10),
            RepoEntry(path: "src/index.ts", type: .file, sha: nil, size: 10)
        ]
        let result = RepoAutoDetector.detect(
            entries: entries,
            packageJSON: nil,
            wranglerTOML: "name = \"website\"\nmain = \"src/index.ts\"\n",
            homepageURL: "https://mesut.uk"
        )
        XCTAssertEqual(result.suggestedDeployment, .cloudflareWorkers)
        XCTAssertEqual(result.suggestedWorkerName, "website")
        XCTAssertEqual(result.suggestedLiveURL, "https://mesut.uk")
    }

    func testVercelJsonSuggestsVercel() {
        let entries = [RepoEntry(path: "vercel.json", type: .file, sha: nil, size: 2)]
        let result = RepoAutoDetector.detect(entries: entries, packageJSON: nil)
        XCTAssertEqual(result.suggestedDeployment, .vercel)
    }

    func testNetlifyTomlSuggestsNetlify() {
        let entries = [RepoEntry(path: "netlify.toml", type: .file, sha: nil, size: 2)]
        let result = RepoAutoDetector.detect(entries: entries, packageJSON: nil)
        XCTAssertEqual(result.suggestedDeployment, .netlify)
    }

    func testStaticSiteDefaultsToGitHubPages() {
        let entries = [RepoEntry(path: "index.html", type: .file, sha: nil, size: 20)]
        let result = RepoAutoDetector.detect(entries: entries, packageJSON: nil)
        XCTAssertEqual(result.techStack, .vanillaHTML)
        XCTAssertEqual(result.suggestedDeployment, .githubPages)
    }

    func testParseWranglerNameVariants() {
        XCTAssertEqual(RepoAutoDetector.parseWranglerName("name = \"my-worker\""), "my-worker")
        XCTAssertEqual(RepoAutoDetector.parseWranglerName("name = 'other'"), "other")
        XCTAssertEqual(RepoAutoDetector.parseWranglerName("{\"name\": \"json-worker\"}"), "json-worker")
        XCTAssertNil(RepoAutoDetector.parseWranglerName("main = \"index.js\""))
    }

    func testGitHubRepoSummaryDisplayTitlePrefersHomepage() {
        let json: [String: Any] = [
            "id": 1,
            "name": "website",
            "full_name": "Cesur2000/website",
            "default_branch": "main",
            "homepage": "https://mesut.uk/",
            "private": false,
            "owner": ["login": "Cesur2000"]
        ]
        let summary = GitHubRepoSummary(json: json)
        XCTAssertEqual(summary?.displayTitle, "mesut.uk")
    }
}
