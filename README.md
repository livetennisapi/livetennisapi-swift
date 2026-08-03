<div align="center">

<img src="https://raw.githubusercontent.com/livetennisapi/.github/main/profile/banner.jpg" alt="Live Tennis API" width="640">

# livetennisapi-swift

**Official Swift client for the [Live Tennis API](https://livetennisapi.com).**

Real-time tennis scores, players, rankings, match-winner market prices and model
win-probability — for ATP, WTA, Challenger, ITF and juniors.

[![license](https://img.shields.io/badge/license-MIT-green.svg)](LICENSE)

[**Documentation**](https://docs.livetennisapi.com) · [**Get a free API key**](https://livetennisapi.com/subscribe/free)

</div>

---

## Install

Add to your `Package.swift`:

```swift
.package(url: "https://github.com/livetennisapi/livetennisapi-swift.git", from: "1.0.0")
```

**Zero dependencies.** `URLSession` + `Codable` only (with `FoundationNetworking`
on Linux). macOS 12+ / iOS 15+ / tvOS 15+ / watchOS 8+ / Linux; Swift 5.9+.

## Quick start

```swift
import LiveTennisApi

let client = LiveTennisApiClient(
    apiKey: ProcessInfo.processInfo.environment["LIVETENNISAPI_KEY"] ?? "")

let live = try await client.listMatches(status: .live, tour: .atp)
for match in live.data {
    let p1 = match.players?.p1?.name ?? "?"
    let p2 = match.players?.p2?.name ?? "?"
    print("\(match.tournament): \(p1) vs \(p2) — \(match.score?.description ?? "-")")
}
```

## Errors and tiers

Every failure is one `LiveTennisApiError` enum, distinguishable by case. A 403
is not an auth problem — the key works, the plan is too low — and the client
names the tier that fixes it:

```swift
do {
    let analysis = try await client.getMatchAnalysis(id)
} catch LiveTennisApiError.upgradeRequired(_, let tier) {
    print("needs \(tier?.rawValue ?? "?")")   // "ULTRA"
} catch LiveTennisApiError.rateLimited(_, let retryAfter) {
    // wait retryAfter seconds
}
```

Only a 429 means you were throttled: the API sends `Retry-After` on successful
responses too, where it merely describes the window. Watch your budget with the
`onRateLimit:` callback on the initializer.

## Shapes worth knowing

- `Match.score` is `nil` on an upcoming match; `Score.server` can be null even
  inside a present score.
- `Score.points` are **strings** (`"15"`, `"40"`, `"AD"`); `Score.games` is
  player-major — two growing per-set arrays. Use `gamesForSet(_:)`.
- `DataCompleteness.known`/`of` are null on a doubles team (with a `note`):
  null means "not applicable", not zero. Check `applicable` first.
- The `tour` *field* the API returns is opaque and granular (UPPERCASE on
  doubles teams). Only the `Tour` enum is valid as a *filter*; an invalid
  filter is a 400 carrying the allowed list.

## License

MIT — see [LICENSE](LICENSE).

## Affiliate program

Know developers who need tennis data? The [affiliate program](https://affiliates.livetennisapi.com/program) pays 51% recurring commission for the life of every referred subscription — 30-day cookie, and the people you refer get 10% off.
