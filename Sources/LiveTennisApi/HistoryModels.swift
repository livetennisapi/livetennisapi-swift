import Foundation

// Models for the history half of the API: the per-match tape, head-to-head,
// the deep results archive (1968–2022) and the bulk history packages. The
// same conventions as Models.swift apply: optionals wherever the API can
// send `null` or omit a field, unknown fields ignored.

// MARK: - Per-match tape

/// Which tape sequence to request from
/// ``LiveTennisApiClient/getMatchTape(_:sequence:)``.
public enum TapeSequence: String, Sendable, CaseIterable {
    /// Every row we committed — deliberately non-monotonic, since independent
    /// sources race and a higher-trust one may correct a lower-trust one
    /// backwards. The API's default.
    case raw
    /// One row per distinct score state, keeping the last assertion of each.
    /// The only sequence whose rows carry ``TapeRow/pointWinner``.
    case clean
}

/// How a tape came to exist — specifically, whether we WATCHED the match.
/// A statement about how the rows were obtained, **not** a synonym for
/// "complete". An unrecognised payload value decodes as ``unknown``.
public enum TapeCoverage: String, Codable, Sendable {
    /// We watched the match live from 0-0; every row carries a real
    /// timestamp.
    case fromStart = "from_start"
    /// We watched it, but recording began after play had started and no
    /// reconstruction is available to repair the opening.
    case partial
    /// The tape opens with rows expanded after the fact from a
    /// finished-match point-by-point record. True about the score, silent
    /// about the clock.
    case reconstructed
    /// As ``reconstructed``, AND the reconstruction is known not to cover
    /// the whole match — it opens after 0-0 or stops short of the final
    /// score. Nothing is synthesised to close either gap, but the match must
    /// not be backtested as if it were complete.
    case reconstructedPartial = "reconstructed_partial"
    /// No rows: the match was on the calendar and was neither watched nor
    /// reconstructable.
    case noTape = "none"
    case unknown

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = TapeCoverage(rawValue: raw) ?? .unknown
    }
}

/// One row of a match's score sequence — the same shape as ``Score`` plus
/// ``pointWinner``.
///
/// Rows we watched live carry a real ``timestamp``. Rows expanded after the
/// fact from a finished-match record carry a null `timestamp` AND null model
/// fields, because neither a wall clock nor a model output ever existed for
/// them — nothing is synthesised. A null `timestamp` is the reliable
/// row-level marker of a reconstructed row.
public struct TapeRow: Decodable, Sendable {
    /// `[sets_p1, sets_p2]`.
    public let sets: [Int]
    /// `[games_p1, games_p2]`, each a per-set list — player-major, exactly
    /// like ``Score/games``.
    public let games: [[Int]]
    /// The current game's points as strings; entries can be null on a dead
    /// row.
    public let points: [String?]
    /// Which player is serving, 1 or 2, `nil` when unknown.
    public let server: Int?
    /// Whether the current game is a tiebreak.
    public let isTiebreak: Bool
    /// The live model's probability that player 1 wins. ULTRA windows only;
    /// null also means "the model had no output for this row".
    public let winProbabilityP1: Double?
    /// The live model's danger rating.
    public let danger: Double?
    /// When the row was observed (ISO 8601 UTC). Null on reconstructed rows.
    public let timestamp: String?
    /// Who won the point this row records, 1 or 2 — present ONLY on
    /// `sequence=clean` rows, and only where the transition from the
    /// previous row is a single attributable point; `nil` on gaps, torn rows
    /// and the first row. Never on the raw sequence. Derived at read time,
    /// never stored or guessed.
    public let pointWinner: Int?

    enum CodingKeys: String, CodingKey {
        case sets, games, points, server, danger, timestamp
        case isTiebreak = "is_tiebreak"
        case winProbabilityP1 = "win_probability_p1"
        case pointWinner = "point_winner"
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
        pointWinner = try c.decodeIfPresent(Int.self, forKey: .pointWinner)
    }
}

/// A set's final tiebreak score, `p1`-`p2`.
public struct SetTiebreak: Decodable, Sendable {
    public let p1: Int
    public let p2: Int
}

