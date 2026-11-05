import Foundation

// MARK: - Upstream API response (Decodable, fault-tolerant)

/// Raw response from GET https://chatgpt.com/backend-api/wham/profiles/me
public struct ProfileUsageResponse: Decodable, Sendable {
    public let stats: ProfileStats?
    public let metadata: ProfileMetadata?
}

public struct ProfileStats: Decodable, Sendable {
    public let lifetime_tokens: Int?
    public let peak_daily_tokens: Int?
    public let longest_running_turn_sec: Double?
    public let current_streak_days: Int?
    public let longest_streak_days: Int?
    public let daily_usage_buckets: [DailyUsageBucket]?
    public let fast_mode_usage_percentage: Double?
    public let most_used_reasoning_effort: String?
    public let most_used_reasoning_effort_percentage: Double?
    public let unique_skills_used: Int?
    public let total_skills_used: Int?
    public let total_threads: Int?
    public let top_invocations: [TopInvocation]?

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        lifetime_tokens = try container.decodeIfPresent(Int.self, forKey: .lifetime_tokens)
        peak_daily_tokens = try container.decodeIfPresent(Int.self, forKey: .peak_daily_tokens)
        longest_running_turn_sec = try container.decodeIfPresent(Double.self, forKey: .longest_running_turn_sec)
        current_streak_days = try container.decodeIfPresent(Int.self, forKey: .current_streak_days)
        longest_streak_days = try container.decodeIfPresent(Int.self, forKey: .longest_streak_days)
        daily_usage_buckets = try container.decodeIfPresent([DailyUsageBucket].self, forKey: .daily_usage_buckets)
        fast_mode_usage_percentage = try container.decodeIfPresent(Double.self, forKey: .fast_mode_usage_percentage)
        most_used_reasoning_effort = try container.decodeIfPresent(String.self, forKey: .most_used_reasoning_effort)
        most_used_reasoning_effort_percentage = try container.decodeIfPresent(Double.self, forKey: .most_used_reasoning_effort_percentage)
        unique_skills_used = try container.decodeIfPresent(Int.self, forKey: .unique_skills_used)
        total_skills_used = try container.decodeIfPresent(Int.self, forKey: .total_skills_used)
        total_threads = try container.decodeIfPresent(Int.self, forKey: .total_threads)
        top_invocations = try container.decodeIfPresent([TopInvocation].self, forKey: .top_invocations)
    }

    private enum CodingKeys: String, CodingKey {
        case lifetime_tokens, peak_daily_tokens, longest_running_turn_sec
        case current_streak_days, longest_streak_days, daily_usage_buckets
        case fast_mode_usage_percentage, most_used_reasoning_effort
        case most_used_reasoning_effort_percentage
        case unique_skills_used, total_skills_used, total_threads, top_invocations
    }
}

public struct DailyUsageBucket: Decodable, Sendable {
    public let start_date: String?
    public let tokens: Int?
}

public struct TopInvocation: Codable, Equatable, Sendable {
    public let name: String?
    public let count: Int?

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decodeIfPresent(String.self, forKey: .name)
        count = try container.decodeIfPresent(Int.self, forKey: .count)
    }

    private enum CodingKeys: String, CodingKey { case name, count }
}

public struct ProfileMetadata: Decodable, Sendable {
    public let stats_as_of: String?
    public let generated_at: String?
    public let stats_error: String?
}

// MARK: - Domain models

public struct DayBucket: Codable, Equatable, Sendable {
    public let dateLabel: String   // "yyyy-MM-dd"
    public let tokens: Int

    public init(dateLabel: String, tokens: Int) {
        self.dateLabel = dateLabel
        self.tokens = tokens
    }
}

public struct AccountUsageStats: Codable, Equatable, Sendable {
    public let accountID: String
    public var lifetimeTokens: Int?
    public var peakDailyTokens: Int?
    public var longestRunningTurnSec: Double?
    public var currentStreakDays: Int?
    public var longestStreakDays: Int?
    public var dailyBuckets: [DayBucket]
    public var fastModeUsagePercentage: Double?
    public var mostUsedReasoningEffort: String?
    public var mostUsedReasoningEffortPercentage: Double?
    public var uniqueSkillsUsed: Int?
    public var totalSkillsUsed: Int?
    public var totalThreads: Int?
    public var topInvocations: [TopInvocation]?
    public var statsAsOf: String?
    public var generatedAt: String?

