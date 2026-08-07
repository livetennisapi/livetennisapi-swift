import Foundation

// Models for the analytics surface: rankings, in-play statistics, rally
// construction, shot-level charting and the push-feed token. The same
// conventions as Models.swift apply.

// MARK: - Rankings

/// A ranking system accepted by the `system` filter on
/// ``LiveTennisApiClient/listRankings(players:asOf:systems:limit:offset:)``.
/// Systems are never collapsed into a single "rank" — they are not
/// comparable. ``utr`` is a rating, not a ranking: it has no listing mode
/// and its records carry `rating` with null rank and points.
public enum RankingSystem: String, Sendable, CaseIterable {
    case atp, wta
    case itfJuniors = "itf_jt"
    case itfMen = "itf_mt"
    case itfWomen = "itf_wt"
    case utr
}

/// One ranking record in force at the requested instant.
///
/// Every other ranking field in this API is the player's CURRENT value
/// joined at read time; this endpoint is the point-in-time answer.
public struct RankingRecord: Decodable, Sendable {
    /// Our player id. `nil` on listing rows for players outside our roster,
    /// so the published table has no silent holes.
    public let playerId: Int64?
    /// The name as the ranking publisher printed it — present on listing
    /// rows, absent on per-player records.
    public let playerName: String?
    /// `"atp"`, `"wta"`, `"itf_jt"`, `"itf_mt"`, `"itf_wt"` or `"utr"` —
    /// always explicit.
    public let system: String?
    public let tour: String?
    /// `nil` for UTR (a rating has no rank).
    public let rank: Int?
    /// `nil` for UTR.
    public let points: Int?
    /// The rank at the immediately preceding snapshot week. ATP/WTA only;
    /// `nil` when no prior week is held, and always `nil` for ITF/UTR.
    public let previousRank: Int?
    /// The circuit's own signed weekly movement. ITF systems only.
    public let rankMovement: Int?
    /// UTR only; `nil` elsewhere.
    public let rating: Double?
    /// The publication week this record took effect.
    public let effectiveDate: String?
    public let observedAt: String?

    enum CodingKeys: String, CodingKey {
        case system, tour, rank, points, rating
        case playerId = "player_id"
        case playerName = "player_name"
        case previousRank = "previous_rank"
        case rankMovement = "rank_movement"
        case effectiveDate = "effective_date"
        case observedAt = "observed_at"
    }
}

/// What a rankings request resolved against what was asked. Read it before
/// trusting an empty result — ITF and UTR history begins 2026-07-29 and
/// cannot be reconstructed earlier, so an earlier `asOf` correctly returns
/// nothing for those systems.
public struct RankingCoverage: Decodable, Sendable {
    public let asOf: String?
    public let playersRequested: Int?
    public let playersResolved: Int?
    public let systemsRequested: [String]?
    public let systemsResolved: [String]?
    /// The earliest effective date held, per requested system.
    public let oldestAvailable: [String: String?]?

    enum CodingKeys: String, CodingKey {
        case asOf = "as_of"
        case playersRequested = "players_requested"
        case playersResolved = "players_resolved"
        case systemsRequested = "systems_requested"
        case systemsResolved = "systems_resolved"
        case oldestAvailable = "oldest_available"
    }
}

/// The rankings pagination envelope: ``ListMeta``'s fields plus coverage.
public struct RankingMeta: Decodable, Sendable {
    public let limit: Int?
    public let offset: Int?
    public let count: Int?
    public let total: Int?
    public let hasMore: Bool?
    public let coverage: RankingCoverage?

    enum CodingKeys: String, CodingKey {
        case limit, offset, count, total, coverage
        case hasMore = "has_more"
    }
}

/// One page of ranking records.
public struct RankingsPage: Decodable, Sendable {
    public let data: [RankingRecord]
    public let meta: RankingMeta?

    enum CodingKeys: String, CodingKey { case data, meta }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        data = try c.decodeIfPresent([RankingRecord].self, forKey: .data) ?? []
        meta = try c.decodeIfPresent(RankingMeta.self, forKey: .meta)
    }
}

// MARK: - In-play statistics

