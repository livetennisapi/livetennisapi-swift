import Foundation

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

/// Which header carries the API key.
public enum AuthMethod: Sendable {
    /// `Authorization: Bearer <key>` — the default, matching the official
    /// Python, JS, Go and .NET clients.
    case bearer
    /// `X-API-Key: <key>` instead. The API accepts either; use this when an
    /// intermediary strips or rewrites `Authorization` headers.
    case apiKey
}

/// A Live Tennis API client.
///
/// Create one and share it: configuration is immutable and requests are
/// independent, so it is safe to use from concurrent tasks.
///
/// ```swift
/// let client = LiveTennisApiClient(apiKey: ProcessInfo.processInfo.environment["LIVETENNISAPI_KEY"] ?? "")
/// let live = try await client.listMatches(status: .live, tour: .atp)
/// for match in live.data {
///     print(match.tournament, match.score?.description ?? "-")
/// }
/// ```
///
/// Access is tiered (FREE / BASIC / PRO / ULTRA); a call above your tier
/// throws ``LiveTennisApiError/upgradeRequired(_:requiredTier:)`` naming the
/// tier that fixes it. Get a free key at
/// <https://livetennisapi.com/subscribe/free>.
public final class LiveTennisApiClient: @unchecked Sendable {
    // @unchecked: every stored property is a `let`, and URLSession is
    // documented thread-safe; the compiler just cannot prove the latter.

    /// The production API root.
    public static let defaultBaseURL = "https://api.livetennisapi.com/api/public/v1"
    /// The largest page size the API accepts.
    public static let maxLimit = 200

    let baseURL: String
    private let apiKey: String
    private let authMethod: AuthMethod
    private let maxRetries: Int
    private let session: URLSession
    private let userAgent: String
    private let onRateLimit: (@Sendable (RateLimit) -> Void)?
    private let decoder = JSONDecoder()

