import Foundation
import Testing
@testable import CodexAccountSwitcher

/// The development build must never reach the public forecast endpoint, including from
/// the startup poll, the 900-second timer and the popover's direct refresh.
@MainActor
struct ForecastNetworkGuardTests {
    @Test func guardStaysOffForProductionEnvironments() {
        #expect(!ForecastNetworkGuard.isDisabled(environment: [:]))
        #expect(!ForecastNetworkGuard.isDisabled(environment: ["OTHER": "1"]))
        #expect(!ForecastNetworkGuard.isDisabled(environment: [ForecastNetworkGuard.environmentKey: "0"]))
    }

    @Test(arguments: ["1", "true", "TRUE", "yes", " true "])
    func guardRecognizesTruthyOptInValues(value: String) {
        #expect(ForecastNetworkGuard.isDisabled(environment: [ForecastNetworkGuard.environmentKey: value]))
    }

    @Test(arguments: ["0", "false", "no", "", "off"])
    func guardIgnoresOtherValues(value: String) {
        #expect(!ForecastNetworkGuard.isDisabled(environment: [ForecastNetworkGuard.environmentKey: value]))
    }

    @Test func disabledFetchNeverBuildsARequest() async {
        var thrown: (any Error)?
        do {
            _ = try await TiboForecastModel.fetch(
                environment: [ForecastNetworkGuard.environmentKey: "1"]
            )
        } catch {
            thrown = error
        }
        let error = try? #require(thrown as? URLError)
        #expect(error?.code == .notConnectedToInternet)
        #expect(error?.localizedDescription.contains("disabled in this development build") == true)
    }

    @Test func guardedModelReportsFailureWithoutTouchingTheNetwork() async {
        let source = CallCounter()
        let model = TiboForecastModel(fetchForecast: {
            await source.record()
            throw ForecastNetworkGuard.disabledError
        })

        await model.refreshIfDue()
        #expect(model.forecast == nil)
        #expect(model.failureMessage == "Forecast networking is disabled in this development build")
        #expect(!model.isLoading)
        #expect(await source.calls == 1)
    }
}

private actor CallCounter {
    private(set) var calls = 0
    func record() { calls += 1 }
}
