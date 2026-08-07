import Foundation

// Models for the account surface: your own usage vs quota, and outbound
// webhooks. The same conventions as Models.swift apply.

// MARK: - Usage

/// The daily quota limits of the calling key.
public struct UsageLimits: Decodable, Sendable {
    public let perMinute: Int?
    public let perDay: Int?

    enum CodingKeys: String, CodingKey {
        case perMinute = "per_minute"
        case perDay = "per_day"
    }
}

/// Today's consumption for the calling key, current to the second.
public struct UsageToday: Decodable, Sendable {
    public let calls: Int?
    public let errors: Int?
    public let remainingDay: Int?

    enum CodingKeys: String, CodingKey {
        case calls, errors
        case remainingDay = "remaining_day"
    }
}

/// One day of usage history.
public struct UsageDay: Decodable, Sendable {
    public let day: String?
    public let calls: Int?
    public let errors: Int?
}

/// Your own usage vs quota, from ``LiveTennisApiClient/getUsage()``.
///
/// Durable daily usage for the calling key: tier, limits, today's calls and a
/// 30-day history. The per-MINUTE window lives on the `X-RateLimit-*` headers
/// of every response (see the `onRateLimit:` callback), not here — and the
/// daily reset instant is only ever published on a daily 429
/// (``LiveTennisApiError/resetsAt``), never by this endpoint.
public struct Usage: Decodable, Sendable {
    /// An opaque reference to your own key.
    public let principal: String?
    /// The EFFECTIVE tier, lowercase (`"free"`, `"basic"`, `"pro"`,
    /// `"ultra"`) — note the ``Tier`` enum's raw values are uppercase.
    public let tier: String?
    /// The subscription tier; equals ``tier`` unless a temporary grant is
    /// active.
    public let baseTier: String?
    /// When a temporary tier grant reverts, else `nil`.
    public let tierExpiresAt: String?
    /// The sales channel of the key (e.g. direct vs RapidAPI).
    public let channel: String?
    public let limits: UsageLimits?
    public let today: UsageToday?
    /// The last 30 days, oldest first.
    public let history: [UsageDay]
    public let asOf: String?

    enum CodingKeys: String, CodingKey {
        case principal, tier, channel, limits, today, history
        case baseTier = "base_tier"
        case tierExpiresAt = "tier_expires_at"
        case asOf = "as_of"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        principal = try c.decodeIfPresent(String.self, forKey: .principal)
        tier = try c.decodeIfPresent(String.self, forKey: .tier)
        baseTier = try c.decodeIfPresent(String.self, forKey: .baseTier)
        tierExpiresAt = try c.decodeIfPresent(String.self, forKey: .tierExpiresAt)
        channel = try c.decodeIfPresent(String.self, forKey: .channel)
        limits = try c.decodeIfPresent(UsageLimits.self, forKey: .limits)
        today = try c.decodeIfPresent(UsageToday.self, forKey: .today)
        history = try c.decodeIfPresent([UsageDay].self, forKey: .history) ?? []
        asOf = try c.decodeIfPresent(String.self, forKey: .asOf)
    }
}

// MARK: - Webhooks

/// An event family a webhook can subscribe to.
public enum WebhookEvent: String, Sendable, CaseIterable {
    /// Every live score commit — the same frames the WebSocket pushes.
    case score
    /// Break-point alerts.
    case breakPoint = "break_point"
}

/// An outbound webhook registration.
///
/// ``secret`` is present ONLY on the response of
/// ``LiveTennisApiClient/createWebhook(url:events:)`` — the one time it is
/// ever shown. Store it then; the list endpoint never includes it.
public struct Webhook: Decodable, Sendable {
    public let id: Int64
    /// The HTTPS endpoint we POST to.
    public let url: String?
    /// The subscribed event names (`"score"`, `"break_point"`).
    public let events: [String]
    public let enabled: Bool
    public let createdAt: String?
    public let lastDeliveryAt: String?
    public let consecutiveFailures: Int?
    public let lastError: String?
    /// The signing secret — registration response only, shown exactly once.
    public let secret: String?
    public let secretNote: String?

    enum CodingKeys: String, CodingKey {
        case id, url, events, enabled, secret
        case createdAt = "created_at"
        case lastDeliveryAt = "last_delivery_at"
        case consecutiveFailures = "consecutive_failures"
        case lastError = "last_error"
        case secretNote = "secret_note"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(Int64.self, forKey: .id) ?? 0
        url = try c.decodeIfPresent(String.self, forKey: .url)
        events = try c.decodeIfPresent([String].self, forKey: .events) ?? []
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        createdAt = try c.decodeIfPresent(String.self, forKey: .createdAt)
        lastDeliveryAt = try c.decodeIfPresent(String.self, forKey: .lastDeliveryAt)
        consecutiveFailures = try c.decodeIfPresent(Int.self, forKey: .consecutiveFailures)
        lastError = try c.decodeIfPresent(String.self, forKey: .lastError)
        secret = try c.decodeIfPresent(String.self, forKey: .secret)
        secretNote = try c.decodeIfPresent(String.self, forKey: .secretNote)
    }
}

/// The acknowledgement of ``LiveTennisApiClient/deleteWebhook(_:)``.
public struct WebhookDeletion: Decodable, Sendable {
    /// The id of the removed webhook.
    public let deleted: Int64?
}
