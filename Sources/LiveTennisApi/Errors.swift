import Foundation

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

/// A subscription level. A call above your tier is refused with
/// ``LiveTennisApiError/upgradeRequired(_:requiredTier:)``.
public enum Tier: String, Sendable, Comparable, CaseIterable {
    /// Self-serve, no card: live and upcoming matches, scores, players and
    /// fixtures. 100 requests/day.
    case free = "FREE"
    /// Adds historical results: completed matches, the per-match tape, the
    /// deep results archive (1968–2022) and head-to-head.
    case basic = "BASIC"
    /// Adds match events, market prices, the rankings listing and the bulk
    /// history packages.
    case pro = "PRO"
    /// Adds model analysis, live model fields, in-play statistics, rally and
    /// charting data, per-player rankings, webhooks and the WebSocket push
    /// feed.
    case ultra = "ULTRA"

    /// Tiers are ordered cheapest first, so `tier >= .pro` reads naturally.
    public static func < (lhs: Tier, rhs: Tier) -> Bool {
        let order = Tier.allCases
        return order.firstIndex(of: lhs)! < order.firstIndex(of: rhs)!
    }
}

/// Named in 403 messages so the fix is one click away.
let pricingURL = "https://livetennisapi.com/#pricing"

/// The lowest tier that unlocks an endpoint, inferred from the path (and,
/// for the two mode-dependent endpoints, the query).
///
/// The API answers a tier wall with a bare `{"error":"upgrade_required"}` and
/// does not say which tier is needed, so the client infers it from the
/// endpoint it called. First match wins; the more specific markers sit above
/// the `/history` catch-all. Aligned with the other official clients.
func requiredTier(forPath path: String, query: [(String, String?)] = []) -> Tier? {
    // /rankings: the rank-ordered listing is PRO; per-player as-of records
    // (any `player` id present) are ULTRA.
    if path.contains("/rankings") {
        return query.contains { $0.0 == "player" } ? .ultra : .pro
    }
    // /history/packages: tape packages are PRO; rankings packages are ULTRA.
    if path.contains("/history/packages") {
        return query.contains { $0.0 == "kind" && $0.1 == "rankings" } ? .ultra : .pro
    }
    let requirements: [(marker: String, tier: Tier)] = [
        ("/analysis", .ultra),
        ("/statistics", .ultra),
        ("/rally", .ultra),
        ("/charting", .ultra),
        ("/ws-token", .ultra),
        ("/webhooks", .ultra),
        ("/events", .pro),
        ("/markets", .pro),
        ("/prices", .pro),
        ("/h2h", .basic),
        ("/history", .basic),
    ]
    return requirements.first { path.contains($0.marker) }?.tier
}

/// The rate-limit budget the API reported on a single response.
///
/// Each field is optional because "the header was absent" and "the value was
/// zero" are genuinely different: a `remaining` of 0 means the budget is
/// spent, while `nil` means nothing was reported at all.
public struct RateLimit: Sendable, Equatable {
    /// `X-RateLimit-Limit` — the ceiling for the current window. The FREE
    /// tier is 30 requests per minute.
    public let limit: Int?
    /// `X-RateLimit-Remaining` — the requests left in the current window.
    public let remaining: Int?
    /// `X-RateLimit-Reset` — the instant the current window rolls over. The
    /// API emits it as unix epoch seconds, not as a delay.
    public let reset: Date?
    /// The `Retry-After` header, in seconds.
    ///
    /// Do not read this as proof of throttling: the API sets `Retry-After` on
    /// ordinary 2xx responses too, where it merely describes the window. Only
    /// a 429 (``LiveTennisApiError/rateLimited(_:retryAfter:)``) means you
    /// were actually limited.
    public let retryAfter: TimeInterval?

    /// Whether the response carried any rate-limit information at all.
    public var known: Bool {
        limit != nil || remaining != nil || reset != nil || retryAfter != nil
    }

    /// Parse the budget off a response's headers. Never fails: a header that
    /// is missing or unparseable is simply left unset.
    init(response: HTTPURLResponse) {
        func int(_ name: String) -> Int? {
            response.value(forHTTPHeaderField: name).flatMap {
                Int($0.trimmingCharacters(in: .whitespaces))
            }
        }
        limit = int("X-RateLimit-Limit")
        remaining = int("X-RateLimit-Remaining")
        // Unix epoch seconds. A non-positive value carries no information, so
        // it is treated as absent rather than decoded into 1970.
        reset = int("X-RateLimit-Reset").flatMap {
            $0 > 0 ? Date(timeIntervalSince1970: TimeInterval($0)) : nil
        }
        retryAfter = response.value(forHTTPHeaderField: "Retry-After")
            .flatMap { TimeInterval($0.trimmingCharacters(in: .whitespaces)) }
            .flatMap { $0 >= 0 ? $0 : nil }
    }
}