/// Coverage of a statistics response or family. An unrecognised payload
/// value decodes as ``unknown``.
public enum StatsCoverage: String, Codable, Sendable {
    /// Current for the live match.
    case live
    /// The closing figures of a completed match (age `nil`).
    case `final`
    /// Held data that has fallen behind the match.
    case stale
    /// Holding nothing for this match — a 200 with null players, not a 404:
    /// the match exists and holding nothing is the honest answer.
    case noData = "none"
    /// The measured family disagrees with the score in a way staleness
    /// cannot explain; its VALUES are withheld and
    /// ``StatisticsFreshness/measuredDivergence`` says why.
    case diverged
    case unknown

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = StatsCoverage(rawValue: raw) ?? .unknown
    }
}

/// Measured counting statistics for one player — COUNTED upstream, not
/// derived from the point record, which is why they can include aces and
/// double faults.
///
/// EVERY field is optional and an absent field is omitted, never
/// zero-filled: read the keys you are given. Aces and double faults are
/// present across every tour; the serve split and break points saved are
/// present on the main tours and absent on ITF singles; winners and
/// unforced errors appear on a minority of main-tour matches. A `…Of` field
/// is the denominator of its base field and a `…Pct` field the percentage,
/// recomputed from the two counts.
public struct MeasuredStatistics: Decodable, Sendable {
    public let aces: Int?
    public let doubleFaults: Int?
    public let pointsWon: Int?
    public let gamesWon: Int?
    public let servicePointsWon: Int?
    public let serviceGamesPlayed: Int?
    public let serviceGamesWon: Int?
    public let returnPointsWon: Int?
    public let breakPointsWon: Int?
    public let breakPointsSaved: Int?
    public let breakPointsSavedOf: Int?
    public let breakPointsSavedPct: Int?
    public let tiebreaksWon: Int?
    public let maxPointsInRow: Int?
    public let maxGamesInRow: Int?
    public let firstServesIn: Int?
    public let firstServesInOf: Int?
    public let firstServesInPct: Int?
    public let firstServePointsWon: Int?
    public let firstServePointsWonOf: Int?
    public let firstServePointsWonPct: Int?
    public let secondServesIn: Int?
    public let secondServesInOf: Int?
    public let secondServesInPct: Int?
    public let secondServePointsWon: Int?
    public let secondServePointsWonOf: Int?
    public let secondServePointsWonPct: Int?
    public let firstReturnPointsWon: Int?
    public let firstReturnPointsWonOf: Int?
    public let firstReturnPointsWonPct: Int?
    public let secondReturnPointsWon: Int?
    public let secondReturnPointsWonOf: Int?
    public let secondReturnPointsWonPct: Int?
    public let winnersTotal: Int?
    public let errorsTotal: Int?
    public let unforcedErrorsTotal: Int?
    public let forehandWinners: Int?
    public let forehandErrors: Int?
    public let forehandUnforcedErrors: Int?
    public let backhandWinners: Int?
    public let backhandErrors: Int?
    public let backhandUnforcedErrors: Int?
    public let groundstrokeWinners: Int?
    public let groundstrokeErrors: Int?
    public let groundstrokeUnforcedErrors: Int?
    public let volleyWinners: Int?
    public let volleyUnforcedErrors: Int?
    public let dropShotWinners: Int?
    public let dropShotUnforcedErrors: Int?
    public let lobWinners: Int?
    public let lobUnforcedErrors: Int?
    public let overheadWinners: Int?
    public let overheadErrors: Int?
    public let returnWinners: Int?
    public let returnErrors: Int?

