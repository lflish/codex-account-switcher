import Foundation
import Testing
@testable import SwitcherCore

// MARK: - Stub Transport

private actor StubTransport: UsageStatsTransport {
    var responses: [String: Result<ProfileUsageResponse, UsageStatsError>] = [:]

    func setResponse(_ accountID: String, _ result: Result<ProfileUsageResponse, UsageStatsError>) {
        responses[accountID] = result
    }

    func fetchProfileUsage(accessToken: String, accountID: String) async throws -> ProfileUsageResponse {
        guard let result = responses[accountID] else {
            throw UsageStatsError.transport("No stub for \(accountID)")
        }
        switch result {
        case .success(let response): return response
        case .failure(let error): throw error
        }
    }
}

// MARK: - Test fixtures

private func fullPayloadJSON() -> Data {
    """
    {
      "stats": {
        "lifetime_tokens": 500000,
        "peak_daily_tokens": 25000,
        "longest_running_turn_sec": 120.5,
        "current_streak_days": 5,
        "longest_streak_days": 14,
        "daily_usage_buckets": [
          {"start_date": "2026-11-01", "tokens": 10000},
          {"start_date": "2026-11-02", "tokens": 15000},
          {"start_date": "2026-11-03", "tokens": 8000},
          {"start_date": "2026-11-04", "tokens": 20000},
          {"start_date": "2026-11-05", "tokens": 12000}
        ],
        "fast_mode_usage_percentage": 0.45,
        "most_used_reasoning_effort": "high",
        "most_used_reasoning_effort_percentage": 0.6,
        "unique_skills_used": 3,
        "total_skills_used": 42,
        "total_threads": 150,
        "top_invocations": [
          {"name": "code_review", "count": 30}
        ]
      },
      "metadata": {
        "stats_as_of": "2026-11-05T12:00:00Z",
        "generated_at": "2026-11-05T12:01:00Z",
        "stats_error": null
      }
    }
    """.data(using: .utf8)!
}

private func statsErrorPayloadJSON() -> Data {
    """
    {
      "stats": {
        "lifetime_tokens": 100
      },
      "metadata": {
        "stats_as_of": "2026-11-05",
        "generated_at": "2026-11-05",
        "stats_error": "upstream_timeout"
      }
    }
    """.data(using: .utf8)!
}

private func missingFieldsPayloadJSON() -> Data {
    """
    {
      "stats": {},
      "metadata": {}
    }
    """.data(using: .utf8)!
}

private func decodeResponse(_ data: Data) throws -> ProfileUsageResponse {
    try JSONDecoder().decode(ProfileUsageResponse.self, from: data)
}

private let shanghaiTZ = TimeZone(identifier: "Asia/Shanghai")!
private let utcTZ = TimeZone(identifier: "UTC")!

// MARK: - Decoding Tests

@Suite struct UsageStatsDecodingTests {
    @Test func decodesFullPayload() throws {
        let response = try decodeResponse(fullPayloadJSON())
        #expect(response.stats?.lifetime_tokens == 500000)
        #expect(response.stats?.peak_daily_tokens == 25000)
        #expect(response.stats?.current_streak_days == 5)
        #expect(response.stats?.longest_streak_days == 14)
        #expect(response.stats?.daily_usage_buckets?.count == 5)
        #expect(response.stats?.total_threads == 150)
        #expect(response.stats?.fast_mode_usage_percentage == 0.45)
        #expect(response.stats?.top_invocations?.first?.name == "code_review")
        #expect(response.metadata?.stats_as_of == "2026-11-05T12:00:00Z")
        #expect(response.metadata?.stats_error == nil)
    }

    @Test func decodesStatsErrorPayload() throws {
        let response = try decodeResponse(statsErrorPayloadJSON())
        #expect(response.metadata?.stats_error == "upstream_timeout")
        #expect(response.stats?.lifetime_tokens == 100)
    }

