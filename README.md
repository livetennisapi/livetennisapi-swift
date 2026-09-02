<div align="center">

<img src="https://raw.githubusercontent.com/livetennisapi/.github/main/profile/banner.jpg" alt="Live Tennis API" width="640">

# livetennisapi-swift

**Official Swift client for the [Live Tennis API](https://livetennisapi.com).**

Real-time tennis scores, players, rankings, match statistics, deep history,
match-winner market prices and model win-probability — for ATP, WTA,
Challenger, ITF and juniors.

[![ci](https://github.com/livetennisapi/livetennisapi-swift/actions/workflows/ci.yml/badge.svg)](https://github.com/livetennisapi/livetennisapi-swift/actions/workflows/ci.yml)
[![license](https://img.shields.io/badge/license-MIT-green.svg)](LICENSE)

[**Documentation**](https://docs.livetennisapi.com) · [**Get a free API key**](https://livetennisapi.com/subscribe/free)

</div>

---

## Install

Add to your `Package.swift`:

```swift
.package(url: "https://github.com/livetennisapi/livetennisapi-swift.git", from: "1.2.0")
```

**Zero dependencies.** `URLSession` + `Codable` only (with `FoundationNetworking`
on Linux). macOS 12+ / iOS 15+ / tvOS 15+ / watchOS 8+ / Linux; Swift 5.9+.

## Quick start

```swift
import LiveTennisApi

let client = LiveTennisApiClient(apiKey: "twjp_your_key_here")

let live = try await client.listMatches(status: .live, tour: .atp)
for match in live.data {
    let p1 = match.players?.p1?.name ?? "?"
    let p2 = match.players?.p2?.name ?? "?"
    print("\(match.tournament): \(p1) vs \(p2) — \(match.score?.description ?? "-")")
}
```

In real code, read the key from the environment rather than hard-coding it:
`ProcessInfo.processInfo.environment["LIVETENNISAPI_KEY"]`.

## Endpoints and tiers

Access is tiered (FREE / BASIC / PRO / ULTRA). A call above your tier throws
`upgradeRequired` naming the tier that fixes it — see [Errors](#errors-and-tiers).

| Method | Endpoint | Tier |
|---|---|---|
| `health()` | `/health` | none (no key) |
| `listMatches(…)` | `/matches` | FREE (`status: .completed` needs BASIC) |
| `getMatch(_:)` | `/matches/{id}` | FREE (+`market` PRO, +`analysis` ULTRA) |
| `getMatchScore(_:)` | `/matches/{id}/score` | FREE (ULTRA adds model fields) |
| `searchPlayers(…)` / `getPlayer(_:)` | `/players`, `/players/{id}` | FREE |
| `listFixtures(…)` | `/fixtures` | FREE |
| `listTournaments(…)` / `getTournament(_:)` | `/tournaments`, `/tournaments/{id}` | FREE |
| `getUsage()` | `/usage` | any tier (quota-exempt) |
| `listCompletedMatches(…)` | `/history/matches` | BASIC |
| `getMatchTape(_:sequence:)` | `/history/matches/{id}` | BASIC |
| `getHeadToHead(p1:p2:)` | `/h2h` | BASIC |
| `listArchiveMatches(…)` / `getArchiveMatch(_:)` | `/history/archive/matches` | BASIC |
| `listArchivePlayers(…)` | `/history/archive/players` | BASIC |
| `getArchiveCareer(name:)` | `/history/archive/career` | BASIC |
| `listMatchEvents(…)` | `/matches/{id}/events` | PRO |
| `listMarkets(…)` / `getMarketPrices(…)` | `/markets`, `/markets/{id}/prices` | PRO |
| `getMatchPrices(matchId:…)` | `/matches/{id}/prices` | PRO |
| `listRankings(…)` | `/rankings` | PRO listing · ULTRA per-player |
| `listHistoryPackages(kind:year:)` | `/history/packages` | PRO (`.rankings`/`.rally` ULTRA; `.archive` = tape) |
| `getHistoryPackage(period:…)` / `downloadHistoryPackage(…)` | `/history/packages/{period}` | PRO (`.rankings`/`.rally` ULTRA; `.archive` = tape) |
| `getMatchAnalysis(_:)` | `/matches/{id}/analysis` | ULTRA |
| `getMatchStatistics(_:)` | `/matches/{id}/statistics` | ULTRA |
| `listRallyMatches(…)` / `getRallyMatch(_:…)` | `/rally/matches` | ULTRA |
| `getMatchRally(matchId:…)` | `/history/matches/{id}/rally` | ULTRA |
| `getChartingPlayer(name:gender:)` / `getChartingMatch(_:)` | `/charting/*` | ULTRA |
| `getWsToken()` | `/ws-token` | ULTRA |
| `createWebhook(…)` / `listWebhooks()` / `deleteWebhook(_:)` | `/webhooks`, `/webhooks/{id}` | ULTRA, direct keys only |

The history surface is also unlocked by the History plans — see
[products](https://livetennisapi.com/products).

This table is the COMPLETE public API: every endpoint in the published
OpenAPI contract has a typed method. Undocumented gateway aliases and the
website's HTML/asset routes are deliberately not part of the SDK surface.

Webhooks (ULTRA) are for direct keys only — on a RapidAPI-issued key they
answer 403 `direct_key_required`, which the client surfaces without naming a
tier, because no upgrade fixes it. At most 3 webhooks per key (a fourth
registration throws `conflict`, code `webhook_limit`), and the signing
`secret` appears exactly once, on the registration response — store it then.

## Quotas

| Tier | Per minute | Per day | Price |
|---|---|---|---|
| FREE | 30 | 100 | $0 |
| BASIC | 60 | 1,000 | $9.99/mo |
| PRO | 300 | 10,000 | $29.99/mo |
| ULTRA | 600 | 500,000 | $99.99/mo |

At 100/day, a free key supports polling roughly every 15 minutes — poll no
faster. For an always-on dashboard, BASIC is the recommended floor. Watch your
budget with the `onRateLimit:` callback (the `X-RateLimit-*` headers arrive on
every response), and on a daily-cap 429 read `error.resetsAt` — the reset is an
absolute instant, not a fixed UTC hour.

## Authentication

The client sends `Authorization: Bearer <key>` by default — the preferred
scheme. If an intermediary strips `Authorization` headers, switch to the
`X-API-Key` header with `authMethod: .apiKey`. The token minted by
`getWsToken()` (ULTRA) is presented to the push WebSocket instead, via its
`?token=` query parameter.

## Errors and tiers

Every failure is one `LiveTennisApiError` enum, distinguishable by case. A 403
is not an auth problem — the key works, the plan is too low — and the client
names the tier that fixes it:

```swift
do {
    let analysis = try await client.getMatchAnalysis(id)
} catch LiveTennisApiError.upgradeRequired(_, let tier) {
    print("needs \(tier?.rawValue ?? "?")")   // "ULTRA"
} catch LiveTennisApiError.rateLimited(let info, let retryAfter) {
    // minute window: wait retryAfter seconds.
    // daily cap: info body carries scope "day" — sleep until error.resetsAt.
} catch LiveTennisApiError.abuseThrottled(_, let retryAtEpoch) {
    // your key is blocked for chronic over-cap traffic — fix the retry loop.
}
```

Only a 429 means you were throttled: the API sends `Retry-After` on successful
responses too, where it merely describes the window. An `abuseThrottled` 429 is
a long block, not a window — the client never auto-retries it.

## Shapes worth knowing

- `Match.score` is `nil` on an upcoming match; `Score.server` can be null even
  inside a present score.
- `Score.points` are **strings** (`"15"`, `"40"`, `"AD"`); `Score.games` is
  player-major — two growing per-set arrays. Use `gamesForSet(_:)`.
- `Match.tour` is the same vocabulary as the `Tour` filter and safe to group
  on; the `tour` field on `Player`/`Fixture` is opaque and granular
  (UPPERCASE on doubles teams) — never parse those into the enum. An invalid
  filter is a 400 carrying the allowed list.
- `Match.hasAnalysis` / `Match.hasMarket` (every tier, since 2026-09-02) say
  whether a model thesis/profile, or a match-winner market, exists for the
  match. Filter a slate on them before calling `getMatchAnalysis` or the
  prices endpoint, which answer `404` (`no_analysis` / `no_market`) about the
  same fact. `nil` only when talking to an older server.
- `DataCompleteness.known`/`of` are null on a doubles team (with a `note`):
  null means "not applicable", not zero. Check `applicable` first.
- Tape rows carry `pointWinner` only on `sequence: .clean`, and a null row
  `timestamp` marks a reconstructed row. Check the tape's `meta` coverage
  before backtesting.
- In-play statistics come in TWO families (derived vs measured) that are
  deliberately not merged, each with its own freshness on a different clock.

## Links

- Documentation: <https://docs.livetennisapi.com>
- Free API key: <https://livetennisapi.com/subscribe/free>
- Discord: <https://discord.gg/f8WUZHgDm6>
- GitHub org: <https://github.com/livetennisapi>

## License

MIT — see [LICENSE](LICENSE).

## Affiliate program

Know developers who need tennis data? The [affiliate program](https://affiliates.livetennisapi.com/program) pays 51% recurring commission for the life of every referred subscription — 30-day cookie, and the people you refer get 10% off.
