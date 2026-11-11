import Foundation

// MARK: - Date range

public enum UsageStatsDateRange: Equatable, Sendable {
    case today
    case yesterday
    case lastDays(Int)  // 7 or 30, includes today, counting backwards
    case custom(startLabel: String, endLabel: String)
}

// MARK: - Aggregation results

/// Why an expected account did not contribute tokens to the selected range.
public enum MissingAccountReason: Equatable, Sendable {
    /// The account was dropped before aggregation because its sync status was not
    /// usable (never synced, auth expired, or unavailable).
    case notSynced
    /// The account synced fine but upstream reported no bucket for this range —
    /// the day is genuinely missing upstream, or the bucket has not landed yet.
    case noDataForRange
}

/// An account that was expected to contribute to the total but did not.
public struct MissingAccount: Equatable, Sendable {
    public let accountID: String
    public let displayName: String
    public let reason: MissingAccountReason

    public init(accountID: String, displayName: String, reason: MissingAccountReason) {
        self.accountID = accountID
        self.displayName = displayName
        self.reason = reason
    }
}

public struct UsageStatsOverview: Equatable, Sendable {
    public let totalTokens: Int
    /// Daily average = totalTokens / daysWithData (not calendar days in range).
    public let dailyAverage: Int
    public let peakDay: (dateLabel: String, tokens: Int)?
    /// Only dates with data; sorted ascending.
    public let dailySeries: [DayBucket]
    /// Dates within the range that have no data.
    public let missingDates: [String]
    /// Per-account breakdown.
    public let accountBreakdown: [AccountBreakdownEntry]
    /// Accounts that were expected but contributed nothing to this range, with why.
    /// Non-empty means `totalTokens` is a lower bound, not the final figure.
    public let missingAccounts: [MissingAccount]
    public let syncedCount: Int
    public let totalAccountCount: Int
    public let isPartial: Bool

    public static func == (lhs: UsageStatsOverview, rhs: UsageStatsOverview) -> Bool {
        lhs.totalTokens == rhs.totalTokens
        && lhs.dailyAverage == rhs.dailyAverage
        && lhs.peakDay?.dateLabel == rhs.peakDay?.dateLabel
        && lhs.peakDay?.tokens == rhs.peakDay?.tokens
        && lhs.dailySeries == rhs.dailySeries
        && lhs.missingDates == rhs.missingDates
        && lhs.accountBreakdown == rhs.accountBreakdown
        && lhs.missingAccounts == rhs.missingAccounts
        && lhs.syncedCount == rhs.syncedCount
        && lhs.totalAccountCount == rhs.totalAccountCount
        && lhs.isPartial == rhs.isPartial
    }
}

public struct AccountBreakdownEntry: Equatable, Sendable {
    public let accountID: String
    public let displayName: String
    public let totalTokens: Int
    public let proportion: Double  // 0.0 – 1.0
    public let coverageStart: String?
    public let coverageEnd: String?
}

// MARK: - Single-account result (same structure, for per-account view)

public struct SingleAccountOverview: Equatable, Sendable {
    public let overview: UsageStatsOverview
    public let lifetimeTokens: Int?
    public let peakDailyTokens: Int?
    public let currentStreakDays: Int?
    public let longestStreakDays: Int?
    public let totalThreads: Int?
    public let statsAsOf: String?
}

// MARK: - Pure aggregation functions

public enum UsageStatsAggregation {