    @Test func decodesMissingFieldsPayload() throws {
        let response = try decodeResponse(missingFieldsPayloadJSON())
        #expect(response.stats?.lifetime_tokens == nil)
        #expect(response.stats?.daily_usage_buckets == nil)
        #expect(response.metadata?.stats_error == nil)
    }
}

// MARK: - Domain model mapping

@Suite struct UsageStatsMappingTests {
    @Test func mapsResponseToDomainModel() throws {
        let response = try decodeResponse(fullPayloadJSON())
        let stats = AccountUsageStats(accountID: "acct-test-1", response: response)
        #expect(stats.lifetimeTokens == 500000)
        #expect(stats.dailyBuckets.count == 5)
        #expect(stats.dailyBuckets.first?.dateLabel == "2026-11-01")
        #expect(stats.dailyBuckets.last?.dateLabel == "2026-11-05")
        #expect(stats.totalThreads == 150)
    }

    @Test func dailyBucketsAreDeduplicated() throws {
        let json = """
        {
          "stats": {
            "daily_usage_buckets": [
              {"start_date": "2026-11-01", "tokens": 100},
              {"start_date": "2026-11-01", "tokens": 200},
              {"start_date": "2026-11-02", "tokens": 300}
            ]
          },
          "metadata": {}
        }
        """.data(using: .utf8)!
        let response = try decodeResponse(json)
        let stats = AccountUsageStats(accountID: "acct-test-1", response: response)
        #expect(stats.dailyBuckets.count == 2)
        // First occurrence wins
        #expect(stats.dailyBuckets[0].tokens == 100)
        #expect(stats.dailyBuckets[1].tokens == 300)
    }
}

// MARK: - Sync Idempotency

@Suite struct UsageStatsSyncTests {
    @Test func syncIdempotency_sameTwice_totalUnchanged() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "usage-sync-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let statsStore = UsageStatsStore(baseURL: root)
        let transport = StubTransport()
        let response = try decodeResponse(fullPayloadJSON())
        await transport.setResponse("acct-test-1", .success(response))

        let profileHome = root.appending(path: "profiles/p1")
        try FileManager.default.createDirectory(at: profileHome, withIntermediateDirectories: true)
        let authJSON = #"{"tokens":{"access_token":"fake-token","account_id":"acct-test-1"}}"#
        try authJSON.data(using: .utf8)!.write(to: profileHome.appending(path: "auth.json"))

        let profile = AccountProfile(id: UUID(), displayName: "Test", email: nil, accountID: "acct-test-1", createdAt: Date())
        let service = UsageStatsService(store: statsStore, transport: transport)

        // Sync twice
        _ = await service.sync(accounts: [(profile, profileHome)])
        let stored1 = try await statsStore.load()
        _ = await service.sync(accounts: [(profile, profileHome)])
        let stored2 = try await statsStore.load()

        // Totals must be identical — replacement, not accumulation
        #expect(stored1.accounts["acct-test-1"]?.dailyBuckets.count == stored2.accounts["acct-test-1"]?.dailyBuckets.count)
        let total1 = stored1.accounts["acct-test-1"]?.dailyBuckets.reduce(0) { $0 + $1.tokens }
        let total2 = stored2.accounts["acct-test-1"]?.dailyBuckets.reduce(0) { $0 + $1.tokens }
        #expect(total1 == total2)
    }

    @Test func syncIdempotency_valueChanges_usesNewValue() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "usage-sync-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let statsStore = UsageStatsStore(baseURL: root)
        let transport = StubTransport()

        let response1JSON = """
        {"stats":{"daily_usage_buckets":[{"start_date":"2026-11-01","tokens":100}]},"metadata":{}}
        """.data(using: .utf8)!
        let response2JSON = """
        {"stats":{"daily_usage_buckets":[{"start_date":"2026-11-01","tokens":999}]},"metadata":{}}
        """.data(using: .utf8)!

        let profileHome = root.appending(path: "profiles/p1")
        try FileManager.default.createDirectory(at: profileHome, withIntermediateDirectories: true)
        try #"{"tokens":{"access_token":"fake-token","account_id":"acct-test-1"}}"#
            .data(using: .utf8)!.write(to: profileHome.appending(path: "auth.json"))

        let profile = AccountProfile(id: UUID(), displayName: "Test", email: nil, accountID: "acct-test-1", createdAt: Date())
        let service = UsageStatsService(store: statsStore, transport: transport)

        await transport.setResponse("acct-test-1", .success(try decodeResponse(response1JSON)))
        _ = await service.sync(accounts: [(profile, profileHome)])

        await transport.setResponse("acct-test-1", .success(try decodeResponse(response2JSON)))
        _ = await service.sync(accounts: [(profile, profileHome)])

        let stored = try await statsStore.load()
        #expect(stored.accounts["acct-test-1"]?.dailyBuckets.first?.tokens == 999)
    }
}