    enum CodingKeys: String, CodingKey {
        case aces
        case doubleFaults = "double_faults"
        case pointsWon = "points_won"
        case gamesWon = "games_won"
        case servicePointsWon = "service_points_won"
        case serviceGamesPlayed = "service_games_played"
        case serviceGamesWon = "service_games_won"
        case returnPointsWon = "return_points_won"
        case breakPointsWon = "break_points_won"
        case breakPointsSaved = "break_points_saved"
        case breakPointsSavedOf = "break_points_saved_of"
        case breakPointsSavedPct = "break_points_saved_pct"
        case tiebreaksWon = "tiebreaks_won"
        case maxPointsInRow = "max_points_in_row"
        case maxGamesInRow = "max_games_in_row"
        case firstServesIn = "first_serves_in"
        case firstServesInOf = "first_serves_in_of"
        case firstServesInPct = "first_serves_in_pct"
        case firstServePointsWon = "first_serve_points_won"
        case firstServePointsWonOf = "first_serve_points_won_of"
        case firstServePointsWonPct = "first_serve_points_won_pct"
        case secondServesIn = "second_serves_in"
        case secondServesInOf = "second_serves_in_of"
        case secondServesInPct = "second_serves_in_pct"
        case secondServePointsWon = "second_serve_points_won"
        case secondServePointsWonOf = "second_serve_points_won_of"
        case secondServePointsWonPct = "second_serve_points_won_pct"
        case firstReturnPointsWon = "first_return_points_won"
        case firstReturnPointsWonOf = "first_return_points_won_of"
        case firstReturnPointsWonPct = "first_return_points_won_pct"
        case secondReturnPointsWon = "second_return_points_won"
        case secondReturnPointsWonOf = "second_return_points_won_of"
        case secondReturnPointsWonPct = "second_return_points_won_pct"
        case winnersTotal = "winners_total"
        case errorsTotal = "errors_total"
        case unforcedErrorsTotal = "unforced_errors_total"
        case forehandWinners = "forehand_winners"
        case forehandErrors = "forehand_errors"
        case forehandUnforcedErrors = "forehand_unforced_errors"
        case backhandWinners = "backhand_winners"
        case backhandErrors = "backhand_errors"
        case backhandUnforcedErrors = "backhand_unforced_errors"
        case groundstrokeWinners = "groundstroke_winners"
        case groundstrokeErrors = "groundstroke_errors"
        case groundstrokeUnforcedErrors = "groundstroke_unforced_errors"
        case volleyWinners = "volley_winners"
        case volleyUnforcedErrors = "volley_unforced_errors"
        case dropShotWinners = "drop_shot_winners"
        case dropShotUnforcedErrors = "drop_shot_unforced_errors"
        case lobWinners = "lob_winners"
        case lobUnforcedErrors = "lob_unforced_errors"
        case overheadWinners = "overhead_winners"
        case overheadErrors = "overhead_errors"
        case returnWinners = "return_winners"
        case returnErrors = "return_errors"
    }
}

/// One player's in-play statistics, in TWO families that are deliberately
/// not merged. The fields at this level are DERIVED from the point-by-point
/// record; ``measured`` holds counts taken upstream. Both families name some
/// of the same quantities, computed two entirely different ways — that is a
/// cross-check, not a duplication to collapse. Percentages are `nil` when no
/// qualifying game or point was played — never 0, so a present 0 is a real
/// measured zero.
public struct MatchStatisticsSide: Decodable, Sendable {
    public let measured: MeasuredStatistics?
    public let serviceGamesPlayed: Int?
    public let serviceGamesWon: Int?
    public let holdPct: Int?
    public let returnGamesPlayed: Int?
    public let returnGamesWon: Int?
    public let breakPct: Int?
    public let breakPointsFaced: Int?
    public let breakPointsSaved: Int?
    public let breakPointsSavedPct: Int?
    public let breakPointsPlayed: Int?
    public let breakPointsConverted: Int?
    public let breakPointsConvertedPct: Int?
    public let servicePointsPlayed: Int?
    public let servicePointsWon: Int?
    public let servicePointsWonPct: Int?
    public let returnPointsPlayed: Int?
    public let returnPointsWon: Int?
    public let returnPointsWonPct: Int?
    public let pointsPlayed: Int?
    public let pointsWon: Int?

    enum CodingKeys: String, CodingKey {
        case measured
        case serviceGamesPlayed = "service_games_played"
        case serviceGamesWon = "service_games_won"
        case holdPct = "hold_pct"
        case returnGamesPlayed = "return_games_played"
        case returnGamesWon = "return_games_won"
        case breakPct = "break_pct"
        case breakPointsFaced = "break_points_faced"
        case breakPointsSaved = "break_points_saved"
        case breakPointsSavedPct = "break_points_saved_pct"
        case breakPointsPlayed = "break_points_played"
        case breakPointsConverted = "break_points_converted"
        case breakPointsConvertedPct = "break_points_converted_pct"
        case servicePointsPlayed = "service_points_played"
        case servicePointsWon = "service_points_won"
        case servicePointsWonPct = "service_points_won_pct"
        case returnPointsPlayed = "return_points_played"
        case returnPointsWon = "return_points_won"
        case returnPointsWonPct = "return_points_won_pct"
        case pointsPlayed = "points_played"
        case pointsWon = "points_won"
    }
}