    /// Compute an overview across multiple accounts for a given date range and timezone.
    public static func overview(
        accounts: [String: AccountUsageStats],
        syncStatuses: [String: AccountSyncStatus],
        displayNames: [String: String],
        range: UsageStatsDateRange,
        timeZone: TimeZone,
        now: Date = Date(),
        totalAccountCount: Int
    ) -> UsageStatsOverview {
        let dateLabels = dateLabelsForRange(range, timeZone: timeZone, now: now)

        // Only include accounts that have been synced (have data)
        let syncedAccounts = accounts.filter { key, _ in
            switch syncStatuses[key] {
            case .synced, .stale: return true
            default: return false
            }
        }

        // Aggregate daily buckets across all synced accounts
        var dailyTotals: [String: Int] = [:]
        var accountTotals: [(id: String, tokens: Int, start: String?, end: String?)] = []
        var missingAccounts: [MissingAccount] = []

        // Accounts excluded entirely because their sync status is unusable
        // (never synced, auth expired, unavailable). They contribute nothing,
        // so the total is a lower bound while any of these exist.
        for accountID in syncStatuses.keys where syncedAccounts[accountID] == nil {
            missingAccounts.append(MissingAccount(
                accountID: accountID,
                displayName: displayNames[accountID] ?? accountID,
                reason: .notSynced
            ))
        }

        for (accountID, stats) in syncedAccounts {
            let filtered = stats.dailyBuckets.filter { dateLabels.contains($0.dateLabel) }
            var accountTotal = 0
            var start: String?
            var end: String?
            for bucket in filtered {
                dailyTotals[bucket.dateLabel, default: 0] += bucket.tokens
                accountTotal += bucket.tokens
                if start == nil || bucket.dateLabel < start! { start = bucket.dateLabel }
                if end == nil || bucket.dateLabel > end! { end = bucket.dateLabel }
            }
            accountTotals.append((accountID, accountTotal, start, end))

            // Synced, but nothing landed in this range: either upstream omitted the
            // day or the bucket has not been published yet. Both make the total a
            // lower bound, and neither is currently distinguishable from each other.
            if filtered.isEmpty {
                missingAccounts.append(MissingAccount(
                    accountID: accountID,
                    displayName: displayNames[accountID] ?? accountID,
                    reason: .noDataForRange
                ))
            }
        }

        let totalTokens = dailyTotals.values.reduce(0, +)
        let daysWithData = dailyTotals.count

        let dailySeries = dailyTotals
            .map { DayBucket(dateLabel: $0.key, tokens: $0.value) }
            .sorted { $0.dateLabel < $1.dateLabel }

        let peakDay = dailySeries.max(by: { $0.tokens < $1.tokens })
            .map { ($0.dateLabel, $0.tokens) }

        let datesWithData = Set(dailyTotals.keys)
        let missingDates = dateLabels.filter { !datesWithData.contains($0) }.sorted()

        let breakdown = accountTotals.map { entry in
            AccountBreakdownEntry(
                accountID: entry.id,
                displayName: displayNames[entry.id] ?? entry.id,
                totalTokens: entry.tokens,
                proportion: totalTokens > 0 ? Double(entry.tokens) / Double(totalTokens) : 0,
                coverageStart: entry.start,
                coverageEnd: entry.end
            )
        }.sorted { $0.totalTokens > $1.totalTokens }

        let syncedCount = syncedAccounts.count
        let neverSyncedCount = syncStatuses.values.filter {
            if case .neverSynced = $0 { return true }; return false
        }.count

        // Stable order so equal totals never reorder across refreshes.
        let sortedMissing = missingAccounts.sorted { $0.displayName < $1.displayName }

        return UsageStatsOverview(
            totalTokens: totalTokens,
            dailyAverage: daysWithData > 0 ? totalTokens / daysWithData : 0,
            peakDay: peakDay,
            dailySeries: dailySeries,
            missingDates: missingDates,
            accountBreakdown: breakdown,
            missingAccounts: sortedMissing,
            syncedCount: syncedCount,
            totalAccountCount: totalAccountCount,
            isPartial: !sortedMissing.isEmpty || neverSyncedCount > 0 || syncedCount < totalAccountCount
        )
    }

    /// Single-account overview with additional summary fields.
    public static func singleAccountOverview(
        accountID: String,
        stats: AccountUsageStats,
        syncStatus: AccountSyncStatus,
        displayName: String,
        range: UsageStatsDateRange,
        timeZone: TimeZone,
        now: Date = Date()
    ) -> SingleAccountOverview {
        let multi = overview(
            accounts: [accountID: stats],
            syncStatuses: [accountID: syncStatus],
            displayNames: [accountID: displayName],
            range: range,
            timeZone: timeZone,
            now: now,
            totalAccountCount: 1
        )
        return SingleAccountOverview(
            overview: multi,
            lifetimeTokens: stats.lifetimeTokens,
            peakDailyTokens: stats.peakDailyTokens,
            currentStreakDays: stats.currentStreakDays,
            longestStreakDays: stats.longestStreakDays,
            totalThreads: stats.totalThreads,
            statsAsOf: stats.statsAsOf
        )
    }

    // MARK: - Date label generation

    /// Generate the set of date label strings for a given range and timezone.
    public static func dateLabelsForRange(
        _ range: UsageStatsDateRange,
        timeZone: TimeZone,
        now: Date = Date()
    ) -> Set<String> {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = timeZone

        switch range {
        case .today:
            return [formatter.string(from: now)]

        case .yesterday:
            guard let date = calendar.date(byAdding: .day, value: -1, to: calendar.startOfDay(for: now)) else { return [] }
            return [formatter.string(from: date)]

        case .lastDays(let count):
            let today = calendar.startOfDay(for: now)
            var labels = Set<String>()
            for offset in 0..<count {
                if let date = calendar.date(byAdding: .day, value: -offset, to: today) {
                    labels.insert(formatter.string(from: date))
                }
            }
            return labels

        case .custom(let startLabel, let endLabel):
            guard let startDate = formatter.date(from: startLabel),
                  let endDate = formatter.date(from: endLabel) else {
                return []
            }
            var labels = Set<String>()
            var current = startDate
            while current <= endDate {
                labels.insert(formatter.string(from: current))
                guard let next = calendar.date(byAdding: .day, value: 1, to: current) else { break }
                current = next
            }
            return labels
        }
    }

    /// Today's date label in the given timezone.
    public static func todayLabel(timeZone: TimeZone, now: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = timeZone
        return formatter.string(from: now)
    }
}