/// The coverage metadata beside a tape.
public struct TapeMeta: Decodable, Sendable {
    /// The match id.
    public let matchId: Int64?
    /// Rows RETURNED — after any `sequence=clean` collapse.
    public let rows: Int?
    /// How the tape came to exist. Check before backtesting.
    public let coverage: TapeCoverage?
    /// Where the rows came from: `"observed"` (every row watched live),
    /// `"reconstructed"` (every row expanded after the fact), `"mixed"` (a
    /// reconstructed opening followed by what we watched), or `nil` on an
    /// empty tape. Reported once here, never per row.
    public let pointSource: String?
    /// Rows BEFORE any collapse — equals ``rows`` when `sequence=raw`.
    public let rawRows: Int?
    /// Distinct score states in the raw tape. `rawRows` minus this is pure
    /// repetition.
    public let uniqueStates: Int?
    /// Echoes the requested `?sequence=`, `"raw"` or `"clean"`.
    public let sequence: String?
    /// The rows were served from the immutable archive rather than the live
    /// table. Informational — the content contract is identical.
    public let fromArchive: Bool?
    /// When the response was assembled (ISO 8601 UTC).
    public let generatedAt: String?

    enum CodingKeys: String, CodingKey {
        case rows, coverage, sequence
        case matchId = "match_id"
        case pointSource = "point_source"
        case rawRows = "raw_rows"
        case uniqueStates = "unique_states"
        case fromArchive = "from_archive"
        case generatedAt = "generated_at"
    }
}

/// A match's point-by-point tape: header, chronological score sequence,
/// model profiles and coverage metadata. From
/// ``LiveTennisApiClient/getMatchTape(_:sequence:)``.
public struct HistoryTape: Decodable, Sendable {
    /// The match header.
    public let match: Match?
    /// The chronological score sequence. NOT guaranteed to cover the whole
    /// match — check ``meta``'s coverage before backtesting.
    public let tape: [TapeRow]
    /// Per-set tiebreak final scores from OBSERVED states only, aligned to
    /// the sets of the final scoreline: an entry for a 7-6 set whose
    /// observed maximum tiebreak state is a valid terminal shape, `nil` per
    /// set otherwise — a breaker whose closing point the feed skipped reads
    /// `nil` rather than an under-report. The whole array is `nil` when the
    /// match has no 7-6 set.
    public let tiebreaks: [SetTiebreak?]?
    /// Model profiles, oldest first.
    public let profiles: [Profile]
    /// Coverage metadata — read it before trusting the tape.
    public let meta: TapeMeta?

    enum CodingKeys: String, CodingKey { case match, tape, tiebreaks, profiles, meta }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        match = try c.decodeIfPresent(Match.self, forKey: .match)
        tape = try c.decodeIfPresent([TapeRow].self, forKey: .tape) ?? []
        tiebreaks = try c.decodeIfPresent([SetTiebreak?].self, forKey: .tiebreaks)
        profiles = try c.decodeIfPresent([Profile].self, forKey: .profiles) ?? []
        meta = try c.decodeIfPresent(TapeMeta.self, forKey: .meta)
    }
}

// MARK: - Head-to-head

/// The resolved identity of one side of a head-to-head.
public struct H2HPlayerRef: Decodable, Sendable {
    /// The resolved display name.
    public let name: String?
    /// ULTRA only — serve/return/break-point aggregates over the pairing:
    /// `archive_serve` (serve side, from 1991) and `current` (2023+, adding
    /// return and break-point conversion, aces and winners), each with
    /// `meetings_with_stats`. The v1 schema does not pin the shape, so it is
    /// carried as unpinned JSON.
    public let stats: JSONValue?
}

/// Both resolved sides of a head-to-head.
public struct H2HPlayers: Decodable, Sendable {
    public let p1: H2HPlayerRef?
    public let p2: H2HPlayerRef?
}

/// Win totals for a head-to-head. Totals count meetings with a KNOWN winner;
/// ``undecided`` counts the rest and is never in the wins.
public struct H2HTotals: Decodable, Sendable {
    public let p1Wins: Int?
    public let p2Wins: Int?
    public let meetings: Int?
    public let undecided: Int?

    enum CodingKeys: String, CodingKey {
        case meetings, undecided
        case p1Wins = "p1_wins"
        case p2Wins = "p2_wins"
    }
}

/// A per-surface win split.
public struct H2HSurfaceSplit: Decodable, Sendable {
    public let p1: Int?
    public let p2: Int?
}

