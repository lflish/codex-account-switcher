import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct QuotaWindowSnapshot: Equatable, Sendable {
    public let remainingPercent: Int
    public let resetsAt: Date?

    public init(remainingPercent: Int, resetsAt: Date?) {
        self.remainingPercent = remainingPercent
        self.resetsAt = resetsAt
    }
}

public struct AccountQuotaSnapshot: Equatable, Sendable {
    public let fiveHour: QuotaWindowSnapshot?
    public let weekly: QuotaWindowSnapshot?
    public let fetchedAt: Date
    public let resetCreditsRemaining: Int?

    public init(fiveHour: QuotaWindowSnapshot?, weekly: QuotaWindowSnapshot?, fetchedAt: Date,
                resetCreditsRemaining: Int? = nil) {
        self.fiveHour = fiveHour
        self.weekly = weekly
        self.fetchedAt = fetchedAt
        self.resetCreditsRemaining = resetCreditsRemaining
    }
}

/// Display data excludes redemption identifiers so this reader cannot supply a consume operation.
public struct ResetCreditDisplay: Equatable, Sendable {
    public let status: String
    public let resetType: String
    public let expiresAt: Date?

    public init(status: String, resetType: String, expiresAt: Date?) {
        self.status = status
        self.resetType = resetType
        self.expiresAt = expiresAt
    }
}

public struct ResetCreditsSnapshot: Equatable, Sendable {
    public let availableCount: Int
    public let credits: [ResetCreditDisplay]
    public let fetchedAt: Date

    public init(availableCount: Int, credits: [ResetCreditDisplay], fetchedAt: Date) {
        self.availableCount = availableCount
        self.credits = credits
        self.fetchedAt = fetchedAt
    }
}

/// Errors deliberately carry no server body, token, account identifier, or URLSession error text.
public enum QuotaReadError: Error, Equatable, Sendable {
    case authExpired, forbidden, rateLimited, identityUnavailable, transport, malformedResponse
    case httpStatus(Int)
}

public protocol QuotaTransport: Sendable {
    func fetchQuota(accessToken: String, accountID: String) async throws -> AccountQuotaSnapshot
}

public protocol ResetCreditsTransport: Sendable {
    func fetchResetCredits(accessToken: String, accountID: String) async throws -> ResetCreditsSnapshot
}

private final class QuotaRedirectPolicy: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest) async -> URLRequest? { nil }
}

/// Uses existing access credentials only. Never starts a CLI, refreshes OAuth, or writes auth files.
public struct URLSessionQuotaTransport: QuotaTransport, ResetCreditsTransport {
    private let session: URLSession

    public init(session: URLSession? = nil) {
        if let session {
            self.session = session
        } else {
            let config = URLSessionConfiguration.ephemeral
            config.urlCache = nil
            config.httpCookieStorage = nil
            config.urlCredentialStorage = nil
            config.requestCachePolicy = .reloadIgnoringLocalCacheData
            config.timeoutIntervalForRequest = 20
            self.session = URLSession(configuration: config, delegate: QuotaRedirectPolicy(), delegateQueue: nil)
        }
    }

    public func fetchQuota(accessToken: String, accountID: String) async throws -> AccountQuotaSnapshot {
        let data = try await get(path: "usage", accessToken: accessToken, accountID: accountID)
        guard let payload = try? JSONDecoder().decode(Payload.self, from: data) else {
            throw QuotaReadError.malformedResponse
        }
        let windows = [payload.rate_limit?.primary_window, payload.rate_limit?.secondary_window].compactMap { $0 }
        // Duration, rather than primary/secondary position, identifies the quota window.
        let five = windows.first { $0.limit_window_seconds == 18_000 }
        let weekly = windows.filter { (6 * 86_400)...(8 * 86_400) ~= $0.limit_window_seconds }
            .max { $0.limit_window_seconds < $1.limit_window_seconds }
        return AccountQuotaSnapshot(fiveHour: five?.snapshot, weekly: weekly?.snapshot, fetchedAt: Date(),
                                    resetCreditsRemaining: payload.rate_limit_reset_credits?.available_count.flatMap { $0 >= 0 ? $0 : nil })
    }

