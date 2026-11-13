import Combine
import Foundation

/// App-lifetime quota polling; neither panel visibility nor elapsed sleep queues extra work.
@MainActor
final class AccountQuotaRefreshScheduler {
    typealias TimerFactory = @MainActor (TimeInterval, @escaping @MainActor () -> Void) -> AnyCancellable

    private let interval: TimeInterval
    private let canRefresh: @MainActor () -> Bool
    private let refresh: @MainActor () async -> Void
    private let makeTimer: TimerFactory
    private var timer: AnyCancellable?
    private var refreshTask: Task<Void, Never>?
    private var generation = 0

    // The transport does not expose Retry-After. Automatic failures retry on the next
    // regular 60-second tick rather than starting a retry loop.
    init(interval: TimeInterval = 60,
         canRefresh: @escaping @MainActor () -> Bool,
         refresh: @escaping @MainActor () async -> Void,
         makeTimer: @escaping TimerFactory = { interval, tick in
             Timer.publish(every: interval, on: .main, in: .common).autoconnect()
                 .sink { _ in tick() }
         }) {
        self.interval = interval
        self.canRefresh = canRefresh
        self.refresh = refresh
        self.makeTimer = makeTimer
    }

    func start() {
        guard timer == nil else { return }
        timer = makeTimer(interval) { [weak self] in self?.requestRefresh() }
    }

    /// A tick or wake can refresh once; requests during any current refresh are dropped.
    func requestRefresh() {
        guard timer != nil, refreshTask == nil, canRefresh() else { return }
        let generation = generation
        refreshTask = Task { [weak self] in
            guard let self else { return }
            defer {
                if self.generation == generation { refreshTask = nil }
            }
            // A manual request can start between the timer firing and this task running.
            guard !Task.isCancelled, canRefresh() else { return }
            await refresh()
        }
    }

    func stop() {
        timer?.cancel()
        timer = nil
        generation += 1
        refreshTask?.cancel()
        refreshTask = nil
    }
}
