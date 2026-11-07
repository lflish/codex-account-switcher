import Combine
import Foundation
import SwitcherCore

struct AccountQuotaState {
    var snapshot: AccountQuotaSnapshot?
    var failure: QuotaReadError?
    var resetCredits: ResetCreditsSnapshot?
    var resetCreditsFailure: QuotaReadError?
}

/// In-memory display cache; this model never switches accounts or writes credentials.
@MainActor
final class AccountQuotaModel: ObservableObject {
    @Published private(set) var states: [UUID: AccountQuotaState] = [:]
    @Published private(set) var isLoading = false

    private let store: AccountStore
    private let fetchQuota: @Sendable (URL, String) async throws -> AccountQuotaSnapshot
    private let fetchResetCredits: @Sendable (URL, String) async throws -> ResetCreditsSnapshot
    private var latestAccounts: [AccountProfile] = []
    private var refreshPending = false

    init(store: AccountStore,
         fetchQuota: @escaping @Sendable (URL, String) async throws -> AccountQuotaSnapshot = {
             try await ProfileQuotaClient().fetchQuota(profileHome: $0, expectedAccountID: $1)
         },
         fetchResetCredits: @escaping @Sendable (URL, String) async throws -> ResetCreditsSnapshot = {
             try await ProfileQuotaClient().fetchResetCredits(profileHome: $0, expectedAccountID: $1)
         }) {
        self.store = store
        self.fetchQuota = fetchQuota
        self.fetchResetCredits = fetchResetCredits
    }

    func refresh(accounts: [AccountProfile]) async {
        latestAccounts = accounts
        guard !isLoading else { refreshPending = true; return }
        isLoading = true
        defer { isLoading = false }
        repeat {
            refreshPending = false
            let accounts = latestAccounts
            let currentIDs = Set(accounts.map(\.id))
            states = states.filter { currentIDs.contains($0.key) }
            for account in accounts {
                guard !Task.isCancelled else { return }
                guard let accountID = account.accountID, !accountID.isEmpty else {
                    states[account.id] = AccountQuotaState(failure: .identityUnavailable)
                    continue
                }
                let home = await store.profileHome(id: account.id)
                do {
                    let snapshot = try await fetchQuota(home, accountID)
                    var state = states[account.id] ?? AccountQuotaState()
                    state.snapshot = snapshot
                    state.failure = nil
                    states[account.id] = state
                } catch {
                    guard !Task.isCancelled else { return }
                    var state = states[account.id] ?? AccountQuotaState()
                    state.failure = error as? QuotaReadError ?? .transport
                    states[account.id] = state
                }
                guard !Task.isCancelled else { return }
                do {
                    let credits = try await fetchResetCredits(home, accountID)
                    var state = states[account.id] ?? AccountQuotaState()
                    state.resetCredits = credits
                    state.resetCreditsFailure = nil
                    states[account.id] = state
                } catch {
                    guard !Task.isCancelled else { return }
                    var state = states[account.id] ?? AccountQuotaState()
                    state.resetCreditsFailure = error as? QuotaReadError ?? .transport
                    states[account.id] = state
                }
            }
        } while refreshPending && !Task.isCancelled
    }
}