/// The match state a statistics family describes, per upstream.
/// `ageSeconds` says when we fetched; this says WHAT we fetched.
public struct StatisticsDescribes: Decodable, Sendable {
    public let gamesP1: [Int]?
    public let gamesP2: [Int]?
    public let totalGames: Int?

    enum CodingKeys: String, CodingKey {
        case gamesP1 = "games_p1"
        case gamesP2 = "games_p2"
        case totalGames = "total_games"
    }
}

/// Per-family coverage and age.
public struct StatisticsFamily: Decodable, Sendable {
    public let coverage: StatsCoverage?
    public let asOf: String?
    /// THE TWO FAMILIES USE DIFFERENT CLOCKS — do not compare their ages.
    /// The derived age is measured against the newest SCORE row (between
    /// points there is no new score either); the measured age is wall
    /// clock, because those are fetched on a fixed cadence.
    public let ageSeconds: Int?
    public let describes: StatisticsDescribes?

    enum CodingKeys: String, CodingKey {
        case coverage, describes
        case asOf = "as_of"
        case ageSeconds = "age_seconds"
    }
}

/// Why the measured values were withheld, with both match states.
public struct MeasuredDivergence: Decodable, Sendable {
    public let reason: String?
    public let gamesInStatistics: Int?
    public let gamesInScore: Int?
    /// Positive = statistics ahead of the score, which staleness cannot
    /// cause.
    public let deltaGames: Int?
    public let detail: String?

    enum CodingKeys: String, CodingKey {
        case reason, detail
        case gamesInStatistics = "games_in_statistics"
        case gamesInScore = "games_in_score"
        case deltaGames = "delta_games"
    }
}

/// Per-family coverage and age. Branch on this rather than on the top-level
/// coverage, which only summarises the response.
public struct StatisticsFreshness: Decodable, Sendable {
    /// `nil` when the families agree.
    public let measuredDivergence: MeasuredDivergence?
    public let derived: StatisticsFamily?
    public let measured: StatisticsFamily?

    enum CodingKeys: String, CodingKey {
        case derived, measured
        case measuredDivergence = "measured_divergence"
    }
}

/// Both players' statistics.
public struct MatchStatisticsPlayers: Decodable, Sendable {
    public let p1: MatchStatisticsSide?
    public let p2: MatchStatisticsSide?
}

/// In-play statistics for one match, from
/// ``LiveTennisApiClient/getMatchStatistics(_:)``. They can be further
/// behind the match than the score, which is why they carry their own
/// freshness rather than living on the score object.
public struct MatchStatistics: Decodable, Sendable {
    public let matchId: Int64
    /// Summarises the response; branch on ``freshness`` per family.
    public let coverage: StatsCoverage?
    public let asOf: String?
    /// Behind the newest SCORE row, not the wall clock.
    public let ageSeconds: Int?
    public let gamesCounted: Int?
    /// Tiebreaks are excluded from the derived family and counted here —
    /// the live record collapses a whole tiebreak onto one entry.
    public let tiebreakGamesExcluded: Int?
    /// Games whose recorded outcome is neither a legal hold nor a legal
    /// break.
    public let inconsistentGamesExcluded: Int?
    public let setsCovered: [Int]
    public let freshness: StatisticsFreshness?
    /// Present only when coverage is ``StatsCoverage/noData``.
    public let detail: String?
    /// `nil` when we hold nothing for the match — a 200, not a 404.
    public let players: MatchStatisticsPlayers?