/// One meeting in a head-to-head, from either half of the product. `era`
/// says which: `"archive"` rows carry ``archiveMatchId``, ``level`` and a
/// printed ``score``; `"current"` rows carry ``matchId`` and ``roundCode``
/// and read their score from the match endpoints.
public struct H2HMeeting: Decodable, Sendable {
    /// `"archive"` (1968–2022 corpus) or `"current"` (2023 onward).
    public let era: String?
    public let date: String?
    public let tournament: String?
    /// The archive's tier code (G, M, A, …). Archive rows only.
    public let level: String?
    public let round: String?
    /// Normalised round vocabulary. Current rows only.
    public let roundCode: String?
    public let surface: String?
    /// The final score as published. Archive rows only.
    public let score: String?
    /// `"completed"`, `"retired"`, `"walkover"`, … — exclude walkovers and
    /// retirements with this, they are part of the record.
    public let outcome: String?
    /// 1 or 2 OF THIS HEAD-TO-HEAD (p1/p2 as requested), `nil` when
    /// underivable.
    public let winner: Int?
    /// Our match id. Current rows only.
    public let matchId: Int64?
    /// The archive row id. Archive rows only.
    public let archiveMatchId: Int64?

    enum CodingKeys: String, CodingKey {
        case era, date, tournament, level, round, surface, score, outcome, winner
        case roundCode = "round_code"
        case matchId = "match_id"
        case archiveMatchId = "archive_match_id"
    }
}

/// The record between two players across the results archive (1968–2022) and
/// our own completed matches (2023 onward). From
/// ``LiveTennisApiClient/getHeadToHead(p1:p2:)``.
public struct HeadToHead: Decodable, Sendable {
    /// The resolved names. `nil` when no player matches the fragments — the
    /// totals are then empty rather than an error.
    public let players: H2HPlayers?
    /// The win totals.
    public let totals: H2HTotals?
    /// Per-surface win split; keys are surface names plus `"unknown"`.
    public let bySurface: [String: H2HSurfaceSplit]
    /// The meetings, newest first, capped at 200.
    public let meetings: [H2HMeeting]

    enum CodingKeys: String, CodingKey {
        case players, totals, meetings
        case bySurface = "by_surface"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        players = try c.decodeIfPresent(H2HPlayers.self, forKey: .players)
        totals = try c.decodeIfPresent(H2HTotals.self, forKey: .totals)
        bySurface = try c.decodeIfPresent([String: H2HSurfaceSplit].self, forKey: .bySurface) ?? [:]
        meetings = try c.decodeIfPresent([H2HMeeting].self, forKey: .meetings) ?? []
    }
}

// MARK: - Results archive (1968–2022)

/// The tours the results archive covers — narrower than ``Tour``, because
/// the corpus holds ATP and WTA only.
public enum ArchiveTour: String, Sendable, CaseIterable {
    case atp, wta
}

/// One participant of an archive result, with values AS PUBLISHED at the
/// time — ``rank`` is the rank at the time of the match, not today's.
public struct ArchiveMatchPlayer: Decodable, Sendable {
    public let name: String?
    /// `"R"` or `"L"`.
    public let hand: String?
    /// 3-letter code, the same vocabulary as ``Player/country``.
    public let country: String?
    /// The player's rank AT THE TIME of the match, as published.
    public let rank: Int?
    public let seed: Int?
    /// The corpus person id — joins the archive players endpoint within the
    /// same tour. NOT a roster player id.
    public let playerId: Int64?
    public let heightCm: Int?
    /// Age at the time of the match, as the corpus records it.
    public let age: Double?
    /// Draw entry where recorded (`"WC"`, `"Q"`, `"LL"`, …) — `nil` for
    /// direct acceptances.
    public let entry: String?

    enum CodingKeys: String, CodingKey {
        case name, hand, country, rank, seed, age, entry
        case playerId = "player_id"
        case heightCm = "height_cm"
    }
}

/// One side's serve statistics on an archive result — recorded by the
/// source from 1991, `nil` before that, never synthesised.
public struct ArchiveServeStats: Decodable, Sendable {
    public let aces: Int?
    public let doubleFaults: Int?
    public let servePoints: Int?
    public let firstIn: Int?
    public let firstWon: Int?
    public let secondWon: Int?
    public let serveGames: Int?
    public let bpSaved: Int?
    public let bpFaced: Int?

