import Foundation

/// Per-account sync result returned by UsageStatsService.
public struct AccountSyncResult: Sendable {
    public let accountID: String
    public let profileID: UUID
    public let displayName: String
    public let status: AccountSyncStatus
    public let stats: AccountUsageStats?
}

/// Orchestrates fetching, merging, and persisting usage stats for all accounts.
public actor UsageStatsService {
    private let store: UsageStatsStore
    private let client: ProfileUsageClient

    public init(store: UsageStatsStore, client: ProfileUsageClient = ProfileUsageClient()) {
        self.store = store
        self.client = client
    }

    public init(store: UsageStatsStore, transport: any UsageStatsTransport) {
        self.store = store
        self.client = ProfileUsageClient(transport: transport)
    }

    /// Load persisted stats without network calls.
    public func load() async throws -> StoredUsageStats {
        try await store.load()
    }

    /// Sync usage stats for all given accounts. Single account failure does not affect others.
    public func sync(
        accounts: [(profile: AccountProfile, profileHome: URL)]
    ) async -> [AccountSyncResult] {
        var results: [AccountSyncResult] = []

        for (profile, profileHome) in accounts {
            guard let accountID = profile.accountID else {
                results.append(AccountSyncResult(
                    accountID: "", profileID: profile.id, displayName: profile.displayName,
                    status: .unavailable(reason: "No account ID"), stats: nil
                ))
                continue
            }

            do {
                let (fetchedAccountID, response) = try await client.fetchUsage(profileHome: profileHome)
                let effectiveAccountID = fetchedAccountID.isEmpty ? accountID : fetchedAccountID

                let newStats = AccountUsageStats(accountID: effectiveAccountID, response: response)

                // Load existing and merge (idempotent replacement)
                let stored = try await store.load()
                let merged: AccountUsageStats
                if let existing = stored.accounts[effectiveAccountID] {
                    merged = existing.mergedWith(newer: newStats)
                } else {
                    merged = newStats
                }

                let status = AccountSyncStatus.synced(fetchedAt: Date())
                try await store.update(accountID: effectiveAccountID, stats: merged, status: status)

                results.append(AccountSyncResult(
                    accountID: effectiveAccountID, profileID: profile.id,
                    displayName: profile.displayName, status: status, stats: merged
                ))
            } catch let error as UsageStatsError {
                let status: AccountSyncStatus
                switch error {
                case .authExpired:
                    status = .authExpired
                case .forbidden:
                    status = .stale(fetchedAt: Date(), reason: error.localizedDescription)
                case .unavailable(let reason):
                    status = .unavailable(reason: reason)
                default:
                    status = .stale(fetchedAt: Date(), reason: error.localizedDescription)
                }

                // Preserve old data for stale status
                let existingStats: AccountUsageStats?
                if case .stale = status {
                    existingStats = try? await store.load().accounts[accountID]
                } else {
                    existingStats = nil
                }
                try? await store.updateStatus(accountID: accountID, status: status)

                results.append(AccountSyncResult(
                    accountID: accountID, profileID: profile.id,
                    displayName: profile.displayName, status: status, stats: existingStats
                ))
            } catch {
                let status = AccountSyncStatus.stale(fetchedAt: Date(), reason: error.localizedDescription)
                let existingStats = try? await store.load().accounts[accountID]
                try? await store.updateStatus(accountID: accountID, status: status)

                results.append(AccountSyncResult(
                    accountID: accountID, profileID: profile.id,
                    displayName: profile.displayName, status: status, stats: existingStats
                ))
            }
        }

        return results
    }
}
