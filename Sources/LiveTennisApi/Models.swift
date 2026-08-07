import Foundation

// Response models, with optionals wherever the API can send `null` or omit a
// field. Unknown fields are ignored: additive changes land within v1.
// Timestamps are carried as the API sends them — UTC ISO 8601 strings with a
// `Z` suffix (fractional seconds possible) — parse them as you prefer.

/// A circuit accepted by the `tour` *filter* on the match, fixture and
/// history list endpoints — the five tours the API serves: ATP, WTA,
/// Challenger, ITF and juniors.
///
/// Each value covers its singles and doubles draws, so ``atp`` includes ATP
/// doubles and ``juniors`` covers both the boys' and girls' Grand Slam draws.
///
/// This is the vocabulary the API accepts as a filter, and the one
/// ``Match/tour`` returns — both are derived from one registry, so a match
/// selected by `?tour=` always carries that value. It is **not** the
/// vocabulary of ``Player/tour`` and ``Fixture/tour``: those are granular
/// (`"juniors_boys"`, `"challenger_men"`) and a doubles team reports
/// UPPERCASE (`"ATP"`). They stay plain strings for that reason — never parse
/// them into this enum. An unrecognised filter value is rejected with a 400
/// carrying code `bad_tour` rather than silently ignored.
public enum Tour: String, Sendable, CaseIterable {
    /// The ATP tour, singles and doubles.
    case atp
    /// The WTA tour, singles and doubles.
    case wta
    /// The Challenger circuit.
    case challenger
    /// The ITF circuit.
    case itf
    /// The junior Grand Slam draws, boys' and girls'.
    case juniors
}

/// A match's lifecycle state. Only `live`, `upcoming` and `completed` are
/// accepted as a filter; `cancelled` appears in payloads but is not a query
/// value. An unrecognised payload value decodes as ``unknown``.
public enum MatchStatus: String, Codable, Sendable {
    case live, upcoming, completed, cancelled, unknown

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = MatchStatus(rawValue: raw) ?? .unknown
    }
}

/// The kind of thing that happened in a match. An unrecognised payload value
/// decodes as ``unknown``.
public enum EventType: String, Codable, Sendable {
    case `break`, setWon = "set_won", gameWon = "game_won"
    case momentumRun = "momentum_run", unknown

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = EventType(rawValue: raw) ?? .unknown
    }
}

/// Arbitrary JSON the v1 schema does not pin, kept decodable so it is never
/// lost (player stats, scenario playbooks).
public enum JSONValue: Codable, Sendable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else {
            self = .object(try container.decode([String: JSONValue].self))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }
}

/// The response from ``LiveTennisApiClient/health()``.
public struct Health: Decodable, Sendable {
    /// `"ok"` when the API is serving.
    public let status: String
    /// The API version, `"v1"`.
    public let version: String
}

/// The pagination envelope beside a list response.
///
/// `count` describes the page just returned, not the whole collection.
/// Detect the end of a list with ``hasMore`` where the endpoint sends it,
/// falling back to receiving fewer items than you asked for.
public struct ListMeta: Decodable, Sendable {
    /// The page size applied.
    public let limit: Int?
    /// The offset applied.
    public let offset: Int?
    /// Items on this page.
    public let count: Int?
    /// The size of the whole filtered set. `nil` when it cannot be counted
    /// cheaply — `/matches?status=completed` always reports it null.
    public let total: Int?
    /// Whether more results exist beyond this page. Read this rather than
    /// comparing ``count`` to ``limit``.
    public let hasMore: Bool?
    /// Echoes the match filter on ``LiveTennisApiClient/listMarkets(matchId:)``
    /// and ``LiveTennisApiClient/getMatchPrices(matchId:limit:minutes:)``.
    public let matchId: Int64?
    /// Echoes the lookback window on
    /// ``LiveTennisApiClient/getMatchPrices(matchId:limit:minutes:)``, the
    /// only endpoint that sets it.
    public let minutes: Int?

