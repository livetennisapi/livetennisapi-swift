import Foundation

// MARK: - GET /players/{id}/stats

/// One player's record over our own completed singles matches (2023 onward),
/// from ``LiveTennisApiClient/getPlayerStats(_:from:to:surface:level:last:)``.
/// ``records`` is **PRO**; ``serveReturn`` is **ULTRA** and `nil` below it,
/// where the server omits the key.
public struct PlayerStatsResult: Decodable, Sendable {
    public let player: PlayerRef?
    /// The window applied, ISO 8601 UTC.
    public let window: PlayerStatsWindow?
    public let filters: PlayerStatsFilters?
    /// The results-based record. **PRO**.
    public let records: PlayerRecords?
    /// Measured serve/return statistics summed over the window. **ULTRA**.
    public let serveReturn: PlayerServeReturn?
    public let meta: PlayerStatsMeta?

    enum CodingKeys: String, CodingKey {
        case player, window, filters, records, meta
        case serveReturn = "serve_return"
    }
}

/// A player id and name.
public struct PlayerRef: Decodable, Sendable {
    public let id: Int64?
    public let name: String?
}

public struct PlayerStatsWindow: Decodable, Sendable {
    public let from: String?
    public let to: String?
}

public struct PlayerStatsFilters: Decodable, Sendable {
    public let surface: String?
    public let level: String?
    public let last: Int?
}

public struct PlayerStatsMeta: Decodable, Sendable {
    /// When the body was computed (cached up to 60 seconds).
    public let generatedAt: String?
    public let note: String?

    enum CodingKeys: String, CodingKey {
        case note
        case generatedAt = "generated_at"
    }
}

/// The results-based record. W/L blocks count matches with a published
/// winner and an outcome of completed, retired, walkover or default.
public struct PlayerRecords: Decodable, Sendable {
    public let overall: PlayerWinLoss?
    public let last12Months: PlayerWinLoss?
    /// Keyed `hard`, `clay`, `grass`, `unknown`.
    public let bySurface: [String: PlayerWinLoss]?
    /// Keyed `indoor`, `outdoor`, `unknown`.
    public let byVenue: [String: PlayerWinLoss]?
    /// Keyed by the match tour (`atp`, `wta`, `challenger`, `itf`, `juniors`) or `unknown`.
    public let byLevel: [String: PlayerWinLoss]?
    /// Keyed by the UTC calendar year of the scheduled start.
    public let bySeason: [String: PlayerWinLoss]?
    /// The set-based record, over matches with a complete, legal final score.
    public let sets: PlayerSetRecord?
    public let withdrawals: PlayerWithdrawals?
    /// Matches in the window left out of every record, by reason.
    public let excluded: PlayerRecordExclusions?
    /// The last N matches in the window, newest first.
    public let recent: [PlayerRecentMatch]?

    enum CodingKeys: String, CodingKey {
        case overall, sets, withdrawals, excluded, recent
        case last12Months = "last_12_months"
        case bySurface = "by_surface"
        case byVenue = "by_venue"
        case byLevel = "by_level"
        case bySeason = "by_season"
    }
}

/// A win/loss count. ``winPct`` is `nil`, never 0, when ``matches`` is 0.
public struct PlayerWinLoss: Decodable, Sendable {
    public let matches: Int?
    public let wins: Int?
    public let losses: Int?
    public let winPct: Double?

    enum CodingKeys: String, CodingKey {
        case matches, wins, losses
        case winPct = "win_pct"
    }
}

/// Played / won / lost (tiebreaks, deciding sets).
public struct PlayerPlayedRecord: Decodable, Sendable {
    public let played: Int?
    public let won: Int?
    public let lost: Int?
    public let winPct: Double?

    enum CodingKeys: String, CodingKey {
        case played, won, lost
        case winPct = "win_pct"
    }
}

/// A match split (after winning or losing the first set).
public struct PlayerSplitRecord: Decodable, Sendable {
    public let matches: Int?
    public let won: Int?
    public let lost: Int?
    public let winPct: Double?

    enum CodingKeys: String, CodingKey {
        case matches, won, lost
        case winPct = "win_pct"
    }
}

public struct PlayerSetRecord: Decodable, Sendable {
    public let sample: PlayerSetSample?
    public let tiebreaks: PlayerPlayedRecord?
    public let decidingSets: PlayerPlayedRecord?
    public let afterWinningFirstSet: PlayerSplitRecord?
    public let afterLosingFirstSet: PlayerSplitRecord?
    public let comebacks: PlayerComebacks?
    public let sets: PlayerSetsCount?

    enum CodingKeys: String, CodingKey {
        case sample, tiebreaks, comebacks, sets
        case decidingSets = "deciding_sets"
        case afterWinningFirstSet = "after_winning_first_set"
        case afterLosingFirstSet = "after_losing_first_set"
    }
}

/// The sample behind the set-based record.
public struct PlayerSetSample: Decodable, Sendable {
    public let matches: Int?
    /// Counted out by reason: `retired`, `walkover`, `default`, `score_incomplete`.
    public let excluded: [String: Int]?
}

public struct PlayerComebacks: Decodable, Sendable {
    /// Matches in which the player lost at least one set.
    public let matchesLostASet: Int?
    public let won: Int?
    public let winPct: Double?