    enum CodingKeys: String, CodingKey {
        case aces
        case doubleFaults = "double_faults"
        case servePoints = "serve_points"
        case firstIn = "first_in"
        case firstWon = "first_won"
        case secondWon = "second_won"
        case serveGames = "serve_games"
        case bpSaved = "bp_saved"
        case bpFaced = "bp_faced"
    }
}

/// Both sides' serve statistics on an archive result (detail endpoint only).
public struct ArchiveMatchStats: Decodable, Sendable {
    public let winner: ArchiveServeStats?
    public let loser: ArchiveServeStats?
}

/// One deep-archive result, 1968–2022. Winner/loser-shaped — results data is
/// recorded that way at the source, so the winner is a field, never an
/// inference. Its OWN id space, separate from `/matches`; people are
/// identified by name and corpus person id, never by roster ids.
public struct ArchiveMatch: Decodable, Sendable {
    public let id: Int64
    /// The stable corpus key.
    public let sourceId: String?
    /// `"atp"` or `"wta"`.
    public let tour: String?
    /// Source tier code: G = grand slam, M = masters, A = tour, F = finals,
    /// D = Davis Cup, C = challenger, O = olympics; futures tiers carry
    /// their category codes as published.
    public let level: String?
    public let tournament: String?
    public let surface: String?
    public let drawSize: Int?
    /// The tournament START date — per-match dates do not exist in this
    /// era's records.
    public let eventDate: String?
    public let round: String?
    public let bestOf: Int?
    public let minutes: Int?
    public let winner: ArchiveMatchPlayer?
    public let loser: ArchiveMatchPlayer?
    /// The final score as published, e.g. `"6-4 7-6(5)"`, `"6-3 RET"`,
    /// `"W/O"`.
    public let score: String?
    /// Parsed from the score's own vocabulary: `"completed"`, `"retired"`,
    /// `"walkover"`, `"default"`, `"abandoned"`; `nil` when unparseable —
    /// never guessed.
    public let outcome: String?
    /// Detail endpoint only; `nil` for the (mostly pre-1991) rows the source
    /// never recorded statistics for.
    public let stats: ArchiveMatchStats?

    enum CodingKeys: String, CodingKey {
        case id, tour, level, tournament, surface, round, minutes
        case winner, loser, score, outcome, stats
        case sourceId = "source_id"
        case drawSize = "draw_size"
        case eventDate = "event_date"
        case bestOf = "best_of"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(Int64.self, forKey: .id) ?? 0
        sourceId = try c.decodeIfPresent(String.self, forKey: .sourceId)
        tour = try c.decodeIfPresent(String.self, forKey: .tour)
        level = try c.decodeIfPresent(String.self, forKey: .level)
        tournament = try c.decodeIfPresent(String.self, forKey: .tournament)
        surface = try c.decodeIfPresent(String.self, forKey: .surface)
        drawSize = try c.decodeIfPresent(Int.self, forKey: .drawSize)
        eventDate = try c.decodeIfPresent(String.self, forKey: .eventDate)
        round = try c.decodeIfPresent(String.self, forKey: .round)
        bestOf = try c.decodeIfPresent(Int.self, forKey: .bestOf)
        minutes = try c.decodeIfPresent(Int.self, forKey: .minutes)
        winner = try c.decodeIfPresent(ArchiveMatchPlayer.self, forKey: .winner)
        loser = try c.decodeIfPresent(ArchiveMatchPlayer.self, forKey: .loser)
        score = try c.decodeIfPresent(String.self, forKey: .score)
        outcome = try c.decodeIfPresent(String.self, forKey: .outcome)
        stats = try c.decodeIfPresent(ArchiveMatchStats.self, forKey: .stats)
    }
}

/// One archive person — the corpus person id space, scoped per tour, that
/// archive match rows carry as `winner.player_id` / `loser.player_id`.
/// Null fields are the era's silence, never guessed.
public struct ArchivePlayerBio: Decodable, Sendable {
    public let id: Int64
    /// `"atp"` or `"wta"`.
    public let tour: String?
    public let name: String?
    /// `"R"` or `"L"`.
    public let hand: String?
    /// Date of birth (calendar date).
    public let dob: String?
    public let country: String?
    public let heightCm: Int?
    /// Career-high rank, computed offline from the corpus's own weekly
    /// ranking tables.
    public let careerHighRank: Int?
    /// The earliest week the career-high rank was reached.
    public let careerHighDate: String?