/// What the API said alongside a non-2xx status.
public struct ApiErrorInfo: Sendable {
    /// The HTTP status code.
    public let status: Int
    /// The API's machine-readable code from the body's `error` field, for
    /// example `"upgrade_required"`. `nil` when the body carried no usable
    /// code.
    public let code: String?
    /// A human-readable summary: the API's code when it sent one, otherwise
    /// the HTTP status text.
    public let message: String
    /// The request URL. The key never appears here — it travels in a header.
    public let url: String
    /// The rate-limit budget the API reported on this response.
    public let rateLimit: RateLimit
    /// The raw response body, kept verbatim so a payload this library failed
    /// to model is still available.
    public let body: Data
}

/// Every error this library throws.
///
/// The common cases are distinguishable by case alone:
///
/// ```swift
/// do {
///     let analysis = try await client.getMatchAnalysis(42)
/// } catch LiveTennisApiError.upgradeRequired(_, let tier) {
///     print("needs \(tier?.rawValue ?? "?")")   // "ULTRA"
/// } catch LiveTennisApiError.rateLimited(_, let retryAfter) {
///     try await Task.sleep(nanoseconds: UInt64((retryAfter ?? 60) * 1e9))
/// }
/// ```
public enum LiveTennisApiError: Error, CustomStringConvertible {
    /// 400 — a query parameter was malformed. `allowed` lists the values the
    /// API would have accepted, when it says so (rejecting a tour answers
    /// `{"error":"bad_tour","allowed":[...]}`).
    case badRequest(ApiErrorInfo, allowed: [String]?)

    /// 401 — the key is missing, unknown, or disabled. This is a credential
    /// problem, never a plan problem.
    case unauthorized(ApiErrorInfo)

    /// 403 — the endpoint exists and your key is valid, but your tier does
    /// not unlock it. Treating this as an auth failure is the classic
    /// mistake: a 403 proves the key works. `requiredTier` is inferred from
    /// the endpoint (the API's body says only `upgrade_required`); `nil` for
    /// an endpoint on the FREE floor.
    ///
    /// One 403 is NOT a tier problem: webhooks on a RapidAPI-issued key
    /// answer code `direct_key_required` — no upgrade fixes that, only a
    /// direct key from livetennisapi.com does, so `requiredTier` stays `nil`
    /// there. Branch on ``errorCode``.
    case upgradeRequired(ApiErrorInfo, requiredTier: Tier?)

    /// 404 — no such resource, or no data for it yet. Analysis and market
    /// endpoints return it for a match the model has not covered.
    case notFound(ApiErrorInfo)

    /// 409 — the request conflicts with current state. The one place the API
    /// answers it: registering a fourth webhook (code `webhook_limit`, at
    /// most 3 per key) — delete one first.
    case conflict(ApiErrorInfo)

    /// 429 — the tier's rate-limit window was exceeded. `retryAfter` is how
    /// long the API asked you to wait, from `Retry-After`. Only a 429 means
    /// you were throttled: the header also appears on successful responses,
    /// where it merely describes the window.
    ///
    /// This case covers both the per-MINUTE window and the per-DAY quota;
    /// the body's `scope` tells them apart. On a daily 429 ``resetsAt``
    /// carries the absolute instant the day rolls over.
    case rateLimited(ApiErrorInfo, retryAfter: TimeInterval?)

    /// 429 with code `abuse_throttled` — not a window, a block: the key was
    /// throttled (typically for 24 hours) for chronically exceeding its caps,
    /// which is almost always a retry loop that never backs off. Fix the
    /// loop rather than waiting the block out. `retryAtEpoch` is when the
    /// block lifts, from the body's `retry_at_epoch`. The client never
    /// auto-retries this error.
    case abuseThrottled(ApiErrorInfo, retryAtEpoch: Date?)

    /// 5xx — the API failed to serve the request. A 503 (public surface
    /// disabled or down) lands here too; branch on `info.status` to tell.
    case serverError(ApiErrorInfo)

    /// Any other non-2xx status this library does not model specifically.
    case status(ApiErrorInfo)

    /// The request exceeded the configured timeout.
    case timeout(url: String, underlying: Error)

    /// The request never produced a response — DNS, TLS, or a refused or
    /// dropped connection.
    case connection(url: String, underlying: Error)

    /// A 2xx body could not be decoded into the expected model.
    case decoding(url: String, underlying: Error)

