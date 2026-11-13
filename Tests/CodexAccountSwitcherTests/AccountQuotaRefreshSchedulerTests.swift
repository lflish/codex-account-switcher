import Combine
import Foundation
import Testing
@testable import CodexAccountSwitcher

@MainActor
struct AccountQuotaRefreshSchedulerTests {
    @Test func refreshesWithoutPanelAndStartsOnlyOneTimer() async {
        let timer = ManualQuotaTimer()
        var calls = 0
        let scheduler = AccountQuotaRefreshScheduler(canRefresh: { true }, refresh: { calls += 1 }, makeTimer: timer.make)
        scheduler.start()
        scheduler.start()
        #expect(timer.intervals == [60])
        #expect(calls == 0)
        timer.fire()
        await drainTasks()
        #expect(calls == 1)
        timer.fire()
        await drainTasks()
        #expect(calls == 2)
        scheduler.stop()
    }

    @Test func skipsTicksAndRepeatedWakeWhileRefreshIsRunning() async {
        let timer = ManualQuotaTimer()
        let refresh = SuspendedQuotaRefresh()
        let scheduler = AccountQuotaRefreshScheduler(canRefresh: { true }, refresh: { await refresh.run() }, makeTimer: timer.make)
        scheduler.start()
        timer.fire()
        await drainTasks()
        #expect(refresh.calls == 1)
        for _ in 0..<10 {
            timer.fire()
            scheduler.requestRefresh() // The same entry point handles wake notifications.
        }
        await drainTasks()
        #expect(refresh.calls == 1)
        refresh.finish()
        await drainTasks()
        #expect(refresh.calls == 1) // Missed intervals never queue a catch-up request.
        scheduler.requestRefresh()
        scheduler.requestRefresh()
        await drainTasks()
        #expect(refresh.calls == 2)
        refresh.finish()
        await drainTasks()
        scheduler.stop()
    }

    @Test func skipsEmptyAccountsAndExternalRefreshWithoutQueueing() async {
        let timer = ManualQuotaTimer()
        let eligibility = QuotaRefreshEligibility()
        var calls = 0
        let scheduler = AccountQuotaRefreshScheduler(canRefresh: { eligibility.hasAccounts && !eligibility.modelLoading },
            refresh: { calls += 1 }, makeTimer: timer.make)
        scheduler.start()
        timer.fire()
        scheduler.requestRefresh()
        await drainTasks()
        #expect(calls == 0)
        eligibility.hasAccounts = true
        eligibility.modelLoading = true
        timer.fire()
        await drainTasks()
        #expect(calls == 0)
        eligibility.modelLoading = false
        await drainTasks()
        #expect(calls == 0)
        timer.fire()
        await drainTasks()
        #expect(calls == 1)
        scheduler.stop()
    }

    @Test func rechecksModelLoadingBeforeStartingTheTask() async {
        let timer = ManualQuotaTimer()
        let eligibility = QuotaRefreshEligibility()
        eligibility.hasAccounts = true
        var calls = 0
        let scheduler = AccountQuotaRefreshScheduler(canRefresh: { !eligibility.modelLoading },
            refresh: { calls += 1 }, makeTimer: timer.make)
        scheduler.start()
        timer.fire()
        eligibility.modelLoading = true // A manual refresh wins the next main-actor turn.
        await drainTasks()
        #expect(calls == 0)
        eligibility.modelLoading = false
        timer.fire()
        await drainTasks()
        #expect(calls == 1)
        scheduler.stop()
    }

    @Test func stoppingCancelsTimerAndInFlightRefreshAndAllowsRestart() async {
        let timer = ManualQuotaTimer()
        let refresh = SuspendedQuotaRefresh()
        let scheduler = AccountQuotaRefreshScheduler(canRefresh: { true }, refresh: { await refresh.run() }, makeTimer: timer.make)
        scheduler.start()
        timer.fire()
        await drainTasks()
        scheduler.stop()
        #expect(timer.cancellations == 1)
        timer.fire()
        scheduler.requestRefresh()
        await drainTasks()
        #expect(refresh.calls == 1)
        refresh.finish()
        await drainTasks()
        #expect(refresh.wasCancelled)
        scheduler.start()
        timer.fire()
        await drainTasks()
        #expect(refresh.calls == 2)
        refresh.finish()
        await drainTasks()
        scheduler.stop()
    }

    private func drainTasks() async {
        for _ in 0..<20 { await Task.yield() }
    }
}

@MainActor
private final class ManualQuotaTimer {
    var intervals: [TimeInterval] = []
    var cancellations = 0
    private var tick: (@MainActor () -> Void)?

    func make(interval: TimeInterval, tick: @escaping @MainActor () -> Void) -> AnyCancellable {
        intervals.append(interval)
        self.tick = tick
        return AnyCancellable { [weak self] in
            // Cancellation is always invoked on the scheduler's main actor.
            MainActor.assumeIsolated { self?.cancellations += 1 }
        }
    }

    func fire() { tick?() }
}

@MainActor
private final class SuspendedQuotaRefresh {
    var calls = 0
    var wasCancelled = false
    private var continuation: CheckedContinuation<Void, Never>?

    func run() async {
        calls += 1
        await withCheckedContinuation { continuation = $0 }
        wasCancelled = Task.isCancelled
    }

    func finish() {
        continuation?.resume()
        continuation = nil
    }
}

@MainActor
private final class QuotaRefreshEligibility {
    var hasAccounts = false
    var modelLoading = false
}