    /// Create a client.
    ///
    /// - Parameters:
    ///   - apiKey: Your key. Empty is allowed, because ``health()`` needs
    ///     none; every other endpoint will then fail with
    ///     ``LiveTennisApiError/unauthorized(_:)``.
    ///   - baseURL: Override the API root, for a proxy or a test server.
    ///   - authMethod: Which header carries the key. Default ``AuthMethod/bearer``.
    ///   - timeout: Per-request timeout in seconds. Ignored when `session` is
    ///     supplied.
    ///   - maxRetries: Retries on top of the initial attempt, for 429, 5xx
    ///     and transport failures only — every other 4xx is a client-side
    ///     mistake that cannot start working, and retrying it only burns
    ///     rate-limit budget. Zero disables retrying.
    ///   - userAgent: Please keep a token identifying your application.
    ///   - session: A custom `URLSession` (also how tests inject a
    ///     `URLProtocol` stub).
    ///   - onRateLimit: Called with the budget reported on every response,
    ///     successful or not — the only way to see it on a success. Called
    ///     once per HTTP attempt; keep it fast.
    public init(
        apiKey: String,
        baseURL: String = LiveTennisApiClient.defaultBaseURL,
        authMethod: AuthMethod = .bearer,
        timeout: TimeInterval = 30,
        maxRetries: Int = 2,
        userAgent: String = "livetennisapi-swift/1.1.1",
        session: URLSession? = nil,
        onRateLimit: (@Sendable (RateLimit) -> Void)? = nil
    ) {
        self.apiKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        var root = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        while root.hasSuffix("/") { root.removeLast() }
        self.baseURL = root
        self.authMethod = authMethod
        self.maxRetries = max(0, maxRetries)
        self.userAgent = userAgent
        self.onRateLimit = onRateLimit
        if let session {
            self.session = session
        } else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = timeout
            self.session = URLSession(configuration: configuration)
        }
    }

    // MARK: - Endpoints

    /// Liveness probe. The one endpoint that needs no API key. FREE.
    public func health() async throws -> Health {
        try await get("/health")
    }

    /// Matches by lifecycle status, each with its latest score. FREE —
    /// except `status: .completed`, which needs **BASIC** (or any History
    /// plan).
    ///
    /// A match that has not started carries `score == nil`.
    ///
    /// - Parameters:
    ///   - status: The lifecycle stage. `nil` means the API's default (live).
    ///   - tour: Restrict to one circuit, singles and doubles draws alike. An
    ///     unrecognised value would be a 400, which this enum makes
    ///     unrepresentable.
    ///   - players: Keep only matches where any of these player ids is
    ///     EITHER participant (deduplicated union). The API accepts at most
    ///     50 ids, so only the first 50 are sent. An unknown id returns an
    ///     empty list, not an error.
    ///   - country: Keep matches where either participant's
    ///     ``Player/country`` equals this lowercase 3-letter IOC-style code
    ///     (`"ned"`, `"sui"` — NOT ISO-3166). Players with no recorded
    ///     country never match.
    ///   - from: Earliest play date, `YYYY-MM-DD` or ISO 8601 UTC datetime.
    ///     A bare date is a UTC day boundary.
    ///   - to: Latest play date (a bare date includes the whole UTC day);
    ///     must not precede `from`.
    ///   - limit: Page size, 1 to ``maxLimit``.
    ///   - offset: Items to skip.
    public func listMatches(
        status: MatchStatus? = nil, tour: Tour? = nil,
        players: [Int64]? = nil, country: String? = nil,
        from: String? = nil, to: String? = nil,
        limit: Int? = nil, offset: Int? = nil
    ) async throws -> Page<Match> {
        try await get(
            "/matches",
            query: [
                ("status", status?.rawValue), ("tour", tour?.rawValue),
                ("country", country), ("from", from), ("to", to),
                ("limit", clamp(limit)), ("offset", offset.map(String.init)),
            ] + repeated("player", ids: players))
    }

    /// One match in full. FREE, with `market` embedded from PRO and
    /// `analysis` from ULTRA.
    public func getMatch(_ matchId: Int64) async throws -> Match {
        try await get("/matches/\(matchId)")
    }

    /// Just the current score — the lowest-latency REST read. FREE; ULTRA
    /// additionally populates `winProbabilityP1` and `danger`.
    ///
    /// Throws ``LiveTennisApiError/notFound(_:)`` for a match with no score
    /// yet, which is the normal answer for a fixture that has not started.
    public func getMatchScore(_ matchId: Int64) async throws -> Score {
        try await get("/matches/\(matchId)/score")
    }

    /// A match's events, newest first. **PRO** — below that,
    /// ``LiveTennisApiError/upgradeRequired(_:requiredTier:)``.
    public func listMatchEvents(
        matchId: Int64, limit: Int? = nil, offset: Int? = nil
    ) async throws -> Page<MatchEvent> {
        try await get(
            "/matches/\(matchId)/events",
            query: [("limit", clamp(limit)), ("offset", offset.map(String.init))])
    }

    /// The model's analysis of a match. **ULTRA** — below that,
    /// ``LiveTennisApiError/upgradeRequired(_:requiredTier:)``. Both halves
    /// may be `nil` for a match the model has not covered.
    public func getMatchAnalysis(_ matchId: Int64) async throws -> Analysis {
        try await get("/matches/\(matchId)/analysis")
    }

    /// Search players by name, ranked players first. FREE. The list carries
    /// no `stats`; use ``getPlayer(_:)`` for that.
    public func searchPlayers(
        search: String? = nil, limit: Int? = nil, offset: Int? = nil
    ) async throws -> Page<Player> {
        try await get(
            "/players",
            query: [
                ("search", search), ("limit", clamp(limit)),
                ("offset", offset.map(String.init)),
            ])
    }

    /// One player's bio, ranking and cached stats. FREE.
    public func getPlayer(_ playerId: Int64) async throws -> Player {
        try await get("/players/\(playerId)")
    }

    /// The match-winner market(s) for a match. **PRO**. The markets carry no
    /// price ticks; use ``getMarketPrices(matchId:limit:)`` for those.
    public func listMarkets(matchId: Int64) async throws -> Page<Market> {
        try await get("/markets", query: [("match_id", String(matchId))])
    }

    /// A match's market with its recent price ticks per side, newest first.
    /// **PRO**. The endpoint takes a limit but no offset.
    public func getMarketPrices(matchId: Int64, limit: Int? = nil) async throws -> Market {
        try await get("/markets/\(matchId)/prices", query: [("limit", clamp(limit))])
    }

    /// Bare price ticks of a match's mapped match-winner market, newest
    /// first — no market wrapper. **PRO**.
    ///
    /// Throws ``LiveTennisApiError/notFound(_:)`` when the match has no
    /// mapped market. There is no offset here: `meta.hasMore` means the
    /// window was clipped at `limit` — raise it or narrow `minutes`.
    ///
    /// - Parameters:
    ///   - limit: 1 to 500 (a larger value is clamped client-side; the
    ///     API's default is 100). Note the cap differs from ``maxLimit``.
    ///   - minutes: Bound the lookback window, 1 to 1440.
    public func getMatchPrices(
        matchId: Int64, limit: Int? = nil, minutes: Int? = nil
    ) async throws -> Page<Price> {
        try await get(
            "/matches/\(matchId)/prices",
            query: [
                ("limit", limit.map { String(min($0, 500)) }),
                ("minutes", minutes.map(String.init)),
            ])
    }

    /// The tournament catalogue — the id space ``Match/tournamentId`` joins,
    /// in name order. FREE.
    ///
    /// - Parameters:
    ///   - search: Case-insensitive substring match on the tournament name.
    ///   - tour: Restrict to one circuit.
    public func listTournaments(
        search: String? = nil, tour: Tour? = nil,
        limit: Int? = nil, offset: Int? = nil
    ) async throws -> Page<Tournament> {
        try await get(
            "/tournaments",
            query: [
                ("search", search), ("tour", tour?.rawValue),
                ("limit", clamp(limit)), ("offset", offset.map(String.init)),
            ])
    }

    /// One tournament by its stable id — the `tournamentId` carried on match
    /// objects. FREE.
    public func getTournament(_ tournamentId: String) async throws -> Tournament {
        let encoded =
            tournamentId.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed)
            ?? tournamentId
        return try await get("/tournaments/\(encoded)")
    }

    /// Completed matches, newest first, each with `winner` derived from the
    /// final sets. **BASIC** — below that,
    /// ``LiveTennisApiError/upgradeRequired(_:requiredTier:)``.
    ///
    /// The filters behave exactly as on
    /// ``listMatches(status:tour:players:country:from:to:limit:offset:)``.
    public func listCompletedMatches(
        tour: Tour? = nil, players: [Int64]? = nil, country: String? = nil,
        from: String? = nil, to: String? = nil,
        limit: Int? = nil, offset: Int? = nil
    ) async throws -> Page<Match> {
        try await get(
            "/history/matches",
            query: [
                ("tour", tour?.rawValue), ("country", country),
                ("from", from), ("to", to),
                ("limit", clamp(limit)), ("offset", offset.map(String.init)),
            ] + repeated("player", ids: players))
    }

    /// A match's point-by-point tape: the chronological score sequence plus
    /// per-point model probabilities where a model was watching. **BASIC**
    /// (or any History plan).
    ///
    /// Works on a LIVE match, not only a completed one — the tape is
    /// assembled from whatever has been committed so far. It is NOT
    /// guaranteed to cover the whole match: check the returned `meta`
    /// coverage before backtesting. ``TapeSequence/clean`` rows additionally
    /// carry ``TapeRow/pointWinner``; the response also lists per-set
    /// tiebreak final scores in ``HistoryTape/tiebreaks``.
    public func getMatchTape(
        _ matchId: Int64, sequence: TapeSequence? = nil
    ) async throws -> HistoryTape {
        try await get(
            "/history/matches/\(matchId)", query: [("sequence", sequence?.rawValue)])
    }

    /// The head-to-head record between two players, assembled from the
    /// results archive (1968–2022) and our own completed matches (2023
    /// onward). **BASIC** (or any History plan).
    ///
    /// Names are the keys — archive people have no roster ids. A fragment
    /// (min 3 chars) matching more than one player is refused with a 400
    /// `ambiguous_name` carrying the candidate list, because two people
    /// summed into one record is a wrong answer, not a convenience.
    public func getHeadToHead(p1: String, p2: String) async throws -> HeadToHead {
        try await get("/h2h", query: [("p1", p1), ("p2", p2)])
    }

    // MARK: - Results archive (1968–2022)

    /// Deep historical results: ATP and WTA main draws, qualifying,
    /// challengers and futures, 1968 through 2022, newest tournament first.
    /// **BASIC** (or any History plan).
    ///
    /// A SEPARATE id space from `/matches` — archive people are identified
    /// by name and corpus person id — and the archive ends where our own
    /// point-by-point coverage begins (2023-01), so no match is ever served
    /// from two datasets.
    ///
    /// - Parameters:
    ///   - tour: `.atp` or `.wta` — the corpus holds nothing else.
    ///   - name: Case-insensitive substring match on EITHER player's name
    ///     (min 3 chars).
    ///   - from: Earliest tournament START date, `YYYY-MM-DD` — the only
    ///     date records of this era carry.
    ///   - to: Latest tournament start date.
    ///   - round: `"F"`, `"SF"`, `"QF"`, `"R16"` … `"Q1"`–`"Q4"`, `"ER"`.
    ///   - level: Source tier code (G, M, A, F, D, C, O; futures carry their
    ///     category codes).
    public func listArchiveMatches(
        tour: ArchiveTour? = nil, name: String? = nil,
        from: String? = nil, to: String? = nil,
        round: String? = nil, level: String? = nil,
        limit: Int? = nil, offset: Int? = nil
    ) async throws -> Page<ArchiveMatch> {
        try await get(
            "/history/archive/matches",
            query: [
                ("tour", tour?.rawValue), ("name", name), ("from", from), ("to", to),
                ("round", round), ("level", level),
                ("limit", clamp(limit)), ("offset", offset.map(String.init)),
            ])
    }

    /// One archive result, with serve statistics where the source recorded
    /// them — `stats` is `nil` for the (mostly pre-1991) rows it never did,
    /// never synthesised. **BASIC** (or any History plan).
    public func getArchiveMatch(_ archiveId: Int64) async throws -> ArchiveMatch {
        try await get("/history/archive/matches/\(archiveId)")
    }

    /// Archive player bios — hand, date of birth, country, height and
    /// career-high — ordered by name. **BASIC** (or any History plan).
    /// The ids are corpus person ids, scoped per tour, never roster ids.
    public func listArchivePlayers(
        name: String? = nil, tour: ArchiveTour? = nil,
        limit: Int? = nil, offset: Int? = nil
    ) async throws -> Page<ArchivePlayerBio> {
        try await get(
            "/history/archive/players",
            query: [
                ("name", name), ("tour", tour?.rawValue),
                ("limit", clamp(limit)), ("offset", offset.map(String.init)),
            ])
    }

    /// One player's whole archive career in one response: W-L record
    /// (overall, by surface, by level, by year), titles and summed serve
    /// statistics. **BASIC** (or any History plan).
    ///
    /// `name` is a fragment (min 3 chars) that must resolve to one person;
    /// an ambiguous fragment is refused with candidates, the same rule as
    /// ``getHeadToHead(p1:p2:)``.
    public func getArchiveCareer(name: String) async throws -> ArchiveCareer {
        try await get("/history/archive/career", query: [("name", name)])
    }

    // MARK: - Bulk history packages

    /// Pre-built monthly bulk packages, newest period first. **PRO** (or a
    /// package subscription); `kind: .rankings` and `kind: .rally` need
    /// **ULTRA**, while `kind: .archive` rides the tape entitlement.
    ///
    /// - Parameters:
    ///   - kind: The package family; `nil` means the API's default (tape).
    ///     The yearly kinds (`.rally`, `.archive`) list bare-year periods
    ///     (`YYYY`), one file per year.
    ///   - year: `YYYY` — list every published month of the year (History
    ///     Business, a 1-year package, or ULTRA).
    public func listHistoryPackages(
        kind: PackageKind? = nil, year: String? = nil
    ) async throws -> HistoryPackagesPage {
        try await get(
            "/history/packages", query: [("kind", kind?.rawValue), ("year", year)])
    }

    /// One package's JSON manifest — file names, sizes and sha256
    /// checksums. **PRO** (or a package subscription); `kind: .rankings` and
    /// `kind: .rally` need **ULTRA**, while `kind: .archive` rides the tape
    /// entitlement.
    ///
    /// - Parameter period: The month, `YYYY-MM` — except for the yearly
    ///   kinds (`.rally`, `.archive`), where it is the bare year, `YYYY`
    ///   (`400 bad_period` otherwise).
    public func getHistoryPackage(
        period: String, kind: PackageKind? = nil
    ) async throws -> HistoryPackage {
        try await get("/history/packages/\(period)", query: [("kind", kind?.rawValue)])
    }

    /// Download one package file as raw bytes — JSONL (one tape
    /// object per line) or CSV (one row per point). Same tiers as
    /// ``getHistoryPackage(period:kind:)``.
    ///
    /// The bytes are returned verbatim; verify them against the manifest's
    /// `sha256` if you store them.
    public func downloadHistoryPackage(
        period: String, kind: PackageKind? = nil, format: PackageFormat
    ) async throws -> Data {
        let (data, _) = try await requestData(
            "GET", "/history/packages/\(period)",
            query: [("kind", kind?.rawValue), ("format", format.rawValue)])
        return data
    }

    // MARK: - Rankings

    /// Point-in-time rankings, in two modes. WITHOUT `players` (**PRO**):
    /// the FULL published table in rank order for exactly one system, the
    /// newest week at or before `asOf`. WITH `players` (**ULTRA**): the
    /// newest record per system effective ON OR BEFORE `asOf` for each
    /// requested player — never one dated after it.
    ///
    /// Listing rows carry `playerName` as published and a `nil` `playerId`
    /// for players outside our roster, so the table has no silent holes.
    /// ``RankingSystem/utr`` has no listing mode (a rating, not a ranking).
    /// Check the meta's ``RankingMeta/coverage`` before trusting an empty
    /// result: ITF and UTR history begins 2026-07-29.
    ///
    /// - Parameters:
    ///   - players: Player ids for per-player mode; at most 50 are sent.
    ///     Omit for the listing mode, which then requires exactly one
    ///     `system`.
    ///   - asOf: `YYYY-MM-DD`. Omit for the latest known record.
    ///   - systems: Restrict to one or more systems. Omit for all (per-player
    ///     mode only).
    public func listRankings(
        players: [Int64]? = nil, asOf: String? = nil,
        systems: [RankingSystem]? = nil,
        limit: Int? = nil, offset: Int? = nil
    ) async throws -> RankingsPage {
        try await get(
            "/rankings",
            query: [
                ("as_of", asOf),
                ("limit", clamp(limit)), ("offset", offset.map(String.init)),
            ] + repeated("player", ids: players)
                + repeated("system", values: (systems ?? []).map(\.rawValue)))
    }

    // MARK: - Rally construction & charting (ULTRA)

    /// Charted matches with shot-by-shot data, newest first. **ULTRA**.
    ///
    /// Rally construction is the layer below the tape: the tape says what
    /// the score became after each point, this says how the point was
    /// played. Its OWN id space — ask this endpoint for the authoritative
    /// coverage list rather than assuming a match is charted: charting is
    /// human work, so coverage is deep, not universal.
    public func listRallyMatches(
        player: String? = nil, from: String? = nil, to: String? = nil,
        surface: String? = nil, gender: RallyGender? = nil,
        limit: Int? = nil, offset: Int? = nil
    ) async throws -> Page<RallyMatch> {
        try await get(
            "/rally/matches",
            query: [
                ("player", player), ("from", from), ("to", to),
                ("surface", surface), ("gender", gender?.rawValue),
                ("limit", clamp(limit)), ("offset", offset.map(String.init)),
            ])
    }

    /// Rally construction for one charted match, points in play order.
    /// **ULTRA**. Paged with `limit`/`offset`; the returned `meta.total` is
    /// the match's full point count.
    public func getRallyMatch(
        _ rallyMatchId: Int64, limit: Int? = nil, offset: Int? = nil
    ) async throws -> RallyTape {
        try await get(
            "/rally/matches/\(rallyMatchId)",
            query: [("limit", clamp(limit)), ("offset", offset.map(String.init))])
    }

    /// Rally construction addressed by OUR match id, resolved through the
    /// optional link. **ULTRA**.
    ///
    /// Answers 404 `not_charted` when we hold the match but nobody charted
    /// it — deliberately distinct from "no such match", because most of our
    /// matches are not charted and a consumer walking the archive must tell
    /// them apart. Branch on ``LiveTennisApiError/errorCode``.
    public func getMatchRally(
        matchId: Int64, limit: Int? = nil, offset: Int? = nil
    ) async throws -> RallyTape {
        try await get(
            "/history/matches/\(matchId)/rally",
            query: [("limit", clamp(limit)), ("offset", offset.map(String.init))])
    }

    /// A player's career shot-level charting aggregate — serve placement,
    /// return depth, net play, clutch serving, winners and errors by wing,
    /// rally-length tendencies — summed over their charted matches.
    /// **ULTRA**.
    ///
    /// `name` (min 3 chars) must resolve to one charted person; an ambiguous
    /// fragment is refused with candidates, and `gender` disambiguates.
    public func getChartingPlayer(
        name: String, gender: ChartingGender? = nil
    ) async throws -> ChartingPlayer {
        try await get(
            "/charting/players", query: [("name", name), ("gender", gender?.rawValue)])
    }

    /// One charted match, every stat family for both players, with the
    /// per-set split exactly as charted. **ULTRA**. `chartingMatchId` is
    /// this product's own id space.
    public func getChartingMatch(_ chartingMatchId: Int64) async throws -> ChartingMatch {
        try await get("/charting/matches/\(chartingMatchId)")
    }

    // MARK: - In-play statistics & push feed (ULTRA)

    /// In-play statistics for one match — aces, double faults, serve split,
    /// hold/break percentages, break points, service and return points.
    /// **ULTRA**.
    ///
    /// Two families that are deliberately not merged: DERIVED (rebuilt from
    /// the point-by-point record) and MEASURED (counted upstream — the only
    /// source of aces and double faults). Read the per-family `freshness`
    /// before trusting either, and never compare their ages: they use
    /// different clocks. "We hold nothing" is a 200 with `players == nil`,
    /// not a 404.
    public func getMatchStatistics(_ matchId: Int64) async throws -> MatchStatistics {
        try await get("/matches/\(matchId)/statistics")
    }

    /// Mint a short-lived connection token for the high-fan-out push
    /// WebSocket. **ULTRA**.
    ///
    /// The response carries the socket URL and the channel vocabulary —
    /// `match:{id}` per-match streams and `slate:all` for every live score
    /// frame. Frames are the same allowlist score objects the polling
    /// endpoints return. Mint a fresh token on every reconnect.
    public func getWsToken() async throws -> WsToken {
        try await get("/ws-token")
    }

    /// Upcoming scheduled fixtures, earliest first. FREE. Fixtures are
    /// name-only; use ``listMatches(status:tour:players:country:from:to:limit:offset:)`` with
    /// `.upcoming` when you need player ids.
    public func listFixtures(
        tour: Tour? = nil, limit: Int? = nil, offset: Int? = nil
    ) async throws -> Page<Fixture> {
        try await get(
            "/fixtures",
            query: [
                ("tour", tour?.rawValue), ("limit", clamp(limit)),
                ("offset", offset.map(String.init)),
            ])
    }

    // MARK: - Account: usage & webhooks

    /// Your own usage vs quota: tier, limits, today's calls (current to the
    /// second) and a 30-day history. Any tier, and QUOTA-EXEMPT — polling it
    /// never consumes the budget it reports.
    ///
    /// The per-minute window is on the `X-RateLimit-*` headers of every
    /// response (see `onRateLimit:`), not here.
    public func getUsage() async throws -> Usage {
        try await get("/usage")
    }

    /// Register an outbound webhook: the API POSTs the same frames the
    /// WebSocket pushes to your HTTPS endpoint on every live score commit.
    /// **ULTRA, direct keys only** — on a RapidAPI-issued key this is a 403
    /// with code `direct_key_required`.
    ///
    /// The response is the ONLY time the signing ``Webhook/secret`` is shown
    /// — store it. At most 3 webhooks per key: a fourth registration throws
    /// ``LiveTennisApiError/conflict(_:)`` (code `webhook_limit`); delete
    /// one first. This request is a POST and is never auto-retried.
    ///
    /// - Parameters:
    ///   - url: Your endpoint — HTTPS only, publicly routable.
    ///   - events: The event families to deliver; `nil` means the API's
    ///     default (score only).
    public func createWebhook(
        url: String, events: [WebhookEvent]? = nil
    ) async throws -> Webhook {
        try await request(
            "POST", "/webhooks",
            body: Self.webhookRegistrationBody(url: url, events: events))
    }

    /// List your webhooks. **ULTRA, direct keys only**. The signing secret
    /// is never included here — it is shown once, at registration.
    public func listWebhooks() async throws -> Page<Webhook> {
        try await get("/webhooks")
    }

    /// Remove one of your webhooks. **ULTRA, direct keys only**.
    public func deleteWebhook(_ webhookId: Int64) async throws -> WebhookDeletion {
        try await request("DELETE", "/webhooks/\(webhookId)")
    }

    /// The JSON body of a webhook registration. Internal so the encoding is
    /// testable without a network round-trip.
    static func webhookRegistrationBody(url: String, events: [WebhookEvent]?) -> Data {
        struct Registration: Encodable {
            let url: String
            let events: [String]?
        }
        // Encoding a two-field struct cannot fail; a crash here would be a
        // programming error, not a runtime condition.
        return try! JSONEncoder().encode(
            Registration(url: url, events: events?.map(\.rawValue)))
    }

    // MARK: - Transport

    private func clamp(_ limit: Int?) -> String? {
        limit.map { String(min($0, Self.maxLimit)) }
    }

    /// A repeatable query parameter. The API accepts at most 50 `player`
    /// ids, so the excess is dropped client-side rather than earning a 400.
    private func repeated(_ name: String, ids: [Int64]?) -> [(String, String?)] {
        (ids ?? []).prefix(50).map { id in (name, Optional(String(id))) }
    }

    private func repeated(_ name: String, values: [String]) -> [(String, String?)] {
        values.map { value in (name, Optional(value)) }
    }

    private func get<T: Decodable>(
        _ path: String, query: [(String, String?)] = []
    ) async throws -> T {
        try await request("GET", path, query: query)
    }

    private func request<T: Decodable>(
        _ method: String, _ path: String, query: [(String, String?)] = [],
        body: Data? = nil
    ) async throws -> T {
        let (data, urlString) = try await requestData(method, path, query: query, body: body)
        do {
            return try decoder.decode(T.self, from: data)
        } catch {
            throw LiveTennisApiError.decoding(url: urlString, underlying: error)
        }
    }

    /// The transport loop, returning the raw 2xx body. Retries apply to
    /// IDEMPOTENT methods only (GET, DELETE): a POST that timed out may have
    /// been processed, and replaying it could create a duplicate resource.
    private func requestData(
        _ method: String, _ path: String, query: [(String, String?)] = [],
        body requestBody: Data? = nil
    ) async throws -> (Data, String) {
        var components = URLComponents(string: baseURL + path)!
        let items = query.compactMap { name, value in
            value.map { URLQueryItem(name: name, value: $0) }
        }
        if !items.isEmpty { components.queryItems = items }
        let url = components.url!

        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        if let requestBody {
            request.httpBody = requestBody
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        if !apiKey.isEmpty {
            switch authMethod {
            case .bearer:
                request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
            case .apiKey:
                request.setValue(apiKey, forHTTPHeaderField: "X-API-Key")
            }
        }

        let idempotent = method == "GET" || method == "DELETE"
        var attempt = 0
        while true {
            let data: Data
            let response: HTTPURLResponse
            do {
                let (body, raw) = try await session.data(for: request)
                guard let http = raw as? HTTPURLResponse else {
                    throw LiveTennisApiError.connection(
                        url: url.absoluteString,
                        underlying: URLError(.badServerResponse))
                }
                data = body
                response = http
            } catch let error as LiveTennisApiError {
                throw error
            } catch {
                if attempt >= maxRetries || !idempotent {
                    if (error as? URLError)?.code == .timedOut {
                        throw LiveTennisApiError.timeout(
                            url: url.absoluteString, underlying: error)
                    }
                    throw LiveTennisApiError.connection(
                        url: url.absoluteString, underlying: error)
                }
                try await sleep(backoff(attempt: attempt, retryAfter: nil))
                attempt += 1
                continue
            }

            let rateLimit = RateLimit(response: response)
            onRateLimit?(rateLimit)

            let status = response.statusCode
            // An abuse_throttled 429 is a long block, not a window — retrying
            // it cannot succeed and is exactly the behaviour that earned it.
            if (status == 429 || status >= 500) && attempt < maxRetries && idempotent
                && !LiveTennisApiError.isAbuseThrottled(status: status, body: data)
            {
                try await sleep(backoff(attempt: attempt, retryAfter: rateLimit.retryAfter))
                attempt += 1
                continue
            }

            guard (200..<300).contains(status) else {
                throw LiveTennisApiError.forStatus(
                    status, path: path, query: query, url: url.absoluteString,
                    rateLimit: rateLimit, body: data)
            }

            return (data, url.absoluteString)
        }
    }

    /// How long to wait before the next attempt, in seconds. Honours the
    /// server's `Retry-After` when present (capped at a minute), otherwise
    /// exponential with jitter so concurrent clients don't retry in lockstep.
    func backoff(attempt: Int, retryAfter: TimeInterval?) -> TimeInterval {
        if let retryAfter { return min(retryAfter, 60) }
        let base = 0.5 * pow(2, Double(min(attempt, 8)))
        return min(base + Double.random(in: 0..<0.25), 10)
    }

    private func sleep(_ seconds: TimeInterval) async throws {
        try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }
}