    enum CodingKeys: String, CodingKey {
        case limit, offset, count, total, minutes
        case hasMore = "has_more"
        case matchId = "match_id"
    }
}

/// One page of a list endpoint: the API's `{data, meta}` envelope.
public struct Page<T: Decodable & Sendable>: Decodable, Sendable {
    /// The items for this page.
    public let data: [T]
    /// The pagination envelope.
    public let meta: ListMeta?

    enum CodingKeys: String, CodingKey { case data, meta }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        data = try container.decodeIfPresent([T].self, forKey: .data) ?? []
        meta = try container.decodeIfPresent(ListMeta.self, forKey: .meta)
    }
}

/// A match score at a point in time.
///
/// Two shapes here reliably trip people up. ``games`` is player-major, not
/// set-major: `[games_p1, games_p2]` where each side is a per-set list, so
/// `[[6,3,2],[4,6,1]]` reads 6-4, 3-6, 2-1. And ``points`` is a list of
/// **strings**, because tennis scores points as `"0"`, `"15"`, `"30"`, `"40"`
/// and `"AD"` — do not parse them as integers.
public struct Score: Decodable, Sendable, CustomStringConvertible {
    /// `[sets_p1, sets_p2]` — sets won by each player.
    public let sets: [Int]
    /// `[games_p1, games_p2]`, each a per-set list. See the type doc.
    public let games: [[Int]]
    /// The current game's points as strings: `"0"`, `"15"`, `"30"`, `"40"`,
    /// `"AD"`. During a tiebreak they are numeric strings. Never integers.
    ///
    /// Each entry is optional because the live API sends `[null, null]` on a
    /// score with no current game — observed on completed matches with empty
    /// ``games`` (the OpenAPI schema does not admit this, the wire does).
    public let points: [String?]
    /// Which player is serving, 1 or 2. `nil` when unknown — which happens
    /// inside otherwise-present scores, so this stays optional.
    public let server: Int?
    /// Whether the current game is a tiebreak.
    public let isTiebreak: Bool
    /// The live model's probability that player 1 wins, 0 to 1. ULTRA only;
    /// `nil` on every lower tier.
    public let winProbabilityP1: Double?
    /// The live model's danger rating for the leading side. ULTRA only.
    public let danger: Double?
    /// When the score was observed (ISO 8601 UTC).
    public let timestamp: String?

    enum CodingKeys: String, CodingKey {
        case sets, games, points, server, danger, timestamp
        case isTiebreak = "is_tiebreak"
        case winProbabilityP1 = "win_probability_p1"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        sets = try c.decodeIfPresent([Int].self, forKey: .sets) ?? []
        games = try c.decodeIfPresent([[Int]].self, forKey: .games) ?? []
        points = try c.decodeIfPresent([String?].self, forKey: .points) ?? []
        server = try c.decodeIfPresent(Int.self, forKey: .server)
        isTiebreak = try c.decodeIfPresent(Bool.self, forKey: .isTiebreak) ?? false
        winProbabilityP1 = try c.decodeIfPresent(Double.self, forKey: .winProbabilityP1)
        danger = try c.decodeIfPresent(Double.self, forKey: .danger)
        timestamp = try c.decodeIfPresent(String.self, forKey: .timestamp)
    }

    /// The games each player won in one set, guarding the player-major layout
    /// of ``games``. `nil` when the set is out of range, which is the normal
    /// case for a match that has not reached that set.
    public func gamesForSet(_ setIndex: Int) -> (p1: Int, p2: Int)? {
        guard games.count >= 2, setIndex >= 0,
            setIndex < games[0].count, setIndex < games[1].count
        else { return nil }
        return (games[0][setIndex], games[1][setIndex])
    }

    /// How many sets have been played or started.
    public var numSets: Int {
        games.count >= 2 ? min(games[0].count, games[1].count) : 0
    }