    enum CodingKeys: String, CodingKey {
        case coverage, freshness, detail, players
        case matchId = "match_id"
        case asOf = "as_of"
        case ageSeconds = "age_seconds"
        case gamesCounted = "games_counted"
        case tiebreakGamesExcluded = "tiebreak_games_excluded"
        case inconsistentGamesExcluded = "inconsistent_games_excluded"
        case setsCovered = "sets_covered"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        matchId = try c.decodeIfPresent(Int64.self, forKey: .matchId) ?? 0
        coverage = try c.decodeIfPresent(StatsCoverage.self, forKey: .coverage)
        asOf = try c.decodeIfPresent(String.self, forKey: .asOf)
        ageSeconds = try c.decodeIfPresent(Int.self, forKey: .ageSeconds)
        gamesCounted = try c.decodeIfPresent(Int.self, forKey: .gamesCounted)
        tiebreakGamesExcluded = try c.decodeIfPresent(Int.self, forKey: .tiebreakGamesExcluded)
        inconsistentGamesExcluded = try c.decodeIfPresent(Int.self, forKey: .inconsistentGamesExcluded)
        setsCovered = try c.decodeIfPresent([Int].self, forKey: .setsCovered) ?? []
        freshness = try c.decodeIfPresent(StatisticsFreshness.self, forKey: .freshness)
        detail = try c.decodeIfPresent(String.self, forKey: .detail)
        players = try c.decodeIfPresent(MatchStatisticsPlayers.self, forKey: .players)
    }
}

// MARK: - Rally construction (charted matches)

/// The gender filter on
/// ``LiveTennisApiClient/listRallyMatches(player:from:to:surface:gender:limit:offset:)``.
public enum RallyGender: String, Sendable, CaseIterable {
    case men = "M"
    case women = "W"
}

/// One participant of a charted match.
public struct RallyPlayerRef: Decodable, Sendable {
    public let name: String?
    /// `"R"`, `"L"`, `"U"` (unknown) or `"A"` (ambidextrous).
    public let hand: String?
}

/// A charted match with shot-by-shot data available. Its OWN id space: the
/// charted corpus reaches back decades and concentrates on the biggest
/// events, so most charted matches have no counterpart in our live table.
public struct RallyMatch: Decodable, Sendable {
    /// The id this product is keyed on.
    public let rallyMatchId: Int64
    public let sourceId: String?
    /// OUR match id, when the charted match is also one we hold. `nil`
    /// otherwise — most charted matches predate our own collection.
    public let matchId: Int64?
    public let date: String?
    public let tournament: String?
    public let round: String?
    public let surface: String?
    /// `"M"` or `"W"`.
    public let gender: String?
    public let bestOf: Int?
    public let players: [RallyPlayerRef]
    /// Charted points in this match.
    public let points: Int?
    /// How many of them our parser read cleanly — the per-match quality
    /// number.
    public let pointsParsed: Int?

    enum CodingKeys: String, CodingKey {
        case date, tournament, round, surface, gender, players, points
        case rallyMatchId = "rally_match_id"
        case sourceId = "source_id"
        case matchId = "match_id"
        case bestOf = "best_of"
        case pointsParsed = "points_parsed"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        rallyMatchId = try c.decodeIfPresent(Int64.self, forKey: .rallyMatchId) ?? 0
        sourceId = try c.decodeIfPresent(String.self, forKey: .sourceId)
        matchId = try c.decodeIfPresent(Int64.self, forKey: .matchId)
        date = try c.decodeIfPresent(String.self, forKey: .date)
        tournament = try c.decodeIfPresent(String.self, forKey: .tournament)
        round = try c.decodeIfPresent(String.self, forKey: .round)
        surface = try c.decodeIfPresent(String.self, forKey: .surface)
        gender = try c.decodeIfPresent(String.self, forKey: .gender)
        bestOf = try c.decodeIfPresent(Int.self, forKey: .bestOf)
        players = try c.decodeIfPresent([RallyPlayerRef].self, forKey: .players) ?? []
        points = try c.decodeIfPresent(Int.self, forKey: .points)
        pointsParsed = try c.decodeIfPresent(Int.self, forKey: .pointsParsed)
    }
}

/// One stroke of a charted point. Shots are numbered from the serve: serve
/// 1, return 2, the server's next ball 3.
public struct RallyShot: Decodable, Sendable {
    public let number: Int?
    /// The charter's raw code, e.g. `"f"`.
    public let code: String?
    /// `"serve"`, `"groundstroke"`, `"slice"`, `"volley"`, `"overhead"`,
    /// `"drop_shot"`, `"lob"`, …
    public let stroke: String?
    /// The side it was struck FROM: `"forehand"` or `"backhand"`.
    public let wing: String?
    /// Where the ball was sent: `"forehand_side"`, `"middle"` or
    /// `"backhand_side"`.
    public let direction: String?
    /// `"shallow"`, `"mid"` or `"deep"`.
    public let depth: String?
    /// `"approaching"`, `"at_net"` or `"baseline"`.
    public let position: String?
}

