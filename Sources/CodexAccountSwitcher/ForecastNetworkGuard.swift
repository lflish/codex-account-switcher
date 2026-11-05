import Foundation

/// Opt-in switch that keeps development copies of the app off the public forecast endpoint.
///
/// Production builds never set `SWITCHER_DISABLE_FORECAST_NETWORK`, so their behaviour is
/// unchanged. A development build sets it in `Info.plist` `LSEnvironment` and in its launcher.
enum ForecastNetworkGuard {
    static let environmentKey = "SWITCHER_DISABLE_FORECAST_NETWORK"

    static var isDisabled: Bool {
        isDisabled(environment: ProcessInfo.processInfo.environment)
    }

    static func isDisabled(environment: [String: String]) -> Bool {
        guard let value = environment[environmentKey] else { return false }
        switch value.trimmingCharacters(in: .whitespaces).lowercased() {
        case "1", "true", "yes": return true
        default: return false
        }
    }

    static var disabledError: any Error {
        URLError(.notConnectedToInternet, userInfo: [
            NSLocalizedDescriptionKey: "Forecast networking is disabled in this development build",
        ])
    }
}
