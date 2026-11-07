import Foundation
import Testing
@testable import SwitcherCore

private final class QuotaProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let status = Int(request.value(forHTTPHeaderField: "X-Test-Status") ?? "200") ?? 200
        let fixture = request.value(forHTTPHeaderField: "X-Test-Fixture") ?? "both"
        let windows: String
        switch fixture {
        case "weekly-primary": windows = #""primary_window":{"used_percent":0,"limit_window_seconds":604800,"reset_at":1800000000}"#
        case "five-only": windows = #""primary_window":{"used_percent":30,"limit_window_seconds":18000}"#
        case "outside": windows = #""primary_window":{"used_percent":-10,"limit_window_seconds":18000},"secondary_window":{"used_percent":140,"limit_window_seconds":604800}"#
        case "missing": windows = #""primary_window":null,"secondary_window":null"#
        default: windows = #""primary_window":{"used_percent":15,"limit_window_seconds":18000,"reset_at":1800000000},"secondary_window":{"used_percent":60,"limit_window_seconds":604800,"reset_at":1800000100}"#
        }
        // Reject incorrect authentication/path locally. No request leaves this URLProtocol.
        let isCredits = request.url?.absoluteString == "https://chatgpt.com/backend-api/wham/rate-limit-reset-credits"
        let valid = request.httpMethod == "GET"
            && (request.url?.absoluteString == "https://chatgpt.com/backend-api/wham/usage" || isCredits)
            && request.value(forHTTPHeaderField: "Authorization") == "Bearer synthetic-access"
            && request.value(forHTTPHeaderField: "ChatGPT-Account-Id") == "synthetic-account"
        let response = HTTPURLResponse(url: request.url!, statusCode: valid ? status : 418,
                                       httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        let cards = fixture == "zero-cards" ? #"{"available_count":0,"credits":[]}"#
            : fixture == "bad-expiry" ? #"{"available_count":1,"credits":[{"status":"available","reset_type":"codex_rate_limits","expires_at":"not-a-date"}]}"#
            : #"{"available_count":2,"credits":[{"id":"synthetic-one","status":"available","reset_type":"codex_rate_limits","granted_at":"2026-11-01T00:00:00Z","expires_at":"2026-11-10T12:00:00Z"},{"id":"synthetic-two","status":"available","reset_type":"codex_rate_limits","granted_at":"2026-11-01T00:00:00Z","expires_at":null},{"id":"synthetic-old","status":"redeemed","reset_type":"future_product","granted_at":"2026-11-01T00:00:00Z","expires_at":"2026-11-08T12:00:00.123Z"}]}"#
        client?.urlProtocol(self, didLoad: Data((isCredits ? cards : "{\"rate_limit\":{\(windows)},\"rate_limit_reset_credits\":{\"available_count\":2}}").utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

private func quotaTransport(fixture: String = "both", status: Int = 200) -> URLSessionQuotaTransport {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [QuotaProtocol.self]
    config.httpAdditionalHeaders = ["X-Test-Fixture": fixture, "X-Test-Status": String(status)]
    return URLSessionQuotaTransport(session: URLSession(configuration: config))
}

@Suite struct QuotaClientTests {
    @Test func readsBothWindowsWithAuthenticatedReadOnlyRequest() async throws {
        let snapshot = try await quotaTransport().fetchQuota(accessToken: "synthetic-access", accountID: "synthetic-account")
        #expect(snapshot.fiveHour?.remainingPercent == 85)
        #expect(snapshot.weekly?.remainingPercent == 40)
        #expect(snapshot.fiveHour?.resetsAt == Date(timeIntervalSince1970: 1800000000))
        #expect(abs(snapshot.fetchedAt.timeIntervalSinceNow) < 5)
        #expect(snapshot.resetCreditsRemaining == 2)
    }

    @Test func readsResetCardsThroughSeparateReadOnlyEndpoint() async throws {
        let snapshot = try await quotaTransport().fetchResetCredits(accessToken: "synthetic-access", accountID: "synthetic-account")
        #expect(snapshot.availableCount == 2)
        #expect(snapshot.credits.count == 3)
        #expect(snapshot.credits[0].status == "available")
        #expect(snapshot.credits[0].resetType == "codexRateLimits")
        #expect(snapshot.credits[0].expiresAt == ISO8601DateFormatter().date(from: "2026-11-10T12:00:00Z"))
        #expect(snapshot.credits[1].expiresAt == nil)
        #expect(snapshot.credits[2].status == "redeemed")
        #expect(snapshot.credits[2].resetType == "future_product")
        #expect(snapshot.credits[2].expiresAt != nil)
        let empty = try await quotaTransport(fixture: "zero-cards").fetchResetCredits(accessToken: "synthetic-access", accountID: "synthetic-account")
        #expect(empty.availableCount == 0 && empty.credits.isEmpty)
    }

    @Test func cardReadUsesTypedErrorWithoutAConsumeRequest() async {
        await #expect(throws: QuotaReadError.authExpired) {
            _ = try await quotaTransport(status: 401).fetchResetCredits(accessToken: "synthetic-access", accountID: "synthetic-account")
        }
        await #expect(throws: QuotaReadError.malformedResponse) {
            _ = try await quotaTransport(fixture: "bad-expiry").fetchResetCredits(accessToken: "synthetic-access", accountID: "synthetic-account")
        }
    }

    @Test func classifiesWeeklyPrimaryAndPreservesZeroUsage() async throws {
        let snapshot = try await quotaTransport(fixture: "weekly-primary").fetchQuota(accessToken: "synthetic-access", accountID: "synthetic-account")
        #expect(snapshot.weekly?.remainingPercent == 100)
        #expect(snapshot.fiveHour == nil)
    }

    @Test func acceptsFiveHourWithoutWeeklyAndMissingReset() async throws {
        let snapshot = try await quotaTransport(fixture: "five-only").fetchQuota(accessToken: "synthetic-access", accountID: "synthetic-account")
        #expect(snapshot.fiveHour?.remainingPercent == 70)
        #expect(snapshot.fiveHour?.resetsAt == nil)
        #expect(snapshot.weekly == nil)
    }

    @Test func missingWindowsStayMissingAndPercentIsClamped() async throws {
        let missing = try await quotaTransport(fixture: "missing").fetchQuota(accessToken: "synthetic-access", accountID: "synthetic-account")
        #expect(missing.fiveHour == nil && missing.weekly == nil)
        let outside = try await quotaTransport(fixture: "outside").fetchQuota(accessToken: "synthetic-access", accountID: "synthetic-account")
        #expect(outside.fiveHour?.remainingPercent == 100)
        #expect(outside.weekly?.remainingPercent == 0)
    }

    @Test(arguments: [401, 403, 429, 500]) func exposesTypedStatusWithoutResponseContents(_ status: Int) async {
        let expected: QuotaReadError = switch status {
        case 401: .authExpired
        case 403: .forbidden
        case 429: .rateLimited
        default: .httpStatus(status)
        }
        await #expect(throws: expected) {
            _ = try await quotaTransport(status: status).fetchQuota(accessToken: "synthetic-access", accountID: "synthetic-account")
        }
    }

    @Test func profileReadDoesNotWriteCredentialsAndRejectsWrongIdentity() async throws {
        let home = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let file = home.appending(path: "auth.json")
        let bytes = Data(#"{"tokens":{"access_token":"synthetic-access","account_id":"synthetic-account","refresh_token":"must-not-be-used"}}"#.utf8)
        try bytes.write(to: file)
        let client = ProfileQuotaClient(transport: quotaTransport())
        await #expect(throws: QuotaReadError.identityUnavailable) {
            _ = try await client.fetchQuota(profileHome: home, expectedAccountID: "other-account")
        }
        _ = try await client.fetchQuota(profileHome: home, expectedAccountID: "synthetic-account")
        await #expect(throws: QuotaReadError.identityUnavailable) {
            _ = try await client.fetchResetCredits(profileHome: home, expectedAccountID: "other-account")
        }
        let cards = try await client.fetchResetCredits(profileHome: home, expectedAccountID: "synthetic-account")
        #expect(cards.availableCount == 2)
        #expect(try Data(contentsOf: file) == bytes)
        #expect(try FileManager.default.contentsOfDirectory(atPath: home.path) == ["auth.json"])
    }
}