    /// Renders as `"6-4 3-6 2-1 (40-30)"`, or `"-"` when nothing is known.
    public var description: String {
        var parts = (0..<numSets).compactMap { index in
            gamesForSet(index).map { "\($0.p1)-\($0.p2)" }
        }
        if parts.isEmpty, sets.count >= 2 {
            parts.append("\(sets[0])-\(sets[1])")
        }
        if points.count >= 2, let p1 = points[0], let p2 = points[1] {
            parts.append("(\(p1)-\(p2))")
        }
        return parts.isEmpty ? "-" : parts.joined(separator: " ")
    }
}

/// How much of a player's biography is populated, so a consumer can tell
/// "not in the feed" from "not yet fetched" without probing.
///
/// It does not apply to a doubles team, which has no single biography: there
/// the API sends ``known`` and ``of`` as `null` with an explanatory ``note``.
/// Both are optional because null means "not applicable", which is
/// emphatically not zero. Check ``applicable`` before reading them.
public struct DataCompleteness: Decodable, Sendable {
    /// How many of the considered fields are populated. `nil` for a doubles
    /// team, where the question does not apply.
    public let known: Int?
    /// How many fields were considered. `nil` for a doubles team.
    public let of: Int?
    /// Names of the unpopulated fields, e.g. `["backhand", "hand"]`.
    public let missing: [String]
    /// Present only when the object is not applicable, explaining why (e.g. a
    /// doubles team).
    public let note: String?

    enum CodingKeys: String, CodingKey { case known, of, missing, note }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        known = try c.decodeIfPresent(Int.self, forKey: .known)
        of = try c.decodeIfPresent(Int.self, forKey: .of)
        missing = try c.decodeIfPresent([String].self, forKey: .missing) ?? []
        note = try c.decodeIfPresent(String.self, forKey: .note)
    }

    /// Whether per-player completeness is meaningful for this record. False
    /// for a doubles team.
    public var applicable: Bool { known != nil && of != nil }
}

/// The cached statistics block on a single player, from
/// ``LiveTennisApiClient/getPlayer(_:)`` only. Both halves are unpinned JSON:
/// the v1 schema does not fix their shape.
public struct PlayerStats: Decodable, Sendable {
    /// The ratings object, or `nil`.
    public let ratings: JSONValue?
    /// The season-by-season array, or `nil`.
    public let season: JSONValue?
}

/// A player's identity, ranking and, on the single-player endpoint, cached
/// statistics. A doubles entry is a single `Player` with ``isDoublesTeam``
/// set and both names in ``name``.
public struct Player: Decodable, Sendable {
    /// The player's stable identifier.
    public let id: Int64
    /// The display name.
    public let name: String
    /// The record's OWN tour — **not** the ``Tour`` filter vocabulary. It is
    /// granular (`"juniors_boys"`) where the filter is grouped, and a doubles
    /// team reports it UPPERCASE. Treat it as opaque.
    public let tour: String?
    /// The country code.
    public let country: String?
    /// The current world ranking. `nil` when unranked — not the same as 0.
    public let ranking: Int?
    /// The current ranking points total.
    public let rankingPoints: Int?
    /// `"up"`, `"down"` or `"same"`.
    public let rankingMovement: String?
    /// The playing hand, `"R"` or `"L"`.
    public let hand: String?
    /// 1 for one-handed, 2 for two-handed.
    public let backhand: Int?
    /// The date of birth (calendar date, no time).
    public let birthday: String?
    /// Whether this entry is a doubles pairing rather than an individual.
    public let isDoublesTeam: Bool
    /// How much biographical detail is known. Present on every player in a
    /// match payload; lower tours carry far less than the main tour.
    public let dataCompleteness: DataCompleteness?
    /// Populated by ``LiveTennisApiClient/getPlayer(_:)`` only, never by the
    /// search endpoint.
    public let stats: PlayerStats?