// MARK: - Multi-account Aggregation

@Suite struct UsageStatsAggregationTests {
    @Test func twoAccountsMergedCorrectly() {
        let stats1 = AccountUsageStats(
            accountID: "acct-test-1",
            dailyBuckets: [
                DayBucket(dateLabel: "2026-11-01", tokens: 100),
                DayBucket(dateLabel: "2026-11-02", tokens: 200),
            ]
        )
        let stats2 = AccountUsageStats(
            accountID: "acct-test-2",
            dailyBuckets: [
                DayBucket(dateLabel: "2026-11-01", tokens: 50),
                DayBucket(dateLabel: "2026-11-03", tokens: 300),
            ]
        )

        let overview = UsageStatsAggregation.overview(
            accounts: ["acct-test-1": stats1, "acct-test-2": stats2],
            syncStatuses: ["acct-test-1": .synced(fetchedAt: Date()), "acct-test-2": .synced(fetchedAt: Date())],
            displayNames: ["acct-test-1": "Account 1", "acct-test-2": "Account 2"],
            range: .custom(startLabel: "2026-11-01", endLabel: "2026-11-03"),
            timeZone: utcTZ,
            totalAccountCount: 2
        )

        #expect(overview.totalTokens == 650) // 100+50+200+300
        #expect(overview.dailySeries.count == 3)
        #expect(overview.peakDay?.dateLabel == "2026-11-03")
        #expect(overview.peakDay?.tokens == 300)

        // Proportions sum to 1
        let proportionSum = overview.accountBreakdown.reduce(0.0) { $0 + $1.proportion }
        #expect(abs(proportionSum - 1.0) < 0.001)

        #expect(overview.syncedCount == 2)
        #expect(!overview.isPartial)
    }

    @Test func partialSync_neverSyncedExcluded() {
        let stats1 = AccountUsageStats(
            accountID: "acct-test-1",
            dailyBuckets: [DayBucket(dateLabel: "2026-11-01", tokens: 500)]
        )
        let stats2 = AccountUsageStats(
            accountID: "acct-test-2",
            dailyBuckets: [DayBucket(dateLabel: "2026-11-01", tokens: 200)]
        )

        let overview = UsageStatsAggregation.overview(
            accounts: ["acct-test-1": stats1, "acct-test-2": stats2],
            syncStatuses: [
                "acct-test-1": .synced(fetchedAt: Date()),
                "acct-test-2": .synced(fetchedAt: Date()),
                "acct-test-3": .neverSynced,
            ],
            displayNames: ["acct-test-1": "A1", "acct-test-2": "A2", "acct-test-3": "A3"],
            range: .custom(startLabel: "2026-11-01", endLabel: "2026-11-01"),
            timeZone: utcTZ,
            totalAccountCount: 3
        )

        #expect(overview.totalTokens == 700) // only synced accounts
        #expect(overview.syncedCount == 2)
        #expect(overview.totalAccountCount == 3)
        #expect(overview.isPartial)
    }

