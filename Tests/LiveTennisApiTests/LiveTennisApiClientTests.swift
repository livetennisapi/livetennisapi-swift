import Foundation
import XCTest

@testable import LiveTennisApi

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

/// A URLProtocol stub that replays recorded fixtures. No test touches the
/// network. The original fixtures were recorded from the live API on
/// 2026-07-24; the fixtures added for the 1.1.0 surface are derived from the
/// public OpenAPI contract.
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

    /// The query items of the first request the stub saw.
    func sentQueryItems() throws -> [URLQueryItem] {
        let url = try XCTUnwrap(StubURLProtocol.requests.first?.url)
        return URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
    }

    /// The first value sent for one query parameter.
    func sentQueryValue(_ name: String) throws -> String? {
        try sentQueryItems().first { $0.name == name }?.value ?? nil
    }

    // MARK: - Decoding the recorded truths

    func testDecodesLiveMatchAndSendsBearerAuth() async throws {
        respond(body: fixture("match-live"))

        let match = try await makeClient().getMatch(22313)
        XCTAssertEqual(match.id, 22313)
        XCTAssertEqual(match.status, .live)
        XCTAssertEqual(match.hasAnalysis, true, "a thesis/profile exists (added 2026-09-02)")
        XCTAssertEqual(match.hasMarket, true, "a match-winner market is mapped")

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
        XCTAssertEqual(requiredTier(forPath: "/matches/1/statistics"), .ultra)
        XCTAssertEqual(requiredTier(forPath: "/rally/matches"), .ultra)
        XCTAssertEqual(requiredTier(forPath: "/history/matches/1/rally"), .ultra)
        XCTAssertEqual(requiredTier(forPath: "/charting/players"), .ultra)
        XCTAssertEqual(requiredTier(forPath: "/ws-token"), .ultra)
        XCTAssertEqual(requiredTier(forPath: "/webhooks"), .ultra)
        XCTAssertEqual(requiredTier(forPath: "/matches/1/events"), .pro)
        XCTAssertEqual(requiredTier(forPath: "/markets"), .pro)
        XCTAssertEqual(requiredTier(forPath: "/matches/1/prices"), .pro)
        XCTAssertEqual(requiredTier(forPath: "/h2h"), .basic)
        XCTAssertEqual(requiredTier(forPath: "/history/matches"), .basic)
        XCTAssertEqual(requiredTier(forPath: "/history/archive/matches"), .basic)
        XCTAssertNil(requiredTier(forPath: "/matches"))
        // The two mode-dependent endpoints read the query.
        XCTAssertEqual(requiredTier(forPath: "/rankings"), .pro)
        XCTAssertEqual(requiredTier(forPath: "/rankings", query: [("player", "1")]), .ultra)
        XCTAssertEqual(requiredTier(forPath: "/history/packages"), .pro)
        XCTAssertEqual(
            requiredTier(forPath: "/history/packages", query: [("kind", "rankings")]), .ultra)
        XCTAssertEqual(
            requiredTier(forPath: "/history/packages", query: [("kind", "rally")]), .ultra)
        // The archive kind rides the tape entitlement, not ULTRA.
        XCTAssertEqual(
            requiredTier(forPath: "/history/packages", query: [("kind", "archive")]), .pro)
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

    // MARK: - New match fields and list filters (1.1.0)

    func testMatchCarriesTourTournamentIdRoundCodeAndWithdrew() async throws {
        let json = """
            {"id": 9, "tournament": "X Open", "tour": "wta", \
            "tournament_id": "wta-x-open", "round": "Final", "round_code": "F", \
            "status": "completed", "event_status": "Retired", \
            "event_status_updated_at": "2026-08-19T09:15:00Z", \
            "has_analysis": true, "has_market": false, \
            "is_doubles": false, "winner": 1, "withdrew": 2}
            """
        respond(body: Data(json.utf8))

        let match = try await makeClient().getMatch(9)
        XCTAssertEqual(match.tour, .wta, "Match.tour is the FILTER vocabulary")
        XCTAssertEqual(match.tournamentId, "wta-x-open")
        XCTAssertEqual(match.roundCode, "F")
        XCTAssertEqual(match.eventStatus, "Retired")
        XCTAssertEqual(match.eventStatusUpdatedAt, "2026-08-19T09:15:00Z")
        XCTAssertEqual(match.withdrew, 2, "the withdrawer is the loser")
        XCTAssertEqual(match.hasAnalysis, true)
        XCTAssertEqual(match.hasMarket, false, "present-false is a real answer: skip /prices")
    }

    // has_analysis / has_market (every tier since 2026-09-02) carry the same
    // fact the per-match analysis and prices endpoints 404 about. An older
    // server omits them, and absence must decode to nil — never to false.
    func testHasAnalysisAndHasMarketDecodeFalseAndAbsent() throws {
        let present = try JSONDecoder().decode(
            Match.self, from: Data("{\"id\":1,\"has_analysis\":false,\"has_market\":true}".utf8))
        XCTAssertEqual(present.hasAnalysis, false)
        XCTAssertEqual(present.hasMarket, true)
        let absent = try JSONDecoder().decode(
            Match.self, from: Data("{\"id\":1}".utf8))
        XCTAssertNil(absent.hasAnalysis)
        XCTAssertNil(absent.hasMarket)
    }

    // event_status_updated_at (added 2026-08-19) is never backfilled: a match
    // whose admin status has never changed since the field was introduced
    // sends null or omits it entirely, and both must decode to nil.
    func testEventStatusUpdatedAtIsNilWhenNullOrAbsent() throws {
        let nulled = try JSONDecoder().decode(
            Match.self, from: Data("{\"id\":1,\"event_status_updated_at\":null}".utf8))
        XCTAssertNil(nulled.eventStatusUpdatedAt)
        let absent = try JSONDecoder().decode(
            Match.self, from: Data("{\"id\":1}".utf8))
        XCTAssertNil(absent.eventStatusUpdatedAt)
    }

    func testAnUnstatedOrUnknownMatchTourDecodesAsNil() throws {
        let unstated = try JSONDecoder().decode(
            Match.self, from: Data("{\"id\":1,\"tour\":null}".utf8))
        XCTAssertNil(unstated.tour)
        let unknown = try JSONDecoder().decode(
            Match.self, from: Data("{\"id\":1,\"tour\":\"exhibition\"}".utf8))
        XCTAssertNil(unknown.tour, "an unknown tour value must not fail decoding")
    }

    func testNewListFiltersAreAllApplied() async throws {
        respond(body: Data("{\"data\":[],\"meta\":{\"count\":0}}".utf8))

        _ = try await makeClient().listMatches(
            status: .completed, tour: .juniors, players: [7, 8], country: "ned",
            from: "2026-08-01", to: "2026-08-07")

        let items = try sentQueryItems()
        XCTAssertEqual(
            items.filter { $0.name == "player" }.map(\.value), ["7", "8"],
            "player is a repeatable parameter")
        XCTAssertEqual(try sentQueryValue("tour"), "juniors")
        XCTAssertEqual(try sentQueryValue("country"), "ned")
        XCTAssertEqual(try sentQueryValue("from"), "2026-08-01")
        XCTAssertEqual(try sentQueryValue("to"), "2026-08-07")
    }

    func testMoreThanFiftyPlayerIdsAreClampedClientSide() async throws {
        respond(body: Data("{\"data\":[],\"meta\":{\"count\":0}}".utf8))

        _ = try await makeClient().listMatches(players: (1...60).map(Int64.init))

        let sent = try sentQueryItems().filter { $0.name == "player" }
        XCTAssertEqual(sent.count, 50, "the API accepts at most 50 ids")
        XCTAssertEqual(sent.last?.value, "50")
    }

    // MARK: - History, h2h and the archive (1.1.0)

    func testTapeCarriesPointWinnerAndPerSetTiebreaks() async throws {
        respond(body: fixture("tape-clean"))

        let tape = try await makeClient().getMatchTape(22313, sequence: .clean)
        XCTAssertEqual(try sentQueryValue("sequence"), "clean")
        XCTAssertEqual(tape.tape.count, 3)
        XCTAssertNil(tape.tape[0].pointWinner, "the first row has no attributable point")
        XCTAssertEqual(tape.tape[1].pointWinner, 1)
        XCTAssertNil(
            tape.tape[2].timestamp,
            "a null timestamp is the row-level marker of a reconstructed row")

        let tiebreaks = try XCTUnwrap(tape.tiebreaks)
        XCTAssertEqual(tiebreaks.count, 2)
        XCTAssertEqual(tiebreaks[0]?.p1, 7)
        XCTAssertEqual(tiebreaks[0]?.p2, 5)
        XCTAssertNil(tiebreaks[1], "a set with no valid terminal breaker reads nil")

        XCTAssertEqual(tape.meta?.coverage, .fromStart)
        XCTAssertEqual(tape.meta?.pointSource, "observed")
        XCTAssertEqual(tape.meta?.rawRows, 5)
        XCTAssertEqual(tape.match?.tour, .atp)
        XCTAssertEqual(tape.profiles.first?.volatilityRating, "med")
    }

    func testHeadToHeadDecodesTotalsSurfacesAndBothEras() async throws {
        respond(body: fixture("h2h"))

        let h2h = try await makeClient().getHeadToHead(p1: "djokovic", p2: "nadal")
        XCTAssertEqual(try sentQueryValue("p1"), "djokovic")
        XCTAssertEqual(try sentQueryValue("p2"), "nadal")

        XCTAssertEqual(h2h.players?.p1?.name, "Novak Djokovic")
        XCTAssertEqual(h2h.totals?.p1Wins, 30)
        XCTAssertEqual(h2h.totals?.undecided, 1, "undecided is never counted in wins")
        XCTAssertEqual(h2h.bySurface["clay"]?.p2, 20)
        XCTAssertEqual(h2h.meetings.count, 2)
        XCTAssertEqual(h2h.meetings[0].era, "current")
        XCTAssertEqual(h2h.meetings[0].matchId, 18321)
        XCTAssertEqual(h2h.meetings[0].roundCode, "R64")
        XCTAssertEqual(h2h.meetings[1].era, "archive")
        XCTAssertEqual(h2h.meetings[1].archiveMatchId, 501_223)
        XCTAssertEqual(h2h.meetings[1].score, "6-2 4-6 6-2 7-6(4)")
    }

    func testArchiveMatchDecodesWinnerLoserAndServeStats() async throws {
        respond(body: fixture("archive-match"))

        let match = try await makeClient().getArchiveMatch(812_345)
        XCTAssertEqual(match.id, 812_345)
        XCTAssertEqual(match.tour, "atp")
        XCTAssertEqual(match.level, "G")
        XCTAssertEqual(match.eventDate, "2019-07-01", "the tournament START date")
        XCTAssertEqual(match.winner?.name, "Novak Djokovic")
        XCTAssertEqual(match.winner?.rank, 1, "rank AT THE TIME, not today's")
        XCTAssertEqual(match.loser?.playerId, 103_819)
        XCTAssertEqual(match.stats?.loser?.aces, 25)
        XCTAssertEqual(match.outcome, "completed")
    }

    func testArchiveListAndPlayerFiltersAreApplied() async throws {
        respond(body: Data("{\"data\":[],\"meta\":{}}".utf8))

        _ = try await makeClient().listArchiveMatches(
            tour: .wta, name: "graf", from: "1988-01-01", to: "1988-12-31",
            round: "F", level: "G", limit: 10)

        XCTAssertEqual(try sentQueryValue("tour"), "wta")
        XCTAssertEqual(try sentQueryValue("name"), "graf")
        XCTAssertEqual(try sentQueryValue("round"), "F")
        XCTAssertEqual(try sentQueryValue("level"), "G")
        XCTAssertEqual(try sentQueryValue("limit"), "10")
        let path = try XCTUnwrap(StubURLProtocol.requests.first?.url?.path)
        XCTAssertEqual(path, "/api/public/v1/history/archive/matches")
    }

    func testArchiveCareerSumsDecode() async throws {
        let json = """
            {"player": {"name": "Steffi Graf"}, \
            "span": {"first": "1982-10-18", "last": "1999-08-02"}, \
            "record": {"wins": 900, "losses": 115, "titles": 107, \
            "by_surface": {"clay": {"wins": 250, "losses": 30}}, \
            "by_level": {"G": {"wins": 278, "losses": 32}}}, \
            "by_year": [{"year": 1988, "wins": 72, "losses": 3}], \
            "serve": {"matches_with_stats": 320, "aces": 1400, "bp_saved_pct": 61.5, \
            "aces_per_match": 4.4}}
            """
        respond(body: Data(json.utf8))

        let career = try await makeClient().getArchiveCareer(name: "graf")
        XCTAssertEqual(career.player?.name, "Steffi Graf")
        XCTAssertEqual(career.record?.titles, 107)
        XCTAssertEqual(career.record?.bySurface["clay"]?.wins, 250)
        XCTAssertEqual(career.record?.byLevel["G"]?.losses, 32)
        XCTAssertEqual(career.byYear.first?.year, 1988)
        XCTAssertEqual(career.serve?.matchesWithStats, 320)
        XCTAssertEqual(career.serve?.acesPerMatch, 4.4)
    }

    func testHistoryPackagesPassKindAndYear() async throws {
        let json = """
            {"data": [{"period": "2019-05", "status": "ready", "match_count": 3120, \
            "row_count": 6, "files": [{"format": "jsonl", \
            "filename": "rankings-2019-05.jsonl.gz", "bytes": 104857600, \
            "sha256": "deadbeef"}], "built_at": "2026-08-01T00:00:00Z", \
            "kind": "rankings"}], "meta": {"count": 1, "year": "2019"}}
            """
        respond(body: Data(json.utf8))

        let page = try await makeClient().listHistoryPackages(kind: .rankings, year: "2019")
        XCTAssertEqual(try sentQueryValue("kind"), "rankings")
        XCTAssertEqual(try sentQueryValue("year"), "2019")
        XCTAssertEqual(page.data.first?.period, "2019-05")
        XCTAssertEqual(page.data.first?.kind, "rankings")
        XCTAssertEqual(page.data.first?.files.first?.format, "jsonl")
        XCTAssertEqual(page.meta?.year, "2019")
    }

    func testPackageKindCoversTheContractVocabulary() {
        XCTAssertEqual(
            PackageKind.allCases.map(\.rawValue), ["tape", "rankings", "rally", "archive"])
    }

    func testHistoryPackagesYearlyKindSendsKindAndDecodesBareYearPeriod() async throws {
        let json = """
            {"data": [{"period": "2001", "status": "ready", "match_count": 3820, \
            "row_count": 3820, "files": [{"format": "jsonl", \
            "filename": "archive-2001.jsonl.gz", "bytes": 52428800, \
            "sha256": "cafef00d"}], "built_at": "2026-08-01T00:00:00Z", \
            "kind": "archive"}], "meta": {"count": 1}}
            """
        respond(body: Data(json.utf8))

        let page = try await makeClient().listHistoryPackages(kind: .archive)
        XCTAssertEqual(try sentQueryValue("kind"), "archive")
        XCTAssertEqual(page.data.first?.period, "2001")
        XCTAssertEqual(page.data.first?.kind, "archive")
        XCTAssertEqual(page.data.first?.files.first?.filename, "archive-2001.jsonl.gz")
    }

    func testHistoryPackageManifestForRallyKindUsesBareYearPeriod() async throws {
        let json = """
            {"period": "2019", "status": "ready", "match_count": 410, \
            "row_count": 61234, "files": [{"format": "csv", \
            "filename": "rally-2019.csv.gz", "bytes": 10485760, \
            "sha256": "feedface"}], "built_at": "2026-08-01T00:00:00Z", \
            "kind": "rally"}
            """
        respond(body: Data(json.utf8))

        let manifest = try await makeClient().getHistoryPackage(period: "2019", kind: .rally)
        let request = try XCTUnwrap(StubURLProtocol.requests.first)
        XCTAssertEqual(request.url?.path, "/api/public/v1/history/packages/2019")
        XCTAssertEqual(try sentQueryValue("kind"), "rally")
        XCTAssertEqual(manifest.period, "2019")
        XCTAssertEqual(manifest.kind, "rally")
        XCTAssertEqual(manifest.files.first?.format, "csv")
    }

    // MARK: - Rankings (1.1.0)

    func testRankingsListingModeDecodesPreviousRankAndCoverage() async throws {
        respond(body: fixture("rankings-listing"))

        let page = try await makeClient().listRankings(systems: [.atp])
        XCTAssertEqual(try sentQueryValue("system"), "atp")
        XCTAssertTrue(
            try sentQueryItems().allSatisfy { $0.name != "player" },
            "listing mode sends no player parameter")

        XCTAssertEqual(page.data.count, 2)
        XCTAssertEqual(page.data[0].rank, 1)
        XCTAssertEqual(page.data[1].previousRank, 3)
        XCTAssertNil(
            page.data[1].playerId,
            "unrostered listing rows keep a null player_id — no silent holes")
        XCTAssertEqual(page.data[1].playerName, "Unrostered Player")
        XCTAssertEqual(page.meta?.hasMore, true)
        XCTAssertEqual(page.meta?.total, 2000)
        XCTAssertEqual(page.meta?.coverage?.oldestAvailable?["atp"], "1973-08-23")
    }

    func testRankingsTierDependsOnTheMode() async throws {
        respond(status: 403, body: Data("{\"error\":\"upgrade_required\"}".utf8))

        do {
            _ = try await makeClient().listRankings(systems: [.atp])
            XCTFail("expected upgradeRequired")
        } catch LiveTennisApiError.upgradeRequired(_, let tier) {
            XCTAssertEqual(tier, .pro, "the listing mode is PRO")
        }

        do {
            _ = try await makeClient().listRankings(players: [1204], systems: [.utr])
            XCTFail("expected upgradeRequired")
        } catch LiveTennisApiError.upgradeRequired(_, let tier) {
            XCTAssertEqual(tier, .ultra, "the per-player mode is ULTRA")
        }
    }

    // MARK: - Statistics, rally, charting, push (1.1.0)

    func testStatisticsKeepMeasuredAndDerivedFamiliesApart() async throws {
        respond(body: fixture("statistics-live"))

        let stats = try await makeClient().getMatchStatistics(22313)
        XCTAssertEqual(stats.matchId, 22313)
        XCTAssertEqual(stats.coverage, .live)
        XCTAssertEqual(stats.tiebreakGamesExcluded, 1)
        XCTAssertEqual(stats.setsCovered, [1, 2])

        let p1 = try XCTUnwrap(stats.players?.p1)
        XCTAssertEqual(p1.holdPct, 89)
        XCTAssertEqual(p1.breakPointsConvertedPct, 40)
        XCTAssertEqual(p1.measured?.aces, 7)
        XCTAssertEqual(p1.measured?.firstServesInPct, 63)

        let p2 = try XCTUnwrap(stats.players?.p2)
        XCTAssertNil(
            p2.measured?.firstServesIn,
            "an absent measured field decodes as nil, never zero-filled")

        XCTAssertEqual(stats.freshness?.derived?.coverage, .live)
        XCTAssertEqual(stats.freshness?.measured?.ageSeconds, 31)
        XCTAssertEqual(stats.freshness?.derived?.describes?.totalGames, 14)
        XCTAssertNil(stats.freshness?.measuredDivergence, "nil when the families agree")
    }

    func testRallyTapeDecodesPointsAndShots() async throws {
        respond(body: fixture("rally-match"))

        let tape = try await makeClient().getRallyMatch(9012, limit: 2)
        XCTAssertEqual(tape.match.rallyMatchId, 9012)
        XCTAssertNil(
            tape.match.matchId, "most charted matches predate our own collection")
        XCTAssertEqual(tape.match.pointsParsed, 209)
        XCTAssertEqual(tape.rally.count, 2)
        XCTAssertEqual(tape.rally[0].pointWinner, 2)
        XCTAssertEqual(tape.rally[0].outcome, "unforced_error")
        XCTAssertEqual(tape.rally[0].shots.count, 3)
        XCTAssertEqual(tape.rally[0].shots[1].wing, "forehand")
        XCTAssertTrue(tape.rally[1].isAce)
        XCTAssertEqual(tape.rally[1].rallyLength, 1, "an ace is 1 stroke")
        XCTAssertEqual(tape.meta?.total, 214, "meta.total is the full point count")
    }

    func testMatchRallyUsesOurMatchIdRoute() async throws {
        respond(body: fixture("rally-match"))

        _ = try await makeClient().getMatchRally(matchId: 22313)
        let path = try XCTUnwrap(StubURLProtocol.requests.first?.url?.path)
        XCTAssertEqual(path, "/api/public/v1/history/matches/22313/rally")
    }

    func testChartingPlayerKeepsUnpinnedFamiliesDecodable() async throws {
        let json = """
            {"player": {"name": "Iga Swiatek"}, "matches_charted": 128, \
            "coverage": "curated", \
            "families": {"serve_direction": {"deuce_wide": 412}}}
            """
        respond(body: Data(json.utf8))

        let player = try await makeClient().getChartingPlayer(name: "swiatek", gender: .women)
        XCTAssertEqual(try sentQueryValue("gender"), "women")
        XCTAssertEqual(player.matchesCharted, 128)
        guard case .object(let families)? = player.families,
            case .object(let serve)? = families["serve_direction"],
            case .number(let value)? = serve["deuce_wide"]
        else {
            return XCTFail("families must stay decodable as unpinned JSON")
        }
        XCTAssertEqual(value, 412)
    }

    func testWsTokenCarriesUrlAndSlateAllChannel() async throws {
        respond(body: fixture("ws-token"))

        let token = try await makeClient().getWsToken()
        XCTAssertFalse(token.token.isEmpty)
        XCTAssertEqual(token.expiresIn, 300)
        XCTAssertEqual(token.wsUrl, "wss://api.livetennisapi.com/connection/websocket")
        XCTAssertEqual(token.channels?.match, "match:{id}")
        XCTAssertEqual(token.channels?.slate, "slate:all")
    }

    // MARK: - New 429 shapes (1.1.0)

    func testADaily429SurfacesResetsAt() async throws {
        respond(
            status: 429,
            headers: ["Retry-After": "25200"],
            body: Data(
                "{\"error\":\"rate_limited\",\"limit_per_day\":100,\"scope\":\"day\",\"resets_at\":\"2026-08-07T21:00:00Z\"}"
                    .utf8))

        do {
            _ = try await makeClient().listMatches()
            XCTFail("expected rateLimited")
        } catch let error as LiveTennisApiError {
            guard case .rateLimited = error else {
                return XCTFail("expected rateLimited, got \(error)")
            }
            XCTAssertEqual(error.resetsAt, "2026-08-07T21:00:00Z")
            XCTAssertTrue(error.description.contains("2026-08-07T21:00:00Z"))
        }
    }

    func testAMinute429HasNoResetsAt() async throws {
        respond(status: 429, body: Data("{\"error\":\"rate_limited\"}".utf8))

        do {
            _ = try await makeClient().listMatches()
            XCTFail("expected rateLimited")
        } catch let error as LiveTennisApiError {
            XCTAssertNil(error.resetsAt)
        }
    }

    func testAbuseThrottledIsItsOwnCaseAndIsNeverRetried() async throws {
        respond(
            status: 429,
            body: Data("{\"error\":\"abuse_throttled\",\"retry_at_epoch\":1786600000}".utf8))

        do {
            _ = try await makeClient(maxRetries: 2).health()
            XCTFail("expected abuseThrottled")
        } catch let error as LiveTennisApiError {
            guard case .abuseThrottled(let info, let retryAtEpoch) = error else {
                return XCTFail("expected abuseThrottled, got \(error)")
            }
            XCTAssertEqual(info.code, "abuse_throttled")
            XCTAssertEqual(retryAtEpoch, Date(timeIntervalSince1970: 1_786_600_000))
            XCTAssertNil(error.resetsAt)
            XCTAssertTrue(error.description.contains("fix the retry loop"))
        }
        XCTAssertEqual(
            StubURLProtocol.requests.count, 1,
            "an abuse block is not a window and must never be retried")
    }

    // MARK: - Parity: prices, tournaments, package manifest (1.1.0)

    func testMatchPricesClampTo500AndCarryWindowMeta() async throws {
        let json = """
            {"data": [{"side": 1, "bid": 0.55, "ask": 0.58, "mid": 0.565, \
            "spread": 0.03, "timestamp": "2026-08-07T14:00:00Z"}], \
            "meta": {"match_id": 22313, "count": 1, "has_more": true, \
            "limit": 500, "minutes": 60}}
            """
        respond(body: Data(json.utf8))

        let page = try await makeClient().getMatchPrices(matchId: 22313, limit: 999, minutes: 60)
        XCTAssertEqual(try sentQueryValue("limit"), "500", "this endpoint caps at 500, not 200")
        XCTAssertEqual(try sentQueryValue("minutes"), "60")
        let path = try XCTUnwrap(StubURLProtocol.requests.first?.url?.path)
        XCTAssertEqual(path, "/api/public/v1/matches/22313/prices")
        XCTAssertEqual(page.data.first?.mid, 0.565)
        XCTAssertEqual(page.meta?.hasMore, true, "clipped window — no offset exists here")
        XCTAssertEqual(page.meta?.minutes, 60)
    }

    func testTournamentCatalogueDecodesAndJoinsTheMatchIdSpace() async throws {
        let json = """
            {"id": "atp-cincinnati-open", "name": "Cincinnati Open", "tour": "atp", \
            "surface": "hard", "indoor": false, "city": "Cincinnati", "country": "US", \
            "category": "masters_1000"}
            """
        respond(body: Data(json.utf8))

        let tournament = try await makeClient().getTournament("atp-cincinnati-open")
        let path = try XCTUnwrap(StubURLProtocol.requests.first?.url?.path)
        XCTAssertEqual(path, "/api/public/v1/tournaments/atp-cincinnati-open")
        XCTAssertEqual(tournament.id, "atp-cincinnati-open")
        XCTAssertEqual(tournament.tour, .atp)
        XCTAssertEqual(tournament.category, "masters_1000")

        StubURLProtocol.requests = []
        respond(body: Data("{\"data\":[],\"meta\":{\"count\":0}}".utf8))
        _ = try await makeClient().listTournaments(search: "cincinnati", tour: .atp)
        XCTAssertEqual(try sentQueryValue("search"), "cincinnati")
        XCTAssertEqual(try sentQueryValue("tour"), "atp")
    }

    func testHistoryPackageManifestAndDownload() async throws {
        respond(
            body: Data(
                "{\"period\":\"2026-06\",\"status\":\"ready\",\"match_count\":4210,\"files\":[]}"
                    .utf8))
        let manifest = try await makeClient().getHistoryPackage(period: "2026-06")
        var path = try XCTUnwrap(StubURLProtocol.requests.first?.url?.path)
        XCTAssertEqual(path, "/api/public/v1/history/packages/2026-06")
        XCTAssertEqual(manifest.period, "2026-06")

        StubURLProtocol.requests = []
        let raw = Data("{\"match\":{}}\n{\"match\":{}}\n".utf8)
        respond(headers: ["Content-Type": "application/x-ndjson"], body: raw)
        let file = try await makeClient().downloadHistoryPackage(
            period: "2026-06", format: .jsonl)
        path = try XCTUnwrap(StubURLProtocol.requests.first?.url?.path)
        XCTAssertEqual(path, "/api/public/v1/history/packages/2026-06")
        XCTAssertEqual(try sentQueryValue("format"), "jsonl")
        XCTAssertEqual(file, raw, "the file is returned verbatim, never decoded")
    }

    // MARK: - Parity: usage & webhooks (1.1.0)

    func testUsageDecodesLimitsTodayAndHistory() async throws {
        let json = """
            {"principal": "key_abc", "tier": "free", "base_tier": "free", \
            "tier_expires_at": null, "channel": "direct", \
            "limits": {"per_minute": 30, "per_day": 100}, \
            "today": {"calls": 41, "errors": 2, "remaining_day": 59}, \
            "history": [{"day": "2026-08-06", "calls": 97, "errors": 0}], \
            "as_of": "2026-08-07T14:00:00Z"}
            """
        respond(body: Data(json.utf8))

        let usage = try await makeClient().getUsage()
        let path = try XCTUnwrap(StubURLProtocol.requests.first?.url?.path)
        XCTAssertEqual(path, "/api/public/v1/usage")
        XCTAssertEqual(usage.tier, "free", "usage reports the tier lowercase")
        XCTAssertEqual(usage.limits?.perDay, 100)
        XCTAssertEqual(usage.today?.remainingDay, 59)
        XCTAssertEqual(usage.history.first?.calls, 97)
    }

    func testCreateWebhookIsAPostAndTheSecretIsShownOnce() async throws {
        respond(
            status: 201,
            body: Data(
                "{\"id\":7,\"url\":\"https://example.com/hook\",\"events\":[\"score\",\"break_point\"],\"enabled\":true,\"secret\":\"whsec_only_now\",\"secret_note\":\"shown once\"}"
                    .utf8))

        let webhook = try await makeClient().createWebhook(
            url: "https://example.com/hook", events: [.score, .breakPoint])
        let request = try XCTUnwrap(StubURLProtocol.requests.first)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
        XCTAssertEqual(request.url?.path, "/api/public/v1/webhooks")
        XCTAssertEqual(webhook.id, 7)
        XCTAssertEqual(webhook.events, ["score", "break_point"])
        XCTAssertEqual(webhook.secret, "whsec_only_now", "the 201 is the only time it appears")
    }

    func testWebhookRegistrationBodyEncoding() throws {
        let body = LiveTennisApiClient.webhookRegistrationBody(
            url: "https://example.com/hook", events: [.breakPoint])
        let parsed = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(parsed["url"] as? String, "https://example.com/hook")
        XCTAssertEqual(parsed["events"] as? [String], ["break_point"])

        let noEvents = LiveTennisApiClient.webhookRegistrationBody(
            url: "https://example.com/hook", events: nil)
        let parsedNoEvents = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: noEvents) as? [String: Any])
        XCTAssertNil(
            parsedNoEvents["events"],
            "omit events entirely so the API default (score) applies")
    }

    func testListWebhooksNeverCarriesTheSecret() async throws {
        respond(
            body: Data(
                "{\"data\":[{\"id\":7,\"url\":\"https://example.com/hook\",\"events\":[\"score\"],\"enabled\":true,\"consecutive_failures\":0,\"last_error\":null}],\"meta\":{\"count\":1}}"
                    .utf8))

        let page = try await makeClient().listWebhooks()
        XCTAssertEqual(page.data.count, 1)
        XCTAssertNil(page.data.first?.secret, "the secret exists only on the 201")
        XCTAssertEqual(page.meta?.count, 1)
    }

    func testDeleteWebhookUsesDelete() async throws {
        respond(body: Data("{\"deleted\":7}".utf8))

        let ack = try await makeClient().deleteWebhook(7)
        let request = try XCTUnwrap(StubURLProtocol.requests.first)
        XCTAssertEqual(request.httpMethod, "DELETE")
        XCTAssertEqual(request.url?.path, "/api/public/v1/webhooks/7")
        XCTAssertEqual(ack.deleted, 7)
    }

    func testAFourthWebhookIsA409Conflict() async throws {
        respond(status: 409, body: Data("{\"error\":\"webhook_limit\"}".utf8))

        do {
            _ = try await makeClient().createWebhook(url: "https://example.com/hook")
            XCTFail("expected conflict")
        } catch let error as LiveTennisApiError {
            guard case .conflict(let info) = error else {
                return XCTFail("expected conflict, got \(error)")
            }
            XCTAssertEqual(info.code, "webhook_limit")
            XCTAssertEqual(error.statusCode, 409)
        }
    }

    func testDirectKeyRequiredNamesNoTier() async throws {
        // A RapidAPI key on /webhooks: the channel is wrong, not the tier —
        // naming ULTRA would send the user to a purchase that fixes nothing.
        respond(status: 403, body: Data("{\"error\":\"direct_key_required\"}".utf8))

        do {
            _ = try await makeClient().listWebhooks()
            XCTFail("expected upgradeRequired")
        } catch let error as LiveTennisApiError {
            guard case .upgradeRequired(let info, let tier) = error else {
                return XCTFail("expected upgradeRequired, got \(error)")
            }
            XCTAssertEqual(info.code, "direct_key_required")
            XCTAssertNil(tier)
        }
    }

    func testWebhooksBelowUltraNameTheTier() async throws {
        respond(status: 403, body: Data("{\"error\":\"upgrade_required\"}".utf8))

        do {
            _ = try await makeClient().listWebhooks()
            XCTFail("expected upgradeRequired")
        } catch LiveTennisApiError.upgradeRequired(_, let tier) {
            XCTAssertEqual(tier, .ultra)
        }
    }

    func testAPostIsNeverRetried() async throws {
        respond(status: 500, body: Data())

        do {
            _ = try await makeClient(maxRetries: 2).createWebhook(
                url: "https://example.com/hook")
            XCTFail("expected serverError")
        } catch let error as LiveTennisApiError {
            guard case .serverError = error else {
                return XCTFail("expected serverError, got \(error)")
            }
        }
        XCTAssertEqual(
            StubURLProtocol.requests.count, 1,
            "a POST that failed may still have been processed — replaying it could duplicate")
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