    enum CodingKeys: String, CodingKey {
        case id, name, tour, country, ranking, hand, backhand, birthday, stats
        case rankingPoints = "ranking_points"
        case rankingMovement = "ranking_movement"
        case isDoublesTeam = "is_doubles_team"
        case dataCompleteness = "data_completeness"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(Int64.self, forKey: .id) ?? 0
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        tour = try c.decodeIfPresent(String.self, forKey: .tour)
        country = try c.decodeIfPresent(String.self, forKey: .country)
        ranking = try c.decodeIfPresent(Int.self, forKey: .ranking)
        rankingPoints = try c.decodeIfPresent(Int.self, forKey: .rankingPoints)
        rankingMovement = try c.decodeIfPresent(String.self, forKey: .rankingMovement)
        hand = try c.decodeIfPresent(String.self, forKey: .hand)
        backhand = try c.decodeIfPresent(Int.self, forKey: .backhand)
        birthday = try c.decodeIfPresent(String.self, forKey: .birthday)
        isDoublesTeam = try c.decodeIfPresent(Bool.self, forKey: .isDoublesTeam) ?? false
        dataCompleteness = try c.decodeIfPresent(DataCompleteness.self, forKey: .dataCompleteness)
        stats = try c.decodeIfPresent(PlayerStats.self, forKey: .stats)
    }
}

/// The pair of players in a match. ``p1`` is the side that "1" refers to
/// everywhere else: in ``Score/server``, ``Match/winner``, ``Price/side`` and
/// ``MatchEvent/player``.
public struct Players: Decodable, Sendable {
    /// Player 1.
    public let p1: Player?
    /// Player 2.
    public let p2: Player?
}

/// A tennis match.
///
/// ``market`` is embedded from PRO and ``analysis`` from ULTRA on
/// ``LiveTennisApiClient/getMatch(_:)``. Below those tiers the API omits them
/// entirely, so `nil` means "not entitled or not available" and never "no
/// market exists".
public struct Match: Decodable, Sendable {
    /// The match's stable identifier.
    public let id: Int64
    /// The event name.
    public let tournament: String
    /// The tour, in the SAME vocabulary the ``Tour`` filter accepts — a match
    /// selected by `?tour=` always carries that value here, so unlike
    /// ``Player/tour`` this one is safe to group and filter on. `nil` when
    /// the feed never stated a tour or the event has no public tour name
    /// (exhibitions, team and mixed events) — and, defensively, for a value
    /// this library version does not know.
    public let tour: Tour?
    /// Stable tournament identity — one id per tournament × event type,
    /// stable across seasons; joins `/tournaments/{id}`. `nil` on matches
    /// ingested before the catalogue covered their tournament.
    public let tournamentId: String?
    /// `"hard"`, `"clay"` or `"grass"`.
    public let surface: String?
    /// Whether the court is indoors.
    public let indoor: Bool
    /// `"BO3"` or `"BO5"`.
    public let format: String?
    /// The round name as the feed labels it, free text.
    public let round: String?
    /// The round in the archive's controlled vocabulary (`"F"`, `"SF"`,
    /// `"QF"`, `"R16"` … `"Q"` for a qualifying round the feed does not
    /// number), normalised from ``round``. `nil` when the label is
    /// unrecognised — never guessed.
    public let roundCode: String?
    /// The lifecycle state.
    public let status: MatchStatus
    /// How the match ended (or paused) when it did not run its course:
    /// `"Retired"`, `"Cancelled"`, `"Walk Over"`, `"Postponed"` or
    /// `"Interrupted"` (an in-play suspension — the match is paused, not
    /// over). `nil` means it completed normally OR the outcome was never
    /// resolved; the feed does not distinguish those.
    public let eventStatus: String?
    /// Whether this is a doubles match.
    public let isDoubles: Bool
    /// The scheduled start (ISO 8601 UTC).
    public let scheduledTime: String?
    /// Both sides.
    public let players: Players?
    /// The latest score. `nil` for an upcoming match that has not started —
    /// always check before unwrapping.
    public let score: Score?
    /// 1 or 2 on a completed match, derived from the final sets. `nil` while
    /// unfinished or indeterminate.
    public let winner: Int?
    /// Which player retired or conceded the walkover, 1 or 2 — by the rules
    /// of the sport, always the loser. Present only when ``eventStatus`` is
    /// `"Retired"` or `"Walk Over"` and the winner is derivable.
    public let withdrew: Int?
    /// The match-winner market, embedded at PRO and above.
    public let market: Market?
    /// The model analysis, embedded at ULTRA.
    public let analysis: Analysis?

