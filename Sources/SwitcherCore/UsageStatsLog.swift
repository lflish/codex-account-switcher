import Foundation
#if canImport(OSLog)
import OSLog
#endif

/// Diagnostics for usage-stat syncing.
///
/// Sync failures used to be silent: the panel showed a smaller total with no way to
/// tell which account dropped out or why, and nothing was recorded after the fact.
/// These logs keep that explainable — `log show --predicate 'subsystem == "..."'`
/// answers "why did yesterday's number change?" without touching user data.
enum UsageStatsLog {
    #if canImport(OSLog)
    private static let logger = Logger(
        subsystem: "com.liuzhao.codex-account-switcher", category: "UsageStats"
    )

    /// Account synced successfully. Bucket count and whether the range had data.
    static func synced(accountID: String, buckets: Int, fetchedAt: Date) {
        logger.info(
            "synced account=\(accountID, privacy: .public) buckets=\(buckets, privacy: .public) at=\(fetchedAt, privacy: .public)"
        )
    }

    /// Account failed to sync. `status` is the resulting coverage state.
    static func failed(accountID: String, status: String, reason: String) {
        logger.error(
            "sync failed account=\(accountID, privacy: .public) status=\(status, privacy: .public) reason=\(reason, privacy: .public)"
        )
    }

    /// The account synced but reported no bucket inside the selected range.
    static func noDataForRange(accountID: String, range: String) {
        logger.notice(
            "no bucket in range account=\(accountID, privacy: .public) range=\(range, privacy: .public)"
        )
    }
    #else
    static func synced(accountID: String, buckets: Int, fetchedAt: Date) {}
    static func failed(accountID: String, status: String, reason: String) {}
    static func noDataForRange(accountID: String, range: String) {}
    #endif
}