/// One charted point. ``raw`` is the charter's own string, verbatim, and is
/// always present; the parsed fields are our reading of it. ``parsed`` is
/// false when the notation contained something we could not read cleanly —
/// the recognised part is still returned. A consumer who wants only
/// unambiguous rows filters on `parsed`.
public struct RallyPoint: Decodable, Sendable {
    public let point: Int?
    /// `[sets_p1, sets_p2]` before this point; entries can be null.
    public let set: [Int?]?
    /// `[games_p1, games_p2]` before this point; entries can be null.
    public let games: [Int?]?
    /// e.g. `"30-40"`.
    public let score: String?
    public let game: Int?
    public let isTiebreak: Bool
    public let server: Int?
    public let pointWinner: Int?
    /// The charter's shot string; both serves joined by `";"` when the
    /// first was a fault.
    public let raw: String?
    public let parsed: Bool
    public let serveNumber: Int?
    /// `"wide"`, `"body"` or `"down_the_t"`.
    public let serveDirection: String?
    /// Strokes including the serve. An ace is 1, a double fault 0.
    public let rallyLength: Int?
    /// `"winner"`, `"forced_error"`, `"unforced_error"`, `"error"` (a miss
    /// the charter did not classify) or `"other"`. Never guessed.
    public let outcome: String?
    /// `"net"`, `"wide"`, `"deep"` or `"wide_and_deep"`.
    public let errorLocation: String?
    public let endingStroke: String?
    public let endingWing: String?
    public let isAce: Bool
    public let isDoubleFault: Bool
    public let isServeAndVolley: Bool
    public let shots: [RallyShot]

    enum CodingKeys: String, CodingKey {
        case point, set, games, score, game, server, raw, parsed, outcome, shots
        case isTiebreak = "is_tiebreak"
        case pointWinner = "point_winner"
        case serveNumber = "serve_number"
        case serveDirection = "serve_direction"
        case rallyLength = "rally_length"
        case errorLocation = "error_location"
        case endingStroke = "ending_stroke"
        case endingWing = "ending_wing"
        case isAce = "is_ace"
        case isDoubleFault = "is_double_fault"
        case isServeAndVolley = "is_serve_and_volley"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        point = try c.decodeIfPresent(Int.self, forKey: .point)
        set = try c.decodeIfPresent([Int?].self, forKey: .set)
        games = try c.decodeIfPresent([Int?].self, forKey: .games)
        score = try c.decodeIfPresent(String.self, forKey: .score)
        game = try c.decodeIfPresent(Int.self, forKey: .game)
        isTiebreak = try c.decodeIfPresent(Bool.self, forKey: .isTiebreak) ?? false
        server = try c.decodeIfPresent(Int.self, forKey: .server)
        pointWinner = try c.decodeIfPresent(Int.self, forKey: .pointWinner)
        raw = try c.decodeIfPresent(String.self, forKey: .raw)
        parsed = try c.decodeIfPresent(Bool.self, forKey: .parsed) ?? false
        serveNumber = try c.decodeIfPresent(Int.self, forKey: .serveNumber)
        serveDirection = try c.decodeIfPresent(String.self, forKey: .serveDirection)
        rallyLength = try c.decodeIfPresent(Int.self, forKey: .rallyLength)
        outcome = try c.decodeIfPresent(String.self, forKey: .outcome)
        errorLocation = try c.decodeIfPresent(String.self, forKey: .errorLocation)
        endingStroke = try c.decodeIfPresent(String.self, forKey: .endingStroke)
        endingWing = try c.decodeIfPresent(String.self, forKey: .endingWing)
        isAce = try c.decodeIfPresent(Bool.self, forKey: .isAce) ?? false
        isDoubleFault = try c.decodeIfPresent(Bool.self, forKey: .isDoubleFault) ?? false
        isServeAndVolley = try c.decodeIfPresent(Bool.self, forKey: .isServeAndVolley) ?? false
        shots = try c.decodeIfPresent([RallyShot].self, forKey: .shots) ?? []
    }
}