    enum CodingKeys: String, CodingKey {
        case id, tournament, tour, surface, indoor, format, round, status
        case players, score, winner, withdrew, market, analysis
        case tournamentId = "tournament_id"
        case roundCode = "round_code"
        case eventStatus = "event_status"
        case isDoubles = "is_doubles"
        case scheduledTime = "scheduled_time"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(Int64.self, forKey: .id) ?? 0
        tournament = try c.decodeIfPresent(String.self, forKey: .tournament) ?? ""
        tour = (try c.decodeIfPresent(String.self, forKey: .tour)).flatMap { Tour(rawValue: $0) }
        tournamentId = try c.decodeIfPresent(String.self, forKey: .tournamentId)
        surface = try c.decodeIfPresent(String.self, forKey: .surface)
        indoor = try c.decodeIfPresent(Bool.self, forKey: .indoor) ?? false
        format = try c.decodeIfPresent(String.self, forKey: .format)
        round = try c.decodeIfPresent(String.self, forKey: .round)
        roundCode = try c.decodeIfPresent(String.self, forKey: .roundCode)
        status = try c.decodeIfPresent(MatchStatus.self, forKey: .status) ?? .unknown
        eventStatus = try c.decodeIfPresent(String.self, forKey: .eventStatus)
        isDoubles = try c.decodeIfPresent(Bool.self, forKey: .isDoubles) ?? false
        scheduledTime = try c.decodeIfPresent(String.self, forKey: .scheduledTime)
        players = try c.decodeIfPresent(Players.self, forKey: .players)
        score = try c.decodeIfPresent(Score.self, forKey: .score)
        winner = try c.decodeIfPresent(Int.self, forKey: .winner)
        withdrew = try c.decodeIfPresent(Int.self, forKey: .withdrew)
        market = try c.decodeIfPresent(Market.self, forKey: .market)
        analysis = try c.decodeIfPresent(Analysis.self, forKey: .analysis)
    }
}

/// One price tick on a match-winner market. PRO and above.
public struct Price: Decodable, Sendable {
    /// 1 for player 1's outcome, 2 for player 2's.
    public let side: Int?
    /// The best bid, 0 to 1. `nil` when absent — different from a bid of 0.
    public let bid: Double?
    /// The best ask, 0 to 1.
    public let ask: Double?
    /// The midpoint between bid and ask.
    public let mid: Double?
    /// The gap between bid and ask.
    public let spread: Double?
    /// When the tick was observed (ISO 8601 UTC).
    public let timestamp: String?
}

/// A match-winner market. PRO and above.
public struct Market: Decodable, Sendable {
    /// The market's identifier.
    public let id: Int64
    /// The market's question text.
    public let question: String?
    /// `"active"`, `"resolved"` or `"closed"`.
    public let status: String?
    /// Traded volume. `nil` when absent, which is not zero volume.
    public let volume: Double?
    /// Available liquidity.
    public let liquidity: Double?
    /// When the market closes (ISO 8601 UTC).
    public let endDate: String?
    /// Recent ticks, newest first. Populated by
    /// ``LiveTennisApiClient/getMarketPrices(matchId:limit:)`` and the
    /// match-detail embed; empty on
    /// ``LiveTennisApiClient/listMarkets(matchId:)``.
    public let prices: [Price]

