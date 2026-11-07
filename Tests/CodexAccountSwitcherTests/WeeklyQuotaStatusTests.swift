import Foundation
import Testing
import SwitcherCore
@testable import CodexAccountSwitcher

struct WeeklyQuotaStatusTests {
    let now = Date(timeIntervalSince1970: 10_000)

    @Test func usesOnlyConfirmedActiveAccount() {
        let a = account("A"), b = account("B")
        let states = [a.id: state(5), b.id: state(57)]
        #expect(WeeklyQuotaStatus(accounts: [a, b], activeID: b.id, identityConfirmed: true,
                                 states: states, now: now).remainingPercent == 57)
        #expect(WeeklyQuotaStatus(accounts: [a, b], activeID: b.id, identityConfirmed: false,
                                 states: states, now: now).remainingPercent == nil)
        #expect(WeeklyQuotaStatus(accounts: [a], activeID: b.id, identityConfirmed: true,
                                 states: states, now: now).remainingPercent == nil)
    }

    @Test func distinguishesZeroMissingExpiredAndFailedCache() {
        let a = account("A")
        func project(_ state: AccountQuotaState) -> WeeklyQuotaStatus {
            WeeklyQuotaStatus(accounts: [a], activeID: a.id, identityConfirmed: true,
                              states: [a.id: state], now: now)
        }
        #expect(project(state(0)).remainingPercent == 0)
        #expect(project(AccountQuotaState()).remainingPercent == nil)
        let expired = state(60, resetsAt: now)
        #expect(project(expired).remainingPercent == nil)
        var cache = state(42)
        cache.failure = .transport
        #expect(project(cache).remainingPercent == 42)
        #expect(project(cache).tooltip.contains("缓存"))
        #expect(project(cache).isCached)
        #expect(!project(state(42)).isCached)
        let fiveHourOnly = AccountQuotaState(snapshot: AccountQuotaSnapshot(
            fiveHour: QuotaWindowSnapshot(remainingPercent: 99, resetsAt: nil), weekly: nil,
            fetchedAt: now, resetCreditsRemaining: nil))
        #expect(project(fiveHourOnly).remainingPercent == nil)
    }

    @Test func thresholdBoundaries() {
        #expect(WeeklyQuotaTone.tone(for: 0) == .critical)
        #expect(WeeklyQuotaTone.tone(for: 9) == .critical)
        #expect(WeeklyQuotaTone.tone(for: 10) == .warning)
        #expect(WeeklyQuotaTone.tone(for: 49) == .warning)
        #expect(WeeklyQuotaTone.tone(for: 50) == .neutral)
        #expect(WeeklyQuotaTone.tone(for: nil) == .neutral)
    }

    private func account(_ name: String) -> AccountProfile {
        AccountProfile(id: UUID(), displayName: name, email: nil, accountID: name, createdAt: now)
    }
    private func state(_ percent: Int, resetsAt: Date? = nil) -> AccountQuotaState {
        AccountQuotaState(snapshot: AccountQuotaSnapshot(fiveHour: nil,
            weekly: QuotaWindowSnapshot(remainingPercent: percent, resetsAt: resetsAt ?? now.addingTimeInterval(500)),
            fetchedAt: now, resetCreditsRemaining: nil))
    }
}