    @Test func staleAccountIncludedWithStaleFlag() {
        let stats = AccountUsageStats(
            accountID: "acct-test-1",
            dailyBuckets: [DayBucket(dateLabel: "2026-11-01", tokens: 100)]
        )

        let overview = UsageStatsAggregation.overview(
            accounts: ["acct-test-1": stats],
            syncStatuses: ["acct-test-1": .stale(fetchedAt: Date(), reason: "timeout")],
            displayNames: ["acct-test-1": "A1"],
            range: .custom(startLabel: "2026-11-01", endLabel: "2026-11-01"),
            timeZone: utcTZ,
            totalAccountCount: 1
        )

        #expect(overview.totalTokens == 100) // stale data still counted
        #expect(overview.syncedCount == 1)
    }
}

// MARK: - Timezone Boundary Tests

@Suite struct UsageStatsTimezoneBoundaryTests {
    @Test func todayLabelDiffersAcrossTimezones() {
        // 2026-11-05T16:30:00Z → Shanghai 2026-11-06 00:30, UTC 2026-11-05
        let now = ISO8601DateFormatter().date(from: "2026-11-05T16:30:00Z")!

        let shanghaiToday = UsageStatsAggregation.todayLabel(timeZone: shanghaiTZ, now: now)
        let utcToday = UsageStatsAggregation.todayLabel(timeZone: utcTZ, now: now)

        #expect(shanghaiToday == "2026-11-06")
        #expect(utcToday == "2026-11-05")
    }

    @Test func lastDays_crossMonth() {
        // 7 days from 2026-10-30 → covers 2026-10-24 to 2026-10-30
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = utcTZ
        let now = formatter.date(from: "2026-10-30")!.addingTimeInterval(12 * 3600) // noon

        let labels = UsageStatsAggregation.dateLabelsForRange(.lastDays(7), timeZone: utcTZ, now: now)

        #expect(labels.count == 7)
        #expect(labels.contains("2026-10-30"))
        #expect(labels.contains("2026-10-29"))
        #expect(labels.contains("2026-10-28"))
        #expect(labels.contains("2026-10-27"))
        #expect(labels.contains("2026-10-26"))
        #expect(labels.contains("2026-10-25"))
        #expect(labels.contains("2026-10-24"))
    }
}

// MARK: - Missing Days Tests

@Suite struct UsageStatsMissingDaysTests {
    @Test func missingDaysNotInSeriesButInMissingList() {
        let stats = AccountUsageStats(
            accountID: "acct-test-1",
            dailyBuckets: [
                DayBucket(dateLabel: "2026-11-01", tokens: 100),
                DayBucket(dateLabel: "2026-11-03", tokens: 200),
            ]
        )

        let overview = UsageStatsAggregation.overview(
            accounts: ["acct-test-1": stats],
            syncStatuses: ["acct-test-1": .synced(fetchedAt: Date())],
            displayNames: ["acct-test-1": "Test"],
            range: .custom(startLabel: "2026-11-01", endLabel: "2026-11-03"),
            timeZone: utcTZ,
            totalAccountCount: 1
        )

        // Daily series should only contain days with data
        #expect(overview.dailySeries.count == 2)
        #expect(!overview.dailySeries.contains { $0.dateLabel == "2026-11-02" })

        // Missing dates should list the gap
        #expect(overview.missingDates.contains("2026-11-02"))
    }
}

// MARK: - CSV Tests