    public func fetchResetCredits(accessToken: String, accountID: String) async throws -> ResetCreditsSnapshot {
        let data = try await get(path: "rate-limit-reset-credits", accessToken: accessToken, accountID: accountID)
        guard let payload = try? JSONDecoder().decode(CreditsPayload.self, from: data),
              payload.available_count >= 0 else { throw QuotaReadError.malformedResponse }
        let credits = try payload.credits.map { credit in
            let expiry: Date?
            if let text = credit.expires_at {
                guard let parsed = SubscriptionSnapshotReader.parseDate(text) else { throw QuotaReadError.malformedResponse }
                expiry = parsed
            } else { expiry = nil }
            // The HTTP backend uses snake_case; the display model follows the app-server spelling.
            // Normalize only this known value so unknown reset products never become Codex cards.
            let resetType = credit.reset_type == "codex_rate_limits" ? "codexRateLimits" : credit.reset_type
            return ResetCreditDisplay(status: credit.status, resetType: resetType, expiresAt: expiry)
        }
        return ResetCreditsSnapshot(availableCount: payload.available_count, credits: credits, fetchedAt: Date())
    }

    // Called only with these two fixed read endpoints; no reset or redemption path exists here.
    private func get(path: String, accessToken: String, accountID: String) async throws -> Data {
        let url = URL(string: "https://chatgpt.com/backend-api/wham/\(path)")!
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue(accountID, forHTTPHeaderField: "ChatGPT-Account-Id")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("codex-cli/1.0.0", forHTTPHeaderField: "User-Agent")
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw QuotaReadError.transport
        }
        guard let response = response as? HTTPURLResponse else { throw QuotaReadError.transport }
        switch response.statusCode {
        case 200: break
        case 401: throw QuotaReadError.authExpired
        case 403: throw QuotaReadError.forbidden
        case 429: throw QuotaReadError.rateLimited
        default: throw QuotaReadError.httpStatus(response.statusCode)
        }
        return data
    }

    private struct Payload: Decodable {
        let rate_limit: Limit?
        let rate_limit_reset_credits: CreditsSummary?
    }
    private struct CreditsSummary: Decodable {
        let available_count: Int?
    }
    private struct CreditsPayload: Decodable {
        let available_count: Int
        let credits: [Credit]
    }
    private struct Credit: Decodable {
        let status: String
        let reset_type: String
        let expires_at: String?
    }
    private struct Limit: Decodable {
        let primary_window: Window?
        let secondary_window: Window?
    }
    private struct Window: Decodable {
        let used_percent: Double
        let limit_window_seconds: Int
        let reset_at: Double?

        var snapshot: QuotaWindowSnapshot {
            QuotaWindowSnapshot(
                remainingPercent: Int(min(100, max(0, (100 - used_percent).rounded()))),
                resetsAt: reset_at.flatMap { $0 > 0 && $0.isFinite ? Date(timeIntervalSince1970: $0) : nil }
            )
        }
    }
}

public struct ProfileQuotaClient: Sendable {
    private let transport: any QuotaTransport
    private let resetCreditsTransport: (any ResetCreditsTransport)?

    public init(transport: any QuotaTransport = URLSessionQuotaTransport(),
                resetCreditsTransport: (any ResetCreditsTransport)? = nil) {
        self.transport = transport
        self.resetCreditsTransport = resetCreditsTransport ?? (transport as? any ResetCreditsTransport)
    }

    public func fetchQuota(profileHome: URL, expectedAccountID: String) async throws -> AccountQuotaSnapshot {
        let credentials = try credentials(profileHome: profileHome, expectedAccountID: expectedAccountID)
        return try await transport.fetchQuota(accessToken: credentials.accessToken, accountID: credentials.accountID)
    }

    public func fetchResetCredits(profileHome: URL, expectedAccountID: String) async throws -> ResetCreditsSnapshot {
        let credentials = try credentials(profileHome: profileHome, expectedAccountID: expectedAccountID)
        guard let resetCreditsTransport else { throw QuotaReadError.transport }
        return try await resetCreditsTransport.fetchResetCredits(accessToken: credentials.accessToken, accountID: credentials.accountID)
    }

    private func credentials(profileHome: URL, expectedAccountID: String) throws -> ProfileCredentialTokens {
        let credentials: ProfileCredentialTokens
        do { credentials = try ProfileCredentialTokens.read(from: profileHome) }
        catch { throw QuotaReadError.identityUnavailable }
        guard !expectedAccountID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              credentials.accountID == expectedAccountID else { throw QuotaReadError.identityUnavailable }
        return credentials
    }
}