    /// The response detail, for the cases where the API answered with a
    /// non-2xx status. `nil` for transport and decoding errors.
    public var info: ApiErrorInfo? {
        switch self {
        case .badRequest(let info, _), .unauthorized(let info),
            .upgradeRequired(let info, _), .notFound(let info),
            .conflict(let info), .rateLimited(let info, _),
            .abuseThrottled(let info, _), .serverError(let info),
            .status(let info):
            return info
        case .timeout, .connection, .decoding:
            return nil
        }
    }

    /// The HTTP status code, when a response was received.
    public var statusCode: Int? { info?.status }

    /// The API's machine-readable code, e.g. `"upgrade_required"`.
    public var errorCode: String? { info?.code }

    /// For a DAILY-quota 429 (body `scope == "day"`), the absolute ISO 8601
    /// instant the daily window resets, from the body's `resets_at`. The
    /// reset is derived from the key's LOCAL midnight, not a UTC one — never
    /// guess the boundary; sleep until this instant instead. `nil` on a
    /// per-minute 429 and on every other error.
    public var resetsAt: String? {
        guard case .rateLimited(let info, _) = self else { return nil }
        let parsed = (try? JSONSerialization.jsonObject(with: info.body)) as? [String: Any]
        return parsed?["resets_at"] as? String
    }

    public var description: String {
        func line(_ info: ApiErrorInfo) -> String {
            "[\(info.status)] \(info.message) (\(info.url))"
        }
        switch self {
        case .badRequest(let info, let allowed):
            if let allowed, !allowed.isEmpty {
                return "\(line(info)) — allowed values are \(allowed.joined(separator: ", "))"
            }
            return line(info)
        case .unauthorized(let info), .notFound(let info),
            .conflict(let info), .serverError(let info), .status(let info):
            return line(info)
        case .upgradeRequired(let info, let tier):
            if let tier {
                return "\(line(info)) — this endpoint requires the \(tier.rawValue) tier. See \(pricingURL)"
            }
            return line(info)
        case .rateLimited(let info, let retryAfter):
            var text = line(info)
            if let retryAfter { text += " — retry after \(retryAfter)s" }
            if let resetsAt { text += " — daily quota resets at \(resetsAt)" }
            return text
        case .abuseThrottled(let info, let retryAtEpoch):
            var text = "\(line(info)) — key blocked for chronic over-limit traffic; fix the retry loop"
            if let retryAtEpoch { text += ". Block lifts at \(retryAtEpoch)" }
            return text
        case .timeout(let url, let underlying):
            return "request to \(url) timed out: \(underlying)"
        case .connection(let url, let underlying):
            return "could not reach \(url): \(underlying)"
        case .decoding(let url, let underlying):
            return "could not decode response from \(url): \(underlying)"
        }
    }

    /// Build the right error for a non-2xx response. Only a string `error`
    /// code is usable: an `{"error": null}` body falls through to the status
    /// text rather than surfacing as "null" — the same rule the rest of the
    /// family applies.
    static func forStatus(
        _ status: Int, path: String, query: [(String, String?)] = [],
        url: String, rateLimit: RateLimit, body: Data
    ) -> LiveTennisApiError {
        let parsed = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
        let code = parsed?["error"] as? String
        let allowed = parsed?["allowed"] as? [String]
        let message = code ?? HTTPURLResponse.localizedString(forStatusCode: status)

        let info = ApiErrorInfo(
            status: status, code: code, message: message, url: url,
            rateLimit: rateLimit, body: body)

        switch status {
        case 400: return .badRequest(info, allowed: allowed)
        case 401: return .unauthorized(info)
        case 403:
            // `direct_key_required` (webhooks on a RapidAPI key) is a channel
            // problem, not a tier problem — naming a tier would mislead.
            let tier =
                code == "direct_key_required"
                ? nil : requiredTier(forPath: path, query: query)
            return .upgradeRequired(info, requiredTier: tier)
        case 404: return .notFound(info)
        case 409: return .conflict(info)
        case 429:
            if code == "abuse_throttled" {
                // `retry_at_epoch` is unix epoch seconds.
                let epoch = (parsed?["retry_at_epoch"] as? Double)
                    ?? (parsed?["retry_at_epoch"] as? Int).map(Double.init)
                return .abuseThrottled(
                    info, retryAtEpoch: epoch.map { Date(timeIntervalSince1970: $0) })
            }
            return .rateLimited(info, retryAfter: rateLimit.retryAfter)
        case 500...: return .serverError(info)
        default: return .status(info)
        }
    }

    /// Whether a 429 body names the `abuse_throttled` block. A block is not
    /// a window — retrying it cannot succeed and only digs the hole deeper,
    /// so the transport never retries it.
    static func isAbuseThrottled(status: Int, body: Data) -> Bool {
        guard status == 429 else { return false }
        let parsed = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
        return parsed?["error"] as? String == "abuse_throttled"
    }
}