@Suite struct UsageStatsCSVTests {
    @Test func csvContainsHeaderAndRows() {
        let stats = AccountUsageStats(
            accountID: "acct-test-1",
            dailyBuckets: [
                DayBucket(dateLabel: "2026-11-01", tokens: 100),
                DayBucket(dateLabel: "2026-11-02", tokens: 200),
            ]
        )

        let csv = UsageStatsCSV.export(
            accounts: ["acct-test-1": stats],
            displayNames: ["acct-test-1": "Test User"],
            range: .custom(startLabel: "2026-11-01", endLabel: "2026-11-02"),
            timeZone: utcTZ
        )

        #expect(csv.contains("account_id,display_name,date,timezone,tokens_total"))
        #expect(csv.contains("acct-test-1"))
        #expect(csv.contains("Test User"))
        // UTC timezone may report as "UTC" or "GMT" depending on platform
        #expect(csv.contains("UTC") || csv.contains("GMT"))
        #expect(csv.contains("100"))
        #expect(csv.contains("200"))
    }

    @Test func csvDoesNotContainBearer() {
        let csv = UsageStatsCSV.export(
            accounts: [:],
            displayNames: [:],
            range: .today,
            timeZone: utcTZ
        )
        #expect(!csv.contains("Bearer"))
    }

    @Test func csvDoesNotContainEmailPatterns() {
        let stats = AccountUsageStats(
            accountID: "acct-test-1",
            dailyBuckets: [DayBucket(dateLabel: "2026-11-01", tokens: 50)]
        )
        let csv = UsageStatsCSV.export(
            accounts: ["acct-test-1": stats],
            displayNames: ["acct-test-1": "User"],
            range: .custom(startLabel: "2026-11-01", endLabel: "2026-11-01"),
            timeZone: utcTZ
        )
        #expect(!csv.contains("@"))
    }

    @Test func csvContainsTimezoneColumn() {
        let stats = AccountUsageStats(
            accountID: "acct-test-1",
            dailyBuckets: [DayBucket(dateLabel: "2026-11-01", tokens: 10)]
        )
        let csv = UsageStatsCSV.export(
            accounts: ["acct-test-1": stats],
            displayNames: ["acct-test-1": "U"],
            range: .custom(startLabel: "2026-11-01", endLabel: "2026-11-01"),
            timeZone: shanghaiTZ
        )
        #expect(csv.contains("Asia/Shanghai"))
    }
}

// MARK: - Error Mapping Tests

@Suite struct UsageStatsErrorMappingTests {
    @Test func http401MapsToAuthExpired() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "usage-err-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let statsStore = UsageStatsStore(baseURL: root)
        let transport = StubTransport()
        await transport.setResponse("acct-test-1", .failure(.authExpired))

        let profileHome = root.appending(path: "profiles/p1")
        try FileManager.default.createDirectory(at: profileHome, withIntermediateDirectories: true)
        try #"{"tokens":{"access_token":"fake-token","account_id":"acct-test-1"}}"#
            .data(using: .utf8)!.write(to: profileHome.appending(path: "auth.json"))

        let profile = AccountProfile(id: UUID(), displayName: "Test", email: nil, accountID: "acct-test-1", createdAt: Date())
        let service = UsageStatsService(store: statsStore, transport: transport)

        let results = await service.sync(accounts: [(profile, profileHome)])
        #expect(results.count == 1)
        if case .authExpired = results[0].status {} else {
            Issue.record("Expected authExpired, got \(results[0].status)")
        }
    }

    @Test func statsErrorMapsToUnavailable() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "usage-err-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let statsStore = UsageStatsStore(baseURL: root)
        let transport = StubTransport()
        let response = try decodeResponse(statsErrorPayloadJSON())
        await transport.setResponse("acct-test-1", .success(response))

        let profileHome = root.appending(path: "profiles/p1")
        try FileManager.default.createDirectory(at: profileHome, withIntermediateDirectories: true)
        try #"{"tokens":{"access_token":"fake-token","account_id":"acct-test-1"}}"#
            .data(using: .utf8)!.write(to: profileHome.appending(path: "auth.json"))

        let profile = AccountProfile(id: UUID(), displayName: "Test", email: nil, accountID: "acct-test-1", createdAt: Date())
        let service = UsageStatsService(store: statsStore, transport: transport)

        let results = await service.sync(accounts: [(profile, profileHome)])
        #expect(results.count == 1)
        if case .unavailable(let reason) = results[0].status {
            #expect(reason.contains("upstream_timeout"))
        } else {
            Issue.record("Expected unavailable, got \(results[0].status)")
        }
    }
}

