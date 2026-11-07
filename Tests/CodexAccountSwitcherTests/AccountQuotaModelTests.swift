import Foundation
import Testing
import SwitcherCore
@testable import CodexAccountSwitcher

@MainActor
struct AccountQuotaModelTests {
    @Test func failedRefreshKeepsSuccessfulTimestampAndValues() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "quota-model-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AccountStore(baseURL: root.appending(path: "store"), activeHomeURL: root.appending(path: "home"))
        let account = AccountProfile(id: UUID(), displayName: "Fixture", email: nil,
                                     accountID: "fixture", createdAt: Date())
        let fetchedAt = Date(timeIntervalSince1970: 1_000)
        let snapshot = AccountQuotaSnapshot(
            fiveHour: QuotaWindowSnapshot(remainingPercent: 72, resetsAt: Date(timeIntervalSince1970: 2_000)),
            weekly: nil, fetchedAt: fetchedAt, resetCreditsRemaining: 2
        )
        let source = QuotaModelSource(snapshot: snapshot)
        let model = AccountQuotaModel(store: store,
            fetchQuota: { _, _ in try await source.fetch() },
            fetchResetCredits: { _, _ in throw QuotaReadError.forbidden })

        await model.refresh(accounts: [account])
        #expect(model.states[account.id]?.snapshot == snapshot)
        #expect(model.states[account.id]?.failure == nil)
        #expect(model.states[account.id]?.resetCreditsFailure == .forbidden)
        #expect(model.states[account.id]?.snapshot?.resetCreditsRemaining == 2)
        await model.refresh(accounts: [account])
        #expect(model.states[account.id]?.snapshot?.fetchedAt == fetchedAt)
        #expect(model.states[account.id]?.snapshot?.fiveHour?.remainingPercent == 72)
        #expect(model.states[account.id]?.failure == .authExpired)
        #expect(!model.isLoading)

        await model.refresh(accounts: [])
        #expect(model.states.isEmpty)
    }
}

private actor QuotaModelSource {
    let snapshot: AccountQuotaSnapshot
    private var hasReturned = false
    init(snapshot: AccountQuotaSnapshot) { self.snapshot = snapshot }
    func fetch() throws -> AccountQuotaSnapshot {
        if hasReturned { throw QuotaReadError.authExpired }
        hasReturned = true
        return snapshot
    }
}
