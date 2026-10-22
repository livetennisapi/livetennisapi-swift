# Changelog

All notable changes to this package are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/); versions follow
[Semantic Versioning](https://semver.org).

## [Unreleased]

### Added

- `getPlayerStats(_:from:to:surface:level:last:)` for
  `GET /players/{id}/stats` (API 1.13.61, 2026-10-22). It returns one
  player's record over our completed singles matches as `PlayerStatsResult`.
  PRO gets `records`: W/L splits, the set-based record, withdrawals and
  recent matches. ULTRA adds `serveReturn`, which stays `nil` below ULTRA.
  `serveReturn.matchesIncomplete` (`matches_incomplete`) counts the matches
  whose statistics stop short of the final and are left out of every sum.
  `PlayerRecentScore.games` is `[[Int?]]?`: the API passes the stored
  per-set lists through as held, so an inner `nil` means that game count is
  unknown and is kept in place rather than read as 0.
- `Player.heightCm` (`height_cm`) and `Player.doublesRanking`
  (`doubles_ranking`: rank, points, observedOn). Single-player read only,
  paid tiers; `nil` on a FREE key.

### Fixed

- A `from` or `to` value with a `+00:00` offset reached the server as
  `12:00:00 00:00` and earned a 400 `bad_date`. `URLComponents.queryItems`
  leaves a literal `+` alone, and the server reads it as a space. The
  transport now percent-encodes `+` in every query it sends.

## [1.2.0] - 2026-09-02

### Added

- `Match.hasAnalysis` / `Match.hasMarket` (`has_analysis` / `has_market`,
  `Bool?`) — whether a model thesis or profile, or a match-winner market,
  exists for the match. On every row of `/matches` and on the match detail,
  every tier (API 1.9.0, shipped 2026-09-02). Filter the slate on them before
  calling `/matches/{id}/analysis` or `/markets/{id}/prices`, which answer
  `404 no_analysis` / `404 no_market` about the same fact. `nil` only against
  an older server that does not send them.
- `Match.eventStatusUpdatedAt` (`event_status_updated_at`) — the instant the
  current `eventStatus` was recorded (ISO 8601 UTC, API 2026-08-19; `nil`
  when the status has never changed since the field was introduced — never
  backfilled). On `main` since 2026-08-19, first released here.

## [1.1.1] - 2026-08-16

### Added

- `PackageKind` gains the two missing package families from the OpenAPI
  contract: `rally` (the charted rally corpus as yearly `YYYY` exports,
  ULTRA) and `archive` (the 1968–2022 results archive as yearly `YYYY`
  exports, same entitlement as the tape packages — not ULTRA). Additive:
  `tape` and `rankings` are unchanged.

### Changed

- Tier inference for `/history/packages` now names ULTRA for `kind=rally`
  too (previously only `kind=rankings`); `kind=archive` correctly stays on
  the tape (PRO) entitlement.
- Package docs (client methods, `HistoryPackage.period`/`kind`, README
  endpoint table) state the yearly-period rule for the new kinds.

## [1.1.0] - 2026-08-07

### Added

- Head-to-head: `getHeadToHead(p1:p2:)` (`/h2h`, BASIC) — both eras, per-surface
  splits, per-meeting `outcome` so walkovers/retirements can be excluded.
- Per-match tape: `getMatchTape(_:sequence:)` (`/history/matches/{id}`, BASIC)
  with the `raw`/`clean` sequence choice, `pointWinner` on clean rows, per-set
  tiebreak final scores, model profiles and coverage meta.
- Results archive (1968–2022, BASIC): `listArchiveMatches`, `getArchiveMatch`
  (serve stats where the era recorded them), `listArchivePlayers`,
  `getArchiveCareer`.
- Rally construction (ULTRA): `listRallyMatches`, `getRallyMatch`,
  `getMatchRally` — charted points with parsed shots, `parsed` quality flag.
- Shot-level charting (ULTRA): `getChartingPlayer`, `getChartingMatch`.
- In-play statistics (ULTRA): `getMatchStatistics` — derived + measured
  families kept apart, per-family freshness and divergence.
- Rankings: `listRankings` — rank-ordered listing mode (PRO) and per-player
  as-of mode (ULTRA); records carry `previousRank`.
- Push feed: `getWsToken` (ULTRA) — token, socket URL and channel vocabulary
  including `slate:all`.
- Bulk packages: `listHistoryPackages(kind:year:)` (PRO; rankings kind ULTRA),
  `getHistoryPackage(period:kind:)` manifest, and
  `downloadHistoryPackage(period:kind:format:)` for the raw JSONL/CSV file.
- Full endpoint parity with the public OpenAPI contract:
  `getMatchPrices(matchId:limit:minutes:)` (`/matches/{id}/prices`, PRO,
  500-cap + `has_more`/`minutes` meta), `listTournaments`/`getTournament`
  (FREE catalogue joined by `Match.tournamentId`), `getUsage()` (`/usage`, any
  tier, quota-exempt), and webhooks (`createWebhook`/`listWebhooks`/
  `deleteWebhook` — ULTRA, direct keys only, max 3 per key, secret shown once
  on the 201).
- `Match` gains `tour` (the filter vocabulary, safe to group on),
  `tournamentId`, `roundCode` and `withdrew`; `Fixture` gains `startTime`,
  `roundCode`, `player1Id`/`player2Id`.
- List filters on matches + history: `player` (repeatable, ≤ 50), `from`/`to`,
  `country`, and `tour` on completed matches too.
- `ListMeta` gains `total`, `hasMore` and `minutes`.
- Error taxonomy: `abuseThrottled` (429 `abuse_throttled`, with
  `retryAtEpoch`) is its own case and is never auto-retried; a daily-quota 429
  now surfaces `resetsAt` on the error; 409 is its own `conflict` case
  (`webhook_limit`); a 403 `direct_key_required` no longer names a tier.
- `scripts/truthcheck.sh` truth-pin, wired into CI.

### Fixed

- The transport now retries IDEMPOTENT requests only (GET/DELETE): a POST
  that failed mid-flight may still have been processed, and replaying it
  could register a duplicate webhook.

### Changed

- Quota grid (2026-08-06 change): FREE 100/day, BASIC 1,000/day, PRO
  10,000/day, ULTRA 500,000/day; per-minute limits unchanged.
- Tier inference covers the new surface, including the two mode-dependent
  endpoints (`/rankings`, `/history/packages`).
- README rewritten to the org fleet standard: endpoint table with tier gates,
  quota table, auth section, links.

## [1.0.0] - 2026-07-24

- Initial release: `LiveTennisApiClient` (matches, scores, events, analysis,
  players, markets, prices, completed matches, fixtures), typed models with
  wire-truth decoding, the full error taxonomy with tier inference, retry with
  `Retry-After`-aware backoff, and recorded-fixture tests.
