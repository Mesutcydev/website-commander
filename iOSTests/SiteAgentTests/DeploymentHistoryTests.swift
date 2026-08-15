import XCTest
@testable import SiteAgent

final class DeploymentHistoryTests: XCTestCase {

    override func tearDown() {
        DeploymentHistoryCache.resetMemoryForTests()
        super.tearDown()
    }

    // MARK: - Error mapping

    func testMapURLErrorOffline() {
        let mapped = DeploymentClientError.map(URLError(.notConnectedToInternet))
        XCTAssertEqual(mapped, .offline)
        XCTAssertFalse(mapped.localizedDescription.contains("-1"))
    }

    func testMapURLErrorTimedOut() {
        XCTAssertEqual(DeploymentClientError.map(URLError(.timedOut)), .timedOut)
    }

    func testMapURLErrorCancelled() {
        XCTAssertEqual(DeploymentClientError.map(URLError(.cancelled)), .cancelled)
        XCTAssertTrue(DeploymentClientError.map(URLError(.cancelled)).isCancellation)
    }

    func testMapCancellationError() {
        XCTAssertEqual(DeploymentClientError.map(CancellationError()), .cancelled)
    }

    func testMapBadURL() {
        XCTAssertEqual(DeploymentClientError.map(URLError(.badURL)), .invalidURL)
    }

    func testHTTPErrorMessagesDoNotSurfaceNegativeSentinel() {
        let legacy = DeploymentClientError.http(-1, "deploy history unavailable (network)")
        let text = legacy.localizedDescription
        XCTAssertFalse(text.contains("-1"))
        XCTAssertTrue(text.contains("deploy history unavailable") || text.contains("could not be loaded"))
    }

    func testHTTP401MapsToAuthFailure() {
        let err = DeploymentClientError.fromHTTP(status: 401, body: "Unauthorized")
        XCTAssertTrue(err.isAuthenticationFailure)
        XCTAssertTrue(err.localizedDescription.lowercased().contains("authentication")
                      || err.localizedDescription.lowercased().contains("invalid"))
    }

    func testHTTP403IsAuthFailure() {
        XCTAssertTrue(DeploymentClientError.fromHTTP(status: 403, body: "nope").isAuthenticationFailure)
    }

    func testHTTP429IsTransient() {
        XCTAssertTrue(DeploymentClientError.fromHTTP(status: 429, body: "slow down").isTransient)
    }

    func testHTTP500IsTransient() {
        XCTAssertTrue(DeploymentClientError.fromHTTP(status: 500, body: "boom").isTransient)
    }

    func testDiagnosticCategoryHasNoSecrets() {
        let err = DeploymentClientError.transport(code: -1009, description: "Bearer supersecrettokenvalue failed")
        XCTAssertEqual(err.diagnosticCategory, "transport:-1009")
        XCTAssertFalse(err.diagnosticCategory.contains("supersecret"))
    }

    // MARK: - Cache fallback

    func testSuccessfulFetchCachesRecords() async throws {
        let site = "site-success-\(UUID().uuidString)"
        defer { DeploymentHistoryCache.clear(for: site) }

        let records = [Self.sampleRecord(id: "d1")]
        let result = try await DeploymentHistoryCache.withFallback(for: site) { records }
        XCTAssertEqual(result.map(\.id), ["d1"])
        XCTAssertEqual(DeploymentHistoryCache.records(for: site)?.map(\.id), ["d1"])

        let meta = DeploymentHistoryCache.consumeLastServe(for: site)
        XCTAssertFalse(meta.servedFromCache)
        XCTAssertNotNil(meta.fetchedAt)
    }

    func testEmptySuccessfulHistoryCachesEmpty() async throws {
        let site = "site-empty-\(UUID().uuidString)"
        defer { DeploymentHistoryCache.clear(for: site) }

        let result = try await DeploymentHistoryCache.withFallback(for: site) { [] }
        XCTAssertTrue(result.isEmpty)
        XCTAssertEqual(DeploymentHistoryCache.records(for: site)?.count, 0)
    }

    func testTimeoutRetainsCachedData() async throws {
        let site = "site-timeout-\(UUID().uuidString)"
        defer { DeploymentHistoryCache.clear(for: site) }

        DeploymentHistoryCache.setRecords([Self.sampleRecord(id: "cached")], for: site)

        let result = try await DeploymentHistoryCache.withFallback(for: site) {
            throw URLError(.timedOut)
        }
        XCTAssertEqual(result.map(\.id), ["cached"])
        let meta = DeploymentHistoryCache.consumeLastServe(for: site)
        XCTAssertTrue(meta.servedFromCache)
    }

    func testOfflineRetainsCachedData() async throws {
        let site = "site-offline-\(UUID().uuidString)"
        defer { DeploymentHistoryCache.clear(for: site) }

        DeploymentHistoryCache.setRecords([Self.sampleRecord(id: "offline-cache")], for: site)
        let result = try await DeploymentHistoryCache.withFallback(for: site) {
            throw URLError(.notConnectedToInternet)
        }
        XCTAssertEqual(result.first?.id, "offline-cache")
    }

    func testOfflineWithoutCacheThrowsTypedError() async {
        let site = "site-offline-miss-\(UUID().uuidString)"
        defer { DeploymentHistoryCache.clear(for: site) }

        do {
            _ = try await DeploymentHistoryCache.withFallback(for: site) {
                throw URLError(.notConnectedToInternet)
            }
            XCTFail("Expected throw")
        } catch let err as DeploymentClientError {
            XCTAssertEqual(err, .offline)
            XCTAssertFalse(err.localizedDescription.contains("-1"))
        } catch {
            XCTFail("Unexpected error \(error)")
        }
    }