    enum CodingKeys: String, CodingKey {
        case id, tour, name, hand, dob, country
        case heightCm = "height_cm"
        case careerHighRank = "career_high_rank"
        case careerHighDate = "career_high_date"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(Int64.self, forKey: .id) ?? 0
        tour = try c.decodeIfPresent(String.self, forKey: .tour)
        name = try c.decodeIfPresent(String.self, forKey: .name)
        hand = try c.decodeIfPresent(String.self, forKey: .hand)
        dob = try c.decodeIfPresent(String.self, forKey: .dob)
        country = try c.decodeIfPresent(String.self, forKey: .country)
        heightCm = try c.decodeIfPresent(Int.self, forKey: .heightCm)
        careerHighRank = try c.decodeIfPresent(Int.self, forKey: .careerHighRank)
        careerHighDate = try c.decodeIfPresent(String.self, forKey: .careerHighDate)
    }
}

/// A wins/losses pair.
public struct ArchiveWinLoss: Decodable, Sendable {
    public let wins: Int?
    public let losses: Int?
}

/// One year of an archive career.
public struct ArchiveCareerYear: Decodable, Sendable {
    public let year: Int?
    public let wins: Int?
    public let losses: Int?
}

/// An archive career's W-L record: overall, by surface and by level.
public struct ArchiveCareerRecord: Decodable, Sendable {
    public let wins: Int?
    public let losses: Int?
    /// Finals won (excluding abandoned finals).
    public let titles: Int?
    /// Keys are surface names.
    public let bySurface: [String: ArchiveWinLoss]
    /// Keys are the archive's level codes.
    public let byLevel: [String: ArchiveWinLoss]

    enum CodingKeys: String, CodingKey {
        case wins, losses, titles
        case bySurface = "by_surface"
        case byLevel = "by_level"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        wins = try c.decodeIfPresent(Int.self, forKey: .wins)
        losses = try c.decodeIfPresent(Int.self, forKey: .losses)
        titles = try c.decodeIfPresent(Int.self, forKey: .titles)
        bySurface = try c.decodeIfPresent([String: ArchiveWinLoss].self, forKey: .bySurface) ?? [:]
        byLevel = try c.decodeIfPresent([String: ArchiveWinLoss].self, forKey: .byLevel) ?? [:]
    }
}

/// Summed serve statistics over an archive career, with derived ratios.
/// ``matchesWithStats`` states the coverage honestly: the corpus records
/// per-match serve statistics from 1991 only. Ratios are `nil` where the
/// denominator is zero.
public struct ArchiveCareerServe: Decodable, Sendable {
    public let matchesWithStats: Int?
    public let aces: Int?
    public let doubleFaults: Int?
    public let servePoints: Int?
    public let firstIn: Int?
    public let firstWon: Int?
    public let secondWon: Int?
    public let serveGames: Int?
    public let bpSaved: Int?
    public let bpFaced: Int?
    public let firstInPct: Double?
    public let firstWonPct: Double?
    public let secondWonPct: Double?
    public let bpSavedPct: Double?
    public let acesPerMatch: Double?

    enum CodingKeys: String, CodingKey {
        case aces
        case matchesWithStats = "matches_with_stats"
        case doubleFaults = "double_faults"
        case servePoints = "serve_points"
        case firstIn = "first_in"
        case firstWon = "first_won"
        case secondWon = "second_won"
        case serveGames = "serve_games"
        case bpSaved = "bp_saved"
        case bpFaced = "bp_faced"
        case firstInPct = "first_in_pct"
        case firstWonPct = "first_won_pct"
        case secondWonPct = "second_won_pct"
        case bpSavedPct = "bp_saved_pct"
        case acesPerMatch = "aces_per_match"
    }
}

/// The player identity on an archive career.
public struct ArchiveCareerPlayer: Decodable, Sendable {
    public let name: String?
}

/// The first and last tournament dates of an archive career.
public struct ArchiveCareerSpan: Decodable, Sendable {
    public let first: String?
    public let last: String?
}

/// One player's whole archive career (1968–2022) in one response.
/// Everything is a sum or a ratio of sums over rows you can fetch
/// individually — nothing is modelled. From
/// ``LiveTennisApiClient/getArchiveCareer(name:)``.
public struct ArchiveCareer: Decodable, Sendable {
    public let player: ArchiveCareerPlayer?
    public let span: ArchiveCareerSpan?
    public let record: ArchiveCareerRecord?
    public let byYear: [ArchiveCareerYear]
    public let serve: ArchiveCareerServe?

