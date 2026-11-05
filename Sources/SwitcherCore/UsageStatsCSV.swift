import Foundation

public enum UsageStatsCSV {
    /// Export filtered usage data as CSV text.
    /// Columns: account_id,display_name,date,timezone,tokens_total
    /// Never includes email, token, or Bearer strings.
    public static func export(
        accounts: [String: AccountUsageStats],
        displayNames: [String: String],
        range: UsageStatsDateRange,
        timeZone: TimeZone,
        now: Date = Date()
    ) -> String {
        let dateLabels = UsageStatsAggregation.dateLabelsForRange(range, timeZone: timeZone, now: now)
        let tzIdentifier = timeZone.identifier

        var lines: [String] = ["account_id,display_name,date,timezone,tokens_total"]

        for (accountID, stats) in accounts.sorted(by: { $0.key < $1.key }) {
            let name = displayNames[accountID] ?? accountID
            for bucket in stats.dailyBuckets where dateLabels.contains(bucket.dateLabel) {
                lines.append("\(csvEscape(accountID)),\(csvEscape(name)),\(csvEscape(bucket.dateLabel)),\(csvEscape(tzIdentifier)),\(bucket.tokens)")
            }
        }

        return lines.joined(separator: "\n") + "\n"
    }

    private static func csvEscape(_ value: String) -> String {
        if value.contains(",") || value.contains("\"") || value.contains("\n") {
            return "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }
        return value
    }
}
