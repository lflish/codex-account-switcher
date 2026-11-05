import SwitcherCore
import Combine
import Foundation
#if os(macOS)
import AppKit
import UniformTypeIdentifiers

@MainActor
final class UsageStatsModel: ObservableObject {
    @Published var accounts: [AccountProfile] = []
    @Published var selectedAccountID: String? // nil = all accounts
    @Published var dateRange: UsageStatsDateRange = .lastDays(7)
    @Published var customStart: Date = Calendar.current.date(byAdding: .day, value: -7, to: Date()) ?? Date()
    @Published var customEnd: Date = Date()
    @Published var timeZoneIdentifier: String = "Asia/Shanghai"
    @Published var isLoading = false
    @Published var overview: UsageStatsOverview?
    @Published var singleOverview: SingleAccountOverview?
    @Published var syncResults: [AccountSyncResult] = []
    @Published var errorMessage: String?

    private let store: AccountStore
    private let statsStore: UsageStatsStore
    private let service: UsageStatsService
    private let language: AppLanguage

    init(store: AccountStore, accounts: [AccountProfile], language: AppLanguage,
         transport: (any UsageStatsTransport)? = nil) {
        self.store = store
        self.accounts = accounts
        self.language = language
        self.statsStore = UsageStatsStore(baseURL: store.baseURL)
        if let transport {
            self.service = UsageStatsService(store: statsStore, transport: transport)
        } else {
            self.service = UsageStatsService(store: statsStore)
        }
    }

    var selectedTimeZone: TimeZone {
        TimeZone(identifier: timeZoneIdentifier) ?? TimeZone(identifier: "Asia/Shanghai")!
    }

    var effectiveDateRange: UsageStatsDateRange {
        if case .custom = dateRange {
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy-MM-dd"
            formatter.timeZone = selectedTimeZone
            return .custom(
                startLabel: formatter.string(from: customStart),
                endLabel: formatter.string(from: customEnd)
            )
        }
        return dateRange
    }

    func text(_ key: String) -> String {
        L10n.string(key, language: language)
    }

    func format(_ key: String, _ args: String...) -> String {
        let template = text(key)
        switch args.count {
        case 1: return String(format: template, args[0])
        case 2: return String(format: template, args[0], args[1])
        default: return template
        }
    }

    func refresh() async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        var profilePairs: [(profile: AccountProfile, profileHome: URL)] = []
        profilePairs.reserveCapacity(accounts.count)
        for account in accounts {
            let home = await store.profileHome(id: account.id)
            profilePairs.append((profile: account, profileHome: home))
        }

        syncResults = await service.sync(accounts: profilePairs)
        await recompute()
    }

    func loadCached() async {
        await recompute()
    }

    private func recompute() async {
        do {
            let stored = try await service.load()
            let displayNames = buildDisplayNames(stored: stored)

            if let selectedID = selectedAccountID,
               let stats = stored.accounts[selectedID],
               let status = stored.syncStatuses[selectedID] {
                let name = displayNames[selectedID] ?? selectedID
                singleOverview = UsageStatsAggregation.singleAccountOverview(
                    accountID: selectedID, stats: stats, syncStatus: status,
                    displayName: name, range: effectiveDateRange,
                    timeZone: selectedTimeZone
                )
                overview = singleOverview?.overview
            } else {
                singleOverview = nil
                overview = UsageStatsAggregation.overview(
                    accounts: stored.accounts,
                    syncStatuses: stored.syncStatuses,
                    displayNames: displayNames,
                    range: effectiveDateRange,
                    timeZone: selectedTimeZone,
                    totalAccountCount: accounts.count
                )
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func buildDisplayNames(stored: StoredUsageStats) -> [String: String] {
        var names: [String: String] = [:]
        for account in accounts {
            if let accountID = account.accountID {
                names[accountID] = account.displayName
            }
        }
        return names
    }

    func exportCSV() async {
        do {
            let stored = try await service.load()
            let displayNames = buildDisplayNames(stored: stored)

            let filteredAccounts: [String: AccountUsageStats]
            if let selectedID = selectedAccountID, let stats = stored.accounts[selectedID] {
                filteredAccounts = [selectedID: stats]
            } else {
                filteredAccounts = stored.accounts
            }

            let csv = UsageStatsCSV.export(
                accounts: filteredAccounts,
                displayNames: displayNames,
                range: effectiveDateRange,
                timeZone: selectedTimeZone
            )

            let panel = NSSavePanel()
            panel.allowedContentTypes = [UTType(filenameExtension: "csv") ?? .commaSeparatedText]
            panel.nameFieldStringValue = "usage-stats.csv"
            guard panel.runModal() == .OK, let url = panel.url else { return }
            try csv.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

#endif