    enum CodingKeys: String, CodingKey {
        case won
        case matchesLostASet = "matches_lost_a_set"
        case winPct = "win_pct"
    }
}

public struct PlayerSetsCount: Decodable, Sendable {
    public let won: Int?
    public let lost: Int?
    public let winPct: Double?

    enum CodingKeys: String, CodingKey {
        case won, lost
        case winPct = "win_pct"
    }
}

public struct PlayerWithdrawals: Decodable, Sendable {
    public let retired: PlayerWithdrawalCount?
    public let walkover: PlayerWithdrawalCount?
    public let `default`: PlayerWithdrawalCount?
}

/// Given (this player did not finish) and received (the opponent did not).
public struct PlayerWithdrawalCount: Decodable, Sendable {
    public let given: Int?
    public let received: Int?
}

public struct PlayerRecordExclusions: Decodable, Sendable {
    public let notSingles: Int?
    public let unresolved: Int?
    public let abandoned: Int?
    public let noPublishedWinner: Int?

    enum CodingKeys: String, CodingKey {
        case unresolved, abandoned
        case notSingles = "not_singles"
        case noPublishedWinner = "no_published_winner"
    }
}

/// One recent match, seen from the player's side.
public struct PlayerRecentMatch: Decodable, Sendable {
    public let matchId: Int64?
    public let date: String?
    public let scheduledTime: String?
    public let tournamentId: String?
    public let tournament: String?
    public let round: String?
    public let roundCode: String?
    public let surface: String?
    public let indoor: Bool?
    public let level: String?
    public let opponent: PlayerRef?
    public let won: Bool?
    /// `completed`, `retired`, `walkover` or `default`.
    public let outcome: String?
    /// The final score turned round to this player, or `nil` when no score row is held.
    public let score: PlayerRecentScore?

    enum CodingKeys: String, CodingKey {
        case date, tournament, round, surface, indoor, level, opponent, won, outcome, score
        case matchId = "match_id"
        case scheduledTime = "scheduled_time"
        case tournamentId = "tournament_id"
        case roundCode = "round_code"
    }
}

/// Sets `[player, opponent]`, games `[[player per set], [opponent per set]]`.
public struct PlayerRecentScore: Decodable, Sendable {
    public let sets: [Int?]?
    public let games: [[Int]]?
}

/// Measured per-match statistics summed over the window. **ULTRA**. Each
/// field carries the number of matches it was summed over.
public struct PlayerServeReturn: Decodable, Sendable {
    public let matches: Int?
    public let matchesWithStats: Int?
    public let serve: PlayerServeTotals?
    public let `return`: PlayerReturnTotals?

    enum CodingKeys: String, CodingKey {
        case matches, serve, `return`
        case matchesWithStats = "matches_with_stats"
    }
}

public struct PlayerServeTotals: Decodable, Sendable {
    public let aces: PlayerStatCount?
    public let doubleFaults: PlayerStatCount?
    public let firstServeIn: PlayerStatRatio?
    public let firstServePointsWon: PlayerStatRatio?
    public let secondServePointsWon: PlayerStatRatio?
    public let serviceGamesWon: PlayerStatRatio?
    public let breakPointsSaved: PlayerStatRatio?

    enum CodingKeys: String, CodingKey {
        case aces
        case doubleFaults = "double_faults"
        case firstServeIn = "first_serve_in"
        case firstServePointsWon = "first_serve_points_won"
        case secondServePointsWon = "second_serve_points_won"
        case serviceGamesWon = "service_games_won"
        case breakPointsSaved = "break_points_saved"
    }
}

public struct PlayerReturnTotals: Decodable, Sendable {
    public let firstServeReturnPointsWon: PlayerStatRatio?
    public let secondServeReturnPointsWon: PlayerStatRatio?
    public let returnGamesWon: PlayerStatRatio?
    public let breakPointsConverted: PlayerStatRatio?

    enum CodingKeys: String, CodingKey {
        case firstServeReturnPointsWon = "first_serve_return_points_won"
        case secondServeReturnPointsWon = "second_serve_return_points_won"
        case returnGamesWon = "return_games_won"
        case breakPointsConverted = "break_points_converted"
    }
}

/// A sum of numerators over a sum of denominators. All `nil` with
/// ``matches`` 0 when no match carried the field.
public struct PlayerStatRatio: Decodable, Sendable {
    public let numerator: Int?
    public let denominator: Int?
    public let pct: Double?
    public let matches: Int?
}

/// A summed count. ``total`` and ``perMatch`` are `nil` with ``matches`` 0
/// when no match carried the field.
public struct PlayerStatCount: Decodable, Sendable {
    public let total: Int?
    public let matches: Int?
    public let perMatch: Double?

    enum CodingKeys: String, CodingKey {
        case total, matches
        case perMatch = "per_match"
    }
}

/// A player's current doubles ranking (``Player/doublesRanking``).
public struct DoublesRanking: Decodable, Sendable {
    public let rank: Int?
    public let points: Int?
    /// UTC date the weekly refresh last found the player on the table.
    public let observedOn: String?

    enum CodingKeys: String, CodingKey {
        case rank, points
        case observedOn = "observed_on"
    }
}
