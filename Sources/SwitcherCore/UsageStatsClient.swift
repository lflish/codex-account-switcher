import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// MARK: - Error type

public enum UsageStatsError: LocalizedError, Equatable, Sendable {
    case authExpired
    case forbidden
    case httpStatus(Int)
    case unavailable(String)
    case decoding(String)
    case transport(String)
    case identityUnavailable

    public var errorDescription: String? {
        switch self {
        case .authExpired: "Authentication expired. Please sign in again."
        case .forbidden: "Access forbidden (possibly rate-limited). Try again later."
        case let .httpStatus(code): "HTTP \(code)"
        case let .unavailable(reason): "Usage stats unavailable: \(reason)"
        case let .decoding(reason): "Failed to decode usage stats: \(reason)"
        case let .transport(reason): "Network error: \(reason)"
        case .identityUnavailable: "Could not read account credentials."
        }
    }
}

// MARK: - Transport protocol (for test injection)

public protocol UsageStatsTransport: Sendable {
    func fetchProfileUsage(accessToken: String, accountID: String) async throws -> ProfileUsageResponse
}

// MARK: - URLSession implementation

public struct URLSessionUsageStatsTransport: UsageStatsTransport {
    private let session: URLSession
    private let baseURL: String

    public init(session: URLSession = .shared,
                baseURL: String = "https://chatgpt.com/backend-api/wham/profiles/me") {
        self.session = session
        self.baseURL = baseURL
    }

    public func fetchProfileUsage(accessToken: String, accountID: String) async throws -> ProfileUsageResponse {
        guard let url = URL(string: baseURL) else {
            throw UsageStatsError.transport("Invalid URL")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue(accountID, forHTTPHeaderField: "chatgpt-account-id")
        request.setValue("codex-cli/1.0.0", forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw UsageStatsError.transport(error.localizedDescription)
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw UsageStatsError.transport("Non-HTTP response")
        }

        switch httpResponse.statusCode {
        case 200:
            break
        case 401:
            throw UsageStatsError.authExpired
        case 403:
            throw UsageStatsError.forbidden
        default:
            throw UsageStatsError.httpStatus(httpResponse.statusCode)
        }

        do {
            return try JSONDecoder().decode(ProfileUsageResponse.self, from: data)
        } catch {
            throw UsageStatsError.decoding(error.localizedDescription)
        }
    }
}

// MARK: - Client that composes credential reading + transport

public struct ProfileUsageClient: Sendable {
    private let transport: any UsageStatsTransport

    public init(transport: any UsageStatsTransport = URLSessionUsageStatsTransport()) {
        self.transport = transport
    }

    /// Fetch usage stats for a single profile. Never prints tokens or full responses.
    public func fetchUsage(profileHome: URL) async throws -> (accountID: String, response: ProfileUsageResponse) {
        let credentials = try ProfileCredentialTokens.read(from: profileHome)

        let response = try await transport.fetchProfileUsage(
            accessToken: credentials.accessToken,
            accountID: credentials.accountID
        )

        // stats_error in metadata → unavailable
        if let statsError = response.metadata?.stats_error, !statsError.isEmpty {
            throw UsageStatsError.unavailable(statsError)
        }

        return (credentials.accountID, response)
    }
}