    enum CodingKeys: String, CodingKey {
        case player, span, record, serve
        case byYear = "by_year"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        player = try c.decodeIfPresent(ArchiveCareerPlayer.self, forKey: .player)
        span = try c.decodeIfPresent(ArchiveCareerSpan.self, forKey: .span)
        record = try c.decodeIfPresent(ArchiveCareerRecord.self, forKey: .record)
        byYear = try c.decodeIfPresent([ArchiveCareerYear].self, forKey: .byYear) ?? []
        serve = try c.decodeIfPresent(ArchiveCareerServe.self, forKey: .serve)
    }
}

// MARK: - Bulk history packages

/// A package family on `/history/packages`.
public enum PackageKind: String, Sendable, CaseIterable {
    /// Point-by-point match tapes — the default, so a tape-only client never
    /// sees a new kind of row appear.
    case tape
    /// As-of ranking records. **ULTRA**.
    case rankings
    /// The charted rally corpus (shot-by-shot) as YEARLY exports — the
    /// `period` is the bare year, `YYYY`, one file per year, because a fixed
    /// historical corpus is not an accruing monthly stream. **ULTRA**.
    case rally
    /// The results archive (1968–2022) as YEARLY exports (`period` is
    /// `YYYY`). Same entitlement as the tape packages — **not** ULTRA.
    case archive
}

/// A downloadable file format of a package. `jsonl` holds ONE LINE PER MATCH
/// (a whole tape object per line, coverage meta included); `csv` is
/// flattened to one row per point and carries no coverage columns.
public enum PackageFormat: String, Sendable, CaseIterable {
    case jsonl, csv
}

/// One downloadable file of a package.
public struct PackageFile: Decodable, Sendable {
    /// `"jsonl"` or `"csv"`.
    public let format: String?
    public let filename: String?
    public let bytes: Int64?
    public let sha256: String?
}

/// A published monthly bulk package. Coverage is not a contiguous run of
/// months and is still being extended backwards, so treat the listing as the
/// authoritative set of months that exist.
public struct HistoryPackage: Decodable, Sendable {
    /// The month, `YYYY-MM` — except for the yearly kinds (`rally`,
    /// `archive`), where it is the bare year, `YYYY`.
    public let period: String
    /// Only built months are listed, so this is `"ready"`.
    public let status: String?
    /// Matches in the package — on a rankings package, players covered.
    public let matchCount: Int?
    /// Tape rows — on a rankings package, ranking records.
    public let rowCount: Int?
    public let files: [PackageFile]
    public let builtAt: String?
    /// Present only on non-tape packages (`"rankings"`, `"rally"`,
    /// `"archive"`).
    public let kind: String?

    enum CodingKeys: String, CodingKey {
        case period, status, files, kind
        case matchCount = "match_count"
        case rowCount = "row_count"
        case builtAt = "built_at"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        period = try c.decodeIfPresent(String.self, forKey: .period) ?? ""
        status = try c.decodeIfPresent(String.self, forKey: .status)
        matchCount = try c.decodeIfPresent(Int.self, forKey: .matchCount)
        rowCount = try c.decodeIfPresent(Int.self, forKey: .rowCount)
        files = try c.decodeIfPresent([PackageFile].self, forKey: .files) ?? []
        builtAt = try c.decodeIfPresent(String.self, forKey: .builtAt)
        kind = try c.decodeIfPresent(String.self, forKey: .kind)
    }
}

/// The `/history/packages` meta object.
public struct HistoryPackagesMeta: Decodable, Sendable {
    public let count: Int?
    /// Echoed only when `?year=` was supplied.
    public let year: String?
}

/// The `/history/packages` listing.
public struct HistoryPackagesPage: Decodable, Sendable {
    /// Ready packages, newest period first.
    public let data: [HistoryPackage]
    public let meta: HistoryPackagesMeta?

    enum CodingKeys: String, CodingKey { case data, meta }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        data = try c.decodeIfPresent([HistoryPackage].self, forKey: .data) ?? []
        meta = try c.decodeIfPresent(HistoryPackagesMeta.self, forKey: .meta)
    }
}