    public init(accountID: String, lifetimeTokens: Int? = nil, peakDailyTokens: Int? = nil,
                longestRunningTurnSec: Double? = nil, currentStreakDays: Int? = nil,
                longestStreakDays: Int? = nil, dailyBuckets: [DayBucket] = [],
                fastModeUsagePercentage: Double? = nil, mostUsedReasoningEffort: String? = nil,
                mostUsedReasoningEffortPercentage: Double? = nil, uniqueSkillsUsed: Int? = nil,
                totalSkillsUsed: Int? = nil, totalThreads: Int? = nil,
                topInvocations: [TopInvocation]? = nil, statsAsOf: String? = nil,
                generatedAt: String? = nil) {
        self.accountID = accountID; self.lifetimeTokens = lifetimeTokens
        self.peakDailyTokens = peakDailyTokens; self.longestRunningTurnSec = longestRunningTurnSec
        self.currentStreakDays = currentStreakDays; self.longestStreakDays = longestStreakDays
        self.dailyBuckets = dailyBuckets; self.fastModeUsagePercentage = fastModeUsagePercentage
        self.mostUsedReasoningEffort = mostUsedReasoningEffort
        self.mostUsedReasoningEffortPercentage = mostUsedReasoningEffortPercentage
        self.uniqueSkillsUsed = uniqueSkillsUsed; self.totalSkillsUsed = totalSkillsUsed
        self.totalThreads = totalThreads; self.topInvocations = topInvocations
        self.statsAsOf = statsAsOf; self.generatedAt = generatedAt
    }
}

// MARK: - Sync status

public enum AccountSyncStatus: Codable, Equatable, Sendable {
    case synced(fetchedAt: Date)
    case stale(fetchedAt: Date, reason: String)
    case authExpired
    case unavailable(reason: String)
    case neverSynced
}

// MARK: - Persisted model

public struct StoredUsageStats: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1
    public var schemaVersion: Int
    public var accounts: [String: AccountUsageStats]     // keyed by chatgpt account_id
    public var syncStatuses: [String: AccountSyncStatus]

    public init(schemaVersion: Int = Self.currentSchemaVersion,
                accounts: [String: AccountUsageStats] = [:],
                syncStatuses: [String: AccountSyncStatus] = [:]) {
        self.schemaVersion = schemaVersion
        self.accounts = accounts
        self.syncStatuses = syncStatuses
    }

    public static let empty = StoredUsageStats()
}

// MARK: - Mapping from upstream response to domain model

extension AccountUsageStats {
    public init(accountID: String, response: ProfileUsageResponse) {
        self.accountID = accountID
        self.lifetimeTokens = response.stats?.lifetime_tokens
        self.peakDailyTokens = response.stats?.peak_daily_tokens
        self.longestRunningTurnSec = response.stats?.longest_running_turn_sec
        self.currentStreakDays = response.stats?.current_streak_days
        self.longestStreakDays = response.stats?.longest_streak_days
        self.fastModeUsagePercentage = response.stats?.fast_mode_usage_percentage
        self.mostUsedReasoningEffort = response.stats?.most_used_reasoning_effort
        self.mostUsedReasoningEffortPercentage = response.stats?.most_used_reasoning_effort_percentage
        self.uniqueSkillsUsed = response.stats?.unique_skills_used
        self.totalSkillsUsed = response.stats?.total_skills_used
        self.totalThreads = response.stats?.total_threads
        self.topInvocations = response.stats?.top_invocations
        self.statsAsOf = response.metadata?.stats_as_of
        self.generatedAt = response.metadata?.generated_at

        // Deduplicate and sort daily buckets by date label
        var seen = Set<String>()
        var buckets: [DayBucket] = []
        for bucket in response.stats?.daily_usage_buckets ?? [] {
            guard let date = bucket.start_date, let tokens = bucket.tokens else { continue }
            if seen.insert(date).inserted {
                buckets.append(DayBucket(dateLabel: date, tokens: tokens))
            }
        }
        buckets.sort { $0.dateLabel < $1.dateLabel }
        self.dailyBuckets = buckets
    }

    /// Merge new upstream buckets into existing stored stats (idempotent replacement by date).
    public func mergedWith(newer: AccountUsageStats) -> AccountUsageStats {
        var result = newer
        // Replace daily buckets entirely with the new set (idempotent)
        result.dailyBuckets = newer.dailyBuckets
        return result
    }
}
