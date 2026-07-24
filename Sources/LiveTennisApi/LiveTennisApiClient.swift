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
        userAgent: String = "livetennisapi-swift/1.0.0",
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

    /// Matches by lifecycle status, each with its latest score. FREE.
    ///
    /// A match that has not started carries `score == nil`.
    ///
    /// - Parameters:
    ///   - status: The lifecycle stage. `nil` means the API's default (live).
    ///   - tour: Restrict to one circuit, singles and doubles draws alike. An
    ///     unrecognised value would be a 400, which this enum makes
    ///     unrepresentable.
    ///   - limit: Page size, 1 to ``maxLimit``.
    ///   - offset: Items to skip.
    public func listMatches(
        status: MatchStatus? = nil, tour: Tour? = nil,
        limit: Int? = nil, offset: Int? = nil
    ) async throws -> Page<Match> {
        try await get(
            "/matches",
            query: [
                ("status", status?.rawValue), ("tour", tour?.rawValue),
                ("limit", clamp(limit)), ("offset", offset.map(String.init)),
            ])
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

    /// Completed matches, newest first, each with `winner` derived from the
    /// final sets. **BASIC** — below that,
    /// ``LiveTennisApiError/upgradeRequired(_:requiredTier:)``.
    public func listCompletedMatches(
        limit: Int? = nil, offset: Int? = nil
    ) async throws -> Page<Match> {
        try await get(
            "/history/matches",
            query: [("limit", clamp(limit)), ("offset", offset.map(String.init))])
    }

    /// Upcoming scheduled fixtures, earliest first. FREE. Fixtures are
    /// name-only; use ``listMatches(status:tour:limit:offset:)`` with
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

    // MARK: - Transport

    private func clamp(_ limit: Int?) -> String? {
        limit.map { String(min($0, Self.maxLimit)) }
    }

    private func get<T: Decodable>(
        _ path: String, query: [(String, String?)] = []
    ) async throws -> T {
        var components = URLComponents(string: baseURL + path)!
        let items = query.compactMap { name, value in
            value.map { URLQueryItem(name: name, value: $0) }
        }
        if !items.isEmpty { components.queryItems = items }
        let url = components.url!

        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        if !apiKey.isEmpty {
            switch authMethod {
            case .bearer:
                request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
            case .apiKey:
                request.setValue(apiKey, forHTTPHeaderField: "X-API-Key")
            }
        }

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
                if attempt >= maxRetries {
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
            if (status == 429 || status >= 500) && attempt < maxRetries {
                try await sleep(backoff(attempt: attempt, retryAfter: rateLimit.retryAfter))
                attempt += 1
                continue
            }

            guard (200..<300).contains(status) else {
                throw LiveTennisApiError.forStatus(
                    status, path: path, url: url.absoluteString,
                    rateLimit: rateLimit, body: data)
            }

            do {
                return try decoder.decode(T.self, from: data)
            } catch {
                throw LiveTennisApiError.decoding(url: url.absoluteString, underlying: error)
            }
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