    enum CodingKeys: String, CodingKey {
        case id, question, status, volume, liquidity, prices
        case endDate = "end_date"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(Int64.self, forKey: .id) ?? 0
        question = try c.decodeIfPresent(String.self, forKey: .question)
        status = try c.decodeIfPresent(String.self, forKey: .status)
        volume = try c.decodeIfPresent(Double.self, forKey: .volume)
        liquidity = try c.decodeIfPresent(Double.self, forKey: .liquidity)
        endDate = try c.decodeIfPresent(String.self, forKey: .endDate)
        prices = try c.decodeIfPresent([Price].self, forKey: .prices) ?? []
    }
}

/// The model's read on a match. ULTRA only.
///
/// Either half may be `nil`: the model does not cover every match, and a
/// match it has not analysed returns both halves null rather than a 404.
public struct Analysis: Decodable, Sendable {
    /// The directional call, or `nil` if the model has none.
    public let thesis: Thesis?
    /// The pre-match shape of the contest, or `nil`.
    public let profile: Profile?
}

/// The model's directional call on a match.
public struct Thesis: Decodable, Sendable {
    /// The player the model favours, 1 or 2.
    public let pickSide: Int?
    /// The model's confidence, 0 to 1.
    public let confidence: Double?
    /// The probability the picked side wins, 0 to 1.
    public let winProbabilityPick: Double?
    /// How the thesis has held up in play: `"valid"`, `"confirmed"`,
    /// `"weakened"` or `"broken"`.
    public let state: String?
    /// The prose argument.
    public let reasoning: String?
    /// The reasoning broken into named factors.
    public let notes: ThesisNotes?
    /// If-then scenarios; the v1 schema does not pin their shape.
    public let scenarioPlaybook: JSONValue?
    /// When the thesis was generated (ISO 8601 UTC).
    public let createdAt: String?

    enum CodingKeys: String, CodingKey {
        case confidence, state, reasoning, notes
        case pickSide = "pick_side"
        case winProbabilityPick = "win_probability_pick"
        case scenarioPlaybook = "scenario_playbook"
        case createdAt = "created_at"
    }
}

/// The named factors behind a ``Thesis``.
public struct ThesisNotes: Decodable, Sendable {
    /// How the two games interact.
    public let matchup: String?
    /// Surface, altitude, conditions.
    public let environment: String?
    /// Recent workload.
    public let fatigue: String?
}

/// The model's pre-match shape of a contest.
public struct Profile: Decodable, Sendable {
    /// The probability player 1 wins, 0 to 1.
    public let winProbabilityP1: Double?
    /// How close the model expects the match to be.
    public let expectedCloseness: Double?
    /// `"low"`, `"med"` or `"high"`.
    public let volatilityRating: String?
    /// The drivers behind the profile.
    public let keyFactors: [String]?
    /// When the profile was generated (ISO 8601 UTC).
    public let createdAt: String?

    enum CodingKeys: String, CodingKey {
        case winProbabilityP1 = "win_probability_p1"
        case expectedCloseness = "expected_closeness"
        case volatilityRating = "volatility_rating"
        case keyFactors = "key_factors"
        case createdAt = "created_at"
    }
}

/// Something that happened in a match. PRO and above.
public struct MatchEvent: Decodable, Sendable {
    /// The kind of event.
    public let type: EventType
    /// Which side it happened to, 1 or 2. `nil` when it applies to neither.
    public let player: Int?
    /// When it happened (ISO 8601 UTC).
    public let timestamp: String?
}

