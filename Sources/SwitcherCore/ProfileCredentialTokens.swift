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

    // Only used to order two local credential files for an already matched account.
    static func preferSaved(_ saved: Data, over incoming: Data) -> Bool {
        func timestamps(_ data: Data) -> (issued: TimeInterval, refreshed: Date)? {
            guard let auth = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let tokens = auth["tokens"] as? [String: Any], let token = tokens["access_token"] as? String,
                  let issued = SubscriptionSnapshotReader.decodePayload(token)?["iat"] as? TimeInterval
            else { return nil }
            return (issued, (auth["last_refresh"] as? String).flatMap(SubscriptionSnapshotReader.parseDate) ?? .distantPast)
        }
        guard let prior = timestamps(saved) else { return false }
        guard let next = timestamps(incoming) else { return true }
        return next <= prior
    }

    private struct AuthCredential: Decodable {
        let tokens: AuthTokens?
    }

    private struct AuthTokens: Decodable {
        let access_token: String?
        let account_id: String?
    }
}