// MARK: - Store Persistence Tests

@Suite struct UsageStatsStoreTests {
    @Test func roundTrip() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "usage-store-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let store = UsageStatsStore(baseURL: root)
        var stats = StoredUsageStats()
        stats.accounts["acct-test-1"] = AccountUsageStats(
            accountID: "acct-test-1",
            lifetimeTokens: 42,
            dailyBuckets: [DayBucket(dateLabel: "2026-11-01", tokens: 10)]
        )
        stats.syncStatuses["acct-test-1"] = .synced(fetchedAt: Date())
        try await store.save(stats)

        let loaded = try await store.load()
        #expect(loaded.accounts["acct-test-1"]?.lifetimeTokens == 42)
        #expect(loaded.accounts["acct-test-1"]?.dailyBuckets.count == 1)
    }

    @Test func emptyStoreReturnsEmpty() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "usage-store-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let store = UsageStatsStore(baseURL: root)
        let loaded = try await store.load()
        #expect(loaded.accounts.isEmpty)
    }
}

// MARK: - ProfileCredentialTokens Tests

@Suite struct ProfileCredentialTokensTests {
    @Test func readsAccessTokenAndAccountID() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "cred-test-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let authJSON = #"{"tokens":{"access_token":"test-token-value","account_id":"acct-test-1"}}"#
        try authJSON.data(using: .utf8)!.write(to: root.appending(path: "auth.json"))

        let tokens = try ProfileCredentialTokens.read(from: root)
        #expect(tokens.accessToken == "test-token-value")
        #expect(tokens.accountID == "acct-test-1")
    }

    @Test func throwsForMissingAuth() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "cred-test-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        #expect(throws: UsageStatsError.self) {
            try ProfileCredentialTokens.read(from: root)
        }
    }

    @Test func throwsForMalformedAuth() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "cred-test-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try "not-json".data(using: .utf8)!.write(to: root.appending(path: "auth.json"))

        #expect(throws: UsageStatsError.self) {
            try ProfileCredentialTokens.read(from: root)
        }
    }
}

@Suite struct YesterdayRangeTests {
    @Test func yesterdayUsesShanghaiCalendarAcrossYearBoundary() {
        let now = ISO8601DateFormatter().date(from: "2026-12-31T16:30:00Z")!
        #expect(UsageStatsAggregation.dateLabelsForRange(.yesterday, timeZone: shanghaiTZ, now: now) == ["2026-12-31"])
    }
    @Test func yesterdayExcludesTodayAndPreservesMissingVersusZero() {
        let now = ISO8601DateFormatter().date(from: "2026-11-01T05:00:00Z")!
        let stats = AccountUsageStats(accountID: "test", dailyBuckets: [DayBucket(dateLabel: "2026-10-31", tokens: 0), DayBucket(dateLabel: "2026-11-01", tokens: 999)])
        let result = UsageStatsAggregation.overview(accounts: ["test": stats], syncStatuses: ["test": .synced(fetchedAt: now)], displayNames: [:], range: .yesterday, timeZone: shanghaiTZ, now: now, totalAccountCount: 1)
        #expect(result.totalTokens == 0)
        #expect(result.dailySeries == [DayBucket(dateLabel: "2026-10-31", tokens: 0)])
        #expect(result.missingDates.isEmpty)
        let missing = UsageStatsAggregation.overview(accounts: [:], syncStatuses: [:], displayNames: [:], range: .yesterday, timeZone: shanghaiTZ, now: now, totalAccountCount: 1)
        #expect(missing.dailySeries.isEmpty)
        #expect(missing.missingDates == ["2026-10-31"])
    }
}