/// One charted match with its points in play order — the header fields plus
/// ``rally``. `meta.total` is the match's full point count, so page with
/// `limit`/`offset` until you have them all.
public struct RallyTape: Decodable, Sendable {
    /// The charted match header (the same shape as list rows).
    public let match: RallyMatch
    /// The charted points, in play order.
    public let rally: [RallyPoint]
    public let meta: ListMeta?

    enum CodingKeys: String, CodingKey { case rally, meta }

    public init(from decoder: Decoder) throws {
        match = try RallyMatch(from: decoder)
        let c = try decoder.container(keyedBy: CodingKeys.self)
        rally = try c.decodeIfPresent([RallyPoint].self, forKey: .rally) ?? []
        meta = try c.decodeIfPresent(ListMeta.self, forKey: .meta)
    }
}

// MARK: - Shot-level charting aggregates

/// The gender disambiguator on
/// ``LiveTennisApiClient/getChartingPlayer(name:gender:)``.
public enum ChartingGender: String, Sendable, CaseIterable {
    case men, women
}

/// A player's career shot-level charting aggregate — every field a raw SUM
/// over the player's charted matches. ``matchesCharted`` states the sample;
/// coverage is curated (concentrated on the majors), not full-slate.
public struct ChartingPlayer: Decodable, Sendable {
    /// The resolved player identity. Unpinned JSON.
    public let player: JSONValue?
    public let matchesCharted: Int?
    public let coverage: String?
    /// Per-family summed numeric columns (serve placement, return depth,
    /// net play, clutch serving, winners/errors by wing, rally length and
    /// direction tendencies). The v1 schema does not pin the shape.
    public let families: JSONValue?

    enum CodingKeys: String, CodingKey {
        case player, coverage, families
        case matchesCharted = "matches_charted"
    }
}

/// One charted match, every stat family for both players, with the per-set
/// split exactly as charted.
public struct ChartingMatch: Decodable, Sendable {
    public let chartingMatchId: Int64
    /// The Match Charting Project's own id string.
    public let mcpId: String?
    public let gender: String?
    /// Unpinned JSON.
    public let players: JSONValue?
    /// Per-family stats with the row/set 1, 2, Total split. Unpinned JSON.
    public let families: JSONValue?

    enum CodingKeys: String, CodingKey {
        case gender, players, families
        case chartingMatchId = "charting_match_id"
        case mcpId = "mcp_id"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        chartingMatchId = try c.decodeIfPresent(Int64.self, forKey: .chartingMatchId) ?? 0
        mcpId = try c.decodeIfPresent(String.self, forKey: .mcpId)
        gender = try c.decodeIfPresent(String.self, forKey: .gender)
        players = try c.decodeIfPresent(JSONValue.self, forKey: .players)
        families = try c.decodeIfPresent(JSONValue.self, forKey: .families)
    }
}

// MARK: - Push feed

/// The channel vocabulary of the push WebSocket.
public struct WsChannels: Codable, Sendable {
    /// The per-match channel template, `"match:{id}"` — substitute the
    /// match id.
    public let match: String?
    /// The all-live-scores channel, `"slate:all"` — every live score frame.
    public let slate: String?
}

/// A short-lived connection token for the high-fan-out push feed, from
/// ``LiveTennisApiClient/getWsToken()``. Frames are the same allowlist
/// score objects the polling endpoints return. Mint a fresh token on
/// reconnect.
public struct WsToken: Codable, Sendable {
    /// The signed token to present to ``wsUrl``.
    public let token: String
    /// Seconds until the token expires.
    public let expiresIn: Int?
    /// The push WebSocket URL.
    public let wsUrl: String?
    /// The channel vocabulary, including the `"slate:all"` channel.
    public let channels: WsChannels?

    enum CodingKeys: String, CodingKey {
        case token, channels
        case expiresIn = "expires_in"
        case wsUrl = "ws_url"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        token = try c.decodeIfPresent(String.self, forKey: .token) ?? ""
        expiresIn = try c.decodeIfPresent(Int.self, forKey: .expiresIn)
        wsUrl = try c.decodeIfPresent(String.self, forKey: .wsUrl)
        channels = try c.decodeIfPresent(WsChannels.self, forKey: .channels)
    }
}