    func testCancellationProducesNoCacheMutationAndRethrows() async {
        let site = "site-cancel-\(UUID().uuidString)"
        defer { DeploymentHistoryCache.clear(for: site) }

        DeploymentHistoryCache.setRecords([Self.sampleRecord(id: "keep")], for: site)
        do {
            _ = try await DeploymentHistoryCache.withFallback(for: site) {
                throw CancellationError()
            }
            XCTFail("Expected cancellation")
        } catch let err as DeploymentClientError {
            XCTAssertTrue(err.isCancellation)
        } catch {
            XCTFail("Unexpected \(error)")
        }
        XCTAssertEqual(DeploymentHistoryCache.records(for: site)?.first?.id, "keep")
    }

    func testHTTP401DoesNotReturnStaleCache() async {
        let site = "site-401-\(UUID().uuidString)"
        defer { DeploymentHistoryCache.clear(for: site) }

        DeploymentHistoryCache.setRecords([Self.sampleRecord(id: "stale")], for: site)
        do {
            _ = try await DeploymentHistoryCache.withFallback(for: site) {
                throw DeploymentClientError.fromHTTP(status: 401, body: "Unauthorized")
            }
            XCTFail("Expected auth failure")
        } catch let err as DeploymentClientError {
            XCTAssertTrue(err.isAuthenticationFailure)
        } catch {
            XCTFail("Unexpected \(error)")
        }
    }

    func testHTTP403DoesNotReturnStaleCache() async {
        let site = "site-403-\(UUID().uuidString)"
        defer { DeploymentHistoryCache.clear(for: site) }

        DeploymentHistoryCache.setRecords([Self.sampleRecord(id: "stale")], for: site)
        do {
            _ = try await DeploymentHistoryCache.withFallback(for: site) {
                throw DeploymentClientError.fromHTTP(status: 403, body: "Forbidden")
            }
            XCTFail("Expected forbidden")
        } catch let err as DeploymentClientError {
            XCTAssertTrue(err.isAuthenticationFailure)
        } catch {
            XCTFail("Unexpected \(error)")
        }
    }

    func testHTTP500FallsBackToCache() async throws {
        let site = "site-500-\(UUID().uuidString)"
        defer { DeploymentHistoryCache.clear(for: site) }

        DeploymentHistoryCache.setRecords([Self.sampleRecord(id: "from-cache")], for: site)
        let result = try await DeploymentHistoryCache.withFallback(for: site) {
            throw DeploymentClientError.fromHTTP(status: 500, body: "server")
        }
        XCTAssertEqual(result.first?.id, "from-cache")
    }

    func testCacheIsIsolatedPerSite() {
        let a = "site-a-\(UUID().uuidString)"
        let b = "site-b-\(UUID().uuidString)"
        defer {
            DeploymentHistoryCache.clear(for: a)
            DeploymentHistoryCache.clear(for: b)
        }

        DeploymentHistoryCache.setRecords([Self.sampleRecord(id: "a1")], for: a)
        DeploymentHistoryCache.setRecords([Self.sampleRecord(id: "b1")], for: b)

        XCTAssertEqual(DeploymentHistoryCache.records(for: a)?.first?.id, "a1")
        XCTAssertEqual(DeploymentHistoryCache.records(for: b)?.first?.id, "b1")
    }

    func testDiskCacheRoundTrip() {
        let site = "site-disk-\(UUID().uuidString)"
        defer { DeploymentHistoryCache.clear(for: site) }

        DeploymentHistoryCache.setRecords([Self.sampleRecord(id: "disk1")], for: site)
        DeploymentHistoryCache.resetMemoryForTests()

        let restored = DeploymentHistoryCache.records(for: site)
        XCTAssertEqual(restored?.first?.id, "disk1")
        XCTAssertNotNil(DeploymentHistoryCache.fetchedAt(for: site))
    }

    func testNoticeModelAuthUsesSettingsAction() {
        let notice = DeploymentHistoryNoticeModel.failure(
            .fromHTTP(status: 401, body: "nope"),
            hasCachedData: false
        )
        XCTAssertTrue(notice.usesSettingsAction)
        XCTAssertEqual(notice.actionTitle, "Open Settings")
    }

    func testNoticeModelStaleUsesRetry() {
        let notice = DeploymentHistoryNoticeModel.stale(fetchedAt: Date())
        XCTAssertFalse(notice.usesSettingsAction)
        XCTAssertEqual(notice.actionTitle, "Retry")
    }

    func testSanitizeErrorBodyStillRedactsBearer() {
        let bearer = #"Bearer abcdefghijklmnop"#
        let sanitized = DeployJSON.sanitizeErrorBodyForTests(Data(bearer.utf8), status: 401)
        XCTAssertFalse(sanitized.lowercased().contains("abcdefghijklmnop"))
    }

    // MARK: Helpers

    private static func sampleRecord(id: String) -> DeploymentRecord {
        DeploymentRecord(
            id: id,
            providerID: .cloudflareWorkers,
            providerName: "Cloudflare Workers",
            projectName: "website",
            state: .success,
            branch: "main",
            commitSHA: "abc1234",
            url: "https://example.com",
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            finishedAt: Date(timeIntervalSince1970: 1_700_000_060),
            message: "Worker deployment",
            logsURL: nil
        )
    }
}