/// A scheduled match on the calendar.
///
/// Fixtures are name-only: the players are not yet resolved to player
/// records, so there are no ids or rankings here. Once a fixture goes live it
/// appears through ``LiveTennisApiClient/listMatches(status:tour:players:country:from:to:limit:offset:)``
/// as a ``Match`` with full ``Player`` objects.
public struct Fixture: Decodable, Sendable {
    /// The fixture's identifier.
    public let id: Int64
    /// The calendar date of the fixture.
    public let eventDate: String?
    /// The scheduled start (ISO 8601 UTC). `nil` until the order of play
    /// assigns a time — a date-only fixture is a real state.
    public let startTime: String?
    /// The record's OWN tour — opaque, **not** the ``Tour`` filter vocabulary
    /// (see ``Player/tour``).
    public let tour: String?
    /// The event name.
    public let tournament: String?
    /// The round name.
    public let round: String?
    /// The round in the controlled vocabulary (same as ``Match/roundCode``).
    public let roundCode: String?
    /// The court surface.
    public let surface: String?
    /// Player 1's name as printed on the calendar. Always present regardless
    /// of whether the id resolved.
    public let player1Name: String?
    /// Player 2's name as printed on the calendar.
    public let player2Name: String?
    /// Our player id, when the participant is in our roster (exact-key
    /// resolution, never a name match). `nil` otherwise.
    public let player1Id: Int64?
    public let player2Id: Int64?
    /// The fixture's status.
    public let status: String?

    enum CodingKeys: String, CodingKey {
        case id, tour, tournament, round, surface, status
        case eventDate = "event_date"
        case startTime = "start_time"
        case roundCode = "round_code"
        case player1Name = "player1_name"
        case player2Name = "player2_name"
        case player1Id = "player1_id"
        case player2Id = "player2_id"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(Int64.self, forKey: .id) ?? 0
        eventDate = try c.decodeIfPresent(String.self, forKey: .eventDate)
        startTime = try c.decodeIfPresent(String.self, forKey: .startTime)
        tour = try c.decodeIfPresent(String.self, forKey: .tour)
        tournament = try c.decodeIfPresent(String.self, forKey: .tournament)
        round = try c.decodeIfPresent(String.self, forKey: .round)
        roundCode = try c.decodeIfPresent(String.self, forKey: .roundCode)
        surface = try c.decodeIfPresent(String.self, forKey: .surface)
        player1Name = try c.decodeIfPresent(String.self, forKey: .player1Name)
        player2Name = try c.decodeIfPresent(String.self, forKey: .player2Name)
        player1Id = try c.decodeIfPresent(Int64.self, forKey: .player1Id)
        player2Id = try c.decodeIfPresent(Int64.self, forKey: .player2Id)
        status = try c.decodeIfPresent(String.self, forKey: .status)
    }
}

/// A tournament in the catalogue — the stable id space ``Match/tournamentId``
/// joins. One row per tournament × event type, stable across seasons.
public struct Tournament: Decodable, Sendable {
    /// The stable id that ``Match/tournamentId`` carries.
    public let id: String
    public let name: String?
    /// The ``Tour`` filter vocabulary, or `nil` (decoded leniently, like
    /// ``Match/tour``).
    public let tour: Tour?
    /// `"hard"`, `"clay"` or `"grass"`.
    public let surface: String?
    public let indoor: Bool
    /// Host city, from a curated table — `nil` where not curated.
    public let city: String?
    /// Host country, ISO-3166 alpha-2 — `nil` where not curated.
    public let country: String?
    /// Tournament category (`"grand_slam"`, `"masters_1000"`, `"atp_250"`,
    /// `"wta_1000"`, …) where the catalogues agree unambiguously — `nil`
    /// otherwise, never derived from the name.
    public let category: String?

    enum CodingKeys: String, CodingKey {
        case id, name, tour, surface, indoor, city, country, category
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? ""
        name = try c.decodeIfPresent(String.self, forKey: .name)
        tour = (try c.decodeIfPresent(String.self, forKey: .tour)).flatMap { Tour(rawValue: $0) }
        surface = try c.decodeIfPresent(String.self, forKey: .surface)
        indoor = try c.decodeIfPresent(Bool.self, forKey: .indoor) ?? false
        city = try c.decodeIfPresent(String.self, forKey: .city)
        country = try c.decodeIfPresent(String.self, forKey: .country)
        category = try c.decodeIfPresent(String.self, forKey: .category)
    }
}
