import Foundation
import XCTest

@testable import LiveTennisApi

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

/// A URLProtocol stub that replays recorded fixtures. No test touches the
/// network. Fixtures were recorded from the live API on 2026-07-24.
final class StubURLProtocol: URLProtocol {
    /// (status, headers, body) for the next request; inspected requests land
    /// in `requests`.
    nonisolated(unsafe) static var handler: ((URLRequest) -> (Int, [String: String], Data))?
    nonisolated(unsafe) static var requests: [URLRequest] = []

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = Self.handler else {
            fatalError("StubURLProtocol.handler not set")
        }
        Self.requests.append(request)
        let (status, headers, body) = handler(request)
        let response = HTTPURLResponse(
            url: request.url!, statusCode: status,
            httpVersion: "HTTP/1.1", headerFields: headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

final class LiveTennisApiClientTests: XCTestCase {
    static let key = "test-key"

    override func setUp() {
        super.setUp()
        StubURLProtocol.handler = nil
        StubURLProtocol.requests = []
    }

    func makeClient(
        apiKey: String = LiveTennisApiClientTests.key,
        authMethod: AuthMethod = .bearer,
        maxRetries: Int = 0,
        onRateLimit: (@Sendable (RateLimit) -> Void)? = nil
    ) -> LiveTennisApiClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        return LiveTennisApiClient(
            apiKey: apiKey,
            baseURL: "https://stub.invalid/api/public/v1",
            authMethod: authMethod,
            maxRetries: maxRetries,
            session: URLSession(configuration: configuration),
            onRateLimit: onRateLimit)
    }

    func fixture(_ name: String) -> Data {
        let url = Bundle.module.url(
            forResource: name, withExtension: "json", subdirectory: "Fixtures")!
        return try! Data(contentsOf: url)
    }

    func respond(status: Int = 200, headers: [String: String] = [:], body: Data) {
        StubURLProtocol.handler = { _ in
            (status, headers.merging(["Content-Type": "application/json"]) { a, _ in a }, body)
        }
    }

    // MARK: - Decoding the recorded truths

    func testDecodesLiveMatchAndSendsBearerAuth() async throws {
        respond(body: fixture("match-live"))

        let match = try await makeClient().getMatch(22313)
        XCTAssertEqual(match.id, 22313)
        XCTAssertEqual(match.status, .live)

        let score = try XCTUnwrap(match.score, "live match has a score")
        // Points are STRINGS; games are per-player growing arrays.
        XCTAssertEqual(score.points, ["30", "15"])
        XCTAssertEqual(score.games.count, 2)
        XCTAssertEqual(score.gamesForSet(0)?.p1, 4)
        XCTAssertEqual(score.gamesForSet(0)?.p2, 6)
        XCTAssertEqual(score.server, 1)

        let completeness = try XCTUnwrap(match.players?.p1?.dataCompleteness)
        XCTAssertTrue(completeness.applicable)
        XCTAssertEqual(completeness.known, 1)

        let request = try XCTUnwrap(StubURLProtocol.requests.first)
        XCTAssertEqual(
            request.value(forHTTPHeaderField: "Authorization"), "Bearer \(Self.key)")
        XCTAssertEqual(request.url?.path, "/api/public/v1/matches/22313")
    }

    func testXApiKeyAuthMethodUsesTheOtherHeader() async throws {
        respond(body: fixture("health"))

        let health = try await makeClient(authMethod: .apiKey).health()
        XCTAssertEqual(health.status, "ok")
        XCTAssertEqual(health.version, "v1")

        let request = try XCTUnwrap(StubURLProtocol.requests.first)
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-API-Key"), Self.key)
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
    }

    func testEmptyKeySendsNoCredentialsAtAll() async throws {
        respond(body: fixture("health"))

        _ = try await makeClient(apiKey: "").health()
        let request = try XCTUnwrap(StubURLProtocol.requests.first)
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
        XCTAssertNil(request.value(forHTTPHeaderField: "X-API-Key"))
    }

    func testUpcomingMatchHasNullScore() async throws {
        let page = Data(
            "{\"data\":[\(String(data: fixture("match-upcoming"), encoding: .utf8)!)],\"meta\":{\"limit\":50,\"offset\":0,\"count\":1}}"
                .utf8)
        respond(body: page)

        let result = try await makeClient().listMatches(status: .upcoming)
        XCTAssertEqual(result.data.count, 1)
        XCTAssertEqual(result.data[0].status, .upcoming)
        XCTAssertNil(result.data[0].score, "upcoming match must decode score: null")
        XCTAssertEqual(result.meta?.count, 1)
    }

    func testServerCanBeNullInsideAPresentScore() async throws {
        respond(body: fixture("match-null-server"))

        let match = try await makeClient().getMatch(21844)
        let score = try XCTUnwrap(match.score, "score is present")
        XCTAssertNil(score.server, "server must decode as nil inside a present score")
        XCTAssertNotNil(score.timestamp)
    }

    func testADeadScoreCarriesNullPointsEntries() async throws {
        // Recorded live: a completed match can carry a present score whose
        // points are [null, null] and whose games are [[], []]. The OpenAPI
        // schema types points as string items; the wire disagrees.
        respond(body: fixture("match-dead-score"))

        let match = try await makeClient().getMatch(22050)
        let score = try XCTUnwrap(match.score, "score is present")
        XCTAssertEqual(score.points, [nil, nil])
        XCTAssertNil(score.server)
        XCTAssertEqual(score.numSets, 0)
        XCTAssertEqual(score.description, "0-0", "sets fall back when games are empty")
    }

    func testDoublesTeamCompletenessIsNullWithANote() async throws {
        respond(body: fixture("match-doubles"))

        let match = try await makeClient().getMatch(20900)
        XCTAssertTrue(match.isDoubles)
        let p1 = try XCTUnwrap(match.players?.p1)
        XCTAssertTrue(p1.isDoublesTeam)
        let completeness = try XCTUnwrap(p1.dataCompleteness)
        XCTAssertNil(completeness.known, "known is NULL on a doubles team, not 0")
        XCTAssertNil(completeness.of)
        XCTAssertFalse(completeness.applicable)
        XCTAssertTrue(completeness.note?.contains("doubles team") ?? false)
        // The response tour field is opaque — "Challenger", capitalized, is real.
        XCTAssertEqual(p1.tour, "Challenger")
    }

    // MARK: - Error taxonomy

    func testAnalysisBelowUltraIsUpgradeRequiredWithTheTierNamed() async throws {
        respond(status: 403, body: fixture("error-403-analysis"))

        do {
            _ = try await makeClient().getMatchAnalysis(22313)
            XCTFail("expected upgradeRequired")
        } catch let error as LiveTennisApiError {
            guard case .upgradeRequired(let info, let tier) = error else {
                return XCTFail("expected upgradeRequired, got \(error)")
            }
            XCTAssertEqual(tier, .ultra)
            XCTAssertEqual(info.code, "upgrade_required")
            XCTAssertEqual(info.status, 403)
            XCTAssertTrue(error.description.contains("requires the ULTRA tier"))
        }
    }

    func testEventsBelowProNamesTheProTier() async throws {
        respond(status: 403, body: Data("{\"error\":\"upgrade_required\"}".utf8))

        do {
            _ = try await makeClient().listMatchEvents(matchId: 1)
            XCTFail("expected upgradeRequired")
        } catch LiveTennisApiError.upgradeRequired(_, let tier) {
            XCTAssertEqual(tier, .pro)
        }
    }

    func testABadTourIsA400WithTheAllowedList() async throws {
        respond(status: 400, body: fixture("error-400-bad-tour"))

        do {
            // The enum makes a bad tour unrepresentable client-side, so the
            // 400 path is exercised by replaying the recorded response.
            _ = try await makeClient().listMatches(tour: .atp)
            XCTFail("expected badRequest")
        } catch LiveTennisApiError.badRequest(let info, let allowed) {
            XCTAssertEqual(info.code, "bad_tour")
            XCTAssertEqual(allowed, ["atp", "challenger", "itf", "juniors", "wta"])
        }
    }

    func testA401IsUnauthorized() async throws {
        respond(status: 401, body: Data("{\"error\":\"unauthorized\"}".utf8))

        do {
            _ = try await makeClient().getPlayer(1)
            XCTFail("expected unauthorized")
        } catch let error as LiveTennisApiError {
            guard case .unauthorized = error else {
                return XCTFail("expected unauthorized, got \(error)")
            }
            XCTAssertEqual(error.statusCode, 401)
            XCTAssertEqual(error.errorCode, "unauthorized")
        }
    }

    func testA429CarriesRetryAfterAndTheEpochReset() async throws {
        respond(
            status: 429,
            headers: [
                "Retry-After": "7",
                "X-RateLimit-Limit": "30",
                "X-RateLimit-Remaining": "0",
                "X-RateLimit-Reset": "1784863621",
            ],
            body: Data("{\"error\":\"rate_limited\"}".utf8))

        do {
            _ = try await makeClient().listMatches()
            XCTFail("expected rateLimited")
        } catch LiveTennisApiError.rateLimited(let info, let retryAfter) {
            XCTAssertEqual(retryAfter, 7)
            XCTAssertEqual(info.rateLimit.remaining, 0)
            XCTAssertEqual(
                info.rateLimit.reset, Date(timeIntervalSince1970: 1_784_863_621))
        }
    }

    // MARK: - Transport policy

    func testRetriesA500ThenSucceeds() async throws {
        StubURLProtocol.handler = { _ in
            if StubURLProtocol.requests.count == 1 {
                return (500, [:], Data())
            }
            return (200, [:], Data("{\"status\":\"ok\",\"version\":\"v1\"}".utf8))
        }

        let health = try await makeClient(maxRetries: 1).health()
        XCTAssertEqual(health.status, "ok")
        XCTAssertEqual(StubURLProtocol.requests.count, 2)
    }

    func testTheRateLimitObserverSeesSuccessfulResponses() async throws {
        respond(
            headers: ["Retry-After": "60", "X-RateLimit-Remaining": "29"],
            body: fixture("health"))

        let seen = Observed()
        _ = try await makeClient(onRateLimit: { seen.append($0) }).health()

        let budgets = seen.values
        XCTAssertEqual(budgets.count, 1)
        // Retry-After on a SUCCESS merely describes the window — it must be
        // observable without being an error.
        XCTAssertEqual(budgets[0].retryAfter, 60)
        XCTAssertEqual(budgets[0].remaining, 29)
    }

    func testQueryParametersAreAllApplied() async throws {
        respond(body: Data("{\"data\":[],\"meta\":{\"count\":0}}".utf8))

        // A limit above maxLimit is clamped to 200 client-side.
        _ = try await makeClient().listMatches(
            status: .live, tour: .wta, limit: 999, offset: 10)

        let url = try XCTUnwrap(StubURLProtocol.requests.first?.url)
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let query = Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value ?? "") })
        XCTAssertEqual(query["status"], "live")
        XCTAssertEqual(query["tour"], "wta")
        XCTAssertEqual(query["limit"], "200")
        XCTAssertEqual(query["offset"], "10")
    }

    // MARK: - Pure logic

    func testTierInferenceMatchesTheFamilyTable() {
        XCTAssertEqual(requiredTier(forPath: "/matches/1/analysis"), .ultra)
        XCTAssertEqual(requiredTier(forPath: "/matches/1/events"), .pro)
        XCTAssertEqual(requiredTier(forPath: "/markets"), .pro)
        XCTAssertEqual(requiredTier(forPath: "/history/matches"), .basic)
        XCTAssertNil(requiredTier(forPath: "/matches"))
    }

    func testTiersAreOrdered() {
        XCTAssertLessThan(Tier.free, Tier.basic)
        XCTAssertLessThan(Tier.pro, Tier.ultra)
    }

    func testBackoffHonoursRetryAfterWithACap() {
        let client = makeClient()
        XCTAssertEqual(client.backoff(attempt: 0, retryAfter: 7), 7)
        XCTAssertEqual(client.backoff(attempt: 0, retryAfter: 600), 60)
        XCTAssertLessThanOrEqual(client.backoff(attempt: 30, retryAfter: nil), 10)
    }

    func testScoreDescriptionFormatsSetsAndPoints() throws {
        let json = "{\"sets\":[1,0],\"games\":[[6,3],[4,1]],\"points\":[\"40\",\"30\"],\"server\":1,\"is_tiebreak\":false}"
        let score = try JSONDecoder().decode(Score.self, from: Data(json.utf8))
        XCTAssertEqual(score.description, "6-4 3-1 (40-30)")
        XCTAssertEqual(score.numSets, 2)
    }

    func testUnknownEnumValuesDoNotFailDecoding() throws {
        let match = try JSONDecoder().decode(
            Match.self, from: Data("{\"id\":1,\"status\":\"suspended\"}".utf8))
        XCTAssertEqual(match.status, .unknown)
        let event = try JSONDecoder().decode(
            MatchEvent.self, from: Data("{\"type\":\"rain_delay\"}".utf8))
        XCTAssertEqual(event.type, .unknown)
    }
}

/// A tiny thread-safe collector for observer callbacks.
final class Observed: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [RateLimit] = []

    func append(_ value: RateLimit) {
        lock.lock()
        storage.append(value)
        lock.unlock()
    }

    var values: [RateLimit] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}
