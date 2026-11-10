import AppKit
import Foundation
import Testing
import SwitcherCore
@testable import CodexAccountSwitcher

@MainActor
struct UsageStatsPopoverTests {
    @Test func reopeningRefreshesSelectedRangeAndSkipsAnInFlightRefresh() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "stats-popover-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AccountStore(baseURL: root.appending(path: "store"), activeHomeURL: root.appending(path: "home"))
        let account = AccountProfile(id: UUID(), displayName: "Fixture", email: nil,
                                     accountID: "fixture", createdAt: Date())
        let home = try await store.createProfileDirectory(id: account.id)
        try Data(#"{"tokens":{"access_token":"fixture-token","account_id":"fixture"}}"#.utf8)
            .write(to: home.appending(path: "auth.json"))

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "Asia/Shanghai"))
        let yesterday = try #require(calendar.date(byAdding: .day, value: -1, to: Date()))
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"

        let gate = AsyncStream<Void>.makeStream()
        defer { gate.continuation.finish() }
        let transport = PopoverUsageTransport(day: formatter.string(from: yesterday), firstRequestGate: gate.stream)
        let model = UsageStatsModel(store: store, accounts: [account], language: .english, transport: transport)
        model.dateRange = .yesterday
        let popover = NSPopover()
        popover.delegate = model
        let didShow = Notification(name: NSPopover.didShowNotification, object: popover)

        popover.delegate?.popoverDidShow?(didShow)
        try await waitUntil { await transport.requestCount == 1 }
        #expect(model.isLoading)
        // Another show while that request is blocked must neither overlap nor queue a second GET.
        popover.delegate?.popoverDidShow?(didShow)
        gate.continuation.finish()
        try await waitUntil { !model.isLoading }
        #expect(await transport.requestCount == 1)
        #expect(model.overview?.totalTokens == 100)

        // The same popover and model are retained when the panel opens again.
        popover.delegate?.popoverDidShow?(didShow)
        try await waitUntil { model.overview?.totalTokens == 200 && !model.isLoading }
        #expect(await transport.requestCount == 2)
    }

    private func waitUntil(_ condition: () async -> Bool) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now + .seconds(3)
        while !(await condition()) {
            try #require(clock.now < deadline)
            try await clock.sleep(for: .milliseconds(10))
        }
    }
}

private actor PopoverUsageTransport: UsageStatsTransport {
    let day: String
    let firstRequestGate: AsyncStream<Void>
    private(set) var requestCount = 0

    init(day: String, firstRequestGate: AsyncStream<Void>) {
        self.day = day
        self.firstRequestGate = firstRequestGate
    }

    func fetchProfileUsage(accessToken: String, accountID: String) async throws -> ProfileUsageResponse {
        requestCount += 1
        let tokens = requestCount * 100
        if requestCount == 1 {
            var gate = firstRequestGate.makeAsyncIterator()
            _ = await gate.next()
        }
        let json = """
        {"stats":{"daily_usage_buckets":[{"start_date":"\(day)","tokens":\(tokens)}]}}
        """
        return try JSONDecoder().decode(ProfileUsageResponse.self, from: Data(json.utf8))
    }
}
