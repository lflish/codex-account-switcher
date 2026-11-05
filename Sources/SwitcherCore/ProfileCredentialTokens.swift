import Foundation

/// Reads access_token and account_id from a profile's auth.json without exposing credential contents.
public struct ProfileCredentialTokens: Sendable {
    public let accessToken: String
    public let accountID: String

    public static func read(from profileHome: URL) throws -> ProfileCredentialTokens {
        let url = profileHome.appending(path: "auth.json")
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw UsageStatsError.identityUnavailable
        }
        do {
            let data = try Data(contentsOf: url)
            let credential = try JSONDecoder().decode(AuthCredential.self, from: data)
            guard let tokens = credential.tokens,
                  let accessToken = nonempty(tokens.access_token),
                  let accountID = nonempty(tokens.account_id) else {
                throw UsageStatsError.identityUnavailable
            }
            return ProfileCredentialTokens(accessToken: accessToken, accountID: accountID)
        } catch let error as UsageStatsError {
            throw error
        } catch {
            // Never leak credential contents in error messages
            throw UsageStatsError.identityUnavailable
        }
    }

    private static func nonempty(_ value: String?) -> String? {
        guard let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return value
    }

    private struct AuthCredential: Decodable {
        let tokens: AuthTokens?
    }

    private struct AuthTokens: Decodable {
        let access_token: String?
        let account_id: String?
    }
}
